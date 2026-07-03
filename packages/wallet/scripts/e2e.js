"use strict";

/**
 * Full Sideline loop, driven end-to-end through WDK wallets:
 *
 *   fan loads tab → mints voucher OFFLINE → hands wire string over →
 *   vendor verifies OFFLINE → vendor redeems on-chain → double-redeem bounces
 *
 * Runs against any EVM chain:
 *   RPC=...  ESCROW=0x..  USDT=0x..  FAN_SEED="..."  VENDOR_SEED="..."  node scripts/e2e.js
 *
 * With no ESCROW set and a local Hardhat node on :8545, it bootstraps
 * the contracts itself so the whole loop can be exercised offline.
 */

const { ethers } = require("ethers");
const { SidelineWallet } = require("..");

const RPC = process.env.RPC || "http://127.0.0.1:8545";
const USDT6 = (n) => ethers.parseUnits(n.toString(), 6);
const fmt = (v) => ethers.formatUnits(v, 6);
const DAY = 86400;

// Public, throwaway dev mnemonics — never hold real value on these.
const FAN_SEED =
  process.env.FAN_SEED || "lonely mutual fly decrease rural consider silly call risk method left adapt";
const VENDOR_SEED =
  process.env.VENDOR_SEED || "craft gold pause network move winner runway toss loan cruise liquid cup";

async function bootstrapLocal(provider) {
  // Hardhat node's first default account bankrolls the local run.
  const HH_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
  const deployer = new ethers.NonceManager(new ethers.Wallet(HH_KEY, provider));

  const load = (name) =>
    require(`@sideline/contracts/artifacts/contracts/${name}.sol/${name}.json`);

  const usdtArt = load("MockUSDT");
  const escrowArt = load("SidelineEscrow");

  const usdt = await new ethers.ContractFactory(usdtArt.abi, usdtArt.bytecode, deployer).deploy();
  await usdt.waitForDeployment();
  const escrow = await new ethers.ContractFactory(escrowArt.abi, escrowArt.bytecode, deployer).deploy(
    usdt.target
  );
  await escrow.waitForDeployment();

  // gas + spending money for the two WDK-derived addresses
  const fanAddr = ethers.HDNodeWallet.fromPhrase(FAN_SEED, undefined, "m/44'/60'/0'/0/0").address;
  const vendorAddr = ethers.HDNodeWallet.fromPhrase(VENDOR_SEED, undefined, "m/44'/60'/0'/0/0").address;
  for (const to of [fanAddr, vendorAddr]) {
    await (await deployer.sendTransaction({ to, value: ethers.parseEther("1") })).wait();
  }
  await (await usdt.faucet(fanAddr, USDT6(100))).wait();

  console.log(`bootstrapped local chain — escrow ${escrow.target}, usdt ${usdt.target}\n`);
  return { escrow: escrow.target, usdt: usdt.target };
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC);
  const net = await provider.getNetwork();
  console.log(`chain ${net.chainId} via ${RPC}\n`);

  let { ESCROW: escrow, USDT: usdt } = process.env;
  if (!escrow) ({ escrow, usdt } = await bootstrapLocal(provider));

  const fan = await SidelineWallet.open({ seedPhrase: FAN_SEED, rpc: RPC, escrow, usdt });
  const vendor = await SidelineWallet.open({ seedPhrase: VENDOR_SEED, rpc: RPC, escrow, usdt });
  console.log(`fan    ${fan.address}  (${fmt(await fan.usdtBalance())} USDT)`);
  console.log(`vendor ${vendor.address}  (${fmt(await vendor.usdtBalance())} USDT)\n`);

  // 1 — ONLINE: fan loads the match-day tab
  const now = Math.floor(Date.now() / 1000);
  await fan.loadTab(USDT6(20), now + 7 * DAY);
  console.log(`1. tab loaded: ${fmt((await fan.tab()).available)} USDT available`);

  // 2 — OFFLINE: fan signs a voucher; nothing here touches the network
  const { wire } = await fan.mintVoucher(USDT6(5), now + 2 * DAY);
  console.log(`2. voucher minted offline (${wire.length} chars, QR-sized)`);

  // 3 — OFFLINE: vendor validates the incoming voucher locally
  const check = vendor.checkIncoming(wire);
  if (!check.ok) throw new Error(`vendor rejected voucher: ${check.reason}`);
  console.log(`3. vendor verified offline: signature valid, 5 USDT from ${check.voucher.payer.slice(0, 8)}…`);

  // 4 — ONLINE: vendor settles
  const tx = await vendor.redeem(wire);
  console.log(`4. redeemed on-chain: ${tx}`);
  console.log(`   vendor now holds ${fmt(await vendor.usdtBalance())} USDT; fan tab ${fmt((await fan.tab()).available)} USDT`);

  // 5 — the same voucher can't be spent twice
  try {
    await vendor.redeem(wire);
    throw new Error("double redeem unexpectedly succeeded");
  } catch (err) {
    if (String(err.message).includes("unexpectedly")) throw err;
    console.log(`5. double-redeem rejected by escrow ✔`);
  }

  console.log("\nfull loop OK");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
