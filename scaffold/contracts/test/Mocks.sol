// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Test double for the TX Hash precompile (0x0830): returns a settable
///      bytes32. Its runtime code is installed at the precompile address via
///      hardhat_setCode; storage written through setHash lives at that address.
contract MockTxHash {
    bytes32 private _hash;

    function setHash(bytes32 h) external {
        _hash = h;
    }

    fallback() external {
        bytes32 h = _hash;
        assembly {
            mstore(0, h)
            return(0, 32)
        }
    }
}

/// @dev Test double for async precompiles: accepts any calldata and returns
///      32 zero bytes (the consumer only requires success).
contract MockSink {
    fallback() external {
        assembly {
            mstore(0, 0)
            return(0, 32)
        }
    }
}
