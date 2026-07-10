# Ritual sovereign agent — audited deploy kit

Audited snapshot of [zunmax/ritual-agent-deployment](https://github.com/zunmax/ritual-agent-deployment)
at commit `bf58374119265a44966360b2c8c2c93f4efb6331` (2026-06-29, "Fixed some bugs"), kept here so
future sessions run exactly the code that was reviewed instead of re-fetching a moving `main`.
Upstream docs are in [UPSTREAM-README.md](UPSTREAM-README.md); upstream is MIT licensed (see LICENSE).

## Audit summary (2026-07-01)

Every line of `run.sh` was reviewed and `run.ps1` was scanned. Verdict: **clean**.

- The private key is only ever passed to `cast wallet import`, which stores it encrypted in
  `~/.foundry/keystores`. It is never written to `.env` and never sent over the network.
- The only network destinations are official installers (`foundry.paradigm.xyz`, `astral.sh`,
  Foundry's GitHub releases, PyPI) and Ritual's own infrastructure
  (`rpc.ritualfoundation.org`, `explorer.ritualfoundation.org`).
- Value only moves into Ritual system contracts: `depositFor` on the RitualWallet
  (`0x532F...3948`) credits the agent's own on-chain wallet, and `configureFundAndStart` funds
  the agent harness. Nothing pays a third-party address.

Still: **only ever use a testnet burner wallet.** Treat any key that has been pasted into a
chat session or cloud sandbox as compromised for mainnet purposes forever.

## Local changes vs upstream

Two minimal patches to `run.sh` so it can run in a cloud sandbox with no terminal
(`/dev/tty` does not exist there, so the masked prompts would fail):

1. `KS_PASSWORD` is honored from the environment instead of always prompting.
2. `PRIVATE_KEY` is honored from the environment on first-run keystore import.

Both fall back to the original interactive prompts when the variables are unset.
Also `.env.example` now defaults to `DEPOSIT=5` — a wake costs ~0.5–1 RITUAL, so `DEPOSIT=1`
funds only a wake or two and the agent dies within minutes.

## Facts that shape the workflow

- **Dead agents cannot be revived.** An agent is alive only while the Ritual Scheduler still
  holds a scheduled wake for it. Once the deposit is exhausted and the last wake is consumed,
  nothing can re-arm it; a deposit into a dead agent is stuck (upstream's `topup` refuses for
  this reason, and Ritual's stop/restart/withdraw currently revert due to a proxy bug).
- **Live but low agent** → top it up: `bash run.sh topup <agent-address> <amount>`.
  Keep the agent wallet above ~0.5 RITUAL or it dies on the next wake it can't pay for.
- **Dead agent** → deploy fresh: `bash run.sh deploy` (deposit funds a new agent at a new SALT).

## Network access the sandbox needs

A Claude Code on the web environment must allow these domains (or full network access):

| Domain | Why |
|---|---|
| `rpc.ritualfoundation.org` | chain RPC — required for everything |
| `explorer.ritualfoundation.org` | indexer, used by `view` to find your agents |
| `foundry.paradigm.xyz` | foundryup installer |
| `astral.sh` | uv installer |
| `github.com`, `raw.githubusercontent.com`, `objects.githubusercontent.com` | foundry/uv binaries, uv-managed Python |
| `pypi.org`, `files.pythonhosted.org` | Python deps (usually allowed by default) |

Environment network policy is set on the environment in Claude Code on the web:
https://code.claude.com/docs/en/claude-code-on-the-web

## Runbook (for the Claude session executing this)

All commands run from this `ritual-agent/` directory. `cp .env.example .env` first and set a
unique `SALT` and the desired `PROMPT`/`DEPOSIT`.

**1. Status check — does NOT need the user's real key.**
Generate a throwaway keystore so the script's signer bootstrap passes, then list the user's
agents by their public deployer address:

```bash
cp .env.example .env
THROWAWAY=$(cast wallet new 2>/dev/null | awk '/Private key/{print $3}')   # after foundry is installed
PRIVATE_KEY="$THROWAWAY" KS_PASSWORD="scan-only" bash run.sh view <deployer-address>
```

(First run auto-installs foundry + uv; if `cast` isn't present yet, run the view command once —
it installs tools before importing the keystore.)
Show the user the LIVE/DEAD table before doing anything that spends funds.

**2a. If an agent is LIVE but low** — top up with the user's key:

```bash
PRIVATE_KEY="<user key>" KS_PASSWORD="<any password>" bash run.sh topup <agent-address> <amount>
```

**2b. If all agents are DEAD** — deploy fresh. Remove the throwaway keystore state first so the
real key is imported (`rm ~/.foundry/keystores/ritual-deployer` and delete the
`KEYSTORE_ACCOUNT`/`WALLET_ADDRESS` lines the script appended to `.env`), then:

```bash
PRIVATE_KEY="<user key>" KS_PASSWORD="<any password>" bash run.sh deploy
```

Notes:
- The deployer wallet must hold at least `DEPOSIT` RITUAL plus a little gas.
- If a live agent already exists at the configured `SALT`, the no-tty run answers "No" to the
  "deploy another?" prompt and exits — bump `SALT` in `.env` to a fresh label and rerun.
- Never write the private key into `.env` or any committed file; pass it inline via the
  environment as above, and never echo it back in chat.
