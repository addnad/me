# Issue 3

**Title:** Recommended compiler configs can't build the skills' own consumer contracts (`via_ir` missing; solc 0.8.20 vs `^0.8.24` pragma mismatch)

**Body:**

Tested against commit `57045a3` (1.0.0) with solc 0.8.24.

Both the `ritual-dapp-http` consumer contract (~line 430 of that SKILL.md) and the `ritual-dapp-llm` consumer fail with **`Stack too deep`** under default compiler settings, and compile only with `viaIR: true` + optimizer (verified both ways).

The repo itself knows this — `ritual-meta-verification` has a checklist item requiring `via_ir = true` in foundry.toml, and `ritual-dapp-multimodal` documents it (~line 992) — but the configs the build skills actually hand to agents don't comply:

| Source | solc | via_ir / viaIR |
|---|---|---|
| `templates/hardhat-starter/hardhat.config.tmpl` | 0.8.24 | absent |
| `skills/ritual-dapp-deploy/SKILL.md` foundry.toml (~line 195) | **0.8.20** | absent |
| `skills/ritual-dapp-testing/SKILL.md` foundry.toml (~line 503) | 0.8.24 | absent |
| `skills/ritual-meta-verification/SKILL.md` checklist | — | **requires** `via_ir = true` |

So a user or agent following `ritual-dapp-http`/`ritual-dapp-llm` together with the deploy or testing skill's foundry.toml — or the shipped hardhat starter — hits a compile failure, and neither the http nor the llm skill mentions via_ir.

Additionally, the deploy skill pins `solc = "0.8.20"` while 8 snippets, both `examples/` contracts, and the hardhat template use `pragma solidity ^0.8.24` — forge fails with "Source file requires different compiler version" for any project that mixes them.

## Suggested fix

- `templates/hardhat-starter/hardhat.config.tmpl`: replace `solidity: "0.8.24"` with
  ```ts
  solidity: {
    version: "0.8.24",
    settings: { viaIR: true, optimizer: { enabled: true, runs: 200 } },
  },
  ```
- `ritual-dapp-deploy` foundry.toml example: bump to `solc = "0.8.24"` and add `via_ir = true`
- `ritual-dapp-testing` foundry.toml example: add `via_ir = true`
- Add a one-line via_ir note to `ritual-dapp-http` and `ritual-dapp-llm` (matching the note already present in `ritual-dapp-multimodal`)
