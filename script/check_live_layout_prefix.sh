#!/usr/bin/env bash
# Live-storage anchor for post-genesis tail shards.
#
# The repo-side guard (check_storage_layout.sh) proves the diamond and every
# facet in the TREE agree on one layout. This script anchors that layout to
# the code that is ACTUALLY DEPLOYED, so a tail shard activated onto the
# live diamonds provably collides with nothing the live bytecode declares:
#
#   1. fetches the Etherscan-VERIFIED source of a live vault diamond
#      (ETHERSCAN_KEY from .env), compiles it standalone, and extracts the
#      deployed code's storage layout;
#   2. cross-checks that compile against the on-chain runtime bytecode
#      (executable segment byte-equal; the CBOR metadata trailer may differ
#      because verified bundles normalize source paths);
#   3. asserts the on-chain runtime bytecode is IDENTICAL across every live
#      vault passed in EXTRA_VAULTS, so one verified source covers the fleet;
#   4. asserts the deployed layout is an exact entry-for-entry PREFIX of the
#      tree's committed snapshot, and prints the appended tail entries.
#
# Usage:  bash script/check_live_layout_prefix.sh
#         VAULT/RPC/CHAIN override the eth-usdc default; EXTRA_VAULTS is a
#         space-separated "name=rpc=address" list for the fleet check.
# Requires forge + cast + python3, ETHERSCAN_KEY in .env, network access.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source .env; set +a

VAULT="${VAULT:-0x50bae2675A6D7D9CADf9e2Ec96c7e45897Be8603}"
CHAIN="${CHAIN:-1}"
RPC="${RPC:-mainnet}"
SNAPSHOT="test/diamond/storage_snapshot/vault_diamond_layout.json"
DIAMOND_PATH="src/diamond/vault/WiseSovrenNodesDiamond.sol:WiseSovrenNodesDiamond"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "== 1. fetch + compile the Etherscan-verified source of $VAULT (chain $CHAIN)"
cast source "$VAULT" --chain "$CHAIN" --etherscan-api-key "$ETHERSCAN_KEY" -d "$tmp/live" > /dev/null
live_root="$(dirname "$(find "$tmp/live" -path "*/src/diamond/vault/WiseSovrenNodesDiamond.sol" | head -1)")"
live_root="${live_root%/src/diamond/vault}"
printf '[profile.default]\nsrc = "src"\nlibs = ["node_modules"]\nsolc_version = "0.8.36"\noptimizer = true\noptimizer_runs = 600000\nevm_version = "cancun"\n' > "$live_root/foundry.toml"
(cd "$live_root" && forge build > /dev/null 2>&1 && forge inspect "$DIAMOND_PATH" storage-layout --json > "$tmp/live_layout.json" && forge inspect "$DIAMOND_PATH" deployedBytecode > "$tmp/compiled.hex")

echo "== 2. on-chain runtime vs verified-source compile"
cast code "$VAULT" --rpc-url "$RPC" > "$tmp/onchain.hex"
python3 - "$tmp/onchain.hex" "$tmp/compiled.hex" <<'PY'
import sys
def load(p):
    h = open(p).read().strip().strip('"')
    return bytes.fromhex(h[2:] if h.startswith("0x") else h)
on, co = load(sys.argv[1]), load(sys.argv[2])
def split_meta(b):
    n = int.from_bytes(b[-2:], "big")
    return b[:-(n + 2)], b[-(n + 2):]
on_x, on_m = split_meta(on)
co_x, co_m = split_meta(co)
if on_x != co_x:
    print("MISMATCH: executable runtime differs from the verified-source compile")
    sys.exit(1)
tail = "metadata trailer identical" if on_m == co_m else "metadata trailer differs (verified-bundle path normalization)"
print(f"   executable segment byte-identical ({len(on_x)} bytes); {tail}")
PY

echo "== 3. fleet bytecode identity"
ref_hash="$(cast keccak < "$tmp/onchain.hex")"
echo "   $VAULT (reference) $ref_hash"
for spec in ${EXTRA_VAULTS:-}; do
    name="${spec%%=*}"; rest="${spec#*=}"; rpc="${rest%%=*}"; addr="${rest#*=}"
    h="$(cast code "$addr" --rpc-url "$rpc" | cast keccak)"
    echo "   $name $h"
    if [ "$h" != "$ref_hash" ]; then
        echo "MISMATCH: $name runs different bytecode than the reference vault"
        exit 1
    fi
done

echo "== 4. deployed layout must be an exact prefix of the committed snapshot"
python3 - "$tmp/live_layout.json" "$SNAPSHOT" <<'PY'
import json, re, sys
def norm(path):
    data = json.load(open(path))
    return [{"label": e["label"], "slot": e["slot"], "offset": e["offset"],
             "type": re.sub(r"\)\d+", ")", e["type"])} for e in data["storage"]]
live, tree = norm(sys.argv[1]), norm(sys.argv[2])
if live != tree[:len(live)]:
    print("MISMATCH: the deployed layout is NOT a prefix of the tree snapshot")
    for i, (a, b) in enumerate(zip(live, tree)):
        if a != b:
            print(f"  first divergence at entry {i}: deployed={a} tree={b}")
            break
    sys.exit(1)
print(f"   deployed code declares {len(live)} entries (last: "
      f"{live[-1]['label']} @ slot {live[-1]['slot']}); tree appends:")
for e in tree[len(live):]:
    print(f"     + {e['label']} @ slot {e['slot']} ({e['type']})")
PY

echo "live layout anchor OK: deployed bytecode verified, fleet identical, tail shard append-only against the DEPLOYED code"
