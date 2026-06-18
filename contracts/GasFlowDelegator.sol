// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

interface IGasFlowConfig {
    function stakePool() external view returns (address);
    function l1FeeBps() external view returns (uint256);
    function priceFeeds(address token) external view returns (address ethUsdFeed, address tokenUsdFeed);
    function feeTokenDecimals(address token) external view returns (uint8);
    function minFeeRateBps() external view returns (uint256);
    function STALENESS_THRESHOLD() external view returns (uint256);
    function processCompensation(
        address feePayer,
        address relayer,
        uint256 ethAmount,
        address feeToken,
        uint256 feeAmount
    ) external;
}

interface IERC20Permit {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/**
 * @title GasFlowDelegator
 * @author GasFlow
 * @notice EIP-7702 delegation contract — the code that runs AT the user's EOA.
 *
 *         CRITICAL: EIP-7702 uses DELEGATECALL semantics.
 *         - address(this) = user's EOA address (NOT the Delegator contract address)
 *         - msg.sender   = whoever called the EOA (usually the relayer)
 *         - storage      = the EOA's own storage (initially all zeroes)
 *
 *         Shared config lives in GasFlowConfig (immutable reference), per-user state
 *         (nonce) lives in the EOA's own storage.
 *
 * ## End-to-end flow:
 *   1. User signs ECDSA over (chainId, nonce, calls) — authorizing the batch
 *   2. User signs EIP-2612 permit — authorizing stablecoin fee payment
 *   3. Relayer submits a type-0x04 tx with authorization + execute data
 *   4. Inside execute(): verify sig → gas metering → execute calls → convert fee →
 *      EIP-2612 permit allowance → processCompensation (Config does transferFrom + compensate)
 */
contract GasFlowDelegator is ReentrancyGuardTransient {

    // ──────────────────────────────────────
    //  Private Variables
    // ──────────────────────────────────────

    // (none)

    // ──────────────────────────────────────
    //  Public Variables
    // ──────────────────────────────────────

    /// @dev Immutable reference to shared config. Baked into bytecode — same for all EOAs.
    IGasFlowConfig public immutable config;

    /// @notice Per-user nonce for replay protection. Lives in the EOA's own storage.
    uint256 public nonce;

    /// @dev Fixed gas overhead for execute() wrapper.
    ///      Covers: sig verify (~21k), nonce SSTORE (5-20k), permit (~46k),
    ///      transferFrom (~51k), oracle (~2.1k), Config+StakePool (~45k), events (~3k).
    ///      Must be calibrated on testnet; 160k is a conservative baseline.
    uint256 public constant FIXED_GAS_OVERHEAD = 160000;

    // ──────────────────────────────────────
    //  Data Structures
    // ──────────────────────────────────────

    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    // ──────────────────────────────────────
    //  Events
    // ──────────────────────────────────────

    event CallExecuted(address indexed to, uint256 value);
    event BatchExecuted(
        uint256 indexed nonce,
        address indexed relayer,
        uint256 gasUsed,
        uint256 ethCompensation,
        uint256 l1Fee
    );
    event FeeCollected(
        address indexed token,
        uint256 feeAmount,
        uint256 ethCompensation
    );

    // ──────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────

    constructor(address _config) {
        require(_config != address(0), "Delegator: zero config");
        config = IGasFlowConfig(_config);
    }

    // ──────────────────────────────────────
    //  View Functions
    // ──────────────────────────────────────

    // (config, nonce are auto-generated getters)

    // ──────────────────────────────────────
    //  Public Write Functions
    // ──────────────────────────────────────

    /**
     * @notice Execute a batch of calls with gas sponsorship.
     * @param calls             The sequence of contract calls the user wants to make.
     * @param signature         ECDSA signature over (chainId, nonce, calls) signed by user's EOA.
     * @param feeToken          The stablecoin token the user pays fees in (e.g., USDC).
     * @param maxPermitAmount   EIP-2612 maximum amount the user authorizes.
     * @param deadline          EIP-2612 deadline for the permit.
     * @param v,r,s             EIP-2612 permit signature components.
     */
    function execute(
        Call[] calldata calls,
        bytes calldata signature,
        address feeToken,
        uint256 maxPermitAmount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable nonReentrant {
        address stakePool = config.stakePool();
        require(stakePool != address(0), "Delegator: stake pool not set");
        (address ethUsdFeed, address tokenUsdFeed) = config.priceFeeds(feeToken);
        require(ethUsdFeed != address(0), "Delegator: unsupported fee token");

        // ── Step 1: Verify ECDSA signature ──
        _verifySignature(calls, signature);

        // ── Step 2: Execute batch with gas metering ──
        uint256 gasStart = gasleft();
        uint256 currentNonce = nonce;
        nonce++;
        _executeBatch(calls);
        uint256 gasUsed = gasStart - gasleft() + FIXED_GAS_OVERHEAD;

        // ── Step 3: Calculate compensation (L2 surcharge included) ──
        uint256 baseEthCompensation = gasUsed * tx.gasprice;
        uint256 l1Fee = (baseEthCompensation * config.l1FeeBps()) / 10000;
        uint256 ethCompensation = baseEthCompensation + l1Fee;

        // ── Step 4: Convert to stablecoin via Chainlink (two feeds) ──
        uint256 baseFee = _ethToStable(ethCompensation, feeToken, ethUsdFeed, tokenUsdFeed);
        uint256 feeAmount = (baseFee * config.minFeeRateBps()) / 10000;
        require(feeAmount <= maxPermitAmount, "Delegator: fee exceeds max permit");
        require(feeAmount > 0, "Delegator: fee too small");

        emit FeeCollected(feeToken, feeAmount, ethCompensation);

        // ── Step 5: EIP-2612 permit (set allowance only, Config does transferFrom) ──
        IERC20Permit(feeToken).permit(
            address(this),       // owner = user's EOA
            address(config),       // spender = user's EOA (Delegator IS the EOA)
            maxPermitAmount,
            deadline,
            v, r, s
        );

        // ── Step 6: Process compensation via Config (transferFrom + compensateRelayer) ──
        config.processCompensation(
            address(this),       // feePayer = user's EOA
            msg.sender,          // relayer
            ethCompensation,
            feeToken,
            feeAmount
        );

        emit BatchExecuted(currentNonce, msg.sender, gasUsed, ethCompensation, l1Fee);
    }

    // ──────────────────────────────────────
    //  Fallback
    // ──────────────────────────────────────

    fallback() external payable {}
    receive() external payable {}

    // ──────────────────────────────────────
    //  Private Write Functions
    // ──────────────────────────────────────

    function _executeBatch(Call[] calldata calls) internal {
        for (uint256 i = 0; i < calls.length; i++) {
            _executeCall(calls[i]);
        }
    }

    function _executeCall(Call calldata callItem) internal {
        (bool success, ) = callItem.to.call{value: callItem.value}(callItem.data);
        require(success, "Delegator: call reverted");
        emit CallExecuted(callItem.to, callItem.value);
    }

    // ──────────────────────────────────────
    //  Private View Functions
    // ──────────────────────────────────────

    /**
     * @dev Verifies ECDSA signature over (chainId, nonce, calls).
     *      Uses abi.encode to prevent collision attacks.
     *      Includes block.chainid to prevent cross-chain replay.
     */
    function _verifySignature(
        Call[] calldata calls,
        bytes calldata signature
    ) internal view {
        bytes32 digest = keccak256(abi.encode(block.chainid, nonce, calls));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(digest);
        address recovered = ECDSA.recover(ethSignedHash, signature);
        require(recovered == address(this), "Delegator: invalid signature");
    }

    /**
     * @dev Converts ETH amount to stablecoin amount using two Chainlink feeds.
     *      feeAmount = ethAmount × ethUsdPrice × 10^tokenDec / (1e18 × tokenUsdPrice)
     *
     *      Both feeds return 8-decimal values; ethUsd/tokenUsd cancels the 10^8 factor.
     *      The remaining 1e18 in denominator cancels ethAmount's wei precision.
     *
     *      Example: 1 ETH ≈ 3000 USDC
     *      1e18 × 3000e8 × 1e6 / (1e18 × 1e8) = 3000e6 ✅
     */
    function _ethToStable(
        uint256 ethAmount,
        address feeToken,
        address ethUsdFeed,
        address tokenUsdFeed
    ) internal view returns (uint256) {
        uint8 tokenDec = config.feeTokenDecimals(feeToken);

        // Fetch ETH/USD price
        (
            /* uint80 roundId */,
            int256 ethUsd,
            /* uint256 startedAt */,
            uint256 ethUpdatedAt,
            /* uint80 answeredInRound */
        ) = AggregatorV3Interface(ethUsdFeed).latestRoundData();

        // Fetch feeToken/USD price
        (
            ,
            int256 tokenUsd,
            ,
            uint256 tokenUpdatedAt,
        ) = AggregatorV3Interface(tokenUsdFeed).latestRoundData();

        // Validate prices
        require(ethUsd > 0, "Delegator: non-positive ETH price");
        require(tokenUsd > 0, "Delegator: non-positive token price");
        require(
            block.timestamp - ethUpdatedAt <= config.STALENESS_THRESHOLD(),
            "Delegator: stale ETH price"
        );
        require(
            block.timestamp - tokenUpdatedAt <= config.STALENESS_THRESHOLD(),
            "Delegator: stale token price"
        );

        // feeAmount = ethAmount × ethUsd × 10^tokenDec / (1e18 × tokenUsd)
        uint256 feeAmount = (ethAmount * uint256(ethUsd) * (10 ** tokenDec))
                            / (1e18 * uint256(tokenUsd));

        return feeAmount;
    }
}