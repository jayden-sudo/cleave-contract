// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FullMath
/// @notice 512-bit multiply-divide (Remco Bloemen's algorithm), ported to Solidity
///         0.8 with `unchecked` to preserve the original wrapping semantics. Computes
///         floor(a*b/denominator) with full precision, reverting only on overflow of
///         the final result or division by zero.
/// @dev    Faithful port of Uniswap v3-core's FullMath.mulDiv.
library FullMath {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division
            if (prod1 == 0) {
                require(denominator > 0, "FM:den0");
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }

            // Make sure the result is less than 2**256.
            require(denominator > prod1, "FM:of");

            // 512 by 256 division.
            // Subtract remainder from [prod1 prod0].
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
            }
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator.
            uint256 twos = (0 - denominator) & denominator;
            assembly {
                denominator := div(denominator, twos)
            }
            assembly {
                prod0 := div(prod0, twos)
            }
            // Shift bits from prod1 into prod0.
            assembly {
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Invert denominator mod 2**256 (Newton-Raphson).
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv; // mod 2**8
            inv *= 2 - denominator * inv; // mod 2**16
            inv *= 2 - denominator * inv; // mod 2**32
            inv *= 2 - denominator * inv; // mod 2**64
            inv *= 2 - denominator * inv; // mod 2**128
            inv *= 2 - denominator * inv; // mod 2**256

            result = prod0 * inv;
            return result;
        }
    }
}
