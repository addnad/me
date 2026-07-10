const { expect } = require("chai");
const { ethers, network } = require("hardhat");

const LOCK_BLOCKS = 100000;
const rit = (n) => ethers.parseEther(String(n));

async function setTime(ts) {
  await network.provider.send("evm_setNextBlockTimestamp", [ts]);
  await network.provider.send("evm_mine");
}

describe("keeper-press", () => {
  let owner, sovereign, alice, bob;
  let wallet; // MockRitualWallet

  beforeEach(async () => {
    [owner, sovereign, alice, bob] = await ethers.getSigners();
    wallet = await (await ethers.getContractFactory("MockRitualWallet")).deploy();
  });

  const deploy = async (name) =>
    (await ethers.getContractFactory(name)).deploy(
      sovereign.address,
      await wallet.getAddress(),
      LOCK_BLOCKS
    );

  describe("AgentWatchdog", () => {
    let dog;
    const agent = "0x00000000000000000000000000000000000000A9";

    beforeEach(async () => {
      dog = await deploy("AgentWatchdog");
    });

    it("registers with escrow and reports needsTopUp from wallet balance", async () => {
      await dog.connect(alice).register(agent, rit(0.5), rit(1), { value: rit(2) });
      expect(await dog.agentCount()).to.equal(1);
      expect(await dog.needsTopUp(agent)).to.equal(true); // wallet balance 0 < 0.5

      await wallet.depositFor(agent, LOCK_BLOCKS, { value: rit(1) });
      expect(await dog.needsTopUp(agent)).to.equal(false);
    });

    it("sovereign tops up a low agent, takes 2% fee into its own wallet", async () => {
      await dog.connect(alice).register(agent, rit(0.5), rit(1), { value: rit(2) });
      await dog.connect(sovereign).topUp(agent);

      expect(await wallet.balanceOf(agent)).to.equal(rit(0.98)); // 1 - 2%
      expect(await wallet.balanceOf(sovereign.address)).to.equal(rit(0.02));
      const reg = await dog.registrations(agent);
      expect(reg.escrow).to.equal(rit(1));
      expect(reg.topUps).to.equal(1);
    });

    it("refuses top-up when agent is above minimum or caller is a stranger", async () => {
      await dog.connect(alice).register(agent, rit(0.5), rit(1), { value: rit(2) });
      await wallet.depositFor(agent, LOCK_BLOCKS, { value: rit(1) });
      await expect(dog.connect(sovereign).topUp(agent)).to.be.revertedWithCustomError(dog, "AboveMinimum");
      await wallet.drain(agent, rit(1));
      await expect(dog.connect(bob).topUp(agent)).to.be.revertedWithCustomError(dog, "NotRegistrant");
    });

    it("registrant can withdraw unspent escrow", async () => {
      await dog.connect(alice).register(agent, rit(0.5), rit(1), { value: rit(2) });
      const before = await ethers.provider.getBalance(alice.address);
      const tx = await dog.connect(alice).withdraw(agent, rit(2));
      const rc = await tx.wait();
      const gas = rc.gasUsed * rc.gasPrice;
      expect(await ethers.provider.getBalance(alice.address)).to.equal(before + rit(2) - gas);
      await expect(dog.connect(sovereign).topUp(agent)).to.be.revertedWithCustomError(dog, "EscrowEmpty");
    });
  });

  describe("KeeperDigest", () => {
    let digest;

    beforeEach(async () => {
      digest = await deploy("KeeperDigest");
    });

    it("only sovereign or owner can publish", async () => {
      await expect(
        digest.connect(alice).publish("h", "b", "s")
      ).to.be.revertedWithCustomError(digest, "NotSovereignOrOwner");
      await digest.connect(sovereign).publish("Genesis lives", "body", "src");
      await digest.connect(owner).publish("Owner fallback", "body", "src");
      expect(await digest.editionCount()).to.equal(2);
    });

    it("tips are deposited into the sovereign's RitualWallet in full", async () => {
      await digest.connect(sovereign).publish("h", "b", "s");
      await digest.connect(alice).tip(0, { value: rit(0.3) });
      expect(await wallet.balanceOf(sovereign.address)).to.equal(rit(0.3));
      const e = await digest.getEdition(0);
      expect(e.tips).to.equal(rit(0.3));
      expect(await ethers.provider.getBalance(await digest.getAddress())).to.equal(0);
    });
  });

  describe("HeadlineMarkets", () => {
    let mkt;
    let t0;

    beforeEach(async () => {
      mkt = await deploy("HeadlineMarkets");
      t0 = (await ethers.provider.getBlock("latest")).timestamp;
      await mkt.connect(sovereign).openMarket("Will it ship?", t0 + 1000, t0 + 2000);
    });

    it("full lifecycle: bet, resolve, claim with 2% fee, feedKeeper", async () => {
      await mkt.connect(alice).bet(0, true, { value: rit(1) });
      await mkt.connect(bob).bet(0, false, { value: rit(1) });

      await setTime(t0 + 1001);
      await mkt.connect(sovereign).resolve(0, 1); // Yes

      const before = await ethers.provider.getBalance(alice.address);
      const rc = await (await mkt.connect(alice).claim(0)).wait();
      const gas = rc.gasUsed * rc.gasPrice;
      // alice takes the whole 2 RITUAL pool minus 2% fee
      expect(await ethers.provider.getBalance(alice.address)).to.equal(before + rit(1.96) - gas);

      await expect(mkt.connect(bob).claim(0)).to.be.revertedWithCustomError(mkt, "NothingToClaim");

      await mkt.feedKeeper();
      expect(await wallet.balanceOf(sovereign.address)).to.equal(rit(0.04));
    });

    it("voids after resolveBy so funds never depend on the agent staying alive", async () => {
      await mkt.connect(alice).bet(0, true, { value: rit(1) });
      await expect(mkt.voidMarket(0)).to.be.revertedWithCustomError(mkt, "NotYetVoidable");
      await setTime(t0 + 2001);
      await mkt.connect(bob).voidMarket(0); // anyone
      const before = await ethers.provider.getBalance(alice.address);
      const rc = await (await mkt.connect(alice).claim(0)).wait();
      const gas = rc.gasUsed * rc.gasPrice;
      expect(await ethers.provider.getBalance(alice.address)).to.equal(before + rit(1) - gas);
    });

    it("auto-voids when the winning pool is empty", async () => {
      await mkt.connect(bob).bet(0, false, { value: rit(1) });
      await setTime(t0 + 1001);
      await mkt.connect(sovereign).resolve(0, 1); // Yes wins but yesPool is empty
      const m = await mkt.getMarket(0);
      expect(m.outcome).to.equal(3); // Void
      const before = await ethers.provider.getBalance(bob.address);
      const rc = await (await mkt.connect(bob).claim(0)).wait();
      const gas = rc.gasUsed * rc.gasPrice;
      expect(await ethers.provider.getBalance(bob.address)).to.equal(before + rit(1) - gas);
    });

    it("strangers cannot open or resolve", async () => {
      await expect(
        mkt.connect(alice).openMarket("q", t0 + 1000, t0 + 2000)
      ).to.be.revertedWithCustomError(mkt, "NotSovereignOrOwner");
      await setTime(t0 + 1001);
      await expect(mkt.connect(alice).resolve(0, 1)).to.be.revertedWithCustomError(mkt, "NotSovereignOrOwner");
    });
  });
});
