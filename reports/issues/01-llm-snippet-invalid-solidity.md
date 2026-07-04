# Issue 1

**Title:** bug(skills/ritual-dapp-llm): consumer snippet is invalid Solidity — abi.decode with nested tuple literal cannot compile

**Body:**

Tested against commit `57045a3` (1.0.0) by compiling the snippet with solc 0.8.24.

The canonical `LLMConsumer` contract in `skills/ritual-dapp-llm/SKILL.md` (code block starting ~line 925) decodes the settlement response with:

```solidity
(hasError, completionData, modelMeta, errorMsg, ) =
    abi.decode(actualOutput, (bool, bytes, bytes, string, (string, string, string)));
```

A nested tuple literal is not a type name in Solidity, so every solc version rejects this line:

```
TypeError: Argument has to be a type name.
  --> SKILL.md snippet, ~line 993 of the file
```

Since this is the copy-paste reference contract for the LLM precompile (`0x0802`), any agent or user following the skill produces a contract that fails to build.

## Suggested fix (verified to compile with solc 0.8.24 + via_ir)

Decode the trailing `(string,string,string)` storage-reference tuple via a struct:

```solidity
struct StorageRef { string platform; string path; string keyRef; }

...
(hasError, completionData, modelMeta, errorMsg, ) =
    abi.decode(actualOutput, (bool, bytes, bytes, string, StorageRef));
```

Note: even with this fix the contract only compiles with `via_ir = true` (stack too deep otherwise) — filed separately since that affects multiple skills and the shipped hardhat template.
