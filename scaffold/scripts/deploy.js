/* Deploys PromptGenesis to Ritual and records the address in deployments/. */
const { ethers, network } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Network:  ${network.name} (chainId ${(await ethers.provider.getNetwork()).chainId})`);
  console.log(`Balance:  ${ethers.formatEther(await ethers.provider.getBalance(deployer.address))} RITUAL`);

  const PromptGenesis = await ethers.getContractFactory("PromptGenesis");
  const gen = await PromptGenesis.deploy();
  await gen.waitForDeployment();
  const address = await gen.getAddress();
  console.log(`PromptGenesis deployed: ${address}`);

  // Fund the contract's RitualWallet balance for Phase 2 execution fees.
  const depositRit = process.env.DEPOSIT_RIT || "5";
  if (Number(depositRit) > 0) {
    console.log(`Depositing ${depositRit} RITUAL into RitualWallet for Phase 2 fees...`);
    const tx = await gen.depositForFees({ value: ethers.parseEther(depositRit) });
    await tx.wait();
    console.log("Deposit confirmed.");
  }

  const outDir = path.join(__dirname, "..", "deployments");
  fs.mkdirSync(outDir, { recursive: true });
  const record = {
    contract: "PromptGenesis",
    address,
    deployer: deployer.address,
    chainId: 1979,
    deployedAt: new Date().toISOString(),
    txHash: gen.deploymentTransaction().hash,
  };
  fs.writeFileSync(path.join(outDir, "ritual.json"), JSON.stringify(record, null, 2) + "\n");
  console.log("Wrote deployments/ritual.json");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
