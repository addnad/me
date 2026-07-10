// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface of Ritual's RitualWallet system contract
/// (0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948 on chain 1979).
interface IRitualWallet {
    function depositFor(address account, uint256 lockBlocks) external payable;
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Shared roles and the "feed the keeper" plumbing for all
/// keeper-press contracts. The sovereign is a Ritual sovereign-agent
/// harness whose address is known before deployment (CREATE3-predicted),
/// so it can be set as an immutable even though the agent deploys later.
abstract contract KeeperBase {
    address public immutable sovereign;
    address public owner;
    IRitualWallet public immutable ritualWallet;
    uint256 public immutable lockBlocks;

    event OwnerChanged(address indexed previousOwner, address indexed newOwner);
    event KeeperFed(uint256 amount);

    error NotSovereign();
    error NotOwner();
    error NotSovereignOrOwner();

    constructor(address sovereign_, address ritualWallet_, uint256 lockBlocks_) {
        require(sovereign_ != address(0) && ritualWallet_ != address(0), "zero address");
        sovereign = sovereign_;
        ritualWallet = IRitualWallet(ritualWallet_);
        lockBlocks = lockBlocks_;
        owner = msg.sender;
    }

    modifier onlySovereign() {
        if (msg.sender != sovereign) revert NotSovereign();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev The owner fallback keeps the dApp operable if the agent runs out
    /// of funded wakes: sovereign agents on Ritual cannot be revived once dead.
    modifier onlySovereignOrOwner() {
        if (msg.sender != sovereign && msg.sender != owner) revert NotSovereignOrOwner();
        _;
    }

    function setOwner(address newOwner) external onlyOwner {
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    /// @dev Deposits `amount` of this contract's balance into the sovereign's
    /// RitualWallet, funding its future wakes.
    function _feedSovereign(uint256 amount) internal {
        if (amount == 0) return;
        ritualWallet.depositFor{value: amount}(sovereign, lockBlocks);
        emit KeeperFed(amount);
    }
}
