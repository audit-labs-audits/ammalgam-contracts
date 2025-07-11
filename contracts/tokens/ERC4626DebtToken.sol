// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';

import {IAmmalgamERC20} from 'contracts/interfaces/tokens/IAmmalgamERC20.sol';
import {IAmmalgamPair} from 'contracts/interfaces/IAmmalgamPair.sol';
import {ITokenController} from 'contracts/interfaces/tokens/ITokenController.sol';
import {ERC20Base, ERC20BaseConfig} from 'contracts/tokens/ERC20Base.sol';
import {ERC20DebtBase} from 'contracts/tokens/ERC20DebtBase.sol';
import {BORROW_X} from 'contracts/interfaces/tokens/ITokenController.sol';
import {Convert} from 'contracts/libraries/Convert.sol';

contract ERC4626DebtToken is ERC4626, ERC20DebtBase {
    using SafeERC20 for IERC20;

    constructor(ERC20BaseConfig memory config, address _asset) ERC4626(IERC20(_asset)) ERC20DebtBase(config) {}

    function ownerMint(
        address sender,
        address to,
        uint256 assets,
        uint256 shares
    ) public virtual override(ERC20Base, IAmmalgamERC20) onlyOwner {
        emit Borrow(sender, to, assets, shares);
        _mint(sender, shares);
    }

    function ownerBurn(
        address sender,
        address onBehalfOf,
        uint256 assets,
        uint256 shares
    ) public virtual override(IAmmalgamERC20) onlyOwner {
        emit Repay(sender, onBehalfOf, assets, shares);
        _burn(onBehalfOf, shares);
    }

    /**
     * @notice We use the callback to transfer debt to the caller and transfer borrowed assets to the receiver.
     *    This contract never has assets or shares unless they were sent to it by the pair within
     *    the context of this function getting called. Calling this function directly will not do
     *    anything because there are no assets or shares to transfer.
     * @dev Shares and assets need testing.
     * @param assetsX assets amount of tokenX sent to this contract
     * @param assetsY assets amount of tokenY sent to this contract
     * @param sharesX shares amount of tokenX sent to this contract
     * @param sharesY shares amount of tokenY sent to this contract
     * @param data encoded data containing the caller and receiver addresses
     */
    function ammalgamBorrowCallV1(
        address sender,
        uint256 assetsX,
        uint256 assetsY,
        uint256 sharesX,
        uint256 sharesY,
        bytes calldata data
    ) public virtual {
        if (data.length > 0 && msg.sender == address(pair) && sender == address(this)) {
            (address caller, address receiver) = abi.decode(data, (address, address));
            (uint256 assets, uint256 shares) = tokenType == BORROW_X ? (assetsX, sharesX) : (assetsY, sharesY);

            // No check for spending allowance since caller set in _deposit
            // which is called from `mint` and `deposit` both which pass
            // msg.sender, so the caller consented to the transfer by calling
            // mint or deposit of a debt token.
            _transfer(address(this), caller, shares);
            IERC20(asset()).safeTransfer(receiver, assets);
        }
    }

    /**
     * @dev ERC4626 facade for {IAmmalgamPair-borrow}.
     * both deposit and mint calls _deposit
     * This is called when the user is borrowing
     */
    // slither-disable-start dead-code // Not dead-code; they are used via ERC4626 facade.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 /*shares*/
    ) internal virtual override {
        bytes memory data = abi.encode(caller, receiver);
        // slither-disable-next-line uninitialized-local
        uint256 amountXAssets;
        // slither-disable-next-line uninitialized-local
        uint256 amountYAssets;
        if (tokenType == BORROW_X) {
            amountXAssets = assets;
        } else {
            amountYAssets = assets;
        }
        IAmmalgamPair(address(pair)).borrow(address(this), amountXAssets, amountYAssets, data);
    }

    /**
     * @dev ERC4626 facade for {IAmmalgamPair-repay}.
     * both withdraw and redeem calls _withdraw
     * This is called when the user is repaying their debt
     */
    function _withdraw(
        address caller,
        address receiver,
        address, /*owner*/
        uint256 assets,
        uint256 /*shares*/
    ) internal virtual override {
        // slither-disable-next-line arbitrary-send-erc20
        IERC20(asset()).safeTransferFrom(caller, address(pair), assets);
        // slither-disable-next-line unused-return
        IAmmalgamPair(address(pair)).repay(receiver);
    }
    // slither-disable-end dead-code

    function approve(
        address account,
        uint256 balance
    ) public pure override(ERC20, ERC20DebtBase, IERC20) returns (bool) {
        super.approve(account, balance);
    }

    function allowance(
        address owner,
        address spender
    ) public view override(ERC20, ERC20DebtBase, IERC20) returns (uint256) {
        return super.allowance(owner, spender);
    }

    function decimals() public view override(ERC20Base, ERC4626, IERC20Metadata) returns (uint8) {
        return super.decimals();
    }

    function totalAssets() public view override returns (uint256) {
        return ITokenController(address(pair)).totalAssets()[tokenType];
    }

    function transfer(address recipient, uint256 amount) public override(ERC20, IERC20, ERC20DebtBase) returns (bool) {
        return super.transfer(recipient, amount);
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override(ERC20, IERC20, ERC20DebtBase) returns (bool) {
        return super.transferFrom(sender, recipient, amount);
    }

    function _update(address from, address to, uint256 amount) internal virtual override(ERC20, ERC20Base) {
        super._update(from, to, amount);
    }

    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual override(ERC20DebtBase, ERC20) {
        super._spendAllowance(owner, spender, amount);
    }

    function balanceOf(
        address account
    ) public view override(ERC20Base, IERC20, ERC20) returns (uint256) {
        return super.balanceOf(account);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return Convert.toShares(assets, totalAssets(), totalSupply(), rounding == Math.Rounding.Floor);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return Convert.toAssets(shares, totalAssets(), totalSupply(), rounding == Math.Rounding.Floor);
    }
}
