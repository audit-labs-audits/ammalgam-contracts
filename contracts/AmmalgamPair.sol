pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {ICallback} from 'contracts/interfaces/callbacks/IAmmalgamCallee.sol';
import {IAmmalgamPair} from 'contracts/interfaces/IAmmalgamPair.sol';
import {GeometricTWAP} from 'contracts/libraries/GeometricTWAP.sol';
import {TickMath} from 'contracts/libraries/TickMath.sol';
import {QuadraticSwapFees} from 'contracts/libraries/QuadraticSwapFees.sol';
import {Validation} from 'contracts/libraries/Validation.sol';
import {Convert} from 'contracts/libraries/Convert.sol';
import {TokenController} from 'contracts/tokens/TokenController.sol';
import {IAmmalgamERC20} from 'contracts/interfaces/tokens/IAmmalgamERC20.sol';
import {MINIMUM_LIQUIDITY, MAG2, Q128, Q72, ZERO_ADDRESS} from 'contracts/libraries/constants.sol';
import {
    BORROW_L,
    BORROW_X,
    BORROW_Y,
    DEPOSIT_L,
    DEPOSIT_X,
    DEPOSIT_Y,
    FIRST_DEBT_TOKEN,
    ROUNDING_UP
} from 'contracts/interfaces/tokens/ITokenController.sol';
import {Liquidation} from 'contracts/libraries/Liquidation.sol';
import {Saturation} from 'contracts/libraries/Saturation.sol';
import {SaturationAndGeometricTWAPState} from 'contracts/SaturationAndGeometricTWAPState.sol';

contract AmmalgamPair is IAmmalgamPair, TokenController {
    uint256 private constant BUFFER = 95;

    uint256 private constant INVERSE_BUFFER = 5;
    uint256 private constant INVERSE_BUFFER_SQUARED = 25;
    uint256 private constant BUFFER_NUMERATOR = 100;

    uint256 private unlocked = 1;

    error Locked();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InsufficientLiquidity();
    error InvalidToAddress();
    error K();
    error InsufficientRepayLiquidity();
    error Overflow();

    function _lock() private view {
        if (unlocked == 0) {
            revert Locked();
        }
    }

    modifier lock() {
        _lock();
        unlocked = 0;
        _;
        unlocked = 1;
    }

    // this low-level function should be called from a contract which performs important safety checks
    function mint(
        address to
    ) external lock returns (uint256 liquidityShares) {
        // slither-disable-start uninitialized-local
        uint256 _reserveXAssets;
        uint256 _reserveYAssets;
        uint256 amountXAssets;
        uint256 amountYAssets;
        uint256 liquidityAssets;
        uint256 activeLiquidityAssets;
        // slither-disable-end uninitialized-local

        // slither-disable-next-line incorrect-equality
        if (lastReserveLiquidity == 0) {
            (_reserveXAssets, _reserveYAssets) = getNetBalances(0, 0);
            uint256 _lastReserveLiquidity =
                lastReserveLiquidity = lastActiveLiquidityAssets = uint128(Math.sqrt(_reserveXAssets * _reserveYAssets));
            liquidityShares = liquidityAssets = _lastReserveLiquidity - MINIMUM_LIQUIDITY;
            (referenceReserveX, referenceReserveY) = _castReserves(_reserveXAssets, _reserveYAssets);

            mintId(DEPOSIT_L, msg.sender, address(factory), MINIMUM_LIQUIDITY, MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
            int16 firstTick = TickMath.getTickAtPrice(Convert.mulDiv(_reserveXAssets, Q128, _reserveYAssets, false));
            saturationAndGeometricTWAPState.init(firstTick);
            uint32 currentTimestamp = GeometricTWAP.getCurrentTimestamp();
            lastUpdateTimestamp = currentTimestamp;
            lastLendingTimestamp = currentTimestamp;
            lastPenaltyTimestamp = currentTimestamp;
        } else {
            (_reserveXAssets, _reserveYAssets, amountXAssets, amountYAssets) = accrueSaturationPenaltiesAndInterest(to);

            uint256 _totalDepositLAssets;
            (_totalDepositLAssets,, activeLiquidityAssets) = getDepositAndBorrowAndActiveLiquidityAssets();
            (liquidityAssets, liquidityShares) = calcMinLiquidityConsideringDepletion(
                amountXAssets,
                amountYAssets,
                _reserveXAssets,
                _reserveYAssets,
                activeLiquidityAssets,
                _totalDepositLAssets,
                totalShares(DEPOSIT_L),
                !ROUNDING_UP
            );
        }

        // slither-disable-next-line incorrect-equality
        if (liquidityShares == 0) revert InsufficientLiquidityMinted();

        mintId(DEPOSIT_L, msg.sender, to, liquidityAssets, liquidityShares);

        // slither-disable-next-line reentrancy-events Sync not related to mint.
        updateReservesAndReference(
            _reserveXAssets, _reserveYAssets, _reserveXAssets + amountXAssets, _reserveYAssets + amountYAssets
        );

        // update Saturation if minter already had a borrow
        getInputParamsAndUpdateSaturation(to, false);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(
        address to
    ) external lock returns (uint256 amountXAssets, uint256 amountYAssets) {
        // ZERO_ADDRESS because we don't need update the receiver of the assets and we already
        // checked the sender in `validateOnUpdate`
        (uint256 _reserveXAssets, uint256 _reserveYAssets,,) = accrueSaturationPenaltiesAndInterest(ZERO_ADDRESS);

        uint256 liquidityShares = balanceOf(address(this), DEPOSIT_L);
        (uint256 depositLiquidityAssets,, uint256 activeLiquidityAssets) = getDepositAndBorrowAndActiveLiquidityAssets();
        uint256 depositLiquidityShares = totalShares(DEPOSIT_L);

        uint256 liquidityAssetsBurned =
            Convert.toAssets(liquidityShares, depositLiquidityAssets, depositLiquidityShares, !ROUNDING_UP);

        amountXAssets = Convert.toLiquidityAssets(
            liquidityShares, _reserveXAssets, activeLiquidityAssets, depositLiquidityAssets, depositLiquidityShares
        );
        amountYAssets = Convert.toLiquidityAssets(
            liquidityShares, _reserveYAssets, activeLiquidityAssets, depositLiquidityAssets, depositLiquidityShares
        );

        // slither-disable-next-line incorrect-equality
        if (amountXAssets == 0 || amountYAssets == 0) {
            revert InsufficientLiquidityBurned();
        }

        // Calculate post-burn reserves
        uint256 newReserveX = _reserveXAssets - amountXAssets;
        uint256 newReserveY = _reserveYAssets - amountYAssets;

        Validation.verifyMaxBorrowL(
            Validation.VerifyMaxBorrowLParams({
                totalAssets: [
                    depositLiquidityAssets - liquidityAssetsBurned,
                    rawTotalAssets(DEPOSIT_X),
                    rawTotalAssets(DEPOSIT_Y),
                    rawTotalAssets(BORROW_L),
                    rawTotalAssets(BORROW_X),
                    rawTotalAssets(BORROW_Y)
                ],
                newBorrowedLAssets: 0,
                reserveXAssets: newReserveX,
                reserveYAssets: newReserveY
            })
        );

        burnId(DEPOSIT_L, msg.sender, to, liquidityAssetsBurned, liquidityShares);

        transferAssets(to, amountXAssets, amountYAssets);

        // slither-disable-next-line reentrancy-events Sync is an unrelated logging event for burn
        updateReservesAndReference(_reserveXAssets, _reserveYAssets, newReserveX, newReserveY);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint256 amountXOut, uint256 amountYOut, address to, bytes calldata data) external lock {
        if (amountXOut == 0 && amountYOut == 0) revert InsufficientOutputAmount();

        (uint256 _reserveXAssets, uint256 _reserveYAssets,) = getReserves(); // gas savings
        // slither-disable-next-line reentrancy-events Sync is an unrelated logging event for swap
        updateObservation(_reserveXAssets, _reserveYAssets);
        // slither-disable-start uninitialized-local
        uint256 amountXIn;
        uint256 amountYIn;
        // slither-disable-end uninitialized-local

        {
            (uint256 _missingXAssets, uint256 _missingYAssets) = missingAssets();

            if (amountXOut >= _reserveXAssets - _missingXAssets || amountYOut >= _reserveYAssets - _missingYAssets) {
                revert InsufficientLiquidity();
            }

            // reentry guarded using lock modifier
            // slither-disable-start reentrancy-no-eth,reentrancy-benign
            // optimistically transfer tokens
            transferAssets(to, amountXOut, amountYOut);
            if (data.length > 0) {
                ICallback(to).ammalgamSwapCallV1(msg.sender, amountXOut, amountYOut, data);
            }
            // slither-disable-end reentrancy-no-eth,reentrancy-benign
            (uint256 balanceXAdjusted, uint256 balanceYAdjusted) = getNetBalances(0, 0);

            amountXIn = calculateAmountIn(amountXOut, balanceXAdjusted, _reserveXAssets);
            amountYIn = calculateAmountIn(amountYOut, balanceYAdjusted, _reserveYAssets);

            // slither-disable-next-line incorrect-equality
            if (amountXIn == 0 && amountYIn == 0) revert InsufficientInputAmount();

            (uint256 _referenceReserveX, uint256 _referenceReserveY) = referenceReserves();
            if (
                calculateBalanceAfterFees(
                    amountXIn, balanceXAdjusted, _reserveXAssets, _referenceReserveX, _missingXAssets
                )
                    * calculateBalanceAfterFees(
                        amountYIn, balanceYAdjusted, _reserveYAssets, _referenceReserveY, _missingYAssets
                    )
                    < calculateReserveAdjustmentsForMissingAssets(_reserveXAssets, _missingXAssets)
                        * calculateReserveAdjustmentsForMissingAssets(_reserveYAssets, _missingYAssets)
            ) {
                revert K();
            }
        }

        // slither-disable-next-line reentrancy-events Cant log event until in is known after callback in some cases
        emit Swap(msg.sender, amountXIn, amountYIn, amountXOut, amountYOut, to);

        updateReserves(_reserveXAssets + amountXIn - amountXOut, _reserveYAssets + amountYIn - amountYOut);
    }

    /**
     * @notice helper method to calculate amountIn for swap
     * @dev Adds jump, saves on runtime size
     *
     * @param amountOut the amount out
     * @param balance the balance
     * @param reserve the reserve
     */
    function calculateAmountIn(
        uint256 amountOut,
        uint256 balance,
        uint256 reserve
    ) private pure returns (uint256 amountIn) {
        if (balance > reserve - amountOut) {
            amountIn = balance - (reserve - amountOut);
        }
    }

    /**
     * @notice helper method to calculate balance after fees
     * @dev Note that amountIn + reserve does not always equal balance if amountOut > 0.
     *      When assets are depleted, we should multiply (balance - missing) * BUFFER_NUMERATOR /
     *      INVERSE_BUFFER, but instead of divide here, we multiply the other side of the K
     *      comparison, see `calculateReserveAdjustmentsForMissingAssets` where we multiply by
     *      INVERSE_BUFFER. When not depleted, we multiply by INVERSE_BUFFER instead of dividing on
     *      the other side.
     * @param amountIn the swap amount in
     * @param balance the balance
     * @param reserve the reserve
     * @param referenceReserve the reference reserve for the block
     * @param missing the missing assets, zero if deposits > borrows of X or Y
     */
    function calculateBalanceAfterFees(
        uint256 amountIn,
        uint256 balance,
        uint256 reserve,
        uint256 referenceReserve,
        uint256 missing
    ) private pure returns (uint256 calculatedBalance) {
        uint256 fee = QuadraticSwapFees.calculateSwapFeeBipsQ64(amountIn, reserve, referenceReserve);

        if (balance * BUFFER < missing * BUFFER_NUMERATOR) {
            // depleted case
            calculatedBalance = Math.ceilDiv(
                ((balance - missing) * QuadraticSwapFees.BIPS_Q64 - amountIn * fee) * BUFFER_NUMERATOR,
                QuadraticSwapFees.BIPS_Q64
            );
        } else {
            // not depleted case
            calculatedBalance = Math.ceilDiv(
                (balance * QuadraticSwapFees.BIPS_Q64 - amountIn * fee) * INVERSE_BUFFER, QuadraticSwapFees.BIPS_Q64
            );
        }
    }

    /**
     * @notice helper method to calculate balance adjustment for missing assets
     * @dev When assets are depleted, we should multiply (reserve - missing) by
     *      BUFFER_NUMERATOR / INVERSE_BUFFER, but instead of divide here, we multiply the other
     *      side of the K comparison, see `calculateBalanceAfterFees` where we multiply by
     *      INVERSE_BUFFER.
     *
     * @param reserve the starting reserve
     * @param missing the missing assets, zero if deposits > borrows of X or Y
     */
    function calculateReserveAdjustmentsForMissingAssets(
        uint256 reserve,
        uint256 missing
    ) private pure returns (uint256 reserveAdjustment) {
        reserveAdjustment = reserve * BUFFER < missing * BUFFER_NUMERATOR
            ? (reserve - missing) * BUFFER_NUMERATOR // depleted case
            : reserve * INVERSE_BUFFER; // not depleted case
    }

    function deposit(
        address to
    ) external lock {
        (uint256 _reserveXAssets, uint256 _reserveYAssets, uint256 amountXAssets, uint256 amountYAssets) =
            accrueSaturationPenaltiesAndInterest(to);

        if (amountXAssets > type(uint112).max || amountYAssets > type(uint112).max) {
            revert Overflow();
        }

        // slither-disable-next-line similar-names
        uint256 userBorrowedX = balanceOf(to, BORROW_X);
        uint256 userBorrowedY = balanceOf(to, BORROW_Y);

        Validation.verifyNotSameAssetsSuppliedAndBorrowed(amountXAssets, amountYAssets, userBorrowedX, userBorrowedY);
        (uint256 _missingXAssets, uint256 _missingYAssets) = missingAssets();
        uint256 adjustReservesX = updateDepositShares(DEPOSIT_X, amountXAssets, _reserveXAssets, _missingXAssets, to);
        uint256 adjustReservesY = updateDepositShares(DEPOSIT_Y, amountYAssets, _reserveYAssets, _missingYAssets, to);
        if (adjustReservesX > 0 || adjustReservesY > 0) {
            updateReservesAndReference(
                _reserveXAssets, _reserveYAssets, _reserveXAssets - adjustReservesX, _reserveYAssets - adjustReservesY
            );
        }
        updateMissingAssets();

        // update Saturation if depositor already had a borrow
        getInputParamsAndUpdateSaturation(to, false);
    }

    function updateDepositShares(
        uint256 depositedTokenType,
        uint256 amountAssets,
        uint256 reserveAssets,
        uint256 _missingAssets,
        address to
    ) private returns (uint256 adjustReserves) {
        if (amountAssets > 0) {
            adjustReserves = depletionReserveAdjustmentWhenAssetIsAdded(amountAssets, reserveAssets, _missingAssets);
            uint112 adjAmountAssets = uint112(amountAssets + adjustReserves);
            updateBorrowOrDepositSharesHelper(to, depositedTokenType, adjAmountAssets, !ROUNDING_UP);
        }
    }

    /**
     * withdraw X and/or Y
     */
    function withdraw(
        address to
    ) external lock {
        // ZERO_ADDRESS because we don't need update the receiver of the assets and we already
        // checked the sender in `validateOnUpdate`

        // accrueSaturationPenaltiesAndInterest(ZERO_ADDRESS);
        (uint256 _reserveXAssets, uint256 _reserveYAssets,,) = accrueSaturationPenaltiesAndInterest(ZERO_ADDRESS);

        uint256 assetsX = updateWithdrawShares(to, DEPOSIT_X, _reserveXAssets);
        uint256 assetsY = updateWithdrawShares(to, DEPOSIT_Y, _reserveYAssets);

        transferAssets(to, assetsX, assetsY);

        updateMissingAssets();
    }

    function updateWithdrawShares(
        address to,
        uint256 depositedTokenType,
        uint256 _reserve
    ) private returns (uint256 withdrawnAssets) {
        uint256 depositedShares = balanceOf(address(this), depositedTokenType);
        // slither-disable-next-line incorrect-equality
        if (depositedShares == 0) return 0;
        uint256 currentAssets = rawTotalAssets(depositedTokenType);
        uint256 _totalShares = totalShares(depositedTokenType);

        withdrawnAssets = Convert.toAssets(depositedShares, currentAssets, _totalShares, !ROUNDING_UP);

        Validation.VerifyMaxBorrowXYParams memory maxBorrowParams = Validation.VerifyMaxBorrowXYParams({
            amount: 0,
            depositedAssets: currentAssets - withdrawnAssets,
            borrowedAssets: rawTotalAssets(depositedTokenType + FIRST_DEBT_TOKEN),
            reserve: _reserve,
            totalLiquidityAssets: rawTotalAssets(DEPOSIT_L),
            borrowedLiquidityAssets: rawTotalAssets(BORROW_L)
        });

        Validation.verifyMaxBorrowXY(maxBorrowParams);

        burnId(depositedTokenType, msg.sender, to, withdrawnAssets, depositedShares);
    }

    // borrow x and y
    function borrow(address to, uint256 amountXAssets, uint256 amountYAssets, bytes calldata data) external lock {
        (uint256 _reserveXAssets, uint256 _reserveYAssets,,) = accrueSaturationPenaltiesAndInterest(to);

        Validation.VerifyMaxBorrowXYParams memory maxBorrowParams = Validation.VerifyMaxBorrowXYParams({
            amount: 0,
            depositedAssets: 0,
            borrowedAssets: 0,
            reserve: 0,
            totalLiquidityAssets: rawTotalAssets(DEPOSIT_L),
            borrowedLiquidityAssets: rawTotalAssets(BORROW_L)
        });

        uint256 amountXShares = borrowHelper(maxBorrowParams, to, amountXAssets, _reserveXAssets, BORROW_X, DEPOSIT_X);
        uint256 amountYShares = borrowHelper(maxBorrowParams, to, amountYAssets, _reserveYAssets, BORROW_Y, DEPOSIT_Y);

        transferAssets(to, amountXAssets, amountYAssets);

        updateMissingAssets();

        if (data.length > 0) {
            unlocked = 1;
            ICallback(to).ammalgamBorrowCallV1(
                msg.sender, amountXAssets, amountYAssets, amountXShares, amountYShares, data
            );
            unlocked = 0;
        }

        validateSolvency(msg.sender, false);
    }

    function borrowHelper(
        Validation.VerifyMaxBorrowXYParams memory maxBorrowParams,
        address to,
        uint256 amountAssets,
        uint256 reserve,
        uint256 borrowedTokenType,
        uint256 depositedTokenType
    ) private returns (uint256 amountShares) {
        if (amountAssets > 0) {
            maxBorrowParams.amount = amountAssets;
            maxBorrowParams.reserve = reserve;
            maxBorrowParams.borrowedAssets = rawTotalAssets(borrowedTokenType);
            maxBorrowParams.depositedAssets = rawTotalAssets(depositedTokenType);

            Validation.verifyMaxBorrowXY(maxBorrowParams);

            // slither-disable-next-line events-maths
            amountShares = updateBorrowOrDepositSharesHelper(to, borrowedTokenType, amountAssets, ROUNDING_UP);
        }
    }

    function updateBorrowOrDepositSharesHelper(
        address to,
        uint256 tokenType,
        uint256 amountAssets,
        bool isRoundingUp
    ) private returns (uint256 amountShares) {
        amountShares = Convert.toShares(amountAssets, rawTotalAssets(tokenType), totalShares(tokenType), isRoundingUp);
        mintId(tokenType, msg.sender, to, amountAssets, amountShares);
    }

    function borrowLiquidity(
        address to,
        uint256 borrowAmountLAssets,
        bytes calldata data
    ) external lock returns (uint256, uint256) {
        (uint256 _reserveXAssets, uint256 _reserveYAssets,,) = accrueSaturationPenaltiesAndInterest(to);

        uint256 borrowAmountLShares;
        uint256 borrowedLXAssets;
        uint256 borrowedLYAssets;
        {
            uint256 _totalBorrowLAssets = rawTotalAssets(BORROW_L);

            Validation.verifyMaxBorrowL(
                Validation.VerifyMaxBorrowLParams({
                    totalAssets: [
                        rawTotalAssets(DEPOSIT_L),
                        rawTotalAssets(DEPOSIT_X),
                        rawTotalAssets(DEPOSIT_Y),
                        _totalBorrowLAssets,
                        rawTotalAssets(BORROW_X),
                        rawTotalAssets(BORROW_Y)
                    ],
                    newBorrowedLAssets: borrowAmountLAssets,
                    reserveXAssets: _reserveXAssets,
                    reserveYAssets: _reserveYAssets
                })
            );

            {
                //LX = BLA * Rx * RL_0 / (RL_1 * ALA_0)
                uint256 adjustedActiveLiquidity = getAdjustedActiveLiquidity(_reserveXAssets, _reserveYAssets);
                borrowedLXAssets = Convert.mulDiv(borrowAmountLAssets, _reserveXAssets, adjustedActiveLiquidity, false);
                borrowedLYAssets = Convert.mulDiv(borrowAmountLAssets, _reserveYAssets, adjustedActiveLiquidity, false);
            }

            borrowAmountLShares =
                Convert.toShares(borrowAmountLAssets, _totalBorrowLAssets, totalShares(BORROW_L), ROUNDING_UP);

            // slither-disable-next-line incorrect-equality
            mintId(BORROW_L, msg.sender, to, borrowAmountLAssets, borrowAmountLShares);
        }

        transferAssets(to, borrowedLXAssets, borrowedLYAssets);

        // Reserves are updated to reflect the borrowed L being deducted from the pool that can no longer be used for trading
        // slither-disable-next-line reentrancy-events Sync is an unrelated logging event for borrowLiquidity
        updateReservesAndReference(
            _reserveXAssets, _reserveYAssets, _reserveXAssets - borrowedLXAssets, _reserveYAssets - borrowedLYAssets
        );

        if (data.length > 0) {
            unlocked = 1;
            ICallback(to).ammalgamBorrowLiquidityCallV1(
                msg.sender, borrowedLXAssets, borrowedLYAssets, borrowAmountLShares, data
            );
            unlocked = 0;
        }

        validateSolvency(msg.sender, false);

        return (borrowedLXAssets, borrowedLYAssets);
    }

    function repay(
        address onBehalfOf
    ) external lock returns (uint256 repayXInXAssets, uint256 repayYInYAssets) {
        return _repay(onBehalfOf);
    }

    /**
     * @notice Internal version to allow for direct calls during liquidations
     */
    function _repay(
        address onBehalfOf
    ) private returns (uint256 repayXInXAssets, uint256 repayYInYAssets) {
        uint256 _reserveXAssets;
        uint256 _reserveYAssets;
        (_reserveXAssets, _reserveYAssets, repayXInXAssets, repayYInYAssets) =
            accrueSaturationPenaltiesAndInterest(onBehalfOf);

        (uint256 _missingXAssets, uint256 _missingYAssets) = missingAssets();

        uint256 adjustReservesX;
        uint256 adjustReservesY;
        (adjustReservesX, repayXInXAssets) =
            repayHelper(onBehalfOf, repayXInXAssets, _reserveXAssets, _missingXAssets, BORROW_X);
        (adjustReservesY, repayYInYAssets) =
            repayHelper(onBehalfOf, repayYInYAssets, _reserveYAssets, _missingYAssets, BORROW_Y);

        if (0 < adjustReservesX || 0 < adjustReservesY) {
            updateReservesAndReference(
                _reserveXAssets, _reserveYAssets, _reserveXAssets - adjustReservesX, _reserveYAssets - adjustReservesY
            );
        }

        updateMissingAssets();

        // update Saturation
        getInputParamsAndUpdateSaturation(onBehalfOf, true);
    }

    function repayHelper(
        address onBehalfOf,
        uint256 repayInAssets,
        uint256 reserveInAssets,
        uint256 missingInAssets,
        uint256 borrowTokenType
    ) private returns (uint256 adjustedReservesInAssets, uint256 netRepayInAssets) {
        // slither-disable-next-line incorrect-equality
        if (repayInAssets == 0) return (0, 0);

        adjustedReservesInAssets =
            depletionReserveAdjustmentWhenAssetIsAdded(repayInAssets, reserveInAssets, missingInAssets);

        netRepayInAssets = repayInAssets + adjustedReservesInAssets;
        uint256 repayInShares = Convert.toShares(
            netRepayInAssets, rawTotalAssets(borrowTokenType), totalShares(borrowTokenType), !ROUNDING_UP
        );
        burnId(borrowTokenType, msg.sender, onBehalfOf, netRepayInAssets, repayInShares);
    }

    function repayLiquidity(
        address onBehalfOf
    ) external lock returns (uint256 repaidLXInXAssets, uint256 repaidLYInYAssets, uint256 repayLiquidityAssets) {
        return _repayLiquidity(onBehalfOf);
    }

    function _repayLiquidity(
        address onBehalfOf
    ) private returns (uint256 repaidLXInXAssets, uint256 repaidLYInYAssets, uint256 repayLiquidityAssets) {
        uint256 _reserveXAssets;
        uint256 _reserveYAssets;
        (_reserveXAssets, _reserveYAssets, repaidLXInXAssets, repaidLYInYAssets) =
            accrueSaturationPenaltiesAndInterest(onBehalfOf);

        // BLA, ALA
        uint256 totalBorrowedLiquidityShares = totalShares(BORROW_L);
        uint256 totalBorrowLiquidityAssets = rawTotalAssets(BORROW_L);

        uint256 repayLiquidityShares;
        (repayLiquidityAssets, repayLiquidityShares) = calcMinLiquidityConsideringDepletion(
            repaidLXInXAssets,
            repaidLYInYAssets,
            _reserveXAssets,
            _reserveYAssets,
            getAdjustedActiveLiquidity(_reserveXAssets, _reserveYAssets),
            totalBorrowLiquidityAssets,
            totalBorrowedLiquidityShares,
            ROUNDING_UP
        );

        // slither-disable-next-line incorrect-equality // repayLiquidityShares is a uint256 can never be less than 0
        if (repayLiquidityShares == 0) {
            revert InsufficientRepayLiquidity();
        }
        uint256 balanceOfBorrowLShares = balanceOf(onBehalfOf, BORROW_L);

        if (repayLiquidityShares > balanceOfBorrowLShares) {
            repayLiquidityShares = balanceOfBorrowLShares;
            unchecked {
                repayLiquidityAssets = Convert.toAssets(
                    repayLiquidityShares, totalBorrowLiquidityAssets, totalBorrowedLiquidityShares, ROUNDING_UP
                );
            }
        }

        if (repayLiquidityAssets > totalBorrowLiquidityAssets) {
            // When there is only one borrower, we repay their entire balance. Due to rounding up in calculations,
            // the final repayment amount might slightly exceed the remaining assets in the pool.
            repayLiquidityAssets = totalBorrowLiquidityAssets;
        }

        // the first `repayAmountLShares` is considered as assets for function burnId.
        burnId(BORROW_L, msg.sender, onBehalfOf, repayLiquidityAssets, repayLiquidityShares);
        // slither-disable-next-line reentrancy-events Sync is an unrelated logging event for repayLiquidity
        updateReservesAndReference(
            _reserveXAssets, _reserveYAssets, _reserveXAssets + repaidLXInXAssets, _reserveYAssets + repaidLYInYAssets
        );

        // update Saturation
        getInputParamsAndUpdateSaturation(onBehalfOf, true);
    }

    /**
     * @notice LTV based liquidation. The LTV dictates the max premium that can be had by the liquidator.
     * @param borrower The account being liquidated
     * @param to The account to send the liquidated deposit to
     * @param depositLToBeTransferredInLAssets The amount of L to be transferred to the liquidator.
     * @param depositXToBeTransferredInXAssets The amount of X to be transferred to the liquidator.
     * @param depositYToBeTransferredInYAssets The amount of Y to be transferred to the liquidator.
     * @param repayLXInXAssets The amount of LX to be repaid by the liquidator.
     * @param repayLYInYAssets The amount of LY to be repaid by the liquidator.
     * @param repayXInXAssets The amount of X to be repaid by the liquidator.
     * @param repayYInYAssets The amount of Y to be repaid by the liquidator.
     * @param liquidationType The type of liquidation to be performed: HARD, SOFT, LEVERAGE
     */
    function liquidate(
        address borrower,
        address to,
        uint256 depositLToBeTransferredInLAssets,
        uint256 depositXToBeTransferredInXAssets,
        uint256 depositYToBeTransferredInYAssets,
        uint256 repayLXInXAssets,
        uint256 repayLYInYAssets,
        uint256 repayXInXAssets,
        uint256 repayYInYAssets,
        uint256 liquidationType
    ) external lock {
        accrueSaturationPenaltiesAndInterest(borrower);

        // get position of borrower
        (Validation.InputParams memory inputParams, bool hasBorrow) = getInputParams(borrower, false);
        if (hasBorrow) {
            if (liquidationType == Liquidation.HARD) {
                liquidateHard(
                    borrower,
                    to,
                    inputParams,
                    Liquidation.HardLiquidationParams({
                        depositLToBeTransferredInLAssets: depositLToBeTransferredInLAssets,
                        depositXToBeTransferredInXAssets: depositXToBeTransferredInXAssets,
                        depositYToBeTransferredInYAssets: depositYToBeTransferredInYAssets,
                        repayLXInXAssets: repayLXInXAssets,
                        repayLYInYAssets: repayLYInYAssets,
                        repayXInXAssets: repayXInXAssets,
                        repayYInYAssets: repayYInYAssets
                    })
                );
            } else if (liquidationType == Liquidation.SOFT) {
                liquidateSoft(
                    inputParams,
                    borrower,
                    to,
                    depositLToBeTransferredInLAssets,
                    depositXToBeTransferredInXAssets,
                    depositYToBeTransferredInYAssets
                );
            } else if (liquidationType == Liquidation.LEVERAGE) {
                liquidateLeverage(inputParams, borrower, to, 0 < depositLToBeTransferredInLAssets, 0 < repayLXInXAssets);
            } // noop if type > 2

            emit Liquidate(
                borrower,
                to,
                depositLToBeTransferredInLAssets,
                depositXToBeTransferredInXAssets,
                depositYToBeTransferredInYAssets,
                repayLXInXAssets,
                repayLYInYAssets,
                repayXInXAssets,
                repayYInYAssets,
                liquidationType
            );
        }
    }

    /**
     * @notice LTV based liquidation. The LTV dictates the max premium that can be had by the liquidator.
     * @param borrower The account being liquidated
     * @param to The account to send the liquidated deposit to
     * @param inputParams The input parameters for the liquidation, including reserves and price limits.
     * @param hardLiquidationParams The parameters for the hard liquidation, including deposits and repayments.
     */
    function liquidateHard(
        address borrower,
        address to,
        Validation.InputParams memory inputParams,
        Liquidation.HardLiquidationParams memory hardLiquidationParams
    ) private {
        // slither-disable-next-line uninitialized-local
        uint256 actualRepaidLiquidityAssets;

        // repay if hard liq requested
        if (0 < hardLiquidationParams.repayXInXAssets || 0 < hardLiquidationParams.repayYInYAssets) {
            repayCallback(hardLiquidationParams.repayXInXAssets, hardLiquidationParams.repayYInYAssets);
            (uint256 actualRepaidXInXAssets, uint256 actualRepaidYInYAssets) = _repay(borrower);

            // check that at least promised amount was repaid
            verifyRepay(
                actualRepaidXInXAssets,
                hardLiquidationParams.repayXInXAssets,
                actualRepaidYInYAssets,
                hardLiquidationParams.repayYInYAssets
            );
        }
        // || forwards to both needed to be non-zero in _repayLiquidity
        if (0 < hardLiquidationParams.repayLXInXAssets || 0 < hardLiquidationParams.repayLYInYAssets) {
            repayCallback(hardLiquidationParams.repayLXInXAssets, hardLiquidationParams.repayLYInYAssets);
            (uint256 actualRepaidLXInXAssets, uint256 actualRepaidLYInYAssets, uint256 _actualRepaidLiquidityAssets) =
                _repayLiquidity(borrower);

            // check that at least promised amount was repaid
            verifyRepay(
                actualRepaidLXInXAssets,
                hardLiquidationParams.repayLXInXAssets,
                actualRepaidLYInYAssets,
                hardLiquidationParams.repayLYInYAssets
            );

            actualRepaidLiquidityAssets = _actualRepaidLiquidityAssets;
        }

        // Reverts if the `maxPremium` < `premium`
        bool badDebt = saturationAndGeometricTWAPState.liquidationCheckHardPremiums(
            inputParams, borrower, hardLiquidationParams, actualRepaidLiquidityAssets
        );

        if (badDebt) {
            if (actualRepaidLiquidityAssets > 0) {
                burnBadDebt(borrower, BORROW_L, 0);
            }
            if (0 < hardLiquidationParams.repayXInXAssets || 0 < hardLiquidationParams.repayYInYAssets) {
                (uint256 _reserveXAssets, uint256 _reserveYAssets,) = getReserves();
                burnBadDebt(borrower, BORROW_X, _reserveXAssets);
                burnBadDebt(borrower, BORROW_Y, _reserveYAssets);
            }

            // Distribute any leftover collateral to the reserves.
            _sync();

            liquidationTransferAll(
                borrower,
                to,
                inputParams.userAssets[DEPOSIT_L],
                inputParams.userAssets[DEPOSIT_X],
                inputParams.userAssets[DEPOSIT_Y]
            );
        } else {
            // transfer deposit tokens ownership to msg.sender == liquidator
            liquidationTransferAll(
                borrower,
                to,
                hardLiquidationParams.depositLToBeTransferredInLAssets,
                hardLiquidationParams.depositXToBeTransferredInXAssets,
                hardLiquidationParams.depositYToBeTransferredInYAssets
            );
        }
    }

    function repayCallback(uint256 repayXAssets, uint256 repayYAssets) private {
        ICallback(msg.sender).ammalgamLiquidateCallV1(repayXAssets, repayYAssets);
    }

    function verifyRepay(uint256 actualX, uint256 expectedX, uint256 actualY, uint256 expectedY) private pure {
        if (actualX < expectedX || actualY < expectedY) {
            revert Liquidation.NotEnoughRepaidForLiquidation();
        }
    }

    /**
     * @notice Liquidation based on change of saturation because of time.
     * @param borrower The account being liquidated.
     * @param to The account to send the liquidated deposit to
     * @param depositLToBeTransferredInLAssets The amount of L to be transferred to the liquidator.
     * @param depositXToBeTransferredInXAssets The amount of X to be transferred to the liquidator.
     * @param depositYToBeTransferredInYAssets The amount of Y to be transferred to the liquidator.
     */
    function liquidateSoft(
        Validation.InputParams memory inputParams,
        address borrower,
        address to,
        uint256 depositLToBeTransferredInLAssets,
        uint256 depositXToBeTransferredInXAssets,
        uint256 depositYToBeTransferredInYAssets
    ) private {
        Liquidation.checkSoftPremiums(
            saturationAndGeometricTWAPState,
            inputParams,
            borrower,
            depositLToBeTransferredInLAssets,
            depositXToBeTransferredInXAssets,
            depositYToBeTransferredInYAssets
        );

        // transfer deposit tokens ownership to msg.sender == liquidator
        liquidationTransferAll(
            borrower,
            to,
            depositLToBeTransferredInLAssets,
            depositXToBeTransferredInXAssets,
            depositYToBeTransferredInYAssets
        );
    }

    /**
     * @notice Liquidation based on leverage.
     * @param borrower The account being liquidated.
     * @param to The account to send the liquidated deposit to
     * @param depositL Flag indicating whether the deposit transferred to the liquidator is L xor X+Y.
     * @param repayL Flag indicating whether the repay by the liquidator is L xor X+Y.
     */
    function liquidateLeverage(
        Validation.InputParams memory inputParams,
        address borrower,
        address to,
        bool depositL,
        bool repayL
    ) private {
        // calc amount to be closed (from both deposit and borrow) and premium to be paid
        Liquidation.LeveragedLiquidationParams memory leveragedLiquidationParams =
            Liquidation.liquidateLeverageCalcDeltaAndPremium(inputParams, depositL, repayL);

        // repay if hard liq requested
        if (repayL) {
            (,, uint256 repayLiquidityAssets) = _repayLiquidity(borrower);
            if (repayLiquidityAssets < leveragedLiquidationParams.closeInLAssets) {
                revert Liquidation.NotEnoughRepaidForLiquidation();
            }
            if (leveragedLiquidationParams.badDebt) burnBadDebt(borrower, BORROW_L, 0);
        } else {
            (uint256 repayXInXAssets, uint256 repayYInYAssets) = _repay(borrower);
            if (
                repayXInXAssets < leveragedLiquidationParams.closeInXAssets
                    || repayYInYAssets < leveragedLiquidationParams.closeInYAssets
            ) {
                revert Liquidation.NotEnoughRepaidForLiquidation();
            }
            if (leveragedLiquidationParams.badDebt) {
                burnBadDebt(borrower, BORROW_X, inputParams.reservesXAssets);
                burnBadDebt(borrower, BORROW_Y, inputParams.reservesYAssets);
            }
        }

        if (depositL) {
            liquidationTransfer(
                borrower,
                to,
                leveragedLiquidationParams.closeInLAssets + leveragedLiquidationParams.premiumInLAssets,
                DEPOSIT_L,
                leveragedLiquidationParams.badDebt
            );
        } else {
            liquidationTransfer(
                borrower,
                to,
                leveragedLiquidationParams.closeInXAssets + leveragedLiquidationParams.premiumLInXAssets,
                DEPOSIT_X,
                leveragedLiquidationParams.badDebt
            );
            liquidationTransfer(
                borrower,
                to,
                leveragedLiquidationParams.closeInYAssets + leveragedLiquidationParams.premiumLInYAssets,
                DEPOSIT_Y,
                leveragedLiquidationParams.badDebt
            );
        }
        if (leveragedLiquidationParams.badDebt) {
            // distribute any leftover collateral to the reserves.
            _sync();
        }
    }

    function liquidationTransferAll(
        address borrower,
        address to,
        uint256 depositLToBeTransferredInLAssets,
        uint256 depositXToBeTransferredInXAssets,
        uint256 depositYToBeTransferredInYAssets
    ) private {
        liquidationTransfer(borrower, to, depositLToBeTransferredInLAssets, DEPOSIT_L, false);
        liquidationTransfer(borrower, to, depositXToBeTransferredInXAssets, DEPOSIT_X, false);
        liquidationTransfer(borrower, to, depositYToBeTransferredInYAssets, DEPOSIT_Y, false);
    }

    /**
     * Transfer deposit to the liquidator from the borrower (==from).
     * @param from The account the deposit is being transferred from.
     * @param to The account the deposit is being transferred to.
     * @param depositToTransferInAssets The amount being transferred to the liquidator.
     * @param tokenType The deposit token type being transferred.
     */
    function liquidationTransfer(
        address from,
        address to,
        uint256 depositToTransferInAssets,
        uint256 tokenType,
        bool isBadDebt
    ) private {
        // slither-disable-next-line incorrect-equality
        if (depositToTransferInAssets == 0) return;
        // this is fairly complex specifically for when L bad debt is burned
        // and the the transfer amount is also L, but the ratio of shares to
        // assets is different than before those bad debts shares were burned.
        IAmmalgamERC20 token = tokens(tokenType);
        uint256 remainingShares = token.balanceOf(from);
        uint256 _totalShares = totalShares(tokenType);
        uint256 _totalAssets = rawTotalAssets(tokenType);
        uint256 expectedShares = Convert.toShares(depositToTransferInAssets, _totalAssets, _totalShares, ROUNDING_UP);
        token.ownerTransfer(from, to, Math.min(remainingShares, expectedShares));

        if (isBadDebt && remainingShares > expectedShares) {
            uint256 burnShares = remainingShares - expectedShares;

            tokens(tokenType).ownerTransfer(from, address(this), burnShares);
            burnId(
                tokenType, to, from, Convert.toAssets(burnShares, _totalAssets, _totalShares, !ROUNDING_UP), burnShares
            );
        }
    }

    // force balances to match reserves
    // slither-disable-start reentrancy-no-eth,reentrancy-benign
    function skim(
        address to
    ) external lock {
        (,, uint256 balanceXAssets, uint256 balanceYAssets) = accrueSaturationPenaltiesAndInterest(to);
        transferAssets(to, balanceXAssets, balanceYAssets);
    }

    // slither-disable-end reentrancy-no-eth,reentrancy-benign
    // force reserves to match balances
    function sync() external lock {
        _sync();
    }

    // internal to be called withing liquidation without hitting the lock.
    function _sync() private {
        (uint256 _reserveXAssets, uint256 _reserveYAssets, uint256 extraXAssets, uint256 extraYAssets) =
            accrueSaturationPenaltiesAndInterest(ZERO_ADDRESS);
        updateReservesAndReference(
            _reserveXAssets, _reserveYAssets, _reserveXAssets + extraXAssets, _reserveYAssets + extraYAssets
        );
    }

    /**
     * @dev When assets are depleted, a user can deposit the depleted asset and earn additional deposit credit for moving
     * the swap curve from the adjusted amount due to assets being depleted to the original curve.
     */
    function depletionReserveAdjustmentWhenAssetIsAdded(
        uint256 amountAssets,
        uint256 reserveAssets,
        uint256 _missingAssets
    ) private pure returns (uint256 adjustReserves_) {
        if (reserveAssets * BUFFER < _missingAssets * MAG2) {
            if (
                amountAssets > _missingAssets
                    || (reserveAssets - amountAssets) * BUFFER >= (_missingAssets - amountAssets) * MAG2
            ) {
                adjustReserves_ = reserveAssets - _missingAssets;
            } else {
                adjustReserves_ = amountAssets;
            }
        }
    }

    function accrueSaturationPenaltiesAndInterest(
        address affectedAccount
    )
        private
        returns (uint256 _reserveXAssets, uint256 _reserveYAssets, uint256 balanceXAssets, uint256 balanceYAssets)
    {
        uint32 _lastTimestamp;
        (_reserveXAssets, _reserveYAssets, _lastTimestamp) = getReserves();

        // time management
        uint32 currentTimestamp;
        uint32 deltaUpdateTimestamp;
        uint32 deltaLendingTimestamp;
        uint32 deltaPenaltyTimestamp;
        unchecked {
            currentTimestamp = GeometricTWAP.getCurrentTimestamp();
            deltaUpdateTimestamp = currentTimestamp - _lastTimestamp;
            deltaLendingTimestamp = currentTimestamp - lastLendingTimestamp;
            deltaPenaltyTimestamp = currentTimestamp - lastPenaltyTimestamp;
        }

        // penalties

        mintPenalties(affectedAccount, deltaPenaltyTimestamp);

        // observe

        updateObservation(_reserveXAssets, _reserveYAssets, currentTimestamp, deltaUpdateTimestamp);

        (balanceXAssets, balanceYAssets) = getNetBalances(_reserveXAssets, _reserveYAssets);

        // slither-disable-next-line incorrect-equality
        if (deltaLendingTimestamp > 0) {
            (_reserveXAssets, _reserveYAssets) = updateTokenController(
                currentTimestamp, deltaUpdateTimestamp, deltaLendingTimestamp, _reserveXAssets, _reserveYAssets
            );
        }
    }

    // slither-disable-next-line naming-convention
    function updateObservation(uint256 _reserveXAssets, uint256 _reserveYAssets) private {
        uint32 currentTimestamp = GeometricTWAP.getCurrentTimestamp();
        updateObservation(_reserveXAssets, _reserveYAssets, currentTimestamp, currentTimestamp - lastUpdateTimestamp);
    }

    // slither-disable-next-line naming-convention
    function updateObservation(
        uint256 _reserveXAssets,
        uint256 _reserveYAssets,
        uint32 currentTimestamp,
        uint32 deltaUpdateTimestamp
    ) private {
        if (0 < deltaUpdateTimestamp && 0 < _reserveXAssets && 0 < _reserveYAssets) {
            int16 newTick = TickMath.getTickAtPrice(Convert.mulDiv(_reserveXAssets, Q128, _reserveYAssets, false));
            // Call to trusted contract holding some pair state.
            // slither-disable-next-line reentrancy-benign,reentrancy-no-eth
            if (saturationAndGeometricTWAPState.recordObservation(newTick, deltaUpdateTimestamp)) {
                lastUpdateTimestamp = currentTimestamp;
            }

            updateReferenceReserve(newTick);
        }
    }

    function validateOnUpdate(address validate, address update, bool isBorrow) external {
        uint32 deltaPenaltyTimestamp;
        unchecked {
            uint32 currentTimestamp = GeometricTWAP.getCurrentTimestamp();
            deltaPenaltyTimestamp = currentTimestamp - lastPenaltyTimestamp;
        }
        mintPenalties(validate, deltaPenaltyTimestamp);
        validateSolvency(validate, isBorrow);

        // we do not want to update the pair itself.
        if (address(this) != update) {
            (Validation.InputParams memory inputParams, bool hasBorrow) = getInputParams(update, true);
            if (hasBorrow || isBorrow) {
                saturationAndGeometricTWAPState.update(inputParams, update);
            }
        }
    }

    function validateSolvency(address validate, bool isBorrow) private {
        // we do not want to validate the pair itself, only possible if `validateOnUpdate` is
        // called.
        if (address(this) != validate) {
            (Validation.InputParams memory inputParams, bool hasBorrow) = getInputParams(validate, true);
            if (hasBorrow || isBorrow) {
                Validation.validateSolvency(inputParams);
                saturationAndGeometricTWAPState.update(inputParams, validate);
            }
        }
    }

    function getInputParamsAndUpdateSaturation(address toUpdate, bool alwaysUpdate) private {
        (Validation.InputParams memory inputParams, bool hasBorrow) = getInputParams(toUpdate, true);
        if (alwaysUpdate || hasBorrow) {
            saturationAndGeometricTWAPState.update(inputParams, toUpdate);
        }
    }

    function getInputParams(
        address toCheck,
        bool includeLongTermPrice
    ) internal view returns (Validation.InputParams memory inputParams, bool hasBorrow) {
        uint128[6] memory currentAssets = totalAssets();
        uint256[6] memory userAssets = getAssets(currentAssets, toCheck);

        // slither-disable-next-line incorrect-equality
        hasBorrow = userAssets[BORROW_L] != 0 || userAssets[BORROW_X] != 0 || userAssets[BORROW_Y] != 0;
        if (!hasBorrow) {
            return (inputParams, hasBorrow);
        }

        (uint256 _reserveXAssets, uint256 _reserveYAssets,) = getReserves();

        (int16 minTick, int16 maxTick) = saturationAndGeometricTWAPState.getTickRange(
            address(this),
            TickMath.getTickAtPrice(Convert.mulDiv(_reserveXAssets, Q128, _reserveYAssets, false)),
            includeLongTermPrice
        );

        return (
            Validation.getInputParams(
                currentAssets, userAssets, _reserveXAssets, _reserveYAssets, externalLiquidity, minTick, maxTick
            ),
            hasBorrow
        );
    }

    function transferAssets(address to, uint256 amountXAssets, uint256 amountYAssets) private {
        (IERC20 _tokenX, IERC20 _tokenY) = underlyingTokens();
        if (to == address(_tokenX) || to == address(_tokenY)) {
            revert InvalidToAddress();
        }
        if (amountXAssets > 0) SafeERC20.safeTransfer(_tokenX, to, amountXAssets);
        if (amountYAssets > 0) SafeERC20.safeTransfer(_tokenY, to, amountYAssets);
    }

    function calcMinLiquidityConsideringDepletion(
        uint256 amountXAssets,
        uint256 amountYAssets,
        uint256 _reserveXAssets,
        uint256 _reserveYAssets,
        uint256 activeLiquidityAssets,
        uint256 depositLiquidityAssets,
        uint256 depositLiquidityShares,
        bool isRoundingUp
    ) private view returns (uint256 liquidityAssets, uint256 liquidityShares) {
        (uint256 _missingXAssets, uint256 _missingYAssets) = missingAssets();
        (uint256 liquidityAssetsFromX, uint256 liquiditySharesFromX) = Convert.calcLiquidityConsideringDepletion(
            amountXAssets,
            _reserveXAssets,
            _missingXAssets,
            activeLiquidityAssets,
            depositLiquidityAssets,
            depositLiquidityShares,
            isRoundingUp
        );
        (uint256 liquidityAssetsFromY, uint256 liquiditySharesFromY) = Convert.calcLiquidityConsideringDepletion(
            amountYAssets,
            _reserveYAssets,
            _missingYAssets,
            activeLiquidityAssets,
            depositLiquidityAssets,
            depositLiquidityShares,
            isRoundingUp
        );
        (liquidityAssets, liquidityShares) = liquiditySharesFromX < liquiditySharesFromY
            ? (liquidityAssetsFromX, liquiditySharesFromX)
            : (liquidityAssetsFromY, liquiditySharesFromY);
    }
}
