// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Median
/// @notice Median of a small array. For an odd count returns the middle element;
///         for an even count returns the average of the two middle elements.
/// @dev    Sorts a memory copy in place (insertion sort — array sizes here are tiny,
///         typically 3). Taking the median is what makes a single de-pegged or
///         manipulated stablecoin pool unable to move the reported price.
library Median {
    function calc(uint256[] memory input) internal pure returns (uint256) {
        uint256 n = input.length;
        require(n > 0, "MED:empty");

        // copy so we don't mutate the caller's array
        uint256[] memory a = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = input[i];
        }

        // insertion sort
        for (uint256 i = 1; i < n; i++) {
            uint256 key = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > key) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = key;
        }

        if (n % 2 == 1) return a[n / 2];
        return (a[n / 2 - 1] + a[n / 2]) / 2;
    }
}
