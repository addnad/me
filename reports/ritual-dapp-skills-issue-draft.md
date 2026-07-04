# Issue draft for ritual-foundation/ritual-dapp-skills

> Test report produced 2026-07-04 against commit `57045a3` (tag 1.0.0).
> Everything below was verified by actually compiling the snippets (solc 0.8.24)
> and executing `scripts/pull_contracts.py` offline against a mock JSON-RPC server.
> Paste the section below as a GitHub issue on ritual-foundation/ritual-dapp-skills.

---

**Title:** Canonical skill snippets don't compile (LLM `abi.decode` tuple, multimodal `StorageRef`), toolchain configs missing `via_ir`, and `pull_contracts.py` selector/CLI bugs

## Summary

I test-ran the repo at `57045a3` (1.0.0): compiled every self-contained Solidity block from the skills with solc 0.8.24, ran `scripts/pull_contracts.py` against a mock JSON-RPC endpoint, and cross-checked constants across all 32 skills, both agents, the examples, and the templates. The shared constants (chain id 1979, precompile addresses, `ASYNC_DELIVERY` `0x5A16...39F6`, factory/registry/wallet addresses, request field counts — 26 persistent / 23 sovereign) are all consistent, both example consumer contracts compile clean, and the plugin manifests are valid. But there are two skill snippets that cannot compile at all, a toolchain-config inconsistency that breaks the skills' own canonical contracts, and a few bugs in `pull_contracts.py`.

## 1. `ritual-dapp-llm` consumer snippet is invalid Solidity (cannot compile)

`skills/ritual-dapp-llm/SKILL.md`, the `LLMConsumer` contract block (~line 925), decodes the response with:

```solidity
(hasError, completionData, modelMeta, errorMsg, ) =
    abi.decode(actualOutput, (bool, bytes, bytes, string, (string, string, string)));
```

A nested tuple literal is not a type name in Solidity — every solc version rejects this with `TypeError: Argument has to be a type name.` Since this is the canonical copy-paste contract for the highest-traffic precompile (0x0802), any agent following the skill produces a contract that fails to build.

**Verified fix** (compiles under solc 0.8.24 + viaIR):

```solidity
struct StorageRef { string platform; string path; string keyRef; }
...
(hasError, completionData, modelMeta, errorMsg, ) =
    abi.decode(actualOutput, (bool, bytes, bytes, string, StorageRef));
```

## 2. `ritual-dapp-multimodal` `MediaConsumer` uses an undefined `StorageRef` type

`skills/ritual-dapp-multimodal/SKILL.md`, the `MediaConsumer` block (~line 612) is presented as a complete file (SPDX header + pragma) but takes `StorageRef calldata outputStorageRef` parameters without ever defining the struct → `DeclarationError: Identifier not found or not unique.`

**Fix:** add the same three-string `StorageRef` struct definition to the snippet (the skill's own §3 documents the tuple as `(string,string,string)` — platform, path, keyRef).

Related, smaller instance: `skills/ritual-dapp-scheduler/SKILL.md`'s `ScheduledHTTPConsumer` block (~line 369) carries its own SPDX+pragma header (i.e. reads as a standalone file) but references `IScheduler`, which is only defined in the *previous* code block. Either inline the interface or drop the file header so it doesn't read as self-contained.

## 3. Recommended compiler configs cannot build the skills' own contracts

Verified with solc 0.8.24: both the `ritual-dapp-http` consumer (~line 430) and the (fixed) `ritual-dapp-llm` consumer fail with **`Stack too deep`** under default settings and compile only with `viaIR: true` + optimizer. The repo knows this — `ritual-meta-verification` even has a checklist item requiring `via_ir = true` in foundry.toml, and `ritual-dapp-multimodal` documents it — but the configs the build skills actually hand to agents don't comply:

| Source | solc | via_ir / viaIR |
|---|---|---|
| `templates/hardhat-starter/hardhat.config.tmpl` | 0.8.24 | ❌ absent |
| `skills/ritual-dapp-deploy` foundry.toml (~line 195) | **0.8.20** | ❌ absent |
| `skills/ritual-dapp-testing` foundry.toml (~line 503) | 0.8.24 | ❌ absent |
| `skills/ritual-meta-verification` checklist | — | **requires** `via_ir = true` |

Also note the deploy skill pins `solc = "0.8.20"` while 8 snippets, both examples, and the hardhat template use `pragma ^0.8.24` — forge fails with "requires different compiler version" for any project mixing them.

**Fix:**
- hardhat template: add `settings: { viaIR: true, optimizer: { enabled: true, runs: 200 } }`;
- deploy skill foundry.toml: bump to `solc = "0.8.24"` and add `via_ir = true`;
- testing skill foundry.toml: add `via_ir = true`;
- add a one-line via_ir note to `ritual-dapp-http` and `ritual-dapp-llm` (currently neither mentions it).

## 4. `scripts/pull_contracts.py` — selector extraction yields false positives

`extract_selectors()` scans for `0x63` (PUSH4) byte-by-byte but never skips the immediate data of *other* PUSH opcodes, so any `0x63` byte inside PUSH1–PUSH32 immediates (constants, addresses, Solidity metadata) is misread as a PUSH4 dispatch entry. Reproduced:

```
bytecode: 0x7f63deadbeef00…0063a9059cbb   (PUSH32 with 0x63 in its data + real PUSH4)
selectors found: ['a9059cbb', 'deadbeef']   ← 'deadbeef' is garbage
```

**Fix:** skip immediates for the whole PUSH family:

```python
while i < len(raw):
    op = raw[i]
    if op == 0x63 and i + 4 < len(raw):
        sel = raw[i + 1 : i + 5].hex()
        if sel not in ("00000000", "ffffffff"):
            selectors.add(sel)
    if 0x60 <= op <= 0x7F:      # PUSH1..PUSH32: skip immediate data
        i += (op - 0x5F) + 1
    else:
        i += 1
```

(Still heuristic — data sections aren't distinguished — but it removes the systematic false-positive class.)

## 5. `pull_contracts.py --block 0` is silently ignored

`main()` dispatches with `if args.block:`, so `--block 0` (genesis) is falsy and the script silently falls through to "pull all registry contracts" — the opposite of what was asked. **Fix:** `if args.block is not None:`.

## 6. Minor

- **`--rpc` override silently falls back to the public endpoint:** `main()` always appends `DEFAULT_RPC` to the endpoint list, so a user pointing at a private/dev node gets silent failover to `rpc.ritualfoundation.org` on any error — confusing when debugging a local chain, and contradicts the `--rpc` docstring. Suggest failing over only when `--rpc` was not given.
- **Dead fee vars in both examples:** `MAX_FEE_GWEI` / `PRIORITY_FEE_GWEI` are defined as configurable in `examples/*/run.sh` but never passed to any `cast send` — setting them does nothing. Either wire them up (`--gas-price`/`--priority-gas-price`) or delete them.
- **Inconsistent secrets JSON in `examples/sovereign-agent/run.sh`:** the OpenAI/Gemini/OpenRouter branches include `"LLM_PROVIDER"` in `SECRETS_JSON`, the Anthropic branch doesn't. If Anthropic-as-default is intentional, a comment would help; otherwise add `"LLM_PROVIDER": "anthropic"`.
- **Native symbol naming:** `templates/nextjs-starter/wagmi.config.tmpl` uses symbol `RITUAL` while the examples' comments denominate in `RIT` (`# 1 RIT`, `# 5 RIT`). Cosmetic, but agents copy these literally.

## What was tested and found clean

- Both example contracts compile (solc 0.8.24); persistent/sovereign helper ABI type lists match the documented 26/23-field layouts and the `poll-phase2`/`poll-dkms` decode paths look correct.
- `pull_contracts.py` registry/ad-hoc/summary flows run end-to-end (mock RPC); `.claude-plugin/*.json` and `examples/registry.json` are valid; all skill frontmatter names match directories; no broken intra-repo file references; all `json` code blocks in skills parse; chain id, RPC/explorer URLs, precompile map, and all shared contract addresses are consistent repo-wide.

*(Live-chain paths — explorer source fetch, 4byte resolution, actual deploys — weren't exercised: the test environment had no route to `rpc.ritualfoundation.org`.)*
