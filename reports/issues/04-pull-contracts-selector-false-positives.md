# Issue 4

**Title:** `pull_contracts.py`: selector extraction misreads PUSH immediate data as PUSH4 — produces false selectors

**Body:**

Tested against commit `57045a3` (1.0.0) by unit-testing `extract_selectors()` directly.

`extract_selectors()` in `scripts/pull_contracts.py` scans bytecode byte-by-byte for `0x63` (PUSH4) but never skips the immediate data of *other* PUSH opcodes. Any `0x63` byte inside a PUSH1–PUSH32 immediate (constants, addresses, Solidity metadata) is misread as a PUSH4 dispatch entry.

Reproduction:

```python
# PUSH32 whose data contains 0x63, followed by a real dispatcher PUSH4 0xa9059cbb
bytecode = "0x" + "7f" + "63deadbeef" + "00"*27 + "63a9059cbb"
extract_selectors(bytecode)
# actual:   ['a9059cbb', 'deadbeef']   <- 'deadbeef' is garbage from PUSH32 data
# expected: ['a9059cbb']
```

Same failure with e.g. `PUSH1 0x63`: the immediate `0x63` is treated as an opcode and the next 4 bytes become a fake selector. These garbage selectors then get sent to 4byte.directory and written into `selectors.json`.

## Suggested fix

Skip immediates for the whole PUSH family:

```python
def extract_selectors(bytecode: str) -> list[str]:
    if bytecode.startswith("0x"):
        bytecode = bytecode[2:]
    raw = bytes.fromhex(bytecode)
    selectors = set()
    i = 0
    while i < len(raw):
        op = raw[i]
        if op == 0x63 and i + 4 < len(raw):
            sel = raw[i + 1 : i + 5].hex()
            if sel not in ("00000000", "ffffffff"):
                selectors.add(sel)
        if 0x60 <= op <= 0x7F:          # PUSH1..PUSH32: skip immediate data
            i += (op - 0x5F) + 1
        else:
            i += 1
    return sorted(selectors)
```

Still a heuristic (data sections aren't distinguished from code), but it removes this systematic false-positive class.
