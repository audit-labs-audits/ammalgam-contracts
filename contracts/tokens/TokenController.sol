// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';

import {INewTokensFactory} from 'contracts/interfaces/factories/INewTokensFactory.sol';
import {IFactoryCallback} from 'contracts/interfaces/factories/IFactoryCallback.sol';
import {IAmmalgamERC20} from 'contracts/interfaces/tokens/IAmmalgamERC20.sol';
import {
    ITokenController,
    BORROW_L,
    BORROW_X,
    BORROW_Y,
    DEPOSIT_L,
    DEPOSIT_X,
    DEPOSIT_Y,
    FIRST_DEBT_TOKEN,
    ROUNDING_UP
} from 'contracts/interfaces/tokens/ITokenController.sol';
import {Interest} from 'contracts/libraries/Interest.sol';
import {Convert} from 'contracts/libraries/Convert.sol';
import {GeometricTWAP} from 'contracts/libraries/GeometricTWAP.sol';
import {TickMath} from 'contracts/libraries/TickMath.sol';
import {Q32, Q128, ZERO_ADDRESS} from 'contracts/libraries/constants.sol';
import {Saturation} from 'contracts/libraries/Saturation.sol';
import {ISaturationAndGeometricTWAPState} from 'contracts/interfaces/ISaturationAndGeometricTWAPState.sol';

/**
 * @dev Wrapper of the ERC20 tokens that has some functionality similar to the ERC1155.
 */
contract TokenController is ITokenController {
    IERC20 private immutable tokenX;
    IERC20 private immutable tokenY;
    IAmmalgamERC20 private immutable _tokenDepositL;
    IAmmalgamERC20 private immutable _tokenDepositX;
    IAmmalgamERC20 private immutable _tokenDepositY;
    IAmmalgamERC20 private immutable _tokenBorrowL;
    IAmmalgamERC20 private immutable _tokenBorrowX;
    IAmmalgamERC20 private immutable _tokenBorrowY;
    uint112[6] private allShares;
    uint128[6] internal allAssets;

    uint112 private reserveXAssets;
    uint112 private reserveYAssets;
    uint32 internal lastUpdateTimestamp;
    uint112 internal referenceReserveX;
    uint112 internal referenceReserveY;
    uint32 internal lastLendingTimestamp;
    uint112 internal missingXAssets;
    uint112 internal missingYAssets;
    uint32 internal lastPenaltyTimestamp;
    uint128 internal lastReserveLiquidity;
    uint128 internal lastActiveLiquidityAssets;

    uint256 internal transient totalDepositLAssets;
    uint256 internal transient totalDepositXAssets;
    uint256 internal transient totalDepositYAssets;
    uint256 internal transient totalBorrowLAssets;
    uint256 internal transient totalBorrowXAssets;
    uint256 internal transient totalBorrowYAssets;

    uint112 public override externalLiquidity = 0;

    IFactoryCallback internal immutable factory;

    ISaturationAndGeometricTWAPState internal immutable saturationAndGeometricTWAPState;

    error Forbidden();

    constructor() {
        IAmmalgamERC20[6] memory tokenData;
        factory = IFactoryCallback(msg.sender);
        (tokenX, tokenY, tokenData) = factory.generateTokensWithinFactory();

        _tokenDepositL = tokenData[DEPOSIT_L];
        _tokenDepositX = tokenData[DEPOSIT_X];
        _tokenDepositY = tokenData[DEPOSIT_Y];
        _tokenBorrowL = tokenData[BORROW_L];
        _tokenBorrowX = tokenData[BORROW_X];
        _tokenBorrowY = tokenData[BORROW_Y];

        saturationAndGeometricTWAPState = ISaturationAndGeometricTWAPState(factory.saturationAndGeometricTWAPState());
    }

    modifier onlyFeeToSetter() {
        _onlyFeeToSetter();
        _;
    }

    function _onlyFeeToSetter() private view {
        if (msg.sender != factory.feeToSetter()) {
            revert Forbidden();
        }
    }

    function underlyingTokens() public view override returns (IERC20, IERC20) {
        return (tokenX, tokenY);
    }

    function updateAssets(uint256 tokenType, uint128 assets) private {
        // totalDepositLAssets == 0 => no transient vars set yet
        // slither-disable-next-line incorrect-equality
        if (totalDepositLAssets == 0) return;

        if (tokenType == DEPOSIT_L) {
            totalDepositLAssets = assets;
        } else if (tokenType == DEPOSIT_X) {
            totalDepositXAssets = assets;
        } else if (tokenType == DEPOSIT_Y) {
            totalDepositYAssets = assets;
        } else if (tokenType == BORROW_L) {
            totalBorrowLAssets = assets;
        } else if (tokenType == BORROW_X) {
            totalBorrowXAssets = assets;
        } else if (tokenType == BORROW_Y) {
            totalBorrowYAssets = assets;
        }
    }

    function updateExternalLiquidity(
        uint112 _externalLiquidity
    ) external onlyFeeToSetter {
        emit UpdateExternalLiquidity(_externalLiquidity);
        externalLiquidity = _externalLiquidity;
    }

    function mintId(uint256 tokenType, address sender, address to, uint256 assets, uint256 shares_) internal {
        allShares[tokenType] += SafeCast.toUint112(shares_);
        uint128 updatedAssets = allAssets[tokenType] + SafeCast.toUint128(assets);
        allAssets[tokenType] = updatedAssets;
        updateAssets(tokenType, updatedAssets);
        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events
        tokens(tokenType).ownerMint(sender, to, assets, shares_);
    }

    function burnId(uint256 tokenType, address sender, address from, uint256 assets, uint256 shares_) internal {
        // Burn tokens first, this will ensure user does not try to repay or burn more than they own.
        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events
        tokens(tokenType).ownerBurn(sender, from, assets, shares_);
        allShares[tokenType] -= SafeCast.toUint112(shares_);
        uint128 updatedAssets = allAssets[tokenType] - SafeCast.toUint128(assets);
        allAssets[tokenType] = updatedAssets;
        updateAssets(tokenType, updatedAssets);
    }

    function tokens(
        uint256 tokenType
    ) public view override returns (IAmmalgamERC20) {
        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events
        return [_tokenDepositL, _tokenDepositX, _tokenDepositY, _tokenBorrowL, _tokenBorrowX, _tokenBorrowY][tokenType];
    }

    function balanceOf(address account, uint256 tokenType) internal view returns (uint256) {
        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events,calls-loop
        return tokens(tokenType).balanceOf(account);
    }

    function totalShares(
        uint256 tokenType
    ) internal view returns (uint256) {
        return allShares[tokenType];
    }

    function rawTotalAssets(
        uint256 tokenType
    ) internal view returns (uint128) {
        return allAssets[tokenType];
    }

    function getReserves()
        public
        view
        returns (uint112 _reserveXAssets, uint112 _reserveYAssets, uint32 _lastTimestamp)
    {
        _reserveXAssets = reserveXAssets;
        _reserveYAssets = reserveYAssets;
        _lastTimestamp = lastUpdateTimestamp;
    }

    function getTickRange() public view returns (int16 minTick, int16 maxTick) {
        (uint112 _reserveXAssets, uint112 _reserveYAssets,) = getReserves();
        uint256 priceInQ128 = Convert.mulDiv(_reserveXAssets, Q128, _reserveYAssets, false);
        int16 currentTick = TickMath.getTickAtPrice(priceInQ128);
        (minTick, maxTick) = saturationAndGeometricTWAPState.getTickRange(address(this), currentTick, true);
    }

    function referenceReserves() public view returns (uint112, uint112) {
        return (referenceReserveX, referenceReserveY);
    }

    /**
     * @notice Computes the current total Assets.
     * @dev If the last lending state update is outdated (i.e., not matching the current block timestamp),
     *      the function recalculates the assets based on the duration since the last update, the lending state,
     *      and reserve balances. If the timestamp is current, the previous asset (without recalculation) is returned.
     * @return totalAssets An array of six `uint128` values representing the total assets for each of the 6 amalgam token types.
     *  These values may be adjusted based on the time elapsed since the last update. If the timestamp is up-to-date, the
     *  previously calculated total assets are returned without recalculation.
     */
    function totalAssets() public view returns (uint128[6] memory) {
        if (totalDepositLAssets != 0) {
            return [
                uint128(totalDepositLAssets),
                uint128(totalDepositXAssets),
                uint128(totalDepositYAssets),
                uint128(totalBorrowLAssets),
                uint128(totalBorrowXAssets),
                uint128(totalBorrowYAssets)
            ];
        }

        uint32 deltaUpdateTimestamp;
        uint32 deltaLendingTimestamp;
        unchecked {
            uint32 currentTimestamp = GeometricTWAP.getCurrentTimestamp();
            deltaUpdateTimestamp = currentTimestamp - lastUpdateTimestamp;
            deltaLendingTimestamp = currentTimestamp - lastLendingTimestamp;
        }
        // slither-disable-next-line incorrect-equality
        if (deltaLendingTimestamp == 0) {
            return allAssets;
        }

        (uint256 _reserveXAssets, uint256 _reserveYAssets,) = getReserves();
        int16 newTick = saturationAndGeometricTWAPState.boundTick(
            TickMath.getTickAtPrice(Convert.mulDiv(_reserveXAssets, Q128, _reserveYAssets, false))
        );

        int16 lendingStateTick;
        uint256 satPercentageInWads;
        unchecked {
            // overflow is desired
            // slither-disable-next-line unused-return
            (lendingStateTick, satPercentageInWads) = saturationAndGeometricTWAPState.getLendingStateTick(
                newTick, deltaUpdateTimestamp, deltaLendingTimestamp
            );
        }

        Interest.AccrueInterestParams memory params = Interest.AccrueInterestParams({
            duration: deltaLendingTimestamp,
            lendingStateTick: lendingStateTick,
            adjustedActiveLiquidity: getAdjustedActiveLiquidity(_reserveXAssets, _reserveYAssets),
            shares: allShares,
            satPercentageInWads: satPercentageInWads
        });

        // slither-disable-next-line unused-return
        (uint128[6] memory currentAssets,,,) = Interest.accrueInterestWithAssets(allAssets, params);

        return currentAssets;
    }

    function mintPenalties(address account, uint32 deltaPenaltyTimestamp) internal {
        if (account != ZERO_ADDRESS || deltaPenaltyTimestamp > 0) {
            // add penalty before interest because penalty state existed for the duration
            // mint DL and BL for pair to the amount of penalty [LAssets] since the previous state update in total
            uint256 allAssetsDepositL = allAssets[DEPOSIT_L];
            uint256 allAssetsBorrowL = allAssets[BORROW_L];
            uint256 allSharesDepositL = allShares[DEPOSIT_L];
            uint256 allSharesBorrowL = allShares[BORROW_L];

            // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events External contract is under our control
            (uint256 totalPenaltyInBorrowLShares, uint256 accountPenaltyInBorrowLShares) =
            saturationAndGeometricTWAPState.accruePenalties(
                account, externalLiquidity, deltaPenaltyTimestamp, allAssetsDepositL, allAssetsBorrowL, allSharesBorrowL
            );

            // Since we will mint penalty directly to the affected account, we back it out from here.
            uint256 totalPenaltyInDepositLAssets =
                Convert.toAssets(totalPenaltyInBorrowLShares, allAssetsDepositL, allSharesDepositL, ROUNDING_UP);

            // mint DL and BL for penalty not minted to any specific account
            // share penalty with all pre-existing DL only
            mintId(BORROW_L, address(this), address(this), totalPenaltyInDepositLAssets, totalPenaltyInBorrowLShares);
            allAssets[DEPOSIT_L] += SafeCast.toUint128(totalPenaltyInDepositLAssets);

            // update the account, we use the min in case rounding up exceeds the amount of shares
            // if there where only one account in penalty that receives the whole penalty.
            if (0 < accountPenaltyInBorrowLShares) {
                tokens(BORROW_L).ownerTransfer(
                    address(this),
                    account,
                    Math.min(accountPenaltyInBorrowLShares, _tokenBorrowL.balanceOf(address(this)))
                );
            }

            // reset the time to ensure multiple calls does not accrue penalties multiple times.
            lastPenaltyTimestamp = GeometricTWAP.getCurrentTimestamp();
        }
    }

    function getAssets(
        uint128[6] memory currentAssets,
        address toCheck
    ) internal view returns (uint256[6] memory userAssets) {
        for (uint256 i; i < userAssets.length; i++) {
            uint256 currentShares = balanceOf(toCheck, i);
            if (0 < currentShares) {
                // FIRST_DEBT_TOKEN <= i <=> rounding up for borrow tokens
                userAssets[i] = Convert.toAssets(currentShares, currentAssets[i], allShares[i], FIRST_DEBT_TOKEN <= i);
            }
        }
    }

    function updateTokenController(
        uint32 currentTimestamp,
        uint32 deltaUpdateTimestamp,
        uint32 deltaLendingTimestamp,
        uint256 _reserveXAssets,
        uint256 _reserveYAssets
    ) internal returns (uint112 updatedReservesX, uint112 updatedReservesY) {
        Interest.AccrueInterestParams memory accrueInterestParams;
        {
            int16 lendingStateTick;
            uint256 satPercentageInWads;
            unchecked {
                // underflow is desired
                // Call to trusted contract holding some pair state.
                // slither-disable-next-line reentrancy-benign,reentrancy-events,reentrancy-no-eth
                (lendingStateTick, satPercentageInWads) = saturationAndGeometricTWAPState
                    .getLendingStateTickAndCheckpoint(deltaUpdateTimestamp, deltaLendingTimestamp);
            }
            lastLendingTimestamp = currentTimestamp;
            accrueInterestParams = Interest.AccrueInterestParams({
                duration: deltaLendingTimestamp,
                lendingStateTick: lendingStateTick,
                adjustedActiveLiquidity: updateReservesAndActiveLiquidity(_reserveXAssets, _reserveYAssets),
                shares: allShares,
                satPercentageInWads: satPercentageInWads
            });
        }

        (uint256 interestXForLP, uint256 interestYForLP, uint256[3] memory protocolFeeAssets) =
            Interest.accrueInterestAndUpdateReservesWithAssets(allAssets, accrueInterestParams);

        updateReserves(_reserveXAssets + interestXForLP, _reserveYAssets + interestYForLP);
        (updatedReservesX, updatedReservesY) =
            (uint112(_reserveXAssets + interestXForLP), uint112(_reserveYAssets + interestYForLP));

        address feeTo = factory.feeTo();

        mintProtocolFees(DEPOSIT_L, feeTo, protocolFeeAssets[DEPOSIT_L]);
        mintProtocolFees(DEPOSIT_X, feeTo, protocolFeeAssets[DEPOSIT_X]);
        mintProtocolFees(DEPOSIT_Y, feeTo, protocolFeeAssets[DEPOSIT_Y]);

        uint128[6] memory currentAssets = allAssets;
        totalDepositLAssets = currentAssets[DEPOSIT_L];
        totalDepositXAssets = currentAssets[DEPOSIT_X];
        totalDepositYAssets = currentAssets[DEPOSIT_Y];
        totalBorrowLAssets = currentAssets[BORROW_L];
        totalBorrowXAssets = currentAssets[BORROW_X];
        totalBorrowYAssets = currentAssets[BORROW_Y];
    }

    function updateReferenceReserve(
        int256 newTick
    ) internal {
        int256 midTermTick = saturationAndGeometricTWAPState.getObservedMidTermTick(false);
        (uint256 _refReserveX, uint256 _refReserveY) = Interest.getReservesAtTick(
            allAssets[DEPOSIT_L] - allAssets[BORROW_L],
            // round towards new tick. both ticks must be int16 so there average is also int16.
            int16(midTermTick > newTick ? (midTermTick + 1 + newTick) / 2 : (midTermTick + newTick - 1) / 2 + 1)
        );
        (referenceReserveX, referenceReserveY) = _castReserves(_refReserveX, _refReserveY);
    }

    function mintProtocolFees(uint256 tokenType, address feeTo, uint256 protocolFee) private {
        if (protocolFee > 0) {
            mintId(
                tokenType,
                address(this),
                feeTo,
                protocolFee,
                Convert.toShares(protocolFee, rawTotalAssets(tokenType), totalShares(tokenType), !ROUNDING_UP)
            );
        }
    }

    function updateReserves(uint256 newReserveXAssets, uint256 newReserveYAssets) internal {
        (uint112 _castedXAssets, uint112 _castedYAssets) = _castReserves(newReserveXAssets, newReserveYAssets);
        reserveXAssets = _castedXAssets;
        reserveYAssets = _castedYAssets;

        emit Sync(_castedXAssets, _castedYAssets);
    }

    function updateReservesAndReference(
        uint256 _reserveXAssets,
        uint256 _reserveYAssets,
        uint256 newReserveXAssets,
        uint256 newReserveYAssets
    ) internal {
        updateReserves(newReserveXAssets, newReserveYAssets);
        (referenceReserveX, referenceReserveY) = _castReserves(
            Convert.mulDiv(referenceReserveX, newReserveXAssets, _reserveXAssets, false),
            Convert.mulDiv(referenceReserveY, newReserveYAssets, _reserveYAssets, false)
        );
    }

    function _castReserves(uint256 _reserveXAssets, uint256 _reserveYAssets) internal pure returns (uint112, uint112) {
        uint112 castedReserveX = SafeCast.toUint112(_reserveXAssets);
        uint112 castedReserveY = SafeCast.toUint112(_reserveYAssets);
        return (castedReserveX, castedReserveY);
    }

    // slither-disable-next-line naming-convention
    function getNetBalances(
        uint256 _reserveXAssets,
        uint256 _reserveYAssets
    ) internal view returns (uint256, uint256) {
        (IERC20 _tokenX, IERC20 _tokenY) = underlyingTokens();

        return (
            _tokenX.balanceOf(address(this)) + rawTotalAssets(BORROW_X) - rawTotalAssets(DEPOSIT_X) - _reserveXAssets,
            _tokenY.balanceOf(address(this)) + rawTotalAssets(BORROW_Y) - rawTotalAssets(DEPOSIT_Y) - _reserveYAssets
        );
    }

    function missingAssets() internal view returns (uint112, uint112) {
        return (missingXAssets, missingYAssets);
    }

    function updateMissingAssets() internal {
        uint256 depositXAssets = rawTotalAssets(DEPOSIT_X);
        uint256 depositYAssets = rawTotalAssets(DEPOSIT_Y);
        uint256 borrowXAssets = rawTotalAssets(BORROW_X);
        uint256 borrowYAssets = rawTotalAssets(BORROW_Y);
        // no need to safe cast.
        // 0 <= borrow <= uint128.max
        // 0 <= deposit <= uint128.max
        // -uint256.max <= -deposit <= 0
        // -uint256.max <= borrow - deposit <= uint128.max
        missingXAssets = uint112(borrowXAssets > depositXAssets ? borrowXAssets - depositXAssets : 0);
        missingYAssets = uint112(borrowYAssets > depositYAssets ? borrowYAssets - depositYAssets : 0);
    }

    /**
     * @notice Get the deposit, borrow, and active liquidity assets.
     * @dev This function is used to get the deposit liquidity assets, borrow liquidity assets (BLA), last active liquidity assets (ALA_0), and current active liquidity assets (ALA_1).
     * @return depositLiquidityAssets The deposit liquidity assets.
     * @return borrowLAssets The borrow liquidity assets.
     * @return currentActiveLiquidityAssets The current active liquidity assets.
     */
    function getDepositAndBorrowAndActiveLiquidityAssets()
        internal
        view
        returns (uint256 depositLiquidityAssets, uint256 borrowLAssets, uint256 currentActiveLiquidityAssets)
    {
        depositLiquidityAssets = rawTotalAssets(DEPOSIT_L);
        borrowLAssets = rawTotalAssets(BORROW_L);
        currentActiveLiquidityAssets = depositLiquidityAssets - borrowLAssets;
    }

    /**
     * @notice Update the reserves and active liquidity.
     * @dev This function is used to update the last reserves liquidity (RL_0) and last active liquidity assets (ALA_0).
     * @param _reserveXAssets The reserve X assets.
     * @param _reserveYAssets The reserve Y assets.
     */
    function updateReservesAndActiveLiquidity(
        uint256 _reserveXAssets,
        uint256 _reserveYAssets
    ) internal returns (uint256 adjustedActiveLiquidity) {
        uint256 currentReserveLiquidity;
        (currentReserveLiquidity, adjustedActiveLiquidity) =
            getCurrentAndAdjustedActiveLiquidity(_reserveXAssets, _reserveYAssets);
        lastReserveLiquidity = uint128(currentReserveLiquidity);

        uint256 depositLiquidityAssets = rawTotalAssets(DEPOSIT_L);
        uint256 borrowLAssets = rawTotalAssets(BORROW_L);
        lastActiveLiquidityAssets = uint128(depositLiquidityAssets - borrowLAssets);
    }

    /**
     * @notice Get the adjusted active liquidity which is the active liquidity without the swap fees.
     * @dev This function is used to get the adjusted active liquidity.
     * @param _reserveXAssets The reserve X assets.
     * @param _reserveYAssets The reserve Y assets.
     * @return adjustedActiveLiquidity The adjusted active liquidity.
     */
    function getAdjustedActiveLiquidity(
        uint256 _reserveXAssets,
        uint256 _reserveYAssets
    ) internal view returns (uint256 adjustedActiveLiquidity) {
        (, adjustedActiveLiquidity) = getCurrentAndAdjustedActiveLiquidity(_reserveXAssets, _reserveYAssets);
    }

    function getCurrentAndAdjustedActiveLiquidity(
        uint256 _reserveXAssets,
        uint256 _reserveYAssets
    ) internal view returns (uint256 currentReserveLiquidity, uint256 adjustedActiveLiquidity) {
        currentReserveLiquidity = getCurrentReserveLiquidity(_reserveXAssets, _reserveYAssets);
        adjustedActiveLiquidity =
            Convert.mulDiv(lastActiveLiquidityAssets, currentReserveLiquidity, lastReserveLiquidity, false);
    }

    function getCurrentReserveLiquidity(
        uint256 _reserveXAssets,
        uint256 _reserveYAssets
    ) private pure returns (uint256) {
        return Math.sqrt(_reserveXAssets * _reserveYAssets);
    }

    function burnBadDebt(address borrower, uint256 tokenType, uint256 reserve) internal {
        uint256 badDebtShares = tokens(tokenType).balanceOf(borrower);
        // round down means the commons debt and commons deposit is 1 unit larger
        uint256 badDebtAssets =
            Convert.toAssets(badDebtShares, rawTotalAssets(tokenType), totalShares(tokenType), !ROUNDING_UP);

        burnId(tokenType, address(this), borrower, badDebtAssets, badDebtShares);
        if (tokenType == BORROW_L) {
            // distribute the loss to the pool.
            allAssets[DEPOSIT_L] -= SafeCast.toUint112(badDebtAssets);
        } else {
            uint256 totalAssetsWithReserves = rawTotalAssets(tokenType - FIRST_DEBT_TOKEN) + reserve;
            uint256 burnReserves = Convert.mulDiv(badDebtAssets, reserve, totalAssetsWithReserves, false);

            if (tokenType == BORROW_X) {
                reserveXAssets -= SafeCast.toUint112(burnReserves);
                allAssets[DEPOSIT_X] -= SafeCast.toUint112(badDebtAssets - burnReserves);
            } else {
                reserveYAssets -= SafeCast.toUint112(burnReserves);
                allAssets[DEPOSIT_Y] -= SafeCast.toUint112(badDebtAssets - burnReserves);
            }
        }

        emit BurnBadDebt(borrower, tokenType, badDebtAssets, badDebtShares);
    }
}
