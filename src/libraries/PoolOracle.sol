// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Calls} from "./Calls.sol";
import {FullMath} from "./FullMath.sol";
import {TickMath} from "./TickMath.sol";

/// @dev Uniswap v3 OracleLibrary.consult/getQuoteAtTick math, with bounded ABI reads.
library PoolOracle {
    function consult(address pool, uint32 window, uint256 budget)
        internal
        view
        returns (bool ok, int24 tick, uint128 liquidity)
    {
        uint32[] memory times = new uint32[](2);
        times[0] = window;
        bytes memory out;
        (ok, out) = Calls.read(pool, budget, abi.encodeWithSignature("observe(uint32[])", times), 256);
        if (!ok) return (false, 0, 0);
        uint256 offset0;
        uint256 offset1;
        uint256 length0;
        uint256 length1;
        int256 t0;
        int256 t1;
        uint256 l0;
        uint256 l1;
        assembly ("memory-safe") {
            offset0 := mload(add(out, 32))
            offset1 := mload(add(out, 64))
            length0 := mload(add(out, 96))
            t0 := mload(add(out, 128))
            t1 := mload(add(out, 160))
            length1 := mload(add(out, 192))
            l0 := mload(add(out, 224))
            l1 := mload(add(out, 256))
        }
        if (
            offset0 != 64 || offset1 != 160 || length0 != 2 || length1 != 2 || t0 != int56(t0) || t1 != int56(t1)
                || l0 > type(uint160).max || l1 > type(uint160).max
        ) {
            return (false, 0, 0);
        }
        int56 delta;
        uint160 secondsDelta;
        // V3 accumulators intentionally wrap.
        unchecked {
            delta = int56(t1) - int56(t0);
            secondsDelta = uint160(l1) - uint160(l0);
        }
        if (secondsDelta == 0) return (false, 0, 0);
        int256 mean = int256(delta) / int256(uint256(window));
        if (delta < 0 && int256(delta) % int256(uint256(window)) != 0) --mean;
        if (mean < -887272 || mean > 887272) return (false, 0, 0);
        uint256 harmonic = uint256(window) * type(uint160).max / (uint256(secondsDelta) << 32);
        if (harmonic > type(uint128).max) return (false, 0, 0);
        return (true, int24(mean), uint128(harmonic));
    }

    function quote(int24 tick, uint128 amount, bool baseIsToken0) internal pure returns (uint256) {
        uint160 sqrtRatio = TickMath.getSqrtRatioAtTick(tick);
        if (sqrtRatio <= type(uint128).max) {
            uint256 ratio = uint256(sqrtRatio) * sqrtRatio;
            return baseIsToken0 ? FullMath.mulDiv(ratio, amount, 1 << 192) : FullMath.mulDiv(1 << 192, amount, ratio);
        }
        uint256 ratio128 = FullMath.mulDiv(sqrtRatio, sqrtRatio, 1 << 64);
        return baseIsToken0 ? FullMath.mulDiv(ratio128, amount, 1 << 128) : FullMath.mulDiv(1 << 128, amount, ratio128);
    }
}
