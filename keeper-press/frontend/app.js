/* keeper-press frontend: read-only via public RPC, writes via injected wallet. */
const C = window.KEEPER_CONFIG;

const DIGEST_ABI = [
  "function editionCount() view returns (uint256)",
  "function getEdition(uint256) view returns (uint64 publishedAt, uint192 tips, string headline, string body, string sourceNote)",
  "function tip(uint256) payable",
];
const MARKETS_ABI = [
  "function marketCount() view returns (uint256)",
  "function getMarket(uint256) view returns (uint64 closeAt, uint64 resolveBy, uint8 outcome, uint256 yesPool, uint256 noPool, string question)",
  "function bet(uint256, bool) payable",
  "function claim(uint256)",
  "function voidMarket(uint256)",
];
const WATCHDOG_ABI = [
  "function agentCount() view returns (uint256)",
  "function agents(uint256) view returns (address)",
  "function registrations(address) view returns (address registrant, uint96 minBalance, uint96 topUpAmount, uint256 escrow, uint64 topUps, bool active)",
  "function needsTopUp(address) view returns (bool)",
  "function register(address, uint96, uint96) payable",
  "function fund(address) payable",
  "function topUp(address)",
  "function withdraw(address, uint256)",
];
const WALLET_ABI = ["function balanceOf(address) view returns (uint256)"];

const provider = new ethers.JsonRpcProvider(C.rpcUrl, C.chainId);
const digest = new ethers.Contract(C.contracts.KeeperDigest, DIGEST_ABI, provider);
const markets = new ethers.Contract(C.contracts.HeadlineMarkets, MARKETS_ABI, provider);
const watchdog = new ethers.Contract(C.contracts.AgentWatchdog, WATCHDOG_ABI, provider);
const rwallet = new ethers.Contract(C.ritualWallet, WALLET_ABI, provider);

let signer = null;

const $ = (id) => document.getElementById(id);
const fmt = (wei) => (+ethers.formatEther(wei)).toFixed(4).replace(/\.?0+$/, "") || "0";
const short = (a) => a.slice(0, 8) + "…" + a.slice(-6);
const ts = (t) => new Date(Number(t) * 1000).toISOString().replace("T", " ").slice(0, 16) + " UTC";

function toast(msg, ms = 4200) {
  const el = $("toast");
  el.textContent = msg;
  el.style.display = "block";
  clearTimeout(el._t);
  el._t = setTimeout(() => (el.style.display = "none"), ms);
}

async function connect() {
  if (!window.ethereum) return toast("no wallet extension found — install MetaMask or similar");
  const browser = new ethers.BrowserProvider(window.ethereum);
  try {
    await browser.send("wallet_switchEthereumChain", [{ chainId: C.chainIdHex }]);
  } catch (e) {
    if (e.error?.code === 4902 || e.code === 4902) {
      await browser.send("wallet_addEthereumChain", [{
        chainId: C.chainIdHex, chainName: C.chainName,
        rpcUrls: [C.rpcUrl], blockExplorerUrls: [C.explorer],
        nativeCurrency: { name: "RITUAL", symbol: "RITUAL", decimals: 18 },
      }]);
    }
  }
  signer = await browser.getSigner();
  $("connect").textContent = short(await signer.getAddress());
  toast("connected");
  render();
}

async function withSigner(fn) {
  if (!signer) { toast("connect a wallet first"); return; }
  try {
    const tx = await fn();
    toast("tx sent: " + tx.hash.slice(0, 18) + "… waiting");
    await tx.wait();
    toast("confirmed ✓");
    render();
  } catch (e) {
    toast("reverted/rejected: " + (e.shortMessage || e.message).slice(0, 120));
  }
}

/* ---------------- keeper vitals ---------------- */

// A sovereign agent is alive while the Scheduler still holds a wake for it:
// read curCallId/nextCallId getters on the harness, then Scheduler.calls(id).
async function keeperAlive() {
  if ((await provider.getCode(C.sovereign)) === "0x") return { state: "not deployed yet", cls: "warn" };
  for (const getter of ["0x618abb34", "0x61f32724"]) {
    try {
      const w = await provider.call({ to: C.sovereign, data: getter });
      if (!w || BigInt(w) === 0n) continue;
      const out = await provider.call({ to: C.scheduler, data: "0xd183ce14" + w.slice(2) });
      if (out && out !== "0x") return { state: "LIVE", cls: "ok" };
    } catch (_) { /* scheduler reverts once the call is consumed */ }
  }
  return { state: "DEAD", cls: "bad" };
}

async function renderVitals() {
  $("v-sovereign").textContent = C.sovereign;
  const [alive, bal] = await Promise.all([keeperAlive(), rwallet.balanceOf(C.sovereign)]);
  const st = $("v-status");
  st.textContent = alive.state;
  st.className = "value " + alive.cls;
  const b = $("v-balance");
  b.textContent = fmt(bal) + " RITUAL";
  b.className = "value " + (bal < ethers.parseEther("0.5") ? "bad" : "ok");
}

/* ---------------- digest ---------------- */

async function renderDigest() {
  const n = Number(await digest.editionCount());
  $("v-editions").textContent = n;
  const box = $("editions");
  if (!n) { box.innerHTML = '<div class="empty">no editions yet — the keeper hasn\'t woken for the first time.</div>'; return; }
  box.innerHTML = "";
  for (let i = n - 1; i >= Math.max(0, n - 12); i--) {
    const e = await digest.getEdition(i);
    const card = document.createElement("div");
    card.className = "card";
    card.innerHTML = `
      <div class="meta"><span>edition #${i}</span><span>${ts(e.publishedAt)}</span><span>tips ${fmt(e.tips)} RITUAL</span></div>
      <h3></h3><p></p>
      <div class="meta"><span class="src"></span></div>
      <div class="row"><input type="text" placeholder="tip (RITUAL)" value="0.05" size="12"><button>tip the keeper</button></div>`;
    card.querySelector("h3").textContent = e.headline;
    card.querySelector("p").textContent = e.body;
    card.querySelector(".src").textContent = e.sourceNote ? "source: " + e.sourceNote : "";
    card.querySelector("button").onclick = () =>
      withSigner(() => digest.connect(signer).tip(i, { value: ethers.parseEther(card.querySelector("input").value || "0") }));
    box.appendChild(card);
  }
}

/* ---------------- markets ---------------- */

const OUTCOME = ["unresolved", "YES", "NO", "void"];

async function renderMarkets() {
  const n = Number(await markets.marketCount());
  $("v-markets").textContent = n;
  const box = $("markets");
  if (!n) { box.innerHTML = '<div class="empty">no markets yet — they open when the keeper publishes its first stories.</div>'; return; }
  box.innerHTML = "";
  const now = Math.floor(Date.now() / 1000);
  for (let i = n - 1; i >= Math.max(0, n - 12); i--) {
    const m = await markets.getMarket(i);
    const open = now < Number(m.closeAt) && Number(m.outcome) === 0;
    const voidable = Number(m.outcome) === 0 && now >= Number(m.resolveBy);
    const card = document.createElement("div");
    card.className = "card";
    card.innerHTML = `
      <div class="meta">
        <span>market #${i}</span>
        <span class="pill ${open ? "open" : Number(m.outcome) ? "closed" : "closed"}">${Number(m.outcome) ? OUTCOME[m.outcome] : open ? "open" : "awaiting resolution"}</span>
        <span>closes ${ts(m.closeAt)}</span>
        <span>YES ${fmt(m.yesPool)} / NO ${fmt(m.noPool)}</span>
      </div>
      <h3></h3>
      <div class="row"></div>`;
    card.querySelector("h3").textContent = m.question;
    const row = card.querySelector(".row");
    if (open) {
      const amt = document.createElement("input");
      amt.placeholder = "stake (RITUAL)"; amt.value = "0.1"; amt.size = 12;
      const yes = document.createElement("button"); yes.textContent = "bet YES";
      const no = document.createElement("button"); no.textContent = "bet NO";
      yes.onclick = () => withSigner(() => markets.connect(signer).bet(i, true, { value: ethers.parseEther(amt.value || "0") }));
      no.onclick = () => withSigner(() => markets.connect(signer).bet(i, false, { value: ethers.parseEther(amt.value || "0") }));
      row.append(amt, yes, no);
    }
    if (Number(m.outcome) !== 0) {
      const cl = document.createElement("button"); cl.textContent = "claim";
      cl.onclick = () => withSigner(() => markets.connect(signer).claim(i));
      row.append(cl);
    }
    if (voidable) {
      const vd = document.createElement("button"); vd.textContent = "void (deadline passed)";
      vd.onclick = () => withSigner(() => markets.connect(signer).voidMarket(i));
      row.append(vd);
    }
    box.appendChild(card);
  }
}

/* ---------------- watchdog ---------------- */

async function renderWatchdog() {
  const n = Number(await watchdog.agentCount());
  $("v-watched").textContent = n;
  const box = $("watched");
  if (!n) { box.innerHTML = '<div class="empty">no agents registered yet.</div>'; return; }
  box.innerHTML = "";
  for (let i = 0; i < Math.min(n, 20); i++) {
    const agent = await watchdog.agents(i);
    const [r, needs, bal] = await Promise.all([
      watchdog.registrations(agent),
      watchdog.needsTopUp(agent),
      rwallet.balanceOf(agent),
    ]);
    const card = document.createElement("div");
    card.className = "card";
    card.innerHTML = `
      <div class="meta">
        <span class="addr">${agent}</span>
        <span class="pill ${needs ? "dead" : "live"}">${needs ? "needs top-up" : "healthy"}</span>
      </div>
      <div class="meta">
        <span>wallet ${fmt(bal)}</span><span>min ${fmt(r.minBalance)}</span>
        <span>top-up ${fmt(r.topUpAmount)}</span><span>escrow ${fmt(r.escrow)}</span>
        <span>top-ups done ${r.topUps}</span><span>${r.active ? "active" : "inactive"}</span>
      </div>
      <div class="row"></div>`;
    const row = card.querySelector(".row");
    if (needs) {
      const b = document.createElement("button"); b.textContent = "top up now";
      b.onclick = () => withSigner(() => watchdog.connect(signer).topUp(agent));
      row.append(b);
    }
    const f = document.createElement("input"); f.placeholder = "add escrow"; f.size = 12;
    const fb = document.createElement("button"); fb.textContent = "fund";
    fb.onclick = () => withSigner(() => watchdog.connect(signer).fund(agent, { value: ethers.parseEther(f.value || "0") }));
    row.append(f, fb);
    box.appendChild(card);
  }
}

/* ---------------- boot ---------------- */

$("connect").onclick = connect;
$("wd-register").onclick = () =>
  withSigner(() => watchdog.connect(signer).register(
    $("wd-agent").value.trim(),
    ethers.parseEther($("wd-min").value || "0.5"),
    ethers.parseEther($("wd-topup").value || "1"),
    { value: ethers.parseEther($("wd-escrow").value || "0") }
  ));
$("f-addrs").textContent =
  `watchdog ${short(C.contracts.AgentWatchdog)} · digest ${short(C.contracts.KeeperDigest)} · markets ${short(C.contracts.HeadlineMarkets)}`;

async function render() {
  await Promise.allSettled([renderVitals(), renderDigest(), renderMarkets(), renderWatchdog()]);
}
render();
setInterval(renderVitals, 30000);
