// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IWETH {
    function deposit() external payable;

    function withdraw(uint256 amount) external;
}

contract GasFlowStakeVault is Initializable, UUPSUpgradeable, ERC4626Upgradeable, ReentrancyGuardTransient, OwnableUpgradeable {
    using SafeERC20 for IERC20;
    
    address public weth;
    uint256 private totalDepositAmount;

    event DepositETH(address sender, uint256 wethAmount, uint256 ethAmount, uint256 shares);
    event WithdrawETH(address sender, address to, uint256 amount);

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
        __Ownable_init(initialOwner);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    /*    ---------- Read Functions -----------    */
    function totalAssets() public view override returns (uint256) {
        return totalDepositAmount;
    }

    /*    ---------- Write Functions -----------    */
    function depositETH(uint256 amount) public payable nonReentrant returns (uint256) {
        uint256 totalAmount = amount + msg.value;
        require(totalAmount > 0, "No assets provided");

        if(msg.value > 0) {
            IWETH(weth).deposit{value: msg.value}();
        }
        if(amount > 0) {
            IERC20(weth).safeTransferFrom(msg.sender, address(this), amount);
        }

        uint256 shares = previewDeposit(totalAmount);
        _mint(msg.sender, shares);
        totalDepositAmount += totalAmount;
        emit DepositETH(msg.sender, amount, msg.value, shares);
        return shares;
    }

    function _transferOut(address to, uint256 assets) internal override {
        totalDepositAmount -= assets;

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