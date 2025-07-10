// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {ITokenController} from 'contracts/interfaces/tokens/ITokenController.sol';
import {IAmmalgamERC20} from 'contracts/interfaces/tokens/IAmmalgamERC20.sol';
import {ERC20DebtBase} from 'contracts/tokens/ERC20DebtBase.sol';
import {ERC20Base, ERC20BaseConfig} from 'contracts/tokens/ERC20Base.sol';
import {BORROW_L} from 'contracts/interfaces/tokens/ITokenController.sol';

contract ERC20DebtLiquidityToken is ERC20DebtBase {
    using SafeERC20 for IERC20;

    constructor(
        ERC20BaseConfig memory config
    ) ERC20DebtBase(config) {}

    function ownerMint(
        address sender,
        address to,
        uint256 assets,
        uint256 shares
    ) public override(ERC20Base, IAmmalgamERC20) onlyOwner {
        emit BorrowLiquidity(sender, to, assets, shares);
        _mint(sender, shares);
    }

    function ownerBurn(address sender, address onBehalfOf, uint256 assets, uint256 shares) public override onlyOwner {
        emit RepayLiquidity(sender, onBehalfOf, assets, shares);
        _burn(onBehalfOf, shares);
    }

    /**
     * @notice This function is reserved for moving collateral to liquidators, but here we reuse it
     * to transfer debt from the pair to a borrower. Since the borrower might already be in trouble
     * if this is called during a liquidation, we do not call `validateOnUpdate` to avoid failing
     * on the loan to value check. This also means that saturation is not updated for this penalty
     * owed. we think this is an acceptable discrepancy since it is only the penalty for over
     * saturation that is not being included in the saturation update, which should be a negligible
     * amount with respect to the total debt. Once a position is updated either by the users
     * actions, or by a soft liquidation, this penalty will be adjusted to the correct value. in
     * the Saturation State.
     *
     * @param from address from which shares are transferred
     * @param to address to which shares are transferred
     * @param amount amount of shares to transfer
     */
    function ownerTransfer(
        address from,
        address to,
        uint256 amount
    ) public override(ERC20Base, IAmmalgamERC20) onlyOwner {
        transferPenaltyFromPairToBorrower = true;
        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events _transfer is in ERC20 and does not make other calls
        _transfer(from, to, amount);
        transferPenaltyFromPairToBorrower = false;
    }

    /**
     * @notice We use the callback to transfer debt to the caller and transfer borrowed assets to the receiver.
     *    This contract never has assets or shares unless they were sent to it by the pair within
     *    the context of this function getting called. Calling this function directly will not do
     *    anything because there are no assets or shares to transfer.
     *
     * @param assetsX amount of tokenX sent to this contract
     * @param assetsY amount of tokenY sent to this contract
     * @param sharesL amount of liquidity debt added to this contract
     * @param data encoded data containing the caller and receiver addresses
     */
    function borrowLiquidityCall(
        address sender,
        uint256 assetsX,
        uint256 assetsY,
        uint256 sharesL,
        bytes calldata data
    ) public {
        if (data.length > 0 && msg.sender == address(pair) && sender == address(this)) {
            (address caller, address receiver) = abi.decode(data, (address, address));

            _transfer(address(this), caller, sharesL);

            (IERC20 tokenX, IERC20 tokenY) = ITokenController(address(pair)).underlyingTokens();

            tokenX.safeTransfer(receiver, assetsX);
            tokenY.safeTransfer(receiver, assetsY);
        }
    }
}
