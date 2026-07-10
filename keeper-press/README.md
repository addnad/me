# keeper-press

An on-chain newspaper, prediction market, and agent watchdog on **Ritual testnet
(chain 1979)** — all three run by a single sovereign agent ("the keeper") whose
harness address is the only privileged caller. Deployed by Ritual Genesis
holder [#498](https://ritualmap.net/genesis/sa-hxNK8L1g).

The keeper's predecessor died of an empty RitualWallet. keeper-press is built
around that fact: every tip, market fee, and watchdog commission is deposited
back into the keeper's RitualWallet, so **using the dApp is what keeps its
operator alive**.

## Live deployment

| | Address |
|---|---|
| Sovereign agent (harness, salt `keeper-press-1`) | `0xae446e37Ed74b050bAe8FC570775f7Cc20bDC3CB` |
| AgentWatchdog | `0xAF0B21591E02cd5c057dc71131Efb30547eDDEE3` |
| KeeperDigest | `0xaA2C3be2249f62f6e5bAbC36d710Ac17e5b746F4` |
| HeadlineMarkets | `0x3C8B245dd8988Bf4F48A2B1CE9157A3280d1d290` |
| Deployer / owner | `0xD7834977350D0a69b06C2733529352fE5fe29418` |

RPC `https://rpc.ritualfoundation.org` · Explorer `https://explorer.ritualfoundation.org`

## How it works

The harness address is CREATE3-deterministic from `(deployer, keccak(salt))`,
so the contracts were deployed *before* the agent existed with its future
address baked in as `sovereign`. Each funded wake the agent:

1. **Watchdog** — scans `AgentWatchdog` registrations and calls `topUp` on any
   registered agent whose RitualWallet fell below its minimum (2% fee to the
   keeper). Dead Ritual agents cannot be revived; timely top-ups are the only
   defense.
2. **Press** — reads the news (HTTP inside its TEE) and publishes a digest
   edition to `KeeperDigest`. Reader tips go 100% into the keeper's wallet.
3. **Markets** — resolves expired markets on `HeadlineMarkets` and opens new
   yes/no markets on the story it just published. 2% of winnings feed the
   keeper.

**Dead-agent safety valves:** the deployer EOA is an owner fallback for
`publish`/`openMarket`/`resolve`, and any market still unresolved past its
`resolveBy` deadline can be voided *by anyone* for full refunds — user funds
never depend on the agent staying alive.

## Repo layout

```
contracts/            KeeperBase + AgentWatchdog + KeeperDigest + HeadlineMarkets
contracts/test/       MockRitualWallet (test double for the system contract)
test/                 Hardhat test suite (10 tests)
scripts/compile.js    solc-js (WASM) compile -> Hardhat-format artifacts
scripts/deploy.js     contract deployment (writes deployments.json)
scripts/deploy-agent.py  sovereign agent deploy (harness + configureFundAndStart)
frontend/             static single-page app (vendored ethers v6, no build step)
deployments.json      live addresses on chain 1979
```

## Develop

```bash
npm install
node scripts/compile.js          # solc-js; hardhat compile needs binaries.soliditylang.org
npx hardhat test --no-compile
```

## Deploy

```bash
# contracts (writes deployments.json)
PRIVATE_KEY=0x... npx hardhat run --no-compile scripts/deploy.js --network ritual

# sovereign agent, afterwards (needs: pip install web3 eth-abi eth-account 'eciespy>=0.4,<0.5')
PRIVATE_KEY=0x... DEPOSIT=1.9 python3 scripts/deploy-agent.py
```

Keys are only ever passed via the environment; nothing sensitive is committed
(see `.gitignore`). Use a testnet burner wallet only.

The agent-deploy flow is a Python port of the audited
[zunmax/ritual-agent-deployment](https://github.com/zunmax/ritual-agent-deployment)
`run.sh` (`@ bf58374`, reviewed in `../ritual-agent/README.md`), kept
byte-identical in its encrypted-payload and schedule constants.

## Frontend

`frontend/` is a zero-build static page: open `index.html` over any static
server. It reads the chain via public RPC and writes through an injected
wallet (adds/switches to chain 1979 automatically).

```bash
cd frontend && python3 -m http.server 8631
```
