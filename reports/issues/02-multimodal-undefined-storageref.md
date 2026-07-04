# Issue 2

**Title:** `ritual-dapp-multimodal` `MediaConsumer` snippet references undefined `StorageRef` struct (won't compile)

**Body:**

Tested against commit `57045a3` (1.0.0) with solc 0.8.24.

The `MediaConsumer` contract in `skills/ritual-dapp-multimodal/SKILL.md` (code block starting ~line 612) is presented as a complete file — it has its own SPDX header and `pragma solidity ^0.8.20;` — but its function signatures take `StorageRef calldata outputStorageRef` parameters without the struct ever being defined or imported:

```
DeclarationError: Identifier not found or not unique.
  --> snippet line 77: StorageRef calldata outputStorageRef,
```

## Suggested fix

Add the struct definition to the snippet (the skill's own Section 3 documents the tuple as `(string,string,string)` — platform, path, keyRef):

```solidity
struct StorageRef { string platform; string path; string keyRef; }
```

## Related smaller instance

`skills/ritual-dapp-scheduler/SKILL.md`'s `ScheduledHTTPConsumer` block (~line 369) also carries its own SPDX + pragma header (so it reads as a standalone file) but references `IScheduler`, which is only defined in the *previous* code block (~line 248). Either inline the interface in that block or drop the file header so the snippet doesn't present as self-contained.
