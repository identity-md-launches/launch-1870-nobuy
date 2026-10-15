// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PadLib} from "src/libs/PadLib.sol";

/// @notice The graduation helper must return floor(a*b/d), including a 512-bit product.
/// Checks inequalities against independent wide multiplication, not another division implementation.
contract IMDMathPropertiesTest is Test {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_mulDivSatisfiesExactFloorInequalities(uint256 a, uint256 b, uint256 d) public pure {
        uint256 minimum = a > b ? a : b;
        if (minimum == 0) minimum = 1;
        d = bound(d, minimum, type(uint256).max); // guarantees the quotient fits, without discarding inputs
        _floor(a, b, d);
    }

    function test_mulDivFullWidthAndZeroBoundaries() public pure {
        uint256 max = type(uint256).max;
        _floor(max, max, max);
        _floor(max - 1, max - 2, max);
        _floor(1 << 200, 1 << 180, 1 << 200);
        _floor((1 << 200) + 1, (1 << 180) + 3, (1 << 200) + 7);
        _floor(0, max, 1);
        _floor(max, 0, 1);
        _floor(1, 1, 1);
    }

    function _floor(uint256 a, uint256 b, uint256 d) private pure {
        uint256 q = PadLib.mulDiv(a, b, d);
        (uint256 ph, uint256 pl) = _product(a, b);
        (uint256 lh, uint256 ll) = _product(q, d);
        assertTrue(lh < ph || (lh == ph && ll <= pl), "q*d exceeds a*b");
        if (q == type(uint256).max) {
            assertLt(ph, d, "a*b is at least (q+1)*d");
        } else {
            (uint256 uh, uint256 ul) = _product(q + 1, d);
            assertTrue(ph < uh || (ph == uh && pl < ul), "a*b is at least (q+1)*d");
        }
    }

    function _product(uint256 a, uint256 b) private pure returns (uint256 high, uint256 low) {
        // Four 128-bit limbs avoid sharing the division helper's mulmod-based product reconstruction.
        uint256 mask = type(uint128).max;
        uint256 p00 = (a & mask) * (b & mask);
        uint256 p01 = (a & mask) * (b >> 128);
        uint256 p10 = (a >> 128) * (b & mask);
        uint256 p11 = (a >> 128) * (b >> 128);
        uint256 middle = (p00 >> 128) + (p01 & mask) + (p10 & mask);
        low = (p00 & mask) | (middle << 128);
        high = p11 + (p01 >> 128) + (p10 >> 128) + (middle >> 128);
    }
}
