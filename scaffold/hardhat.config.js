require("@nomicfoundation/hardhat-ethers");
require("@nomicfoundation/hardhat-chai-matchers");

// Offline escape hatch: HARDHAT_OFFLINE_SOLC=1 compiles with the solc WASM
// package from node_modules instead of downloading a native binary from
// binaries.soliditylang.org (useful in sandboxed/proxied environments).
if (process.env.HARDHAT_OFFLINE_SOLC === "1") {
  const { subtask } = require("hardhat/config");
  const {
    TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD,
  } = require("hardhat/builtin-tasks/task-names");
  subtask(TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD, async (args, hre, runSuper) => {
    if (args.solcVersion === "0.8.24") {
      return {
        compilerPath: require.resolve("solc/soljson.js"),
        isSolcJs: true,
        version: args.solcVersion,
        longVersion: "0.8.24+commit.e11b9ed9",
      };
    }
    return runSuper(args);
  });
}

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.24",
    // viaIR + optimizer are required on Ritual: precompile request structs
    // are large enough that consumer contracts hit "stack too deep" without
    // them (see ritual-dapp-skills toolchain guidance).
    settings: {
      viaIR: true,
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    ritual: {
      url: process.env.RITUAL_RPC_URL || "https://rpc.ritualfoundation.org",
      chainId: 1979,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
  },
};
