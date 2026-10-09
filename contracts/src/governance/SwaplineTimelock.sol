// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title SwaplineTimelock
/// @notice Holds DEFAULT_ADMIN_ROLE on every Swapline contract. Minimum delay is hard-floored at 48 hours.
///         The timelock administers itself (no external admin); proposers are set at deployment.
contract SwaplineTimelock is TimelockController {
    uint256 public constant MIN_DELAY_FLOOR = 48 hours;

    uint256 private _delay;

    error DelayTooShort();

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors)
        TimelockController(minDelay, proposers, executors, address(0))
    {
        if (minDelay < MIN_DELAY_FLOOR) revert DelayTooShort();
        _delay = minDelay;
    }

    function getMinDelay() public view override returns (uint256) {
        return _delay;
    }

    /// @dev Only callable by the timelock itself (i.e. through a delayed proposal); cannot go below 48h.
    function updateDelay(uint256 newDelay) external override {
        if (msg.sender != address(this)) revert TimelockUnauthorizedCaller(msg.sender);
        if (newDelay < MIN_DELAY_FLOOR) revert DelayTooShort();
        emit MinDelayChange(_delay, newDelay);
        _delay = newDelay;
    }
}
