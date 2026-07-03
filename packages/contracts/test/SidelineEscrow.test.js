const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time, loadFixture } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { mintVoucher, verifyVoucher, encodeVoucher, decodeVoucher } = require("@sideline/voucher");

const USDT = (n) => ethers.parseUnits(n.toString(), 6);
const DAY = 24 * 60 * 60;

describe("SidelineEscrow", function () {
  async function deployFixture() {
    const [payer, vendor, other] = await ethers.getSigners();

    const usdt = await (await ethers.getContractFactory("MockUSDT")).deploy();
    const escrow = await (await ethers.getContractFactory("SidelineEscrow")).deploy(usdt.target);

    await usdt.faucet(payer.address, USDT(1000));
    await usdt.connect(payer).approve(escrow.target, USDT(1000));

    const { chainId } = await ethers.provider.getNetwork();
    const ctx = { chainId, escrow: escrow.target };

    const tabExpiry = (await time.latest()) + 7 * DAY;
    return { payer, vendor, other, usdt, escrow, ctx, tabExpiry };
  }

  async function fundedFixture() {
    const f = await deployFixture();
    await f.escrow.connect(f.payer).deposit(USDT(100), f.tabExpiry);
    return f;
  }

  describe("tab lifecycle", function () {
    it("accepts deposits and tracks available funds", async function () {
      const { payer, escrow, usdt, tabExpiry } = await loadFixture(deployFixture);
      await expect(escrow.connect(payer).deposit(USDT(100), tabExpiry))
        .to.emit(escrow, "TabFunded")
        .withArgs(payer.address, USDT(100), tabExpiry);
      expect(await escrow.available(payer.address)).to.equal(USDT(100));
      expect(await usdt.balanceOf(escrow.target)).to.equal(USDT(100));
    });

    it("rejects a tab expiry in the past or one that shortens the window", async function () {
      const { payer, escrow, tabExpiry } = await loadFixture(fundedFixture);
      const past = (await time.latest()) - 1;
      await expect(escrow.connect(payer).deposit(USDT(1), past)).to.be.revertedWithCustomError(
        escrow,
        "TabExpiryInPast"
      );
      await expect(
        escrow.connect(payer).deposit(USDT(1), tabExpiry - DAY)
      ).to.be.revertedWithCustomError(escrow, "TabExpiryNotExtendable");
    });

    it("lets the payer reclaim the unredeemed remainder only after expiry", async function () {
      const { payer, vendor, escrow, usdt, ctx, tabExpiry } = await loadFixture(fundedFixture);
      const { voucher, sig } = await mintVoucher(payer, { ...ctx, amount: USDT(30), expiry: tabExpiry });
      await escrow.connect(vendor).redeem(voucher, sig);

      await expect(escrow.connect(payer).reclaim()).to.be.revertedWithCustomError(escrow, "TabNotExpired");

      await time.increaseTo(tabExpiry + 1);
      const before = await usdt.balanceOf(payer.address);
      await expect(escrow.connect(payer).reclaim()).to.emit(escrow, "Reclaimed").withArgs(payer.address, USDT(70));
      expect((await usdt.balanceOf(payer.address)) - before).to.equal(USDT(70));

      await expect(escrow.connect(payer).reclaim()).to.be.revertedWithCustomError(escrow, "NothingToReclaim");
    });
  });

  describe("offline flow: mint → verify offline → redeem", function () {
    it("pays the bearer on redemption", async function () {
      const { payer, vendor, escrow, usdt, ctx, tabExpiry } = await loadFixture(fundedFixture);

      // payer signs offline
      const minted = await mintVoucher(payer, { ...ctx, amount: USDT(5), expiry: tabExpiry });

      // vendor checks it with zero network access
      expect(verifyVoucher(minted, ctx).ok).to.equal(true);

      // ...later, back online, vendor redeems
      await expect(escrow.connect(vendor).redeem(minted.voucher, minted.sig))
        .to.emit(escrow, "Redeemed")
        .withArgs(payer.address, vendor.address, minted.voucher.id, USDT(5));
      expect(await usdt.balanceOf(vendor.address)).to.equal(USDT(5));
      expect(await escrow.available(payer.address)).to.equal(USDT(95));
    });

    it("survives the wire: encode → decode → redeem", async function () {
      const { payer, vendor, escrow, ctx, tabExpiry } = await loadFixture(fundedFixture);
      const minted = await mintVoucher(payer, { ...ctx, amount: USDT(5), expiry: tabExpiry });

      const wire = encodeVoucher(minted); // what travels over P2P or a QR code
      const received = decodeVoucher(wire);

      expect(verifyVoucher(received, ctx).ok).to.equal(true);
      await escrow.connect(vendor).redeem(received.voucher, received.sig);
    });

    it("redeems a batch (vendor settling a match day)", async function () {
      const { payer, vendor, escrow, usdt, ctx, tabExpiry } = await loadFixture(fundedFixture);
      const a = await mintVoucher(payer, { ...ctx, amount: USDT(5), expiry: tabExpiry });
      const b = await mintVoucher(payer, { ...ctx, amount: USDT(7), expiry: tabExpiry });
      await escrow.connect(vendor).redeemBatch([a.voucher, b.voucher], [a.sig, b.sig]);
      expect(await usdt.balanceOf(vendor.address)).to.equal(USDT(12));
    });
  });

  describe("double-spend containment", function () {
    it("a voucher ID can only be redeemed once — first bearer wins", async function () {
      const { payer, vendor, other, escrow, ctx, tabExpiry } = await loadFixture(fundedFixture);
      const { voucher, sig } = await mintVoucher(payer, { ...ctx, amount: USDT(5), expiry: tabExpiry });

      await escrow.connect(vendor).redeem(voucher, sig);
      await expect(escrow.connect(other).redeem(voucher, sig)).to.be.revertedWithCustomError(
        escrow,
        "VoucherAlreadySpent"
      );
    });

    it("vouchers beyond the deposit bounce: the tab is the hard ceiling", async function () {
      const { payer, vendor, other, escrow, ctx, tabExpiry } = await loadFixture(fundedFixture);
      // 100 deposited, but payer signs 60 + 60
      const a = await mintVoucher(payer, { ...ctx, amount: USDT(60), expiry: tabExpiry });
      const b = await mintVoucher(payer, { ...ctx, amount: USDT(60), expiry: tabExpiry });

      await escrow.connect(vendor).redeem(a.voucher, a.sig);
      await expect(escrow.connect(other).redeem(b.voucher, b.sig)).to.be.revertedWithCustomError(
        escrow,
        "TabUnderfunded"
      );
    });

    it("rejects forged and tampered vouchers", async function () {
      const { payer, vendor, other, escrow, ctx, tabExpiry } = await loadFixture(fundedFixture);

      // signed by someone who isn't the claimed payer
      const forged = await mintVoucher(other, { ...ctx, amount: USDT(5), expiry: tabExpiry });
      forged.voucher.payer = payer.address;
      expect(verifyVoucher(forged, ctx).ok).to.equal(false);
      await expect(escrow.connect(vendor).redeem(forged.voucher, forged.sig)).to.be.revertedWithCustomError(
        escrow,
        "BadSignature"
      );

      // amount inflated after signing
      const tampered = await mintVoucher(payer, { ...ctx, amount: USDT(5), expiry: tabExpiry });
      tampered.voucher.amount = USDT(50);
      expect(verifyVoucher(tampered, ctx).ok).to.equal(false);
      await expect(escrow.connect(vendor).redeem(tampered.voucher, tampered.sig)).to.be.revertedWithCustomError(
        escrow,
        "BadSignature"
      );
    });

    it("rejects expired vouchers, on-chain and offline", async function () {
      const { payer, vendor, escrow, ctx } = await loadFixture(fundedFixture);
      const soon = (await time.latest()) + 60;
      const minted = await mintVoucher(payer, { ...ctx, amount: USDT(5), expiry: soon });

      await time.increaseTo(soon + 1);
      expect(verifyVoucher(minted, { ...ctx, now: soon + 1 }).ok).to.equal(false);
      await expect(escrow.connect(vendor).redeem(minted.voucher, minted.sig)).to.be.revertedWithCustomError(
        escrow,
        "VoucherExpired"
      );
    });
  });
});
