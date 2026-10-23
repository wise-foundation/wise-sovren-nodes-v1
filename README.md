# Wise Sovren Nodes

Solidity contracts for Wise Sovren Nodes, a USDC vault on Ethereum whose deposits finance
Sovren infrastructure nodes. Selector-routed diamond architecture with an on-chain exit
queue, per-holder interest accounting and cross-chain share bridging. Built on the
Wise Telecom Nodes vault codebase.

## Requirements

- [Foundry](https://getfoundry.sh) (forge, cast)
- Node.js 20+ and npm
- Python 3 (used by the storage layout check)
- Git

## Setup

```bash
git clone --recurse-submodules https://github.com/vonMangoldt/wise-sovren-nodes-v1.git
cd wise-sovren-nodes-v1
npm ci
```

If the repository was cloned without submodules, fetch them with
`git submodule update --init --recursive`.

The contracts pin solc 0.8.36. Recent Foundry releases resolve it automatically; if your
forge predates that compiler, install it once into the compiler cache:

```bash
version=0.8.36
url=https://binaries.soliditylang.org/linux-amd64/solc-linux-amd64-v0.8.36+commit.8a079791
sha=c8d35afdddc3cd2743ee88b8f25e0fecd16e2bdd5f2120f37e52cd9cc45ae0e6
dest="$HOME/.svm/$version/solc-$version"
mkdir -p "$(dirname "$dest")"
curl -sSfL "$url" -o "$dest"
echo "$sha  $dest" | sha256sum --check --strict
chmod +x "$dest"
```

## Build and test

```bash
forge build
```

```bash
forge test --no-match-path 'test/diamond/fork/*'
```

The excluded suites under `test/diamond/fork/` need a mainnet archive endpoint; everything
else runs offline. The storage layout check proves the diamond and every facet compile to
one identical storage layout, and that the committed snapshot still matches:

```bash
bash script/check_storage_layout.sh
```

## Fork tests

```bash
cp .env.example .env
```

Set `MAINNET_RPC_URL` in `.env`, then:

```bash
forge test --match-path 'test/diamond/fork/*'
```

## Coverage

```bash
forge coverage --no-match-path 'test/diamond/fork/*'
```

## Referral system

The vault joins the referral system shared with the WiseTelecomNodes vaults: one registry
per chain, one hub on Ethereum mainnet, one rate table and one payout pot, all deployed and
operated from the WiseTelecomNodes repository and recorded here in `config/registry.mainnet.json`
and `config/hub.mainnet.json`. The vault side lives in `src/diamond/vault/facets/pending/`
(the referral facets, the cohort engine, the flush transport), `src/diamond/shared/pending/`
and `src/diamond/vault/declarations/pending/` (the tail shards at slots 67 to 95), and ships
onto the live diamond through the selector timelock in two rounds. The registry round
puts its fourteen facets onchain first and records them in
`config/referral-round.<product>.<network>.json`; the propose step then routes the recorded
facets without deploying again:

```bash
VAULT_PRODUCT=usdc forge script script/diamond/UpgradeReferralRegistry.s.sol --sig "deployFacets()" --rpc-url mainnet
```

```bash
VAULT_PRODUCT=usdc forge script script/diamond/UpgradeReferralRegistry.s.sol --sig "propose()" --rpc-url mainnet
```

```bash
VAULT_PRODUCT=usdc forge script script/diamond/UpgradeCohortFlush.s.sol --sig "propose()" --rpc-url mainnet
```

Each script documents its phases (propose, execute after three days, the pointer, the arm,
the legacy bridge pair retirement). The registry and hub sources under `test/referral/` are
compiled here only so the vault suites run against the real shared code; they are never
deployed from this repository. `test/diamond/fork/WiseSovrenNodesReferralUpgradeFork.t.sol`
rehearses the whole join on a mainnet fork.
