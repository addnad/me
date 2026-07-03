const { ethers, network } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`Deploying to ${network.name} as ${deployer.address}`);

  // On testnets we stand in for USDT with a faucet token; on a real
  // deployment USDT_ADDRESS points at the canonical token.
  let usdtAddress = process.env.USDT_ADDRESS;
  if (!usdtAddress) {
    const usdt = await (await ethers.getContractFactory("MockUSDT")).deploy();
    await usdt.waitForDeployment();
    usdtAddress = usdt.target;
    console.log(`MockUSDT: ${usdtAddress}`);
  }

  const escrow = await (await ethers.getContractFactory("SidelineEscrow")).deploy(usdtAddress);
  await escrow.waitForDeployment();
  console.log(`SidelineEscrow: ${escrow.target}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
