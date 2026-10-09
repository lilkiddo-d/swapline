// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TickBitmap
/// @notice Packed bitmap of initialised ticks for non-negative tick indices that are multiples of `spacing`.
///         Searches are bounded by `maxWord` (the last word that can hold a valid tick).
library TickBitmap {
    function position(int24 compressed) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(compressed >> 8);
        bitPos = uint8(uint24(compressed % 256));
    }

    function flip(mapping(int16 => uint256) storage self, int24 tick, int24 spacing) internal {
        (int16 wordPos, uint8 bitPos) = position(tick / spacing);
        self[wordPos] ^= (uint256(1) << bitPos);
    }

    /// @notice Smallest initialised tick strictly greater than `tick`, or (false, 0) if none up to `maxTick`.
    function nextAbove(mapping(int16 => uint256) storage self, int24 tick, int24 spacing, int24 maxTick)
        internal
        view
        returns (bool found, int24 next)
    {
        int24 compressed = tick < 0 ? int24(0) : tick / spacing + 1;
        if (tick < 0) compressed = 0;
        int24 maxCompressed = maxTick / spacing;
        if (compressed > maxCompressed) return (false, 0);
        (int16 wordPos, uint8 bitPos) = position(compressed);
        int16 lastWord = int16(maxCompressed >> 8);
        // mask: bits >= bitPos
        uint256 word = self[wordPos] & ~((uint256(1) << bitPos) - 1);
        while (true) {
            if (word != 0) {
                uint256 lsb = Math.log2(word & (~word + 1));
                int24 c = (int24(wordPos) << 8) + int24(uint24(lsb));
                if (c > maxCompressed) return (false, 0);
                return (true, c * spacing);
            }
            if (wordPos >= lastWord) return (false, 0);
            wordPos++;
            word = self[wordPos];
        }
    }

    /// @notice Largest initialised tick less than or equal to `tick`, or (false, 0) if none down to 0.
    function nextAtOrBelow(mapping(int16 => uint256) storage self, int24 tick, int24 spacing)
        internal
        view
        returns (bool found, int24 next)
    {
        if (tick < 0) return (false, 0);
        int24 compressed = tick / spacing;
        (int16 wordPos, uint8 bitPos) = position(compressed);
        // mask: bits <= bitPos
        uint256 mask = bitPos == 255 ? type(uint256).max : (uint256(1) << (uint256(bitPos) + 1)) - 1;
        uint256 word = self[wordPos] & mask;
        while (true) {
            if (word != 0) {
                uint256 msb = Math.log2(word);
                return (true, ((int24(wordPos) << 8) + int24(uint24(msb))) * spacing);
            }
            if (wordPos == 0) return (false, 0);
            wordPos--;
            word = self[wordPos];
        }
    }
}
