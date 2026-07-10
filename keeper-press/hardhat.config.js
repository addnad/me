require("@nomicfoundation/hardhat-ethers");
require("@nomicfoundation/hardhat-chai-matchers");

// The deployer key is only ever passed via the environment — never committed.
const accounts = process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [];

module.exports = {
  solidity: {
    version: "0.8.24",
    settings: { optimizer: { enabled: true, runs: 200 } },
  },
  networks: {
    ritual: {
      url: process.env.RPC_URL || "https://rpc.ritualfoundation.org",
      chainId: 1979,
      accounts,
    },
  },
  mocha: { timeout: 120000 },
};
