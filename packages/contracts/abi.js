"use strict";

/**
 * Human-readable ABIs for consumers that shouldn't depend on Hardhat
 * artifacts (the wallet package, the Pear app).
 */

const ESCROW_ABI = [
  "function deposit(uint128 amount, uint64 expiry)",
  "function redeem((address payer, bytes32 id, uint128 amount, uint64 expiry) v, bytes sig)",
  "function redeemBatch((address payer, bytes32 id, uint128 amount, uint64 expiry)[] vs, bytes[] sigs)",
  "function reclaim()",
  "function available(address payer) view returns (uint128)",
  "function tabs(address payer) view returns (uint128 deposited, uint128 redeemed, uint64 expiry)",
  "function spent(bytes32 id) view returns (bool)",
  "function usdt() view returns (address)",
  "event TabFunded(address indexed payer, uint128 amount, uint64 expiry)",
  "event Redeemed(address indexed payer, address indexed bearer, bytes32 indexed id, uint128 amount)",
  "event Reclaimed(address indexed payer, uint128 amount)",
];

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function faucet(address to, uint256 amount)",
];

module.exports = { ESCROW_ABI, ERC20_ABI };
