#!/usr/bin/env bash
# Deterministic explorer verification for EVERY contract of a deploy:
#   - the 19 diamond facets (top-level CREATEs)               [ADDED]
#   - the diamond   (internal CREATE3 creation by the shim)
#   - the shim      (internal CREATE3 creation by CreateX)
#
# Facets are top-level CREATEs and are normally covered by forge's
# in-run --verify, but that silently misses on --skip-simulation chains
# on some chains, and on lagging explorers, so this backfill re-submits every
# facet from the deploy broadcast by exact (name, address). Idempotent:
# an already-verified contract just reports "already verified".
#
#   ./script/vault/verify_all.sh <product> <network> [deploy_script]
#
# deploy_script defaults to the deterministic deploy script on every
# network (the testnet rehearsal runs the production path); override as
# arg 3 if needed.
# Uses --guess-constructor-args for the diamond/shim (forge reconstructs
# args from the on-chain creation code); facets take no constructor args.
# If guessing fails on a given explorer, fall back to passing them
# explicitly:
#   forge verify-contract <addr> <contract> --constructor-args $(cast abi-encode "constructor(...)" ...)
# Run inside WSL with foundry on PATH and ETHERSCAN_KEY set.
set -euo pipefail
cd "$(dirname "$0")/../.."

PRODUCT="${1:?usage: verify_all.sh <product> <network> [deploy_script]}"
NET="${2:?network required}"

SUFFIX=""
case "$NET" in
  sepolia)
    SUFFIX=".testnet"
    ;;
esac

DEPLOY_SCRIPT="${3:-DeployVaultDeterministic.s.sol}"

MESH="config/vault_mesh.${PRODUCT}${SUFFIX}.json"
CANON=$(python3 -c "import json; print(json.load(open('$MESH'))['canonical'])")

# Blockscout-backed chains need an explicit verifier; the Etherscan
# family is the default. Add a case here when adding such a chain.
VERIFIER_ARGS=""

# The 19 diamond facets, in deploy order. Every one lives at
# src/diamond/vault/facets/<Name>.sol and takes no constructor args
# (placeholder init params are hard-coded inside the constructor).
FACET_NAMES="AdminFacet ProxyFacet UserFacet SweepFacet CashedInterestFacet \
BurnWiseFacet MoveFacet BridgeFacet Permit2UserFacet MulticallFacet \
QueueAdminFacet QueueJoinLeaveFacet QueueFulfillFacet QueueViewFacet \
QueueForecastFacet InterestAdminFacet RescueFacet \
GraceFreezeHookFacet GraceAccumHookFacet"

verify() {
  # verify <address> <contract-path:Name> [extra args...]
  local addr="$1"; local contract="$2"; shift 2
  forge verify-contract "$addr" "$contract" \
    --rpc-url "$NET" --compiler-version 0.8.36 --watch $VERIFIER_ARGS "$@" \
    || echo "!! verification submission failed for $contract @ $addr (continuing)"
}

echo "=== verifying diamond $CANON on $NET"
verify "$CANON" src/diamond/vault/WiseSovrenNodesDiamond.sol:WiseSovrenNodesDiamond --guess-constructor-args

SHIM=$(VAULT_PRODUCT="$PRODUCT" forge script script/vault/PredictCanonicalAddress.s.sol --rpc-url "$NET" 2>/dev/null \
  | awk '$1 == "shim" {print $2}')
echo "=== verifying shim $SHIM on $NET"
verify "$SHIM" script/diamond/WiseSovrenNodesBootstrap.sol:WiseSovrenNodesBootstrap --guess-constructor-args

CHAINID=$(cast chain-id --rpc-url "$NET")
RUN="broadcast/${DEPLOY_SCRIPT}/${CHAINID}/run-latest.json"

if [ ! -f "$RUN" ]; then
  echo "!! no deploy broadcast at $RUN"
  echo "!! facets NOT verified - run the deploy first, or pass the correct deploy script as arg 3"
  exit 1
fi

echo "=== verifying 19 facets from $RUN"
MISSING=0
for NAME in $FACET_NAMES; do
  ADDR=$(python3 -c "
import json,sys
j=json.load(open('$RUN'))
addr=''
for t in j.get('transactions',[]):
    if t.get('contractName')=='$NAME' and t.get('contractAddress'):
        addr=t['contractAddress']
        break
print(addr)")
  if [ -z "$ADDR" ]; then
    echo "!! $NAME NOT FOUND in broadcast - not verified"
    MISSING=$((MISSING+1))
    continue
  fi
  echo "--- $NAME @ $ADDR"
  verify "$ADDR" "src/diamond/vault/facets/${NAME}.sol:${NAME}"
done

if [ "$MISSING" -ne 0 ]; then
  echo "!! $MISSING facet(s) were missing from the broadcast - investigate before mainnet"
  exit 1
fi

echo "=== all facets + diamond + shim submitted for verification on $NET"
