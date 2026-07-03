"use strict";

/**
 * @sideline/voucher — mint, verify, and serialize bearer vouchers.
 *
 * A voucher is an EIP-712 signature over { payer, id, amount, expiry }
 * against the SidelineEscrow domain. Verification needs no network
 * access, which is the whole point: a payee standing in a stadium with
 * no signal can validate a payment with nothing but cryptography.
 */

const { ethers } = require("ethers");

const VOUCHER_TYPES = {
  Voucher: [
    { name: "payer", type: "address" },
    { name: "id", type: "bytes32" },
    { name: "amount", type: "uint128" },
    { name: "expiry", type: "uint64" },
  ],
};

function domain(chainId, escrow) {
  return {
    name: "Sideline",
    version: "1",
    chainId,
    verifyingContract: escrow,
  };
}

/**
 * Sign a fresh voucher against the payer's tab.
 * @param {ethers.Signer} signer  payer's wallet (must own the tab)
 * @param {{chainId: number|bigint, escrow: string, amount: bigint, expiry: number|bigint}} opts
 * @returns {Promise<{voucher: object, sig: string}>}
 */
async function mintVoucher(signer, { chainId, escrow, amount, expiry }) {
  const voucher = {
    payer: await signer.getAddress(),
    id: ethers.hexlify(ethers.randomBytes(32)),
    amount: BigInt(amount),
    expiry: BigInt(expiry),
  };
  const sig = await signer.signTypedData(domain(chainId, escrow), VOUCHER_TYPES, voucher);
  return { voucher, sig };
}

/**
 * Offline check: does the signature really come from voucher.payer,
 * and is the voucher not stale? (Whether the tab still has funds can
 * only be known on-chain — this is the bearer-risk boundary.)
 * @returns {{ok: boolean, reason?: string}}
 */
function verifyVoucher({ voucher, sig }, { chainId, escrow, now = Math.floor(Date.now() / 1000) }) {
  if (BigInt(voucher.expiry) < BigInt(now)) {
    return { ok: false, reason: "expired" };
  }
  let recovered;
  try {
    recovered = ethers.verifyTypedData(domain(chainId, escrow), VOUCHER_TYPES, voucher, sig);
  } catch {
    return { ok: false, reason: "malformed signature" };
  }
  if (recovered.toLowerCase() !== voucher.payer.toLowerCase()) {
    return { ok: false, reason: "signer is not the payer" };
  }
  return { ok: true };
}

/**
 * Compact wire format (base64url JSON) — small enough for a QR code,
 * trivial to ship over a P2P stream.
 */
function encodeVoucher({ voucher, sig }) {
  const payload = JSON.stringify({
    p: voucher.payer,
    i: voucher.id,
    a: voucher.amount.toString(),
    e: voucher.expiry.toString(),
    s: sig,
  });
  return Buffer.from(payload, "utf8").toString("base64url");
}

function decodeVoucher(encoded) {
  const { p, i, a, e, s } = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));
  return {
    voucher: { payer: p, id: i, amount: BigInt(a), expiry: BigInt(e) },
    sig: s,
  };
}

module.exports = {
  VOUCHER_TYPES,
  domain,
  mintVoucher,
  verifyVoucher,
  encodeVoucher,
  decodeVoucher,
};
