// Deploys the keeper-press suite to Ritual testnet (chain 1979).
// Run: PRIVATE_KEY=0x... npx hardhat run scripts/deploy.js --network ritual
const fs = require("fs");
const path = require("path");
const { ethers, network } = require("hardhat");

// The sovereign agent's harness address is CREATE3-deterministic from
// (deployer, keccak(salt label)), so it is known before the agent exists.
const SOVEREIGN = "0xae446e37Ed74b050bAe8FC570775f7Cc20bDC3CB"; // salt: keeper-press-1
const RITUAL_WALLET = "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948";
const LOCK_BLOCKS = 100000;

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("network :", network.name, "deployer:", deployer.address);
  console.log("balance :", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "RITUAL");

  const args = [SOVEREIGN, RITUAL_WALLET, LOCK_BLOCKS];
  const out = { chainId: 1979, sovereign: SOVEREIGN, ritualWallet: RITUAL_WALLET, lockBlocks: LOCK_BLOCKS, contracts: {} };

  for (const name of ["AgentWatchdog", "KeeperDigest", "HeadlineMarkets"]) {
    const factory = await ethers.getContractFactory(name);
    const contract = await factory.deploy(...args);
    await contract.waitForDeployment();
    out.contracts[name] = await contract.getAddress();
    console.log(`${name}: ${out.contracts[name]}`);
  }

  const file = path.join(__dirname, "..", "deployments.json");
  fs.writeFileSync(file, JSON.stringify(out, null, 2) + "\n");
  console.log("wrote", file);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
