// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Constants} from "../libraries/Constants.sol";

interface IInsuranceSink {
    function fundInsurance(uint256 amount) external;
}

interface IStakingRewards {
    function rewardsActive() external view returns (bool);
    function notifyRewardAmount(uint256 amount) external;
}

/// @title FeeCollector
/// @notice Receives protocol trading fees (stablecoin) and splits them on `distribute()` (permissionless):
///         insurance fund → $SWPL stakers (only once the project token is set and has stakers) → treasury.
///         Until the project token is set the staker share goes to the treasury.
contract FeeCollector is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public treasury;
    IInsuranceSink public insurance;
    IStakingRewards public staking;
    uint256 public insuranceBps;
    uint256 public stakerBps;

    event Distributed(uint256 toInsurance, uint256 toStakers, uint256 toTreasury);
    event ConfigUpdated(address treasury, address insurance, address staking, uint256 insuranceBps, uint256 stakerBps);

    error InvalidConfig();

    constructor(
        IERC20 token_,
        address admin,
        address treasury_,
        IInsuranceSink insurance_,
        uint256 insuranceBps_,
        uint256 stakerBps_
    ) {
        if (address(token_) == address(0) || admin == address(0)) revert InvalidConfig();
        token = token_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setConfig(treasury_, insurance_, IStakingRewards(address(0)), insuranceBps_, stakerBps_);
    }

    function distribute() external nonReentrant returns (uint256 toInsurance, uint256 toStakers, uint256 toTreasury) {
        uint256 bal = token.balanceOf(address(this));
        // slither-disable-start incorrect-equality
        if (bal == 0) return (0, 0, 0); // nothing to split
        // slither-disable-end incorrect-equality
        toInsurance = address(insurance) == address(0) ? 0 : (bal * insuranceBps) / Constants.BPS;
        IStakingRewards s = staking;
        if (address(s) != address(0) && s.rewardsActive()) toStakers = (bal * stakerBps) / Constants.BPS;
        toTreasury = bal - toInsurance - toStakers;
        emit Distributed(toInsurance, toStakers, toTreasury);

        if (toInsurance > 0) {
            token.forceApprove(address(insurance), toInsurance);
            insurance.fundInsurance(toInsurance);
        }
        if (toStakers > 0) {
            token.forceApprove(address(s), toStakers);
            s.notifyRewardAmount(toStakers);
        }
        if (toTreasury > 0) token.safeTransfer(treasury, toTreasury);
    }

    function setConfig(
        address treasury_,
        IInsuranceSink insurance_,
        IStakingRewards staking_,
        uint256 insuranceBps_,
        uint256 stakerBps_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setConfig(treasury_, insurance_, staking_, insuranceBps_, stakerBps_);
    }

    function _setConfig(
        address treasury_,
        IInsuranceSink insurance_,
        IStakingRewards staking_,
        uint256 insuranceBps_,
        uint256 stakerBps_
    ) internal {
        if (treasury_ == address(0) || insuranceBps_ + stakerBps_ > Constants.BPS) revert InvalidConfig();
        treasury = treasury_;
        insurance = insurance_;
        staking = staking_;
        insuranceBps = insuranceBps_;
        stakerBps = stakerBps_;
        emit ConfigUpdated(treasury_, address(insurance_), address(staking_), insuranceBps_, stakerBps_);
    }
}
