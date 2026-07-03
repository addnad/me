// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SidelineEscrow — prefunded bearer vouchers for offline USDT payments
///
/// A payer opens a "tab" by depositing USDT while online, then signs
/// fixed-denomination vouchers that can be handed to anyone offline
/// (over P2P, QR, or any channel — security lives in the signature,
/// not the pipe). The bearer redeems a voucher on-chain once they are
/// back online. A voucher ID can only be redeemed once, and total
/// redemptions can never exceed the tab's deposit, so the payer cannot
/// mint value they don't have. After the tab expires, the payer
/// reclaims whatever was never redeemed.
contract SidelineEscrow is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Tab {
        uint128 deposited; // total USDT ever deposited into the tab
        uint128 redeemed; // total USDT paid out against vouchers
        uint64 expiry; // after this timestamp the payer may reclaim
    }

    struct Voucher {
        address payer; // tab owner who signed this voucher
        bytes32 id; // unique per voucher; replay key
        uint128 amount; // denomination in USDT base units
        uint64 expiry; // voucher itself is stale after this
    }

    bytes32 public constant VOUCHER_TYPEHASH =
        keccak256("Voucher(address payer,bytes32 id,uint128 amount,uint64 expiry)");

    IERC20 public immutable usdt;

    mapping(address => Tab) public tabs;
    mapping(bytes32 => bool) public spent;

    event TabFunded(address indexed payer, uint128 amount, uint64 expiry);
    event Redeemed(address indexed payer, address indexed bearer, bytes32 indexed id, uint128 amount);
    event Reclaimed(address indexed payer, uint128 amount);

    error TabExpiryInPast();
    error TabExpiryNotExtendable();
    error VoucherExpired();
    error VoucherAlreadySpent();
    error BadSignature();
    error TabUnderfunded();
    error TabNotExpired();
    error NothingToReclaim();

    constructor(IERC20 _usdt) EIP712("Sideline", "1") {
        usdt = _usdt;
    }

    /// @notice Load the tab: deposit USDT that future vouchers draw against.
    /// @dev Expiry may only move forward so outstanding vouchers can't be
    ///      invalidated early by shortening the reclaim window.
    function deposit(uint128 amount, uint64 expiry) external nonReentrant {
        if (expiry <= block.timestamp) revert TabExpiryInPast();
        Tab storage tab = tabs[msg.sender];
        if (expiry < tab.expiry) revert TabExpiryNotExtendable();
        tab.deposited += amount;
        tab.expiry = expiry;
        usdt.safeTransferFrom(msg.sender, address(this), amount);
        emit TabFunded(msg.sender, amount, expiry);
    }

    /// @notice Redeem a bearer voucher; funds go to the caller.
    ///         First valid redemption of an ID wins.
    function redeem(Voucher calldata v, bytes calldata sig) external nonReentrant {
        _redeem(v, sig);
    }

    /// @notice Redeem several vouchers in one transaction (e.g. a vendor
    ///         settling a whole match day at the final whistle).
    function redeemBatch(Voucher[] calldata vs, bytes[] calldata sigs) external nonReentrant {
        require(vs.length == sigs.length, "length mismatch");
        for (uint256 i = 0; i < vs.length; i++) {
            _redeem(vs[i], sigs[i]);
        }
    }

    /// @notice After the tab expires, the payer takes back whatever was
    ///         deposited but never redeemed.
    function reclaim() external nonReentrant {
        Tab storage tab = tabs[msg.sender];
        if (block.timestamp <= tab.expiry) revert TabNotExpired();
        uint128 remainder = tab.deposited - tab.redeemed;
        if (remainder == 0) revert NothingToReclaim();
        tab.redeemed = tab.deposited;
        usdt.safeTransfer(msg.sender, remainder);
        emit Reclaimed(msg.sender, remainder);
    }

    /// @notice Funds still available to honor vouchers from `payer`.
    function available(address payer) external view returns (uint128) {
        Tab storage tab = tabs[payer];
        return tab.deposited - tab.redeemed;
    }

    function hashVoucher(Voucher calldata v) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(VOUCHER_TYPEHASH, v.payer, v.id, v.amount, v.expiry)));
    }

    function _redeem(Voucher calldata v, bytes calldata sig) internal {
        if (block.timestamp > v.expiry) revert VoucherExpired();
        if (spent[v.id]) revert VoucherAlreadySpent();
        if (ECDSA.recover(hashVoucher(v), sig) != v.payer) revert BadSignature();

        Tab storage tab = tabs[v.payer];
        if (tab.deposited - tab.redeemed < v.amount) revert TabUnderfunded();

        spent[v.id] = true;
        tab.redeemed += v.amount;
        usdt.safeTransfer(msg.sender, v.amount);
        emit Redeemed(v.payer, msg.sender, v.id, v.amount);
    }
}
