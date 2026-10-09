// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

/// @title ProjectTokenHooks
/// @notice Every $SWPL feature lives here and is disabled until the Timelock calls `setProjectToken` (once).
///         Swapline deploys NO token; $SWPL is launched separately. Features:
///           1. Staking with a cooldown; stakers share protocol trading fees (paid in the margin stablecoin).
///           2. Advisory votes on new rate sources and maturities. Results are signals only — execution is a
///              separate Timelock proposal (MarketFactory.createMarket).
/// @dev Double-vote resistance: voting weight is the caller's active stake at vote time, and unstaking requires a
///      cooldown that is always longer than the voting period, so tokens used to vote on a proposal cannot be moved
///      to another address and re-used before that proposal closes.
contract ProjectTokenHooks is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum ProposalKind {
        NewRateSource,
        NewMaturity,
        ParameterChange,
        Other
    }

    struct Proposal {
        ProposalKind kind;
        address proposer;
        uint64 start;
        uint64 end;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 totalStakedAtStart;
        bytes32 payloadHash; // hash of the intended Timelock calldata / spec, for verification
        string description;
    }

    struct PendingUnstake {
        uint256 amount;
        uint256 availableAt;
    }

    uint256 private constant PRECISION = 1e36;
    uint256 public constant MAX_DESCRIPTION = 2_000;

    IERC20 public immutable rewardToken;
    IERC20 public projectToken;

    uint256 public cooldown = 7 days;
    uint256 public votingPeriod = 5 days;
    uint256 public proposalThreshold; // min stake to propose (project token units)
    uint256 public quorumBps = 1_000; // 10% of stake at proposal start

    uint256 public totalStaked;
    mapping(address => uint256) public stakeOf;
    mapping(address => PendingUnstake) public pendingUnstake;

    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    Proposal[] private _proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    event ProjectTokenSet(address indexed token);
    event Staked(address indexed account, uint256 amount);
    event UnstakeRequested(address indexed account, uint256 amount, uint256 availableAt);
    event Withdrawn(address indexed account, uint256 amount);
    event RewardAdded(uint256 amount, uint256 rewardPerToken);
    event RewardPaid(address indexed account, uint256 amount);
    event ProposalCreated(uint256 indexed id, ProposalKind kind, address indexed proposer, bytes32 payloadHash, string description);
    event VoteCast(uint256 indexed id, address indexed voter, bool support, uint256 weight);
    event GovernanceParamsUpdated(uint256 cooldown, uint256 votingPeriod, uint256 threshold, uint256 quorumBps);

    error TokenNotSet();
    error TokenAlreadySet();
    error InvalidToken();
    error ZeroAmount();
    error InsufficientStake();
    error CooldownActive();
    error NoStakers();
    error VotingClosed();
    error AlreadyVoted();
    error NoVotingPower();
    error InvalidParams();
    error UnknownProposal();

    modifier tokenEnabled() {
        if (address(projectToken) == address(0)) revert TokenNotSet();
        _;
    }

    modifier updateReward(address account) {
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    constructor(IERC20 rewardToken_, address admin) {
        if (address(rewardToken_) == address(0) || admin == address(0)) revert InvalidParams();
        rewardToken = rewardToken_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ------------------------------------------------------------------------------------------ token wiring

    /// @notice One-shot: wire the $SWPL token address. Callable only by DEFAULT_ADMIN_ROLE (the Timelock).
    function setProjectToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(projectToken) != address(0)) revert TokenAlreadySet();
        if (token == address(0) || token.code.length == 0 || token == address(rewardToken)) revert InvalidToken();
        projectToken = IERC20(token);
        emit ProjectTokenSet(token);
    }

    function tokenSet() external view returns (bool) {
        return address(projectToken) != address(0);
    }

    /// @notice FeeCollector routes the staker share here only when this returns true.
    function rewardsActive() external view returns (bool) {
        return address(projectToken) != address(0) && totalStaked > 0;
    }

    // ------------------------------------------------------------------------------------------ staking

    function stake(uint256 amount) external nonReentrant tokenEnabled updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        IERC20 t = projectToken;
        uint256 before = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = t.balanceOf(address(this)) - before; // fee-on-transfer safe
        stakeOf[msg.sender] += received;
        totalStaked += received;
        emit Staked(msg.sender, received);
    }

    function requestUnstake(uint256 amount) external nonReentrant tokenEnabled updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        if (amount > stakeOf[msg.sender]) revert InsufficientStake();
        stakeOf[msg.sender] -= amount;
        totalStaked -= amount;
        PendingUnstake storage p = pendingUnstake[msg.sender];
        p.amount += amount;
        p.availableAt = block.timestamp + cooldown;
        emit UnstakeRequested(msg.sender, amount, p.availableAt);
    }

    function withdraw() external nonReentrant tokenEnabled {
        PendingUnstake memory p = pendingUnstake[msg.sender];
        if (p.amount == 0) revert ZeroAmount();
        if (block.timestamp < p.availableAt) revert CooldownActive();
        delete pendingUnstake[msg.sender];
        emit Withdrawn(msg.sender, p.amount);
        projectToken.safeTransfer(msg.sender, p.amount);
    }

    function claim() external nonReentrant updateReward(msg.sender) returns (uint256 reward) {
        reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            emit RewardPaid(msg.sender, reward);
            rewardToken.safeTransfer(msg.sender, reward);
        }
    }

    /// @notice Pull `amount` of the reward token and distribute it pro-rata to current stakers.
    function notifyRewardAmount(uint256 amount) external nonReentrant tokenEnabled {
        if (amount == 0) revert ZeroAmount();
        if (totalStaked == 0) revert NoStakers();
        rewardPerTokenStored += mulDiv(amount, PRECISION, totalStaked);
        emit RewardAdded(amount, rewardPerTokenStored);
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function earned(address account) public view returns (uint256) {
        return rewards[account]
            + mulDiv(stakeOf[account], rewardPerTokenStored - userRewardPerTokenPaid[account], PRECISION);
    }

    // ------------------------------------------------------------------------------------------ advisory votes

    function propose(ProposalKind kind, bytes32 payloadHash, string calldata description)
        external
        tokenEnabled
        returns (uint256 id)
    {
        if (stakeOf[msg.sender] < proposalThreshold || stakeOf[msg.sender] == 0) revert InsufficientStake();
        if (bytes(description).length > MAX_DESCRIPTION) revert InvalidParams();
        id = _proposals.length;
        _proposals.push(
            Proposal({
                kind: kind,
                proposer: msg.sender,
                start: uint64(block.timestamp),
                end: uint64(block.timestamp + votingPeriod),
                forVotes: 0,
                againstVotes: 0,
                totalStakedAtStart: totalStaked,
                payloadHash: payloadHash,
                description: description
            })
        );
        emit ProposalCreated(id, kind, msg.sender, payloadHash, description);
    }

    function vote(uint256 id, bool support) external tokenEnabled {
        if (id >= _proposals.length) revert UnknownProposal();
        Proposal storage p = _proposals[id];
        if (block.timestamp >= p.end) revert VotingClosed();
        if (hasVoted[id][msg.sender]) revert AlreadyVoted();
        uint256 weight = stakeOf[msg.sender];
        if (weight == 0) revert NoVotingPower();
        hasVoted[id][msg.sender] = true;
        if (support) p.forVotes += weight;
        else p.againstVotes += weight;
        emit VoteCast(id, msg.sender, support, weight);
    }

    function proposal(uint256 id) external view returns (Proposal memory) {
        if (id >= _proposals.length) revert UnknownProposal();
        return _proposals[id];
    }

    function proposalCount() external view returns (uint256) {
        return _proposals.length;
    }

    /// @notice Advisory outcome: closed, quorum reached, and more for than against.
    function passed(uint256 id) external view returns (bool) {
        if (id >= _proposals.length) revert UnknownProposal();
        Proposal storage p = _proposals[id];
        if (block.timestamp < p.end) return false;
        uint256 quorum = (p.totalStakedAtStart * quorumBps) / 10_000;
        return p.forVotes + p.againstVotes >= quorum && p.forVotes > p.againstVotes;
    }

    function setGovernanceParams(uint256 cooldown_, uint256 votingPeriod_, uint256 threshold_, uint256 quorumBps_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (votingPeriod_ == 0 || cooldown_ <= votingPeriod_ || cooldown_ > 60 days || quorumBps_ > 10_000) {
            revert InvalidParams();
        }
        cooldown = cooldown_;
        votingPeriod = votingPeriod_;
        proposalThreshold = threshold_;
        quorumBps = quorumBps_;
        emit GovernanceParamsUpdated(cooldown_, votingPeriod_, threshold_, quorumBps_);
    }
}
