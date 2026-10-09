// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRateSource} from "../../src/interfaces/IRateSource.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @dev Test-only ERC-20. The project NEVER deploys a token; this exists only in tests (stablecoin + mock $SWPL).
contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Rate source with a directly settable index.
contract MockRateSource is IRateSource {
    uint256 public index = 1e18;
    uint256 public tvl = 1e30;
    address public override underlying;
    bool public reverts;

    constructor(address underlying_) {
        underlying = underlying_;
    }

    function setIndex(uint256 i) external {
        index = i;
    }

    function setTvl(uint256 t) external {
        tvl = t;
    }

    function setReverts(bool r) external {
        reverts = r;
    }

    function currentIndex() external view override returns (uint256) {
        require(!reverts, "source down");
        return index;
    }

    function totalValue() external view override returns (uint256) {
        require(!reverts, "source down");
        return tvl;
    }

    function description() external pure override returns (string memory) {
        return "mock";
    }
}

/// @dev ERC-4626 whose share price grows when someone calls `accrue` (mints assets into the vault) — and which is
///      also vulnerable to direct donations, like many real vaults.
contract MockYieldVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Mock Yield", "mYLD") ERC4626(asset_) {}

    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }
}

contract MockAggregator is IAggregatorV3 {
    uint8 public override decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint256 public startedAt;
    string public override description = "mock";

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
        startedAt = block.timestamp;
    }

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function setStartedAt(uint256 t) external {
        startedAt = t;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, updatedAt, 1);
    }
}

/// @dev Spark-style vault exposing nowChi() (RAY).
contract MockSparkVault {
    uint256 public chi = 1e27;
    address public asset;
    uint256 public totalAssets = 1e12;

    constructor(address a) {
        asset = a;
    }

    function setChi(uint256 c) external {
        chi = c;
    }

    function nowChi() external view returns (uint256) {
        return chi;
    }
}
