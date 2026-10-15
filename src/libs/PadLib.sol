// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Min} from "../interfaces/Interfaces.sol";

import {PadErrors} from "../interfaces/PadErrors.sol";

/// @notice Internal-only helpers (inlined by the compiler, so no link placeholders in bytecode).
library PadLib {
    /// @dev Stipend for a best-effort payout. It bounds a hostile recipient's work (the call also caps
    /// returndata at 32 bytes); a failed push becomes a claim. IMD is a bridged token behind a beacon
    /// proxy whose live transfer path is unverified: a plain OZ-v4 shape to a fresh holder needs about
    /// 40k and each extra cold storage read adds 2.1k, so 100k leaves more than 2x headroom.
    uint256 internal constant PUSH_GAS = 100_000;

    /// @dev Deploys an EIP-1167 minimal proxy pointing at `implementation`.
    function clone(address implementation) internal returns (address instance) {
        assembly ("memory-safe") {
            mstore(0x00, or(shr(0xe8, shl(0x60, implementation)), 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000))
            mstore(0x20, or(shl(0x78, implementation), 0x5af43d82803e903d91602b57fd5bf3))
            instance := create(0, 0x09, 0x37)
        }
        if (!(instance != address(0))) revert PadErrors.PadCloneFailed();
    }

    /// @dev Bounded ERC20 call, accepting empty returns. No returndata copy bomb.
    function tokenCall(address token, bytes memory data, uint256 gasCap) internal returns (bool ok) {
        if (token.code.length == 0) return false;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0)
            ok := call(gasCap, token, 0, add(data, 32), mload(data), ptr, 32)
            ok := and(ok, or(iszero(returndatasize()), and(eq(returndatasize(), 32), eq(mload(ptr), 1))))
        }
    }

    function push(address token, address to, uint256 amount) internal returns (bool) {
        return amount == 0 || tokenCall(token, abi.encodeWithSelector(0xa9059cbb, to, amount), PUSH_GAS);
    }

    function transfer(address token, address to, uint256 amount) internal {
        if (!tokenCall(token, abi.encodeWithSelector(0xa9059cbb, to, amount), gasleft())) revert PadErrors.PadToken();
    }

    function approve(address token, address spender) internal {
        if (!tokenCall(token, abi.encodeWithSelector(0x095ea7b3, spender, type(uint256).max), gasleft())) {
            revert PadErrors.PadAllowance();
        }
    }

    /// @dev Credits are based on the specified, verified receipt, never the contract's whole balance.
    function pullExact(address token, address from, address to, uint256 amount) internal {
        uint256 beforeBalance = IERC20Min(token).balanceOf(to);
        if (!tokenCall(token, abi.encodeWithSelector(0x23b872dd, from, to, amount), gasleft())) {
            revert PadErrors.PadToken();
        }
        uint256 afterBalance = IERC20Min(token).balanceOf(to);
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert PadErrors.PadAmount();
    }

    /// @dev floor(a * b / d) with full 512-bit intermediate precision.
    function mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) return prod0 / d;
            if (!(d > prod1)) revert PadErrors.PadMulDivOverflow();
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(a, b, d)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = d & (0 - d);
            assembly ("memory-safe") {
                d := div(d, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inv = (3 * d) ^ 2;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            result = prod0 * inv;
        }
    }

    /// @dev floor(sqrt(x)).
    function sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        uint256 r = 1;
        uint256 v = x;
        if (v >= 1 << 128) {
            v >>= 128;
            r <<= 64;
        }
        if (v >= 1 << 64) {
            v >>= 64;
            r <<= 32;
        }
        if (v >= 1 << 32) {
            v >>= 32;
            r <<= 16;
        }
        if (v >= 1 << 16) {
            v >>= 16;
            r <<= 8;
        }
        if (v >= 1 << 8) {
            v >>= 8;
            r <<= 4;
        }
        if (v >= 1 << 4) {
            v >>= 4;
            r <<= 2;
        }
        if (v >= 1 << 2) r <<= 1;
        unchecked {
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            uint256 r1 = x / r;
            z = r < r1 ? r : r1;
        }
    }

    /// @dev Encode sqrt(numerator / denominator) in Q96 without a 256-bit Q192 overflow
    /// for very large raw-token ratios. The high-ratio branch retains at least 96 root bits.
    function sqrtRatioX96(uint256 numerator, uint256 denominator) internal pure returns (uint160) {
        if (numerator / denominator < 1 << 64) {
            return uint160(sqrt(mulDiv(numerator, 1 << 192, denominator)));
        }
        uint256 root = sqrt(mulDiv(numerator, 1 << 128, denominator));
        return uint160(root << 32);
    }

    function abs(int256 v) internal pure returns (uint256) {
        return v < 0 ? uint256(-v) : uint256(v);
    }
}
