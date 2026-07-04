/* Deploys PromptGenesis to Ritual and records the address in deployments/.
 *
 * Idempotent: waits for any pending txs from the deployer to mine, then
 * reuses an already-deployed PromptGenesis from a recent nonce if one
 * exists (handles 'already known' — a deploy tx accepted by the mempool
 * whose HTTP response was lost). The fee deposit is capped to what the
 * wallet can actually afford.
 */
const { ethers, network } = require("hardhat");
const fs = require("fs");
const path = require("path");

const RITUAL_WALLET = "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948";
const WALLET_ABI = ["function balanceOf(address) view returns (uint256)"];

async function waitForPendingTxs(addr, timeoutSec = 150) {
  const start = Date.now();
  for (;;) {
    const latest = await ethers.provider.getTransactionCount(addr, "latest");
    const pending = await ethers.provider.getTransactionCount(addr, "pending");
    if (pending === latest) return latest;
    console.log(`Waiting for ${pending - latest} pending tx(s) to mine (nonce ${latest} -> ${pending})...`);
    if ((Date.now() - start) / 1000 > timeoutSec) {
      throw new Error("Pending tx did not mine in time — re-run this workflow in a minute.");
    }
    await new Promise((r) => setTimeout(r, 5000));
  }
}

async function findExistingDeployment(deployer, latestNonce) {
  for (let n = latestNonce - 1; n >= Math.max(0, latestNonce - 6); n--) {
    const candidate = ethers.getCreateAddress({ from: deployer, nonce: n });
    const code = await ethers.provider.getCode(candidate);
    if (code === "0x") continue;
    try {
      const gen = await ethers.getContractAt("PromptGenesis", candidate);
      const owner = await gen.owner();
      await gen.mintPrice();
      if (owner.toLowerCase() === deployer.toLowerCase()) return candidate;
    } catch {
      /* not our contract */
    }
  }
  return null;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Network:  ${network.name} (chainId ${(await ethers.provider.getNetwork()).chainId})`);
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`Balance:  ${ethers.formatEther(balance)} RITUAL`);

  const latestNonce = await waitForPendingTxs(deployer.address);

  let gen;
  let address = await findExistingDeployment(deployer.address, latestNonce);
  if (address) {
    console.log(`Reusing existing PromptGenesis deployment: ${address}`);
    gen = await ethers.getContractAt("PromptGenesis", address);
  } else {
    const PromptGenesis = await ethers.getContractFactory("PromptGenesis");
    gen = await PromptGenesis.deploy();
    await gen.waitForDeployment();
    address = await gen.getAddress();
    console.log(`PromptGenesis deployed: ${address}`);
  }

  // Fund the contract's RitualWallet balance for Phase 2 execution fees,
  // capped to the deployer's spendable balance (keep 1 RITUAL for gas/mints).
  const wallet = new ethers.Contract(RITUAL_WALLET, WALLET_ABI, ethers.provider);
  const feeBalance = await wallet.balanceOf(address);
  console.log(`Contract RitualWallet fee balance: ${ethers.formatEther(feeBalance)} RITUAL`);

  const requested = ethers.parseEther(process.env.DEPOSIT_RIT || "2");
  if (feeBalance >= ethers.parseEther("1")) {
    console.log("Fee balance sufficient — skipping deposit.");
  } else {
    const spendable = (await ethers.provider.getBalance(deployer.address)) - ethers.parseEther("1");
    const deposit = requested < spendable ? requested : spendable;
    if (deposit <= 0n) {
      console.log("WARNING: not enough balance to deposit Phase 2 fees — fund the deployer and re-run.");
    } else {
      console.log(`Depositing ${ethers.formatEther(deposit)} RITUAL into RitualWallet...`);
      const tx = await gen.depositForFees({ value: deposit });
      await tx.wait();
      console.log("Deposit confirmed.");
    }
  }

  const outDir = path.join(__dirname, "..", "deployments");
  fs.mkdirSync(outDir, { recursive: true });
  const record = {
    contract: "PromptGenesis",
    address,
    deployer: deployer.address,
    chainId: 1979,
    deployedAt: new Date().toISOString(),
  };
  fs.writeFileSync(path.join(outDir, "ritual.json"), JSON.stringify(record, null, 2) + "\n");
  console.log("Wrote deployments/ritual.json");
  console.log(`ADDRESS=${address}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
