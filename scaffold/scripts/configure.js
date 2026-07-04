/* Configures the deployed PromptGenesis with a TEE executor and encrypted
 * storage credentials.
 *
 * Env:
 *   DA_PROVIDER   hf | pinata               (default hf)
 *   HF_TOKEN      HuggingFace token          (hf)
 *   HF_REPO_ID    user/repo dataset id       (hf)
 *   PINATA_JWT    Pinata JWT                 (pinata)
 *   EXECUTOR_TEE_ADDRESS  optional explicit executor
 */
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");
const { encrypt, ECIES_CONFIG } = require("eciesjs");

// Ritual executors expect a 12-byte AES-GCM nonce (matches the reference
// helpers in ritual-dapp-skills examples).
ECIES_CONFIG.symmetricNonceLength = 12;

const TEE_SERVICE_REGISTRY = "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F";
const CAPABILITY_IMAGE_CALL = 7;

const REGISTRY_ABI = [
  "function getServicesByCapability(uint8 capability, bool checkValidity) view returns (tuple(tuple(address paymentAddress, address teeAddress, uint8 teeType, bytes publicKey, string endpoint, bytes32 certPubKeyHash, uint8 capability) node, bool isValid, bytes32 workloadId)[])",
];

function loadDeployment() {
  const p = path.join(__dirname, "..", "deployments", "ritual.json");
  if (!fs.existsSync(p)) throw new Error("deployments/ritual.json not found — run deploy first");
  return JSON.parse(fs.readFileSync(p));
}

function buildStorage() {
  const provider = (process.env.DA_PROVIDER || "hf").toLowerCase();
  if (provider === "hf") {
    const token = process.env.HF_TOKEN;
    const repo = process.env.HF_REPO_ID;
    if (!token || !repo) throw new Error("DA_PROVIDER=hf requires HF_TOKEN and HF_REPO_ID");
    if (!/^[A-Za-z0-9][\w.-]*\/[A-Za-z0-9][\w.-]*$/.test(repo)) {
      throw new Error(`HF_REPO_ID must be 'user/repo', got: ${repo}`);
    }
    return {
      secrets: { HF_TOKEN: token },
      storageRef: { platform: "hf", path: `${repo}/images/`, keyRef: "HF_TOKEN" },
    };
  }
  if (provider === "pinata") {
    const jwt = process.env.PINATA_JWT;
    if (!jwt) throw new Error("DA_PROVIDER=pinata requires PINATA_JWT");
    return {
      secrets: { DA_PINATA_JWT: jwt },
      storageRef: { platform: "pinata", path: "", keyRef: "DA_PINATA_JWT" },
    };
  }
  throw new Error("DA_PROVIDER must be hf or pinata");
}

async function pickExecutor() {
  const registry = await ethers.getContractAt(REGISTRY_ABI, TEE_SERVICE_REGISTRY);
  const services = await registry.getServicesByCapability(CAPABILITY_IMAGE_CALL, true);
  if (services.length === 0) throw new Error("No valid IMAGE_CALL executors in TEEServiceRegistry");

  const explicit = process.env.EXECUTOR_TEE_ADDRESS;
  if (explicit) {
    const target = ethers.getAddress(explicit);
    for (const s of services) {
      if (ethers.getAddress(s.node.teeAddress) === target) return s.node;
    }
    throw new Error(`Executor ${target} not found among valid IMAGE_CALL services`);
  }
  return services[0].node;
}

async function main() {
  const dep = loadDeployment();
  const gen = await ethers.getContractAt("PromptGenesis", dep.address);
  const { secrets, storageRef } = buildStorage();

  const node = await pickExecutor();
  console.log(`Executor: ${node.teeAddress} (${node.endpoint})`);

  const pubKey = Buffer.from(ethers.getBytes(node.publicKey));
  const blob = encrypt(pubKey, Buffer.from(JSON.stringify(secrets)));
  console.log(`Encrypted secrets: ${blob.length} bytes for keyRef ${storageRef.keyRef}`);

  // eciesjs returns a Uint8Array — hexlify it (Uint8Array.toString("hex")
  // silently yields comma-separated decimals, not hex).
  const tx = await gen.setExecutorConfig(node.teeAddress, [ethers.hexlify(blob)], storageRef);
  await tx.wait();
  console.log(`setExecutorConfig confirmed: ${tx.hash}`);
  console.log(`Storage: ${storageRef.platform} ${storageRef.path}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
