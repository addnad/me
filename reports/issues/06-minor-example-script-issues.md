# Issue 6

**Title:** Minor: dead fee vars in example run.sh, silent `--rpc` failover, inconsistent secrets JSON, RIT/RITUAL symbol naming

**Body:**

Batch of small issues found while test-running commit `57045a3` (1.0.0). Filed together since each is a one-liner.

## 1. `MAX_FEE_GWEI` / `PRIORITY_FEE_GWEI` are dead variables

Both `examples/persistent-agent/run.sh` (lines 82–83) and `examples/sovereign-agent/run.sh` (lines 68–69) define them as user-configurable, but no `cast send` in either script ever uses them — setting them does nothing. Either wire them into the sends (`--gas-price` / `--priority-gas-price`) or remove them.

## 2. `pull_contracts.py --rpc` silently fails over to the public endpoint

`main()` always appends `DEFAULT_RPC` (`https://rpc.ritualfoundation.org`) to the endpoint list, even when the user passed an explicit `--rpc`. Pointing at a private/dev node therefore silently falls back to the public chain on any error — confusing when debugging a local chain, and it contradicts the "Use a specific RPC endpoint" docstring. Suggest only adding the default as failover when `--rpc` was not given.

## 3. Anthropic branch omits `LLM_PROVIDER` from secrets JSON

In `examples/sovereign-agent/run.sh` step 4, the OpenAI/Gemini/OpenRouter branches include `"LLM_PROVIDER": "..."` in `SECRETS_JSON`, but the Anthropic branch doesn't. If Anthropic-as-default is intentional on the executor side, a comment would prevent it looking like a bug; otherwise add `"LLM_PROVIDER": "anthropic"`.

## 4. Native currency symbol: `RITUAL` vs `RIT`

`templates/nextjs-starter/wagmi.config.tmpl` declares `nativeCurrency: { name: 'RITUAL', symbol: 'RITUAL' }` while the examples' comments denominate amounts in `RIT` (`# 1 RIT`, `# 5 RIT`, `# 100,000 RIT`). Cosmetic, but agents copy these literally into UIs.
