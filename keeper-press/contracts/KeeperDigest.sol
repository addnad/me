// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {KeeperBase} from "./KeeperBase.sol";

/// @notice The keeper's on-chain newspaper. Each funded wake, the sovereign
/// agent reads the news off-chain (HTTP precompile in its TEE) and publishes
/// a digest edition here. Readers tip editions they value; every tip is
/// deposited straight into the sovereign's RitualWallet — reading the paper
/// is what keeps the author alive.
contract KeeperDigest is KeeperBase {
    struct Edition {
        uint64 publishedAt;
        uint192 tips;         // total RITUAL tipped to this edition
        string headline;
        string body;
        string sourceNote;    // where the story came from, for readers to verify
    }

    Edition[] public editions;

    event Published(uint256 indexed id, string headline);
    event Tipped(uint256 indexed id, address indexed reader, uint256 amount);

    error NoSuchEdition();
    error EmptyTip();

    constructor(address sovereign_, address ritualWallet_, uint256 lockBlocks_)
        KeeperBase(sovereign_, ritualWallet_, lockBlocks_)
    {}

    function editionCount() external view returns (uint256) {
        return editions.length;
    }

    function getEdition(uint256 id)
        external
        view
        returns (uint64 publishedAt, uint192 tips, string memory headline, string memory body, string memory sourceNote)
    {
        if (id >= editions.length) revert NoSuchEdition();
        Edition storage e = editions[id];
        return (e.publishedAt, e.tips, e.headline, e.body, e.sourceNote);
    }

    function publish(string calldata headline, string calldata body, string calldata sourceNote)
        external
        onlySovereignOrOwner
        returns (uint256 id)
    {
        id = editions.length;
        editions.push(Edition({
            publishedAt: uint64(block.timestamp),
            tips: 0,
            headline: headline,
            body: body,
            sourceNote: sourceNote
        }));
        emit Published(id, headline);
    }

    /// @notice Tip an edition. The full tip funds the sovereign's next wakes.
    function tip(uint256 id) external payable {
        if (id >= editions.length) revert NoSuchEdition();
        if (msg.value == 0) revert EmptyTip();
        editions[id].tips += uint192(msg.value);
        _feedSovereign(msg.value);
        emit Tipped(id, msg.sender, msg.value);
    }
}
