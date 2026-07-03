"use strict";

/**
 * @sideline/wallet — the Sideline client SDK.
 *
 * Self-custody via Tether WDK (@tetherto/wdk-wallet-evm): the user's
 * BIP-39 seed never leaves the device, every transaction and every
 * voucher signature comes from the WDK account. This module adds the
 * Sideline verbs on top: load a tab, mint vouchers, verify and redeem
 * them, reclaim what's left after the final whistle.
 */

const WalletManagerEvm = require("@tetherto/wdk-wallet-evm").default;
const { SeedSignerEvm } = require("@tetherto/wdk-wallet-evm/signers");
const { ethers } = require("ethers");
const { ESCROW_ABI, ERC20_ABI } = require("@sideline/contracts/abi");
const { mintVoucherWith, verifyVoucher, encodeVoucher, decodeVoucher } = require("@sideline/voucher");

const escrowIface = new ethers.Interface(ESCROW_ABI);
const erc20Iface = new ethers.Interface(ERC20_ABI);

class SidelineWallet {
  /**
   * @param {object} opts
   * @param {string} opts.seedPhrase BIP-39 mnemonic (self-custodied)
   * @param {string} opts.rpc EVM RPC endpoint
   * @param {string} opts.escrow SidelineEscrow address
   * @param {string} opts.usdt USDT token address
   * @param {number} [opts.accountIndex] BIP-44 account index (default 0)
   */
  static async open({ seedPhrase, rpc, escrow, usdt, accountIndex = 0 }) {
    // Hand WDK raw seed bytes rather than the phrase: bip39's dynamic
    // wordlist require breaks under browser bundlers, and ethers derives
    // the identical BIP-39 seed in every runtime.
    const seedBytes = ethers.getBytes(ethers.Mnemonic.fromPhrase(seedPhrase).computeSeed());
    const manager = new WalletManagerEvm(new SeedSignerEvm(seedBytes), { provider: rpc });
    const account = await manager.getAccount(accountIndex);
    const address = await account.getAddress();
    const provider = new ethers.JsonRpcProvider(rpc);
    const { chainId } = await provider.getNetwork();
    return new SidelineWallet({ account, address, provider, chainId, escrow, usdt });
  }

  constructor({ account, address, provider, chainId, escrow, usdt }) {
    this.account = account; // WDK WalletAccountEvm — sole signer
    this.address = address;
    this.provider = provider; // read-only views
    this.chainId = chainId;
    this.escrow = escrow;
    this.usdt = usdt;
    this._escrowRead = new ethers.Contract(escrow, ESCROW_ABI, provider);
    this._usdtRead = new ethers.Contract(usdt, ERC20_ABI, provider);
  }

  // ---- reads ----------------------------------------------------------

  async usdtBalance() {
    return this._usdtRead.balanceOf(this.address);
  }

  async tab(payer = this.address) {
    const [deposited, redeemed, expiry] = await this._escrowRead.tabs(payer);
    return { deposited, redeemed, expiry, available: deposited - redeemed };
  }

  async isSpent(voucherId) {
    return this._escrowRead.spent(voucherId);
  }

  // ---- online: load the tab -------------------------------------------

  /**
   * Approve (if needed) and deposit USDT into the tab.
   * @param {bigint} amount USDT base units (6 decimals)
   * @param {number|bigint} expiry unix seconds; only extendable
   */
  async loadTab(amount, expiry) {
    const receipts = [];
    const allowance = await this._usdtRead.allowance(this.address, this.escrow);
    if (allowance < amount) {
      receipts.push(
        await this._send(this.usdt, erc20Iface.encodeFunctionData("approve", [this.escrow, amount]))
      );
    }
    receipts.push(
      await this._send(this.escrow, escrowIface.encodeFunctionData("deposit", [amount, expiry]))
    );
    return receipts;
  }

  // ---- offline: mint & verify ------------------------------------------

  /**
   * Sign a bearer voucher against this wallet's tab. Pure signing —
   * works with zero connectivity. Returns the compact wire string.
   */
  async mintVoucher(amount, expiry) {
    const minted = await mintVoucherWith(
      { address: this.address, signTypedData: (args) => this.account.signTypedData(args) },
      { chainId: this.chainId, escrow: this.escrow, amount, expiry }
    );
    return { ...minted, wire: encodeVoucher(minted) };
  }

  /**
   * Payee-side check of an incoming wire voucher. No network.
   * @returns {{ok: boolean, reason?: string, voucher?: object, sig?: string}}
   */
  checkIncoming(wire, now = Math.floor(Date.now() / 1000)) {
    let decoded;
    try {
      decoded = decodeVoucher(wire);
    } catch {
      return { ok: false, reason: "unreadable voucher" };
    }
    const res = verifyVoucher(decoded, { chainId: this.chainId, escrow: this.escrow, now });
    return { ...res, ...decoded };
  }

  // ---- online: settle ---------------------------------------------------

  /** Redeem one or many wire vouchers; funds land at this wallet. */
  async redeem(wires) {
    const list = (Array.isArray(wires) ? wires : [wires]).map(decodeVoucher);
    for (const item of list) {
      const res = verifyVoucher(item, { chainId: this.chainId, escrow: this.escrow });
      if (!res.ok) throw new Error(`refusing to redeem: ${res.reason}`);
    }
    const asTuple = ({ voucher }) => [voucher.payer, voucher.id, voucher.amount, voucher.expiry];
    const data =
      list.length === 1
        ? escrowIface.encodeFunctionData("redeem", [asTuple(list[0]), list[0].sig])
        : escrowIface.encodeFunctionData("redeemBatch", [list.map(asTuple), list.map((x) => x.sig)]);
    return this._send(this.escrow, data);
  }

  /** After tab expiry: pull back whatever was never redeemed. */
  async reclaim() {
    return this._send(this.escrow, escrowIface.encodeFunctionData("reclaim", []));
  }

  // ---- internal ---------------------------------------------------------

  async _send(to, data) {
    // Explicit, locally tracked nonce: both WDK's and ethers' providers
    // cache the account transaction count for a short window, which
    // breaks back-to-back sends (approve → deposit).
    if (this._nonce == null) {
      this._nonce = await this.provider.getTransactionCount(this.address, "pending");
    }
    const nonce = this._nonce++;
    try {
      const { hash } = await this.account.sendTransaction({ to, data, nonce });
      await this.provider.waitForTransaction(hash);
      return hash;
    } catch (err) {
      this._nonce = null; // resync from chain on the next attempt
      throw err;
    }
  }
}

module.exports = { SidelineWallet };
