// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/**
 * @title GasFlowStakeVault
 * @author GasFlow
 * @notice ERC4626 WETH vault for the GasFlow gas sponsorship system.
 *
 *         Stakers deposit ETH/WETH and receive gfETH shares.
 *         The vault provides ETH liquidity for relayer compensation.
 *         Stablecoin fees (USDC, DAI, etc.) are periodically swapped to WETH
 *         by the owner via swap(), increasing totalAssets() and
 *         naturally appreciating gfETH share value. No separate reward claiming
 *         is needed — stakers earn by holding gfETH.
 *
 *         Withdrawal has a 7-day waiting period to prevent flash-loan attacks.
 */
contract GasFlowStakeVault is Initializable, UUPSUpgradeable, ERC4626Upgradeable, ReentrancyGuardTransient, Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;

    struct WithdrawRequest {
        uint256 endTime;
        uint256 amount;
    }

    address public weth;
    address public config;
    uint256 public withdrawDelay = 7 days;
    uint256 public pendingWithdrawAmount;

    uint256 private totalDepositAmount;

    /// @notice feeToken → accumulated stablecoin fees waiting to be swapped to WETH.
    mapping(address => uint256) public pendingFees;

    /// @notice account → withdrawal request info.
    mapping(address => WithdrawRequest) public withdrawRequestInfos;

    event DepositETH(address indexed sender, uint256 wethAmount, uint256 ethAmount, uint256 shares);
    event WithdrawETH(address indexed sender, address indexed to, uint256 amount);
    event WithdrawRequested(address indexed account, uint256 shares, uint256 requestTime);
    event RelayerCompensated(address indexed relayer, uint256 amount);
    event FeeReceived(address indexed token, uint256 amount);
    event ConfigUpdated(address indexed oldConfig, address indexed newConfig);
    event WithdrawDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event SwapToken(address from, address to, uint256 amountOut);

    error TokenNotIncrease();

    /*    ------------ Constructor ------------    */
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        address weth_
    ) public initializer {
        weth = weth_;

        __ERC20_init("GasFlow ETH", "gfETH");
        __ERC4626_init(IERC20(weth));
        __Ownable2Step_init();
        _transferOwnership(initialOwner);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    /*    ------------- Modifiers ------------    */
    modifier onlyConfig() {
        require(msg.sender == config, "GasFlowStake: caller is not config");
        _;
    }

    /*    ---------- Read Functions -----------    */
    /// @notice Returns the total WETH assets held by the vault.
    ///         Uses actual WETH balance — consistent with all deposit/withdrawal paths.
    function totalAssets() public view override returns (uint256) {
        return totalDepositAmount;
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /*    ---------- Write Functions -----------    */
    /// @notice Deposit ETH or WETH into the vault and receive gfETH shares.
    function depositETH(uint256 amount) public payable nonReentrant returns (uint256) {
        require(withdrawDelay > 0, "ERC4626_MODE_OFF");
        uint256 totalAmount = amount + msg.value;
        require(totalAmount > 0, "No assets provided");

        if (msg.value > 0) {
            IWETH(weth).deposit{value: msg.value}();
        }
        if (amount > 0) {
            IERC20(weth).safeTransferFrom(msg.sender, address(this), amount);
        }

        uint256 shares = previewDeposit(totalAmount);
        _mint(msg.sender, shares);
        totalDepositAmount += totalAmount;
        emit DepositETH(msg.sender, amount, msg.value, shares);
        return shares;
    }

    /// @notice Request withdrawal of shares. Starts the waiting period.
    function requestWithdraw(uint256 shares) external nonReentrant {
        require(withdrawDelay > 0, "ERC4626_MODE_OFF");
        require(shares > 0, "Must redeem more than 0 shares");
        uint256 maxShares = maxRedeem(msg.sender);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(msg.sender, shares, maxShares);
        }
        uint256 assets = previewRedeem(shares);

        withdrawRequestInfos[msg.sender].endTime = block.timestamp + withdrawDelay;
        withdrawRequestInfos[msg.sender].amount += assets;
        _burn(msg.sender, shares);
        totalDepositAmount -= assets;
        pendingWithdrawAmount += assets;
        emit WithdrawRequested(msg.sender, shares, block.timestamp);
    }

    /// @notice Withdraw assets after the waiting period has passed.
    function withdrawAfterDelay(address to) external nonReentrant returns (uint256) {
        uint256 requestTime = withdrawRequestInfos[msg.sender].endTime;
        uint256 assets = withdrawRequestInfos[msg.sender].amount;
        require(assets > 0, "GasFlowStake: no pending withdrawal");
        require(to != address(0), "GasFlowStake: zero address");
        require(block.timestamp >= requestTime, "GasFlowStake: withdrawal too early");
        require(IERC20(weth).balanceOf(address(this)) >= assets, "insufficient balance");

        withdrawRequestInfos[msg.sender].amount = 0;
        withdrawRequestInfos[msg.sender].endTime = 0;
        pendingWithdrawAmount -= assets;
        _transferOut(to, assets);

        return assets;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        require(withdrawDelay == 0, "ERC4626_MODE_ON");
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        require(withdrawDelay == 0, "ERC4626_MODE_ON");
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public virtual override returns (uint256) {
        require(withdrawDelay == 0, "ERC4626_MODE_ON");
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public virtual override returns (uint256) {
        require(withdrawDelay == 0, "ERC4626_MODE_ON");
        return super.redeem(shares, receiver, owner);
    }

    function swap(
        address from,
        address to,
        uint256 amount,
        address router,
        bytes memory encodedSwapData
    ) external onlyOwner nonReentrant {
        require(to == weth, "GasFlowStake: can only swap to WETH");
        IERC20 tokenContract = IERC20(from);
        uint256 bal = pendingFees[from];
        if(amount == 0 || amount > bal) {
            amount = bal;
        }

        tokenContract.forceApprove(router, amount);
        uint256 tokenBalBefore = IERC20(to).balanceOf(address(this));
        (bool success, ) = router.call(encodedSwapData);
        require(success, "Router call failed");
        uint256 tokenBalAfter = IERC20(to).balanceOf(address(this));
        if(tokenBalAfter <= tokenBalBefore) {
            revert TokenNotIncrease();
        }
        pendingFees[from] -= amount;
        totalDepositAmount += tokenBalAfter - tokenBalBefore;

        emit SwapToken(from, to, tokenBalAfter - tokenBalBefore);
    }

    /**
     * @notice Compensates the relayer with ETH from the staking pool.
     * @dev Only callable by GasFlowConfig. Unwraps WETH and sends raw ETH.
     * @param relayer The address that paid for gas.
     * @param amount  The amount of ETH to compensate, in wei.
     */
    function compensateRelayer(
        address relayer,
        uint256 amount
    ) external onlyConfig nonReentrant {
        require(relayer != address(0), "GasFlowStake: zero relayer");
        require(IERC20(weth).balanceOf(address(this)) - pendingWithdrawAmount >= amount, "GasFlowStake: insufficient WETH");

        IWETH(weth).withdraw(amount);
        (bool success, ) = relayer.call{value: amount}("");
        require(success, "GasFlowStake: ETH transfer failed");
        totalDepositAmount -= amount;
        emit RelayerCompensated(relayer, amount);
    }

    /**
     * @notice Records stablecoin fees received from user sponsorship payments.
     * @dev Only callable by GasFlowConfig. Fees are accumulated in pendingFees
     *      until the owner swaps them to WETH via swap().
     * @param token  The stablecoin token address.
     * @param amount The amount received.
     */
    function receiveFee(
        address token,
        uint256 amount
    ) external onlyConfig {
        require(token != address(0), "GasFlowStake: zero token");
        pendingFees[token] += amount;
        emit FeeReceived(token, amount);
    }

    function setConfig(address _config) external onlyOwner {
        require(_config != address(0), "GasFlowStake: zero address");
        address oldConfig = config;
        config = _config;
        emit ConfigUpdated(oldConfig, _config);
    }

    function setWithdrawDelay(uint256 _delay) external onlyOwner {
        require(_delay <= 30 days, "GasFlowStake: delay too long");
        uint256 oldDelay = withdrawDelay;
        withdrawDelay = _delay;
        emit WithdrawDelayUpdated(oldDelay, _delay);
    }

    function _transferOut(address to, uint256 assets) internal override {
        IWETH(weth).withdraw(assets);
        (bool success, ) = to.call{value: assets}("");
        require(success, "ETH transfer failed");
        emit WithdrawETH(msg.sender, to, assets);
    }

    receive() external payable {
        if (msg.sender != weth) {
            depositETH(0);
        }
    }
}