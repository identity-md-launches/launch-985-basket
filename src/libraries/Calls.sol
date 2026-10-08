// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

/// @dev Bounded output copying prevents external return/revert data from expanding our memory.
library Calls {
    function read(address target, uint256 budget, bytes memory input, uint256 size)
        internal
        view
        returns (bool ok, bytes memory output)
    {
        output = new bytes(size);
        assembly ("memory-safe") {
            ok := staticcall(budget, target, add(input, 32), mload(input), add(output, 32), size)
            ok := and(ok, iszero(lt(returndatasize(), size)))
        }
    }

    function word(address target, uint256 budget, bytes memory input) internal view returns (bool ok, uint256 value) {
        bytes memory output;
        (ok, output) = read(target, budget, input, 32);
        assembly ("memory-safe") { value := mload(add(output, 32)) }
    }

    function transfer(address token, bytes memory input) internal returns (bool ok) {
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := call(gas(), token, 0, add(input, 32), mload(input), 0, 32)
            ok := and(ok, or(iszero(returndatasize()), and(eq(returndatasize(), 32), eq(mload(0), 1))))
        }
    }
}
