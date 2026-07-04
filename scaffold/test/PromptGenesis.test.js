const { expect } = require("chai");
const { ethers, network } = require("hardhat");

const IMAGE_PRECOMPILE = "0x0000000000000000000000000000000000000818";
const TX_HASH_PRECOMPILE = "0x0000000000000000000000000000000000000830";
const ASYNC_DELIVERY = "0x5A16214fF555848411544b005f7Ac063742f39F6";

const RESPONSE_TYPES = [
  "bool", "bytes", "string", "bytes32", "bool", "uint32", "uint32", "uint32", "string",
];

function imageResponse({ hasError = false, uri = "", contentHash = ethers.ZeroHash, error = "" } = {}) {
  return ethers.AbiCoder.defaultAbiCoder().encode(RESPONSE_TYPES, [
    hasError, "0x", uri, contentHash, false, 12345, 1024, 1024, error,
  ]);
}

describe("PromptGenesis", function () {
  let gen, owner, minter, other, asyncDelivery;
  let fakeTxHash;

  beforeEach(async function () {
    [owner, minter, other] = await ethers.getSigners();

    // Install mocks at the Ritual precompile addresses.
    // MockTxHash returns a settable bytes32; MockSink accepts any call.
    const MockTxHash = await ethers.getContractFactory("MockTxHash");
    const txHashMock = await MockTxHash.deploy();
    await network.provider.send("hardhat_setCode", [
      TX_HASH_PRECOMPILE,
      await network.provider.send("eth_getCode", [await txHashMock.getAddress()]),
    ]);
    const MockSink = await ethers.getContractFactory("MockSink");
    const sink = await MockSink.deploy();
    await network.provider.send("hardhat_setCode", [
      IMAGE_PRECOMPILE,
      await network.provider.send("eth_getCode", [await sink.getAddress()]),
    ]);

    fakeTxHash = ethers.keccak256(ethers.toUtf8Bytes("mint-tx-1"));
    await (await ethers.getContractAt("MockTxHash", TX_HASH_PRECOMPILE)).setHash(fakeTxHash);

    // Impersonate the AsyncDelivery system for callbacks.
    await network.provider.send("hardhat_impersonateAccount", [ASYNC_DELIVERY]);
    await network.provider.send("hardhat_setBalance", [ASYNC_DELIVERY, "0x1000000000000000000"]);
    asyncDelivery = await ethers.getSigner(ASYNC_DELIVERY);

    const PromptGenesis = await ethers.getContractFactory("PromptGenesis");
    gen = await PromptGenesis.deploy();
    await gen.setExecutorConfig(
      other.address,
      ["0x1234"],
      { platform: "hf", path: "user/hex-payload-art", keyRef: "HF_TOKEN" }
    );
  });

  const PRICE = ethers.parseEther("0.01");

  describe("mint", function () {
    it("mints a gestating token, maps jobId = tx hash, emits MintRequested", async function () {
      await expect(gen.connect(minter).mint("neon shrine in the rain", { value: PRICE }))
        .to.emit(gen, "MintRequested")
        .withArgs(1n, fakeTxHash, minter.address, "neon shrine in the rain");

      expect(await gen.ownerOf(1)).to.equal(minter.address);
      expect(await gen.jobToToken(fakeTxHash)).to.equal(1n);
      const piece = await gen.pieces(1);
      expect(piece.prompt).to.equal("neon shrine in the rain");
      expect(piece.revealed).to.equal(false);
      expect(piece.jobId).to.equal(fakeTxHash);
    });

    it("rejects wrong payment", async function () {
      await expect(gen.connect(minter).mint("x", { value: 0 }))
        .to.be.revertedWithCustomError(gen, "WrongPayment");
    });

    it("rejects when executor is not configured", async function () {
      const fresh = await (await ethers.getContractFactory("PromptGenesis")).deploy();
      await expect(fresh.connect(minter).mint("x", { value: PRICE }))
        .to.be.revertedWithCustomError(fresh, "ExecutorNotConfigured");
    });

    it("rejects a second mint sharing the same tx hash (jobId collision)", async function () {
      await gen.connect(minter).mint("first", { value: PRICE });
      // tx hash mock still returns the same hash -> collision guard trips
      await expect(gen.connect(minter).mint("second", { value: PRICE }))
        .to.be.revertedWith("one mint per tx");
    });

    it("tokenURI reports gestating before reveal", async function () {
      await gen.connect(minter).mint("aurora over ruins", { value: PRICE });
      const uri = await gen.tokenURI(1);
      const json = JSON.parse(Buffer.from(uri.split(",")[1], "base64").toString());
      expect(json.name).to.equal("HEX_PAYLOAD Genesis #1");
      expect(json.attributes.find((a) => a.trait_type === "Status").value).to.equal("gestating");
      expect(json.attributes.find((a) => a.trait_type === "Prompt").value).to.equal("aurora over ruins");
    });
  });

  describe("onImageReady", function () {
    beforeEach(async function () {
      await gen.connect(minter).mint("glass cathedral", { value: PRICE });
    });

    it("reveals the token on success", async function () {
      const hash = ethers.keccak256(ethers.toUtf8Bytes("image-bytes"));
      await expect(
        gen.connect(asyncDelivery).onImageReady(
          fakeTxHash,
          imageResponse({ uri: "ipfs://QmExample", contentHash: hash })
        )
      )
        .to.emit(gen, "Revealed")
        .withArgs(1n, fakeTxHash, "ipfs://QmExample", hash);

      const piece = await gen.pieces(1);
      expect(piece.revealed).to.equal(true);
      expect(piece.imageUri).to.equal("ipfs://QmExample");

      const uri = await gen.tokenURI(1);
      const json = JSON.parse(Buffer.from(uri.split(",")[1], "base64").toString());
      expect(json.image).to.equal("ipfs://QmExample");
      expect(json.attributes.find((a) => a.trait_type === "Status").value).to.equal("revealed");
      expect(json.attributes.find((a) => a.trait_type === "Provenance (jobId = mint tx)").value)
        .to.equal(fakeTxHash);
    });

    it("rejects callers other than AsyncDelivery", async function () {
      await expect(
        gen.connect(other).onImageReady(fakeTxHash, imageResponse({ uri: "ipfs://x" }))
      ).to.be.revertedWithCustomError(gen, "NotAsyncDelivery");
    });

    it("rejects unknown jobIds", async function () {
      await expect(
        gen.connect(asyncDelivery).onImageReady(ethers.ZeroHash, imageResponse({ uri: "ipfs://x" }))
      ).to.be.revertedWithCustomError(gen, "UnknownJob");
    });

    it("marks the piece failed on error responses", async function () {
      await expect(
        gen.connect(asyncDelivery).onImageReady(
          fakeTxHash,
          imageResponse({ hasError: true, error: "model timeout" })
        )
      )
        .to.emit(gen, "RevealFailed")
        .withArgs(1n, fakeTxHash, "model timeout");
      const piece = await gen.pieces(1);
      expect(piece.failed).to.equal(true);
      expect(piece.failReason).to.equal("model timeout");
    });
  });

  describe("retry", function () {
    beforeEach(async function () {
      await gen.connect(minter).mint("shattered moon", { value: PRICE });
      await gen.connect(asyncDelivery).onImageReady(
        fakeTxHash,
        imageResponse({ hasError: true, error: "boom" })
      );
    });

    it("lets the token owner re-fire generation under a new jobId", async function () {
      const newHash = ethers.keccak256(ethers.toUtf8Bytes("retry-tx"));
      await (await ethers.getContractAt("MockTxHash", TX_HASH_PRECOMPILE)).setHash(newHash);

      await expect(gen.connect(minter).retry(1))
        .to.emit(gen, "MintRequested")
        .withArgs(1n, newHash, minter.address, "shattered moon");

      expect(await gen.jobToToken(newHash)).to.equal(1n);
      const piece = await gen.pieces(1);
      expect(piece.failed).to.equal(false);

      // and the new job can reveal
      await gen.connect(asyncDelivery).onImageReady(newHash, imageResponse({ uri: "ipfs://retryimg" }));
      expect((await gen.pieces(1)).revealed).to.equal(true);
    });

    it("rejects retry by non-owners and on non-failed tokens", async function () {
      await expect(gen.connect(other).retry(1)).to.be.revertedWithCustomError(gen, "NotAuthorized");
      const newHash = ethers.keccak256(ethers.toUtf8Bytes("retry-tx"));
      await (await ethers.getContractAt("MockTxHash", TX_HASH_PRECOMPILE)).setHash(newHash);
      await gen.connect(minter).retry(1);
      await expect(gen.connect(minter).retry(1)).to.be.revertedWithCustomError(gen, "NotFailed");
    });
  });

  describe("ERC-721 basics", function () {
    it("transfers and tracks balances", async function () {
      await gen.connect(minter).mint("drift", { value: PRICE });
      await gen.connect(minter).transferFrom(minter.address, other.address, 1);
      expect(await gen.ownerOf(1)).to.equal(other.address);
      expect(await gen.balanceOf(minter.address)).to.equal(0n);
      expect(await gen.balanceOf(other.address)).to.equal(1n);
    });

    it("blocks unauthorized transfers", async function () {
      await gen.connect(minter).mint("drift", { value: PRICE });
      await expect(
        gen.connect(other).transferFrom(minter.address, other.address, 1)
      ).to.be.revertedWithCustomError(gen, "NotAuthorized");
    });

    it("owner can withdraw mint fees", async function () {
      await gen.connect(minter).mint("drift", { value: PRICE });
      const before = await ethers.provider.getBalance(other.address);
      await gen.withdraw(other.address);
      expect(await ethers.provider.getBalance(other.address)).to.equal(before + PRICE);
    });
  });
});
