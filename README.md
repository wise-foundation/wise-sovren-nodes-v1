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
