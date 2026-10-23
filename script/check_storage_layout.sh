#!/usr/bin/env bash
# Storage-collision guard for the WiseSovrenNodes diamond.
#
# Proves that the diamond entry contract and every concrete facet compile
# to one byte-identical storage layout (label/slot/offset/type per entry,
# compiler AST ids normalized away), and that the committed snapshot in
# test/diamond/storage_snapshot/ still matches the compiled diamond.
#
# Every facet is entered via DELEGATECALL into the diamond's storage, so
# a single facet disagreeing about any slot silently corrupts state;
# this check turns that class of bug into a loud CI failure with a
# unified diff. Run from anywhere; requires forge + python3.
set -euo pipefail
cd "$(dirname "$0")/.."

DIAMOND="src/diamond/vault/WiseSovrenNodesDiamond.sol:WiseSovrenNodesDiamond"
SNAPSHOT="test/diamond/storage_snapshot/vault_diamond_layout.json"
FACETS=(
    AdminFacet
    AutoCompoundFacet
    BridgeFacet
    BurnWiseFacet
    CashedInterestFacet
    CohortFlushPolicyFacet
    CohortRecorderFacet
    GraceAccumHookFacet
    GraceFreezeHookFacet
    InterestAdminFacet
    MoveFacet
    MulticallFacet
    Permit2ReferralFacet
    Permit2UserFacet
    ProxyFacet
    QueueAdminFacet
    QueueForecastFacet
    QueueFulfillFacet
    QueueJoinLeaveFacet
    QueueViewFacet
    ReferralFacet
    RescueFacet
    SweepFacet
    UserFacet
)

# Project each storage entry to {label, slot, offset, type} and strip the
# AST-id suffixes solc embeds in struct/contract type names (they churn
# across unrelated recompiles and would cause false drift).
normalize() {
    python3 -c '
import json, re, sys
data = json.load(sys.stdin)
for e in data["storage"]:
    print(json.dumps({
        "label": e["label"],
        "slot": e["slot"],
        "offset": e["offset"],
        "type": re.sub(r"\)\d+", ")", e["type"]),
    }, sort_keys=True))
'
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Facets live in facets/ when routed on the live diamonds and in
# facets/pending/ until their upgrade has actually been broadcast;
# resolve whichever exists.
facet_path() {
    if [ -f "src/diamond/vault/facets/$1.sol" ]; then
        echo "src/diamond/vault/facets/$1.sol:$1"
    else
        echo "src/diamond/vault/facets/pending/$1.sol:$1"
    fi
}

forge inspect "$DIAMOND" storage-layout --json > "$tmp/diamond.raw.json"
normalize < "$tmp/diamond.raw.json" > "$tmp/diamond.txt"

fail=0
for name in "${FACETS[@]}"; do
    forge inspect "$(facet_path "$name")" storage-layout --json \
        | normalize > "$tmp/$name.txt"
    if ! diff -u "$tmp/diamond.txt" "$tmp/$name.txt" > "$tmp/$name.diff"; then
        echo "STORAGE LAYOUT DRIFT: $name != WiseSovrenNodesDiamond"
        cat "$tmp/$name.diff"
        fail=1
    fi
done

normalize < "$SNAPSHOT" > "$tmp/snapshot.txt"
if ! diff -u "$tmp/snapshot.txt" "$tmp/diamond.txt" > "$tmp/snapshot.diff"; then
    echo "SNAPSHOT DRIFT: $SNAPSHOT no longer matches the compiled diamond."
    echo "If the layout change is intentional, regenerate with:"
    echo "  forge inspect $DIAMOND storage-layout --json > $SNAPSHOT"
    cat "$tmp/snapshot.diff"
    fail=1
fi

# Deploy-slim facets mirror only the slots they touch, padded into place
# with __gap*/__pad* fillers. Every pinned (non-filler) entry must sit at
# exactly the slot/offset/type the diamond assigns to the same label, or
# the facet reads garbage through the delegatecall.
PINNED_FACETS=(
    CohortBridgeHookFacet
    CohortFlushFacet
    CohortHookFacet
    CohortMoveHookFacet
)

for name in "${PINNED_FACETS[@]}"; do
    forge inspect "$(facet_path "$name")" storage-layout --json > "$tmp/$name.raw.json"
    normalize < "$tmp/$name.raw.json" > "$tmp/$name.pinned.txt"
    if ! python3 -c '
import json, sys
diamond = {}
for line in open(sys.argv[1]):
    e = json.loads(line)
    diamond[e["label"]] = (e["slot"], e["offset"], e["type"])
bad = 0
pinned = 0
for line in open(sys.argv[2]):
    e = json.loads(line)
    if e["label"].startswith("__gap") or e["label"].startswith("__pad"):
        continue
    pinned += 1
    want = diamond.get(e["label"])
    got = (e["slot"], e["offset"], e["type"])
    if want is None:
        print(f"  {e['\''label'\'']}: not present in the diamond layout")
        bad = 1
    elif want != got:
        print(f"  {e['\''label'\'']}: facet has slot={got[0]} offset={got[1]} type={got[2]}, diamond has slot={want[0]} offset={want[1]} type={want[2]}")
        bad = 1
if pinned == 0:
    print("  no pinned entries found (unexpected)")
    bad = 1
sys.exit(bad)
' "$tmp/diamond.txt" "$tmp/$name.pinned.txt"; then
        echo "PINNED SLOT MISMATCH: $name does not line up with the diamond layout."
        fail=1
    fi
done

# Byte-range proof that no storage byte has two owners: the diamond's
# own entries never overlap, a slim facet's entries (fillers included)
# never overlap each other, and every byte a slim facet's named entry
# occupies belongs in the diamond to that same label and nothing else.
pinned_raw=()
for name in "${PINNED_FACETS[@]}"; do
    pinned_raw+=("$tmp/$name.raw.json")
done
if ! python3 -c '
import json, sys

def ranges(path):
    data = json.load(open(path))
    types = data["types"] or {}
    out = []
    for e in data["storage"]:
        start = int(e["slot"]) * 32 + e["offset"]
        size = int(types[e["type"]]["numberOfBytes"])
        out.append((start, start + size, e["label"]))
    return sorted(out)

def overlaps(entries, where):
    bad = 0
    for (s1, e1, l1), (s2, e2, l2) in zip(entries, entries[1:]):
        if s2 < e1:
            print(f"  {where}: {l1} and {l2} share storage bytes {s2}..{min(e1, e2) - 1}")
            bad = 1
    return bad

diamond = ranges(sys.argv[1])
bad = overlaps(diamond, "diamond")
for path in sys.argv[2:]:
    name = path.rsplit("/", 1)[-1].replace(".raw.json", "")
    facet = ranges(path)
    bad |= overlaps(facet, name)
    for s, e, label in facet:
        if label.startswith("__gap") or label.startswith("__pad"):
            continue
        for ds, de, dl in diamond:
            if ds < e and s < de and dl != label:
                print(f"  {name}: {label} overlaps the diamond entry {dl}")
                bad = 1
sys.exit(bad)
' "$tmp/diamond.raw.json" "${pinned_raw[@]}"; then
    echo "STORAGE OVERLAP: a storage byte is claimed by two entries."
    fail=1
fi

# Transient storage is not part of the forge layout output, so the one
# transient variable is pinned by declaration: the declaration chain
# and the slim cohort base must each declare exactly that line.
transient_line="bool internal transient hookExecuting;"
chain_transient="$(grep -rh "transient" src/diamond/vault/declarations --include=*.sol | grep -v "^ *\*" | sed "s/^ *//")"
slim_transient="$(grep -h "transient" src/diamond/vault/facets/pending/CohortPinnedBase.sol | grep -v "^ *\*" | sed "s/^ *//")"
if [ "$chain_transient" != "$transient_line" ] || [ "$slim_transient" != "$transient_line" ]; then
    echo "TRANSIENT DRIFT: the chain and CohortPinnedBase must each declare only: $transient_line"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "storage layout OK: diamond + ${#FACETS[@]} facets identical, ${#PINNED_FACETS[@]} slim facets pinned correctly, snapshot matches ($(wc -l < "$tmp/diamond.txt") entries)"
fi
exit "$fail"
