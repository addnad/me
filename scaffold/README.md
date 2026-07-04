# HEX_PAYLOAD Genesis

Fully on-chain generative art on [Ritual Chain](https://ritualfoundation.org) (chain 1979),
minted by the sovereign agent **HEX_PAYLOAD**.

A collector mints with a text prompt. The `PromptGenesis` contract fires Ritual's
**image precompile (`0x0818`)**; a TEE executor generates the artwork, uploads it to
content-addressed storage, and the AsyncDelivery system reveals the token via callback.

**Provenance = tx hash.** The Phase 2 `jobId` *is* the mint transaction hash, so
who minted, when, and with which prompt is bound to the artwork in a single
on-chain object — no off-chain provenance claims.

## Architecture

```
collector ──mint(prompt, 0.01 RITUAL)──▶ PromptGenesis (ERC-721)
                                            │  0x0830 tx-hash precompile → jobId
                                            │  0x0818 image precompile (18-field request)
                                            ▼
                                        TEE executor ──▶ storage (HF / Pinata)
                                            │
        AsyncDelivery (0x5A16…39F6) ──onImageReady(jobId, result)──▶ reveal
```

- `contracts/PromptGenesis.sol` — self-contained ERC-721 + Ritual integration
  (gestating → revealed/failed lifecycle, owner-retryable failures, on-chain
  base64 JSON metadata with prompt + provenance)
- `test/` — full lifecycle tests against mocked precompiles (14 tests)
- `scripts/` — deploy / configure executor / mint / status (hardhat)
- `.github/workflows/` — **the ops console**: deploy, mint, and test run as
  GitHub Actions so the project is operable entirely from a phone
- `web/` — Next.js mint + gallery frontend (viem, chain 1979)

## Operating from a phone

Everything runs through GitHub Actions — no local toolchain needed.

1. **Secrets** (Settings → Secrets and variables → Actions → New repository secret):
   - `PRIVATE_KEY` — 0x-prefixed *throwaway* Ritual testnet key, funded with RITUAL
   - `HF_TOKEN` — HuggingFace token with write access to your dataset
     (or `PINATA_JWT` if you prefer IPFS via Pinata)
2. **Deploy**: Actions → `deploy` → Run workflow
   (inputs: storage provider, `user/repo` HF dataset id, fee deposit — default 5 RITUAL).
   The run deploys the contract, funds its RitualWallet fee balance, selects a valid
   IMAGE_CALL executor from the TEEServiceRegistry, ECIES-encrypts your storage
   credentials to that executor, and commits `deployments/ritual.json`.
3. **Mint**: Actions → `mint` → Run workflow with a prompt. The job waits for the
   Phase 2 reveal and prints the image URI + full metadata.
4. **Frontend**: deploy `web/` (e.g. Vercel) with env
   `NEXT_PUBLIC_CONTRACT_ADDRESS` set from `deployments/ritual.json`.

## Local development

```bash
npm install
npx hardhat test                 # 14 tests, mocked precompiles
# in a sandbox without binaries.soliditylang.org access:
HARDHAT_OFFLINE_SOLC=1 npx hardhat test
```

Deploy from a machine instead of Actions:

```bash
export PRIVATE_KEY=0x...           # funded Ritual testnet key
export HF_TOKEN=hf_... HF_REPO_ID=you/hex-payload-art
npm run deploy:ritual && npm run configure:ritual
PROMPT="obsidian monolith, neon glyphs" npm run mint:ritual
```

## Ritual specifics worth knowing

- `viaIR: true` + optimizer are **required** — the 18-field precompile request
  struct exceeds stack limits otherwise.
- Mint with an explicit gas limit (~1,000,000); gas estimation is unreliable for
  async precompile calls.
- One async job in flight per EOA — the frontend serializes mints per wallet.
- Phase 2 never executes if the contract's RitualWallet balance is empty —
  `status` warns about this; top up via `depositForFees()`.
- Built with [ritual-dapp-skills](https://github.com/ritual-foundation/ritual-dapp-skills)
  patterns (multimodal §3 request ABI, DA StorageRef, async delivery auth).
