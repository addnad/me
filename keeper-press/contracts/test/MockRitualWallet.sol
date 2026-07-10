// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test stand-in for Ritual's RitualWallet system contract: records
/// deposits per account the same way the real one credits agent wallets.
contract MockRitualWallet {
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public lastLockBlocks;

    function depositFor(address account, uint256 lockBlocks) external payable {
        balanceOf[account] += msg.value;
        lastLockBlocks[account] = lockBlocks;
    }

    /// @dev Lets tests simulate an agent spending its balance on wakes.
    function drain(address account, uint256 amount) external {
        balanceOf[account] -= amount;
    }
}
