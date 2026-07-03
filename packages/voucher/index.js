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
 * Sign a fresh voucher against the payer's tab, using any signing backend.
 * @param {{address: string, signTypedData: function}} payer
 *   `signTypedData({domain, types, message})` — the WDK account shape.
 * @param {{chainId: number|bigint, escrow: string, amount: bigint, expiry: number|bigint}} opts
 * @returns {Promise<{voucher: object, sig: string}>}
 */
async function mintVoucherWith(payer, { chainId, escrow, amount, expiry }) {
  const voucher = {
    payer: payer.address,
    id: ethers.hexlify(ethers.randomBytes(32)),
    amount: BigInt(amount),
    expiry: BigInt(expiry),
  };
  const sig = await payer.signTypedData({
    domain: domain(chainId, escrow),
    types: VOUCHER_TYPES,
    message: voucher,
  });
  return { voucher, sig };
}

/**
 * Convenience wrapper for ethers.Signer backends (tests, scripts).
 * @param {ethers.Signer} signer  payer's wallet (must own the tab)
 */
async function mintVoucher(signer, opts) {
  return mintVoucherWith(
    {
      address: await signer.getAddress(),
      signTypedData: ({ domain, types, message }) => signer.signTypedData(domain, types, message),
    },
    opts
  );
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
 * trivial to ship over a P2P stream. Uses ethers' codecs so the same
 * code runs in Node, Bare, and browsers (no Buffer dependency).
 */
function encodeVoucher({ voucher, sig }) {
  const payload = JSON.stringify({
    p: voucher.payer,
    i: voucher.id,
    a: voucher.amount.toString(),
    e: voucher.expiry.toString(),
    s: sig,
  });
  const b64 = ethers.encodeBase64(ethers.toUtf8Bytes(payload));
  return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function decodeVoucher(encoded) {
  let b64 = encoded.replace(/-/g, "+").replace(/_/g, "/");
  b64 += "=".repeat((4 - (b64.length % 4)) % 4);
  const { p, i, a, e, s } = JSON.parse(ethers.toUtf8String(ethers.decodeBase64(b64)));
  return {
    voucher: { payer: p, id: i, amount: BigInt(a), expiry: BigInt(e) },
    sig: s,
  };
}

module.exports = {
  VOUCHER_TYPES,
  domain,
  mintVoucher,
  mintVoucherWith,
  verifyVoucher,
  encodeVoucher,
  decodeVoucher,
};
