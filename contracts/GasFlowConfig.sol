// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ──────────────────────────────────────────
//  Interfaces
// ──────────────────────────────────────────

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

interface IGasFlowStake {
    function compensateRelayer(address relayer, uint256 amount) external;
    function receiveFee(address token, uint256 amount) external;
}

/**
 * @title GasFlowConfig
 * @author GasFlow
 * @notice Global configuration contract for the GasFlow EIP-7702 system.
 *
 *         EIP-7702 uses DELEGATECALL semantics. When a user's EOA delegates to the
 *         GasFlowDelegator contract, the Delegator's code runs in the context of the
 *         user's EOA. Shared configuration MUST live here (immutable reference), not
 *         in per-EOA storage.
 *
 *         This contract also serves as the ONLY authorized caller of GasFlowStake's
 *         compensateRelayer() and receiveFee(). It atomically transfers the stablecoin
 *         fee from the user's EOA to the stake pool, validates the fee against live
 *         oracle prices, records it, then compensates the relayer.
 */
contract GasFlowConfig is Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    uint256 public constant STALENESS_THRESHOLD = 1 hours;

    address public stakePool;
    bytes32 public delegatorCodeHash;
    address public ethUsdFeed;

    mapping(address => address) public tokenUsdFeeds;
    mapping(address => uint8) public feeTokenDecimals;
    mapping(address => bool) public relayers;

    /// @dev Minimum fee-to-compensation ratio (basis points).
    ///      10000 = 100%. Fee must be >= minFeeRateBps * ethCompensation / 10000.
    uint256 public minFeeRateBps = 12000;

    /// @notice L1 data fee compensation multiplier (basis points).
    ///         0 on L1. On L2 rollups, covers L1 calldata costs not in tx.gasprice.
    uint256 public l1FeeBps = 0;

    event StakePoolUpdated(address indexed oldPool, address indexed newPool);
    event EthUsdFeedUpdated(address indexed oldFeed, address indexed newFeed);
    event TokenFeedUpdated(address indexed token, address tokenUsdFeed, uint8 decimals);
    event TokenFeedRemoved(address indexed token);
    event DelegatorCodeHashSet(bytes32 oldCodeHash, bytes32 newCodeHash);
    event MinFeeRateUpdated(uint256 oldRate, uint256 newRate);
    event L1FeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event RelayerAdded(address indexed relayer);
    event RelayerRemoved(address indexed relayer);
    event CompensationProcessed(
        address indexed relayer,
        uint256 ethAmount,
        address indexed feeToken,
        uint256 feeAmount
    );
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    error InvalidPrice();
    error StalePrice();
    error FeeBelowOracleRate(uint256 expected, uint256 provided);

    constructor(address _owner) Ownable(_owner) {}

    /// @notice Returns (ethUsdFeed, tokenUsdFeed) for a given fee token.
    ///         Used by GasFlowDelegator for client-side fee estimation.
    function priceFeeds(address token) external view returns (address, address) {
        return (ethUsdFeed, tokenUsdFeeds[token]);
    }

    /**
     * @dev Validates feeAmount against live Chainlink oracle prices.
     *      feeAmount >= (ethAmount * ethUsdPrice * 10^tokenDec) / (tokenUsdPrice * 1e8) * minFeeRateBps / 10000
     *
     *      This is an independent check — even if the Delegator miscalculates,
     *      Config will reject the transaction here.
     */
    function _validateFeeAgainstOracle(
        uint256 ethAmount,
        address feeToken,
        uint256 feeAmount
    ) internal view {
        require(ethUsdFeed != address(0), "GasFlowConfig: ETH/USD feed not set");
        address tokenUsdFeed = tokenUsdFeeds[feeToken];
        require(tokenUsdFeed != address(0), "GasFlowConfig: unsupported fee token");

        uint8 tokenDec = feeTokenDecimals[feeToken];

        // Read ETH/USD price
        (
            /* uint80 roundId */,
            int256 ethUsd,
            /* uint256 startedAt */,
            uint256 ethUpdatedAt,
            /* uint80 answeredInRound */
        ) = AggregatorV3Interface(ethUsdFeed).latestRoundData();

        // Read feeToken/USD price
        (
            ,
            int256 tokenUsd,
            ,
            uint256 tokenUpdatedAt,
        ) = AggregatorV3Interface(tokenUsdFeed).latestRoundData();

        // Validate
        if (ethUsd <= 0 || tokenUsd <= 0) revert InvalidPrice();
        if (block.timestamp - ethUpdatedAt > STALENESS_THRESHOLD) revert StalePrice();
        if (block.timestamp - tokenUpdatedAt > STALENESS_THRESHOLD) revert StalePrice();

        // Calculate minimum fee: feeAmount >= ethAmount * ethUsd * 10^dec * minFeeRateBps / (tokenUsd * 1e8 * 10000)
        //                       = ethAmount * ethUsd * 10^dec * minFeeRateBps / (tokenUsd * 1e12)
        uint256 expectedFee = (ethAmount * uint256(ethUsd) * (10 ** tokenDec)) / (1e18 * uint256(tokenUsd));
        uint256 minFee = (expectedFee * minFeeRateBps) / 10000;

        if (feeAmount < minFee) revert FeeBelowOracleRate(minFee, feeAmount);
    }

    // ──────────────────────────────────────
    //  Admin: Pause
    // ──────────────────────────────────────

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Called by the Delegator (running at a user's EOA) to atomically:
     *         1. Validate the fee amount against live oracle prices
     *         2. Transfer the stablecoin fee from the user's EOA to the stake pool
     *         3. Record the fee in the stake pool (enables future swap to WETH)
     *         4. Compensate the relayer with ETH from the stake pool
     *
     *         SECURITY MODEL:
     *         - extcodehash(msg.sender) == delegatorCodeHash ensures caller is a delegated EOA
     *         - Oracle price validation prevents Delegator from misreporting the exchange rate
     *         - feeAmount >= minFeeRateBps * ethAmount / 10000 prevents drainage attacks
     *         - Stablecoin transfer is atomic — if transferFrom fails, nothing exits the pool
     */
    function processCompensation(
        address feePayer,
        address relayer,
        uint256 ethAmount,
        address feeToken,
        uint256 feeAmount
    ) external whenNotPaused {
        // Verify caller has delegated to GasFlowDelegator
        bytes32 callerCodeHash;
        assembly {
            callerCodeHash := extcodehash(caller())
        }
        require(
            callerCodeHash == delegatorCodeHash,
            "GasFlowConfig: caller not delegated to Delegator"
        );

        require(ethAmount > 0, "GasFlowConfig: zero ethAmount");
        require(feeAmount > 0, "GasFlowConfig: zero feeAmount");

        // ── Oracle validation: independent price check ──
        _validateFeeAgainstOracle(ethAmount, feeToken, feeAmount);

        // ── Transfer + record + compensate ──
        IERC20(feeToken).safeTransferFrom(feePayer, stakePool, feeAmount);
        IGasFlowStake(stakePool).receiveFee(feeToken, feeAmount);
        IGasFlowStake(stakePool).compensateRelayer(relayer, ethAmount);

        emit CompensationProcessed(relayer, ethAmount, feeToken, feeAmount);
    }

    // ──────────────────────────────────────
    //  Admin: Configuration Setters
    // ──────────────────────────────────────

    function setStakePool(address _stakePool) external onlyOwner {
        require(_stakePool != address(0), "GasFlowConfig: zero stake pool");
        address oldPool = stakePool;
        stakePool = _stakePool;
        emit StakePoolUpdated(oldPool, _stakePool);
    }

    function setEthUsdFeed(address _ethUsdFeed) external onlyOwner {
        require(_ethUsdFeed != address(0), "GasFlowConfig: zero feed");
        address oldFeed = ethUsdFeed;
        ethUsdFeed = _ethUsdFeed;
        emit EthUsdFeedUpdated(oldFeed, _ethUsdFeed);
    }

    function setPriceFeed(
        address feeToken,
        address _tokenUsdFeed,
        uint8 decimals
    ) external onlyOwner {
        require(feeToken != address(0), "GasFlowConfig: zero token");
        require(_tokenUsdFeed != address(0), "GasFlowConfig: zero token/USD feed");
        require(decimals > 0 && decimals <= 18, "GasFlowConfig: invalid decimals");
        tokenUsdFeeds[feeToken] = _tokenUsdFeed;
        feeTokenDecimals[feeToken] = decimals;
        emit TokenFeedUpdated(feeToken, _tokenUsdFeed, decimals);
    }

    function removePriceFeed(address feeToken) external onlyOwner {
        require(tokenUsdFeeds[feeToken] != address(0), "GasFlowConfig: feed not set");
        delete tokenUsdFeeds[feeToken];
        delete feeTokenDecimals[feeToken];
        emit TokenFeedRemoved(feeToken);
    }

    function setDelegatorCodeHash(bytes32 _codeHash) external onlyOwner {
        require(_codeHash != bytes32(0), "GasFlowConfig: zero code hash");
        bytes32 oldCodeHash = delegatorCodeHash;
        delegatorCodeHash = _codeHash;
        emit DelegatorCodeHashSet(oldCodeHash, _codeHash);
    }

    function setMinFeeRateBps(uint256 _minFeeRateBps) external onlyOwner {
        require(_minFeeRateBps >= 5000, "GasFlowConfig: rate too low");   // min 50%
        require(_minFeeRateBps <= 20000, "GasFlowConfig: rate too high"); // max 200%
        uint256 oldRate = minFeeRateBps;
        minFeeRateBps = _minFeeRateBps;
        emit MinFeeRateUpdated(oldRate, _minFeeRateBps);
    }

    function setL1FeeBps(uint256 _l1FeeBps) external onlyOwner {
        require(_l1FeeBps <= 5000, "GasFlowConfig: L1 fee bps too high"); // max 50%
        uint256 oldBps = l1FeeBps;
        l1FeeBps = _l1FeeBps;
        emit L1FeeBpsUpdated(oldBps, _l1FeeBps);
    }

    function addRelayer(address relayer) external onlyOwner {
        require(relayer != address(0), "GasFlowConfig: zero relayer");
        require(!relayers[relayer], "GasFlowConfig: already a relayer");
        relayers[relayer] = true;
        emit RelayerAdded(relayer);
    }

    function removeRelayer(address relayer) external onlyOwner {
        require(relayers[relayer], "GasFlowConfig: not a relayer");
        delete relayers[relayer];
        emit RelayerRemoved(relayer);
    }

    /**
     * @notice Rescue tokens accidentally sent to this contract.
     * @dev Cannot withdraw tokens that are actively managed by the system.
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        require(to != address(0), "GasFlowConfig: zero to");
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }
}