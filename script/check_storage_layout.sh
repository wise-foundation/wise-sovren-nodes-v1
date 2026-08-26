#!/usr/bin/env bash
# Storage-collision guard for the WiseSovrenNodes diamond.
#
# Proves that the diamond entry contract and every concrete facet compile
# to one byte-identical storage layout (label/slot/offset/type per entry,
# compiler AST ids normalized away), and that the committed snapshot in
# test/diamond/storage_snapshot/ still matches the compiled diamond.
#
# Every facet is entered via DELEGATECALL into the diamond's storage, so
# a single facet disagreeing about any slot silently corrupts state —
# this check turns that class of bug into a loud CI failure with a
# unified diff. Run from anywhere; requires forge + python3.
set -euo pipefail
cd "$(dirname "$0")/.."

DIAMOND="src/diamond/vault/WiseSovrenNodesDiamond.sol:WiseSovrenNodesDiamond"
SNAPSHOT="test/diamond/storage_snapshot/vault_diamond_layout.json"
FACETS=(
    AdminFacet
    BridgeFacet
    BurnWiseFacet
    CashedInterestFacet
    GraceAccumHookFacet
    GraceFreezeHookFacet
    InterestAdminFacet
    MoveFacet
    MulticallFacet
    Permit2UserFacet
    ProxyFacet
    QueueAdminFacet
    QueueForecastFacet
    QueueFulfillFacet
    QueueJoinLeaveFacet
    QueueViewFacet
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

forge inspect "$DIAMOND" storage-layout --json | normalize > "$tmp/diamond.txt"

fail=0
for name in "${FACETS[@]}"; do
    forge inspect "src/diamond/vault/facets/$name.sol:$name" storage-layout --json \
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

if [ "$fail" -eq 0 ]; then
    echo "storage layout OK: diamond + ${#FACETS[@]} facets identical, snapshot matches ($(wc -l < "$tmp/diamond.txt") entries)"
fi
exit "$fail"
