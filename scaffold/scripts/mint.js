/* Mints a piece and polls for the Phase 2 reveal.
 *
 * Env:
 *   PROMPT           the art prompt (required)
 *   REVEAL_TIMEOUT   seconds to wait for the callback (default 300)
 */
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const prompt = process.env.PROMPT;
  if (!prompt) throw new Error("Set PROMPT to the art prompt");
  const timeout = Number(process.env.REVEAL_TIMEOUT || 300);

  const dep = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "deployments", "ritual.json")));
  const gen = await ethers.getContractAt("PromptGenesis", dep.address);

  const price = await gen.mintPrice();
  console.log(`Minting with prompt: "${prompt}" (price ${ethers.formatEther(price)} RITUAL)`);

  // Explicit gas limit: estimation is unreliable for async precompile calls.
  const tx = await gen.mint(prompt, { value: price, gasLimit: 1_000_000 });
  console.log(`Mint tx: ${tx.hash}`);
  const receipt = await tx.wait();

  const minted = receipt.logs
    .map((l) => { try { return gen.interface.parseLog(l); } catch { return null; } })
    .find((l) => l && l.name === "MintRequested");
  if (!minted) throw new Error("MintRequested event not found");
  const tokenId = minted.args.tokenId;
  const jobId = minted.args.jobId;
  console.log(`Token #${tokenId} gestating, jobId ${jobId} (should equal mint tx hash)`);

  console.log(`Waiting up to ${timeout}s for Phase 2 reveal...`);
  const start = Date.now();
  while ((Date.now() - start) / 1000 < timeout) {
    const piece = await gen.pieces(tokenId);
    if (piece.revealed) {
      console.log(`REVEALED in ${((Date.now() - start) / 1000).toFixed(1)}s`);
      console.log(`Image URI:    ${piece.imageUri}`);
      console.log(`Content hash: ${piece.contentHash}`);
      const uri = await gen.tokenURI(tokenId);
      const json = JSON.parse(Buffer.from(uri.split(",")[1], "base64").toString());
      console.log(`Metadata: ${JSON.stringify(json, null, 2)}`);
      return;
    }
    if (piece.failed) {
      console.error(`Reveal FAILED: ${piece.failReason}`);
      console.error(`The token owner can re-fire with retry(${tokenId}).`);
      process.exit(1);
    }
    await new Promise((r) => setTimeout(r, 3000));
  }
  console.error("Timed out waiting for reveal — check AsyncJobTracker / executor status.");
  process.exit(1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
