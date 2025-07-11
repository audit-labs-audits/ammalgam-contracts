// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {IERC20DebtToken} from 'contracts/interfaces/tokens/IERC20DebtToken.sol';
import {IAmmalgamERC20} from 'contracts/interfaces/tokens/IAmmalgamERC20.sol';
import {ITokenController} from 'contracts/interfaces/tokens/ITokenController.sol';
import {IAmmalgamPair} from 'contracts/interfaces/IAmmalgamPair.sol';
import {ERC20Base, ERC20BaseConfig} from 'contracts/tokens/ERC20Base.sol';
import {IERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol';

abstract contract ERC20DebtBase is ERC20Base, IERC20DebtToken {
    using SafeERC20 for IERC20;

    error DebtERC20ApproveDebt();
    error DebtERC20IncreaseDebtAllowance();
    error DebtERC20DecreaseDebtAllowance();

    constructor(
        ERC20BaseConfig memory config
    ) ERC20Base(config) {}

    function nonces(
        address owner
    ) public view virtual override(ERC20Base, IERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }

    function approve(
        address, /*owner*/
        uint256 /*amount*/
    ) public pure virtual override(ERC20, IERC20) returns (bool) {
        revert DebtERC20ApproveDebt();
    }

    function allowance(
        address receiver,
        address spender
    ) public view virtual override(ERC20, IERC20) returns (uint256) {
        return super.allowance(receiver, spender);
    }

    /// @dev Sets `amount` as the allowance of `spender` to send `receiver` debt tokens.
    /// Map key is the receiver of the debt approving the debt to be moved to them.
    function debtAllowance(address receiver, address spender) public view returns (uint256) {
        return super.allowance(receiver, spender);
    }

    function approveDebt(address spender, uint256 amount) public returns (bool) {
        address receiver = _msgSender();
        _approve(receiver, spender, amount);
        return true;
    }

    function transfer(address receiver, uint256 amount) public virtual override(ERC20, IERC20) returns (bool) {
        return transferFrom(_msgSender(), receiver, amount);
    }

    function transferFrom(
        address owner,
        address receiver,
        uint256 amount
    ) public virtual override(ERC20, IERC20) returns (bool) {
        address spender = _msgSender();
        // always check spend allowance since we don't want a contract, as the
        // receiver, to accept debt tokens expecting them to be assets rather
        // than a debt.
        _spendAllowance(receiver, spender, amount);
        _transfer(owner, receiver, amount);
        return true;
    }

    function claimDebt(address owner, uint256 amount) public override {
        _transfer(owner, _msgSender(), amount);
    }

    /// @dev override this method to be able to use debtAllowance
    function _spendAllowance(address receiver, address spender, uint256 amount) internal virtual override {
        super._spendAllowance(receiver, spender, amount);
    }
}
