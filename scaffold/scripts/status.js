/* Prints deployment status: config, RitualWallet fee balance, and all pieces. */
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

const RITUAL_WALLET = "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948";
const WALLET_ABI = ["function balanceOf(address) view returns (uint256)"];

async function main() {
  const dep = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "deployments", "ritual.json")));
  const gen = await ethers.getContractAt("PromptGenesis", dep.address);

  console.log(`PromptGenesis @ ${dep.address}`);
  console.log(`Executor:   ${await gen.executor()}`);
  console.log(`Model:      ${await gen.model()}`);
  console.log(`Mint price: ${ethers.formatEther(await gen.mintPrice())} RITUAL`);

  const wallet = await ethers.getContractAt(WALLET_ABI, RITUAL_WALLET);
  const feeBalance = await wallet.balanceOf(dep.address);
  console.log(`RitualWallet fee balance: ${ethers.formatEther(feeBalance)} RITUAL`);
  if (feeBalance === 0n) console.log("  WARNING: zero fee balance — Phase 2 will never execute. Run depositForFees.");

  const next = await gen.nextTokenId();
  console.log(`Minted: ${next - 1n} piece(s)`);
  for (let i = 1n; i < next; i++) {
    const p = await gen.pieces(i);
    const status = p.revealed ? "revealed" : p.failed ? `FAILED (${p.failReason})` : "gestating";
    console.log(`  #${i} [${status}] "${p.prompt}" minter=${p.minter}${p.revealed ? ` uri=${p.imageUri}` : ""}`);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
