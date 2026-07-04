# Issue 5

**Title:** `pull_contracts.py --block 0` is silently ignored and pulls the whole registry instead

**Body:**

Tested against commit `57045a3` (1.0.0).

`main()` in `scripts/pull_contracts.py` dispatches the block-discovery mode with a truthiness check:

```python
if args.block:
    # Discover mode
```

`--block 0` (the genesis block) makes `args.block == 0`, which is falsy — so instead of discovering contracts at block 0, the script silently falls through to the default "pull all registry contracts" branch. The user gets output that looks successful but is the wrong operation entirely.

## Suggested fix

```python
if args.block is not None:
```

(`--name` and `--address` are strings so their truthiness checks are fine as-is.)
