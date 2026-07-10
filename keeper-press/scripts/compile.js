// Compile with solc-js (WASM) and emit Hardhat-format artifacts.
// Used instead of `hardhat compile` because this build environment cannot
// reach binaries.soliditylang.org to download a native compiler; the solc
// npm package (same 0.8.24 release, WASM build) comes from the npm registry.
const fs = require("fs");
const path = require("path");
const solc = require("solc");

const ROOT = path.join(__dirname, "..");
const SOURCES_DIR = path.join(ROOT, "contracts");
const ARTIFACTS_DIR = path.join(ROOT, "artifacts", "contracts");

function collectSources(dir, prefix) {
  const out = {};
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const rel = path.join(prefix, entry.name);
    if (entry.isDirectory()) {
      Object.assign(out, collectSources(path.join(dir, entry.name), rel));
    } else if (entry.name.endsWith(".sol")) {
      out[rel] = { content: fs.readFileSync(path.join(dir, entry.name), "utf8") };
    }
  }
  return out;
}

const sources = collectSources(SOURCES_DIR, "contracts");

const input = {
  language: "Solidity",
  sources,
  settings: {
    optimizer: { enabled: true, runs: 200 },
    outputSelection: { "*": { "*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object"] } },
  },
};

const output = JSON.parse(solc.compile(JSON.stringify(input)));

const errors = (output.errors || []).filter((e) => e.severity === "error");
for (const e of output.errors || []) console.error(e.formattedMessage);
if (errors.length) process.exit(1);

let count = 0;
for (const [sourceName, contracts] of Object.entries(output.contracts || {})) {
  for (const [contractName, c] of Object.entries(contracts)) {
    const dir = path.join(ROOT, "artifacts", sourceName);
    fs.mkdirSync(dir, { recursive: true });
    const artifact = {
      _format: "hh-sol-artifact-1",
      contractName,
      sourceName,
      abi: c.abi,
      bytecode: "0x" + c.evm.bytecode.object,
      deployedBytecode: "0x" + c.evm.deployedBytecode.object,
      linkReferences: {},
      deployedLinkReferences: {},
    };
    fs.writeFileSync(path.join(dir, `${contractName}.json`), JSON.stringify(artifact, null, 2));
    count++;
  }
}
console.log(`compiled ${count} contracts -> artifacts/`);
