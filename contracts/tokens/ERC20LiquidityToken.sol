// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IAmmalgamPair} from 'contracts/interfaces/IAmmalgamPair.sol';
import {ERC20Base, ERC20BaseConfig} from 'contracts/tokens/ERC20Base.sol';
import {DEPOSIT_L} from 'contracts/interfaces/tokens/ITokenController.sol';

contract ERC20LiquidityToken is ERC20Base {
    constructor(
        ERC20BaseConfig memory config
    ) ERC20Base(config) {}

    /**
     * @dev override {ERC20Base-ownerMint}.
     */
    function ownerMint(address sender, address to, uint256 assets, uint256 shares) public virtual override onlyOwner {
        emit Mint(sender, to, assets, shares);
        _mint(to, shares);
    }

    /**
     * @dev override {ERC20Base-ownerBurn}.
     */
    function ownerBurn(address sender, address to, uint256 assets, uint256 shares) public virtual override onlyOwner {
        emit Burn(sender, to, assets, shares);
        _burn(msg.sender, shares); // msg.sender is the pair who has been sent the token to be burned from the user
    }

    /**
     * @notice Transfers `amount` tokens from the `from` address to the `to` address.
     * @dev override {ERC20Base-ownerTransfer}.
     * @param from The account to deduct the tokens from.
     * @param to The account to deliver the tokens to.
     * @param amount The amount of tokens to be transferred.
     */
    function ownerTransfer(address from, address to, uint256 amount) public virtual override onlyOwner {
        _transfer(from, to, amount);
    }
}
