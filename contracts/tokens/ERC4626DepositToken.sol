// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {IAmmalgamPair} from 'contracts/interfaces/IAmmalgamPair.sol';
import {ITokenController} from 'contracts/interfaces/tokens/ITokenController.sol';
import {ERC20Base, ERC20BaseConfig} from 'contracts/tokens/ERC20Base.sol';
import {Convert} from 'contracts/libraries/Convert.sol';

contract ERC4626DepositToken is ERC4626, ERC20Base {
    constructor(ERC20BaseConfig memory config, address _asset) ERC4626(IERC20(_asset)) ERC20Base(config) {}

    /**
     * @dev override {AmmalgamERC20Base-ownerMint}.
     * @param sender The address that sent the underlying assets to the pair contract.
     * @param to The address that will receive the minted shares.
     * @param assets The amount of underlying assets that were sent to the pair contract.
     * @param shares The amount of shares that will be minted.
     */
    function ownerMint(address sender, address to, uint256 assets, uint256 shares) public virtual override onlyOwner {
        emit Deposit(sender, to, assets, shares);
        _mint(to, shares);
    }

    /**
     * @dev override {AmmalgamERC20Base-ownerBurn}.
     * @param sender The owner of the Ammalgam Deposit token.
     * @param to The address that will receive the underlying assets.
     * @param assets The amount of underlying assets that will be received.
     * @param shares The amount of shares that will be burned.
     */
    function ownerBurn(address sender, address to, uint256 assets, uint256 shares) public virtual override onlyOwner {
        emit Withdraw(msg.sender, to, sender, assets, shares);
        _burn(msg.sender, shares);
    }

    /**
     * @notice Transfers `amount` tokens from the `from` address to the `to` address.
     * @param from The account to deduct the tokens from.
     * @param to The account to deliver the tokens to.
     * @param amount The amount of tokens to be transferred.
     */
    function ownerTransfer(address from, address to, uint256 amount) public virtual override onlyOwner {
        _transfer(from, to, amount);
    }

    /**
     * @dev ERC4626 facade for {IAmmalgamPair-deposit}.
     * both deposit and mint calls _deposit
     */
    // slither-disable-start dead-code // Not dead-code; they are used via ERC4626 facade.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 /*shares*/
    ) internal virtual override {
        // slither-disable-next-line arbitrary-send-erc20
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, address(pair), assets);
        IAmmalgamPair(address(pair)).deposit(receiver);
    }

    /**
     * @dev ERC4626 facade for {IAmmalgamPair-withdraw}.
     * both withdraw and redeem calls _withdraw
     */
    function _withdraw(
        address caller,
        address receiver,
        address, /*owner*/
        uint256, /*assets*/
        uint256 shares
    ) internal virtual override {
        // slither-disable-next-line arbitrary-send-erc20
        SafeERC20.safeTransferFrom(IERC20(address(this)), caller, address(pair), shares);
        IAmmalgamPair(address(pair)).withdraw(receiver);
    }
    // slither-disable-end dead-code

    function _update(address from, address to, uint256 amount) internal virtual override(ERC20Base, ERC20) {
        super._update(from, to, amount);
    }

    function balanceOf(
        address account
    ) public view override(ERC20Base, ERC20, IERC20) returns (uint256) {
        return super.balanceOf(account);
    }

    function decimals() public view override(ERC20Base, ERC4626) returns (uint8) {
        return super.decimals();
    }

    function totalAssets() public view override returns (uint256) {
        return ITokenController(address(pair)).totalAssets()[tokenType];
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return Convert.toShares(assets, totalAssets(), totalSupply(), rounding == Math.Rounding.Ceil);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return Convert.toAssets(shares, totalAssets(), totalSupply(), rounding == Math.Rounding.Ceil);
    }
}
