# ⚽ Sideline

**Offline-first USDT payments for the stands.**

80,000 fans in a stadium and the network is gone — yet match day is when everyone
is trying to pay: a scarf, a beer, a bet with your mate two rows back. Sideline
lets USDT change hands with **zero connectivity**, peer to peer, and settles
on-chain when the crowd disperses and the signal comes back.

Built for the [Tether Developers Cup](https://dorahacks.io/hackathon/tether-developers-cup)
on the **Pears** (P2P) and **WDK** (self-custodial wallets) tracks.

## How it works

Security lives in the signature, not the pipe.

```
   ONLINE (before the match)          OFFLINE (in the stands)           ONLINE (after)
┌──────────────────────────┐      ┌──────────────────────────┐      ┌──────────────────┐
│ Fan deposits USDT into   │      │ Fan hands a signed       │      │ Vendor redeems   │
│ the SidelineEscrow "tab" │ ───► │ voucher to the vendor    │ ───► │ vouchers against │
│ and mints signed, fixed- │      │ over P2P (Hyperswarm) or │      │ the tab. First   │
│ denomination vouchers    │      │ a QR code. Vendor checks │      │ redemption of an │
│ — like loading a transit │      │ the EIP-712 signature    │      │ ID wins; the tab │
│ card.                    │      │ locally. No network.     │      │ is a hard ceiling│
└──────────────────────────┘      └──────────────────────────┘      └──────────────────┘
```

1. **Load the tab (online).** The payer deposits USDT into [`SidelineEscrow`](packages/contracts/contracts/SidelineEscrow.sol)
   and signs bearer vouchers against it — unique ID, fixed denomination, expiry.
2. **Pay (offline).** A voucher travels over any channel: the local P2P swarm, a QR
   code, a text file. The payee verifies the payer's EIP-712 signature entirely
   on-device.
3. **Settle (online).** The bearer redeems vouchers on-chain. Each ID redeems once,
   and total redemptions can never exceed the tab's deposit.
4. **Reclaim.** After the tab expires, the payer withdraws whatever was never spent.

### The double-spend question, answered honestly

Offline payment schemes die on double-spend, so Sideline is explicit about its
trust boundary:

- A payer **cannot mint value they don't have** — vouchers only redeem while the
  prefunded tab covers them, first-come-first-served.
- A payer **cannot spend the same voucher twice on-chain** — spent IDs are tracked
  forever.
- A malicious payer **can** hand the *same* voucher to two people offline; only the
  first redeemer collects. Mitigation (roadmap): peers gossip seen voucher IDs over
  the local swarm, so a re-used voucher is flagged inside the venue within seconds,
  plus payer reputation. The residual risk is bounded to the voucher denomination —
  the same trust you extend accepting a banknote you haven't UV-scanned.

## Repository layout

| Package | What it is |
|---|---|
| [`packages/contracts`](packages/contracts) | `SidelineEscrow` (tabs, redemption, reclaim) + `MockUSDT` test token — Hardhat |
| [`packages/voucher`](packages/voucher) | Mint / verify / serialize vouchers (EIP-712, offline-capable, QR-sized wire format) |
| [`app`](app) | Pear desktop app: wallet, tab loading, offline pay/receive over Hyperswarm *(in progress)* |

## Quickstart

```bash
npm install
npm test          # contract + voucher test suite (10 specs)
```

Requires Node.js ≥ 22. Contract tests run on the in-process Hardhat network — no
keys, RPC, or funds needed.

## Roadmap (knockout rounds)

- [x] **Phase 0** — escrow contract, voucher library, full test coverage
- [ ] **Phase 1** — WDK wallet integration: deposit → mint → redeem end-to-end on testnet
- [ ] **Phase 2** — Pear app: offline voucher handoff over Hyperswarm (LAN, no WAN) → *Round-of-16 demo, July 8*
- [ ] **Phase 3** — seen-voucher gossip + double-spend flagging, gasless redemption, fan/vendor UX → *July 12*
- [ ] **Phase 4** — polish, pitch, live two-device demo → *Final, July 15*

## Stack & disclosure

- [Pears / Holepunch](https://docs.pears.com) — P2P transport & discovery
- [Tether WDK](https://docs.wdk.tether.io) — self-custodial wallets & USDT payments
- OpenZeppelin Contracts, Hardhat, ethers.js

## License

[MIT](LICENSE)
