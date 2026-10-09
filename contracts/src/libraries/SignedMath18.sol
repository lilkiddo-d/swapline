// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

/// @dev a * b / c for signed a, rounded toward negative infinity (protocol-favourable).
function mulDivSigned(int256 a, uint256 b, uint256 c) pure returns (int256) {
    if (a >= 0) return SafeCast.toInt256(mulDiv(uint256(a), b, c));
    uint256 ua = uint256(-a);
    uint256 r = mulDiv(ua, b, c);
    if (mulmod(ua, b, c) != 0) r += 1;
    return -SafeCast.toInt256(r);
}

/// @dev a / b rounded toward negative infinity.
function floorDiv(int256 a, uint256 b) pure returns (int256) {
    int256 bi = SafeCast.toInt256(b);
    int256 q = a / bi;
    if (a % bi != 0 && a < 0) q -= 1;
    return q;
}
