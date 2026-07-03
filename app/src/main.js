"use strict";

/**
 * Sideline app shell.
 *
 * Two layers, matching the product's trust model:
 *  - the SIGNER (WDK account from the on-device seed) — always available,
 *    powers offline minting and verification;
 *  - the CHAIN CLIENT (SidelineWallet) — only when an RPC is reachable,
 *    powers tab loading and settlement.
 *
 * Nothing here is simulated: with no RPC configured the online panels
 * say so and stay disabled; balances only ever come from the chain.
 */

const { ethers } = require("ethers");
const WalletManagerEvm = require("@tetherto/wdk-wallet-evm").default;
const { SeedSignerEvm } = require("@tetherto/wdk-wallet-evm/signers");
const { mintVoucherWith, verifyVoucher, decodeVoucher, encodeVoucher } = require("@sideline/voucher");
const { SidelineWallet } = require("@sideline/wallet");
const QRCode = require("qrcode");

const USDT6 = (n) => ethers.parseUnits(String(n), 6);
const fmt = (v) => ethers.formatUnits(v, 6);
const short = (a) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "—");
const now = () => Math.floor(Date.now() / 1000);
const DAY = 86400;

// ---- persistence -----------------------------------------------------

const store = {
  get(key, fallback) {
    try {
      const raw = localStorage.getItem(`sideline.${key}`);
      return raw ? JSON.parse(raw) : fallback;
    } catch {
      return fallback;
    }
  },
  set(key, value) {
    localStorage.setItem(`sideline.${key}`, JSON.stringify(value));
  },
};

const state = {
  config: store.get("config", { rpc: "", escrow: "", usdt: "", chainId: null }),
  pocket: store.get("pocket", []), // [{wire, payer, amount, expiry, id}]
  activity: store.get("activity", []), // [{t, kind, text}]
  seed: null,
  account: null, // WDK account (signer layer)
  address: null,
  wallet: null, // SidelineWallet (chain layer)
  denom: 5,
};

// ---- helpers -----------------------------------------------------------

const $ = (id) => document.getElementById(id);

function toast(msg, isError = false) {
  const el = $("toast");
  el.textContent = msg;
  el.className = `toast show${isError ? " error" : ""}`;
  clearTimeout(el._t);
  el._t = setTimeout(() => (el.className = "toast"), 4200);
}

function logActivity(kind, text) {
  state.activity.unshift({ t: now(), kind, text });
  state.activity = state.activity.slice(0, 50);
  store.set("activity", state.activity);
  renderActivity();
}

function online() {
  return state.wallet != null;
}

// ---- signer layer (always on) ------------------------------------------

async function initSigner() {
  let seed = localStorage.getItem("sideline.seed");
  if (!seed) {
    seed = ethers.Wallet.createRandom().mnemonic.phrase;
    localStorage.setItem("sideline.seed", seed);
    logActivity("wallet", "new self-custodial wallet created on this device");
  }
  state.seed = seed;
  // Pass raw seed bytes: bip39's dynamic wordlist require doesn't survive
  // browser bundling, and ethers derives the identical BIP-39 seed.
  const seedBytes = ethers.getBytes(ethers.Mnemonic.fromPhrase(seed).computeSeed());
  // provider URL is only dialed for chain calls; signing stays local
  const manager = new WalletManagerEvm(new SeedSignerEvm(seedBytes), {
    provider: state.config.rpc || "http://127.0.0.1:8545",
  });
  state.account = await manager.getAccount(0);
  state.address = await state.account.getAddress();
}

// ---- chain layer (best effort) -------------------------------------------

async function connect() {
  const { rpc, escrow, usdt } = state.config;
  state.wallet = null;
  if (rpc && escrow && usdt) {
    try {
      state.wallet = await SidelineWallet.open({ seedPhrase: state.seed, rpc, escrow, usdt });
      state.config.chainId = Number(state.wallet.chainId);
      store.set("config", state.config);
    } catch {
      state.wallet = null; // offline is a supported state, not an error
    }
  }
  renderChip();
  refreshHome();
}

// ---- rendering ------------------------------------------------------------

function renderChip() {
  $("chip-addr").textContent = short(state.address);
  $("chip-dot").className = `dot ${online() ? "on" : "off"}`;
  $("chip-net").textContent = online() ? `online · chain ${state.config.chainId}` : "offline mode";
}

function renderActivity() {
  const box = $("home-activity");
  if (!state.activity.length) {
    box.innerHTML = `<div class="empty">Nothing yet. Load your tab before kickoff.</div>`;
    return;
  }
  box.innerHTML = state.activity
    .map((a) => {
      const when = new Date(a.t * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
      return `<div class="row"><span>${a.text}</span><span class="mono">${when}</span></div>`;
    })
    .join("");
}

function pocketTotal() {
  return state.pocket.reduce((s, v) => s + BigInt(v.amount), 0n);
}

async function refreshHome() {
  const hint = $("home-hint");
  $("home-pocket").textContent = `${fmt(pocketTotal())} USDT`;
  if (!online()) {
    $("home-available").innerHTML = `—<span class="unit">USDT</span>`;
    $("home-balance").textContent = "—";
    $("home-deposited").textContent = "—";
    hint.textContent = state.config.escrow
      ? "Offline. Minting and receiving still work; balances refresh when you're back in signal."
      : "Configure the network in Settings, then load your tab before the match.";
    return;
  }
  try {
    const [tab, bal] = await Promise.all([state.wallet.tab(), state.wallet.usdtBalance()]);
    $("home-available").innerHTML = `${fmt(tab.available)}<span class="unit">USDT</span>`;
    $("home-balance").textContent = `${fmt(bal)} USDT`;
    $("home-deposited").textContent = `${fmt(tab.deposited)} USDT`;
    hint.textContent =
      tab.available > 0n
        ? "Tab is live. You can pay with zero signal."
        : "Tab is empty — load it while you're online.";
  } catch (err) {
    hint.textContent = `Could not read chain state: ${err.message}`;
  }
}

function renderPocket() {
  const box = $("recv-pocket");
  if (!state.pocket.length) {
    box.innerHTML = `<div class="empty">No vouchers in your pocket.</div>`;
  } else {
    box.innerHTML = state.pocket
      .map(
        (v, i) => `
        <div class="row">
          <span><strong>${fmt(BigInt(v.amount))} USDT</strong> from <span class="mono">${short(v.payer)}</span></span>
          <span class="badge ok">verified</span>
        </div>`
      )
      .join("");
  }
  $("settle-count").textContent = String(state.pocket.length);
  $("settle-total").textContent = `${fmt(pocketTotal())} USDT`;
  $("home-pocket").textContent = `${fmt(pocketTotal())} USDT`;
}

// ---- actions ---------------------------------------------------------------

async function actionLoadTab() {
  if (!online()) return toast("You're offline — loading the tab needs a connection.", true);
  const amount = Number($("load-amount").value);
  if (!amount || amount <= 0) return toast("Enter an amount.", true);
  const days = Number($("load-days").value);
  const btn = $("load-submit");
  btn.disabled = true;
  try {
    await state.wallet.loadTab(USDT6(amount), now() + days * DAY);
    logActivity("tab", `loaded ${amount} USDT into the tab (${days}d)`);
    toast(`Tab loaded: ${amount} USDT.`);
    refreshHome();
  } catch (err) {
    toast(err.shortMessage || err.message, true);
  } finally {
    btn.disabled = false;
  }
}

async function actionMint() {
  const { chainId, escrow } = state.config;
  if (!chainId || !escrow) return toast("Connect once in Settings first, so the app knows your chain.", true);
  const btn = $("pay-mint");
  btn.disabled = true;
  try {
    const minted = await mintVoucherWith(
      { address: state.address, signTypedData: (args) => state.account.signTypedData(args) },
      { chainId, escrow, amount: USDT6(state.denom), expiry: now() + 2 * DAY }
    );
    const wire = encodeVoucher(minted);
    $("pay-ticket").style.display = "flex";
    $("pay-ticket-amount").textContent = `${state.denom} USDT`;
    $("pay-ticket-wire").textContent = wire;
    $("pay-copy").onclick = () => navigator.clipboard.writeText(wire).then(() => toast("Voucher copied."));
    await QRCode.toCanvas($("pay-qr"), wire, { width: 132, margin: 1 });
    logActivity("pay", `minted a ${state.denom} USDT voucher (offline)`);
  } catch (err) {
    toast(err.shortMessage || err.message, true);
  } finally {
    btn.disabled = false;
  }
}

function actionReceive() {
  const { chainId, escrow } = state.config;
  if (!chainId || !escrow) return toast("Connect once in Settings first, so the app knows your chain.", true);
  const wire = $("recv-wire").value.trim();
  if (!wire) return toast("Paste a voucher code.", true);
  let decoded;
  try {
    decoded = decodeVoucher(wire);
  } catch {
    return toast("That's not a readable voucher.", true);
  }
  const res = verifyVoucher(decoded, { chainId, escrow });
  if (!res.ok) return toast(`Rejected: ${res.reason}.`, true);
  if (state.pocket.some((v) => v.id === decoded.voucher.id)) {
    return toast("You already hold this exact voucher — possible double-spend attempt.", true);
  }
  state.pocket.push({
    wire,
    id: decoded.voucher.id,
    payer: decoded.voucher.payer,
    amount: decoded.voucher.amount.toString(),
    expiry: decoded.voucher.expiry.toString(),
  });
  store.set("pocket", state.pocket);
  $("recv-wire").value = "";
  renderPocket();
  logActivity("receive", `accepted ${fmt(BigInt(decoded.voucher.amount))} USDT from ${short(decoded.voucher.payer)}`);
  toast(`Voucher verified offline: ${fmt(BigInt(decoded.voucher.amount))} USDT.`);
}

async function actionSettle() {
  if (!online()) return toast("You're offline — settling needs a connection.", true);
  if (!state.pocket.length) return toast("Pocket is empty.", true);
  const btn = $("settle-submit");
  btn.disabled = true;
  try {
    const tx = await state.wallet.redeem(state.pocket.map((v) => v.wire));
    const total = fmt(pocketTotal());
    $("settle-log").innerHTML =
      `<div class="row"><span>settled ${state.pocket.length} voucher(s), ${total} USDT</span>` +
      `<span class="mono">${tx.slice(0, 14)}…</span></div>` + $("settle-log").innerHTML;
    logActivity("settle", `settled ${state.pocket.length} voucher(s) — ${total} USDT`);
    state.pocket = [];
    store.set("pocket", state.pocket);
    renderPocket();
    refreshHome();
    toast(`Settled on-chain: ${total} USDT.`);
  } catch (err) {
    toast(err.shortMessage || err.message, true);
  } finally {
    btn.disabled = false;
  }
}

function actionSaveSettings() {
  state.config.rpc = $("set-rpc").value.trim();
  state.config.escrow = $("set-escrow").value.trim();
  state.config.usdt = $("set-usdt").value.trim();
  store.set("config", state.config);
  toast("Saved. Connecting…");
  connect();
}

// ---- wiring -----------------------------------------------------------------

function bindNav() {
  document.querySelectorAll(".nav-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".nav-btn").forEach((b) => b.classList.remove("active"));
      document.querySelectorAll(".view").forEach((v) => v.classList.remove("active"));
      btn.classList.add("active");
      $(`view-${btn.dataset.view}`).classList.add("active");
      if (btn.dataset.view === "home") refreshHome();
    });
  });
}

function bindControls() {
  $("load-submit").addEventListener("click", actionLoadTab);
  $("pay-mint").addEventListener("click", actionMint);
  $("recv-check").addEventListener("click", actionReceive);
  $("settle-submit").addEventListener("click", actionSettle);
  $("set-save").addEventListener("click", actionSaveSettings);
  $("set-reveal").addEventListener("click", () => {
    const box = $("set-seed");
    box.style.display = box.style.display === "none" ? "block" : "none";
    box.value = state.seed;
  });
  document.querySelectorAll(".denom").forEach((d) => {
    d.addEventListener("click", () => {
      document.querySelectorAll(".denom").forEach((x) => x.classList.remove("selected"));
      d.classList.add("selected");
      state.denom = Number(d.dataset.v);
    });
  });
}

async function main() {
  bindNav();
  bindControls();
  await initSigner();
  $("set-addr").textContent = short(state.address);
  $("set-rpc").value = state.config.rpc;
  $("set-escrow").value = state.config.escrow;
  $("set-usdt").value = state.config.usdt;
  renderChip();
  renderActivity();
  renderPocket();
  await connect();
}

main().catch((err) => {
  console.error(err);
  toast(err.message, true);
});
