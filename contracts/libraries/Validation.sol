/// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {
    DEPOSIT_L,
    DEPOSIT_X,
    DEPOSIT_Y,
    BORROW_L,
    BORROW_X,
    BORROW_Y
} from 'contracts/interfaces/tokens/ITokenController.sol';

import {Q72, Q128, LTVMAX_IN_MAG2, ALLOWED_LIQUIDITY_LEVERAGE, MAG2} from 'contracts/libraries/constants.sol';
import {Convert} from 'contracts/libraries/Convert.sol';
import {TickMath} from 'contracts/libraries/TickMath.sol';
import {QuadraticSwapFees} from 'contracts/libraries/QuadraticSwapFees.sol';

library Validation {
    uint256 private constant MAX_BORROW_PERCENTAGE = 90;
    uint256 private constant ONE_HUNDRED_TIMES_N = 2000;
    uint256 private constant TWO_Q64 = 0x20000000000000000;
    uint256 private constant FIVE_Q64 = 0x50000000000000000;
    uint256 private constant NINE_Q64 = 0x90000000000000000;
    uint256 private constant FIFTY_Q64 = 0x320000000000000000;
    uint256 private constant TWO_TIMES_N_Q64 = 0x280000000000000000;
    uint256 private constant TWO_Q128 = 0x200000000000000000000000000000000;
    uint256 private constant TWO_THOUSAND_FIVE_HUNDRED_Q128 = 0x9c400000000000000000000000000000000;

    struct InputParams {
        uint256[6] userAssets;
        uint256 sqrtPriceMinInQ72;
        uint256 sqrtPriceMaxInQ72;
        uint256 activeLiquidityScalerInQ72;
        uint256 activeLiquidityAssets;
        uint256 reservesXAssets;
        uint256 reservesYAssets;
    }

    struct CheckLtvParams {
        uint256 netDepositedXinLAssets;
        uint256 netDepositedYinLAssets;
        uint256 netBorrowedXinLAssets;
        uint256 netBorrowedYinLAssets;
        uint256 depositedLAssets;
    }

    struct VerifyMaxBorrowXYParams {
        uint256 amount;
        uint256 depositedAssets;
        uint256 borrowedAssets;
        uint256 reserve;
        uint256 totalLiquidityAssets;
        uint256 borrowedLiquidityAssets;
    }

    struct VerifyMaxBorrowLParams {
        uint256[6] totalAssets;
        uint256 newBorrowedLAssets;
        uint256 reserveXAssets;
        uint256 reserveYAssets;
    }

    error InsufficientLiquidity();
    error AmmalgamCannotBorrowAgainstSameCollateral();
    error AmmalgamMaxBorrowReached();
    error AmmalgamDepositIsNotStrictlyBigger();
    error AmmalgamLTV();
    error AmmalgamMaxSlippage();
    error AmmalgamTooMuchLeverage();
    error AmmalgamTransferAmtExceedsBalance();

    function getInputParams(
        uint128[6] memory currentAssets,
        uint256[6] memory userAssets,
        uint256 reserveXAssets,
        uint256 reserveYAssets,
        uint256 externalLiquidity,
        int16 minTick,
        int16 maxTick
    ) internal pure returns (Validation.InputParams memory inputParams) {
        uint256 activeLiquidityAssets = currentAssets[DEPOSIT_L] - currentAssets[BORROW_L];
        return Validation.InputParams({
            userAssets: userAssets,
            sqrtPriceMinInQ72: TickMath.getSqrtPriceAtTick(minTick),
            sqrtPriceMaxInQ72: TickMath.getSqrtPriceAtTick(maxTick),
            activeLiquidityScalerInQ72: Convert.mulDiv(
                Math.sqrt(reserveXAssets * reserveYAssets), Q72, activeLiquidityAssets, false
            ),
            activeLiquidityAssets: activeLiquidityAssets + externalLiquidity,
            reservesXAssets: reserveXAssets,
            reservesYAssets: reserveYAssets
        });
    }

    function getCheckLtvParams(
        InputParams memory inputParams
    ) internal pure returns (CheckLtvParams memory checkLtvParams) {
        checkLtvParams.depositedLAssets = inputParams.userAssets[DEPOSIT_L];
        (checkLtvParams.netBorrowedXinLAssets, checkLtvParams.netBorrowedYinLAssets) = getBorrowedInL(inputParams);
        (checkLtvParams.netDepositedXinLAssets, checkLtvParams.netDepositedYinLAssets) = getDepositsInL(inputParams);
    }

    function validateBalanceAndLiqAndNotSameAssetsSuppliedAndBorrowed(
        InputParams memory inputParams
    ) internal pure {
        // testBorrowWithoutOtherMintersFails
        if (inputParams.activeLiquidityAssets <= inputParams.userAssets[DEPOSIT_L]) revert InsufficientLiquidity();

        verifyNotSameAssetsSuppliedAndBorrowed(
            inputParams.userAssets[DEPOSIT_X],
            inputParams.userAssets[DEPOSIT_Y],
            inputParams.userAssets[BORROW_X],
            inputParams.userAssets[BORROW_Y]
        );
    }

    function validateLTVAndLeverage(
        CheckLtvParams memory checkLtvParams,
        uint256 activeLiquidityAssets
    ) internal pure {
        checkLtv(checkLtvParams, activeLiquidityAssets);
        checkLeverage(checkLtvParams);
    }

    /**
     * Added TokenType and uint256s for amount, balance from, and balance to
     * to enable to pass a value for the current balance of a token to avoid one
     * check of a balance that can be done from within a token.
     */
    function validateSolvency(
        InputParams memory inputParams
    ) internal pure {
        validateBalanceAndLiqAndNotSameAssetsSuppliedAndBorrowed(inputParams);
        CheckLtvParams memory checkLtvParams = getCheckLtvParams(inputParams);
        validateLTVAndLeverage(checkLtvParams, inputParams.activeLiquidityAssets);
    }

    function verifyNotSameAssetsSuppliedAndBorrowed(
        uint256 depositedXAssets,
        uint256 depositedYAssets,
        uint256 borrowedXAssets,
        uint256 borrowedYAssets
    ) internal pure {
        if ((borrowedXAssets > 0 && depositedXAssets > 0) || (borrowedYAssets > 0 && depositedYAssets > 0)) {
            revert AmmalgamCannotBorrowAgainstSameCollateral();
        }
    }

    function verifyMaxBorrowXY(
        VerifyMaxBorrowXYParams memory params
    ) internal pure {
        unchecked {
            uint256 scaledBorrowedLiquidityAssets = Convert.mulDiv(
                params.reserve,
                params.borrowedLiquidityAssets,
                params.totalLiquidityAssets - params.borrowedLiquidityAssets,
                false
            );

            if (
                Convert.mulDiv(params.reserve + scaledBorrowedLiquidityAssets, MAX_BORROW_PERCENTAGE, MAG2, false)
                    + params.depositedAssets < params.amount + scaledBorrowedLiquidityAssets + params.borrowedAssets
            ) {
                revert AmmalgamMaxBorrowReached();
            }
        }
    }

    function verifyMaxBorrowL(
        VerifyMaxBorrowLParams memory params
    ) internal pure {
        unchecked {
            uint256 totalBorrowedLAssets = params.newBorrowedLAssets + params.totalAssets[BORROW_L];
            uint256 newActiveLiquidityAssets = params.totalAssets[DEPOSIT_L] - params.totalAssets[BORROW_L];

            // slither-disable-next-line similar-names
            bool moreBorrowedXAssets = params.totalAssets[BORROW_X] > params.totalAssets[DEPOSIT_X];
            bool moreBorrowedYAssets = params.totalAssets[BORROW_Y] > params.totalAssets[DEPOSIT_Y];

            if (moreBorrowedXAssets && moreBorrowedYAssets) {
                totalBorrowedLAssets += Math.max(
                    Convert.mulDiv(params.totalAssets[BORROW_X], newActiveLiquidityAssets, params.reserveXAssets, false),
                    Convert.mulDiv(params.totalAssets[BORROW_Y], newActiveLiquidityAssets, params.reserveYAssets, false)
                );
            } else {
                if (moreBorrowedXAssets) {
                    totalBorrowedLAssets += Convert.mulDiv(
                        params.totalAssets[BORROW_X], newActiveLiquidityAssets, params.reserveXAssets, false
                    );
                }
                if (moreBorrowedYAssets) {
                    totalBorrowedLAssets += Convert.mulDiv(
                        params.totalAssets[BORROW_Y], newActiveLiquidityAssets, params.reserveYAssets, false
                    );
                }
            }

            if (params.totalAssets[DEPOSIT_L] * MAX_BORROW_PERCENTAGE < totalBorrowedLAssets * MAG2) {
                revert AmmalgamMaxBorrowReached();
            }
        }
    }

    function getDepositsInL(
        InputParams memory inputParams
    ) private pure returns (uint256 netDepositedXinLAssets, uint256 netDepositedYinLAssets) {
        netDepositedXinLAssets = inputParams.userAssets[DEPOSIT_L];
        netDepositedYinLAssets = inputParams.userAssets[DEPOSIT_L];

        if (0 < inputParams.userAssets[DEPOSIT_X]) {
            netDepositedXinLAssets += Validation.convertXToL(
                inputParams.userAssets[DEPOSIT_X],
                inputParams.sqrtPriceMaxInQ72, // max tick is applied on X for deposit
                inputParams.activeLiquidityScalerInQ72,
                false
            );
        }
        if (0 < inputParams.userAssets[DEPOSIT_Y]) {
            netDepositedYinLAssets += Validation.convertYToL(
                inputParams.userAssets[DEPOSIT_Y],
                inputParams.sqrtPriceMinInQ72, // min tick is applied on Y for deposit
                inputParams.activeLiquidityScalerInQ72,
                false
            );
        }
    }

    function getBorrowedInL(
        InputParams memory inputParams
    ) private pure returns (uint256 netBorrowedXinLAssets, uint256 netBorrowedYinLAssets) {
        netBorrowedXinLAssets = inputParams.userAssets[BORROW_L];
        netBorrowedYinLAssets = inputParams.userAssets[BORROW_L];

        if (inputParams.userAssets[BORROW_X] > 0) {
            netBorrowedXinLAssets += Validation.convertXToL(
                inputParams.userAssets[BORROW_X],
                inputParams.sqrtPriceMinInQ72, // min tick is applied on X for borrow
                inputParams.activeLiquidityScalerInQ72,
                true
            );
        }
        if (inputParams.userAssets[BORROW_Y] > 0) {
            netBorrowedYinLAssets += Validation.convertYToL(
                inputParams.userAssets[BORROW_Y],
                inputParams.sqrtPriceMaxInQ72, // max tick is applied on Y for borrow
                inputParams.activeLiquidityScalerInQ72,
                true
            );
        }
    }

    /**
     * The original math:
     *         L * activeLiquidityScalerInQ72 = x / (2 * sqrt(p))
     *
     *     previous equation:
     *         amountLAssets = mulDiv(amount, Q72, 2 * sqrtPriceInXInQ72, rounding);
     *
     *     adding activeLiquidityScalerInQ72:
     *         amountLAssets = (amount * Q72 / (2 * sqrtPriceInXInQ72)) / (activeLiquidityScalerInQ72 / Q72);
     *
     *     simplify to:
     *         (amount * Q72 * Q72) / (2 * sqrtPriceInXInQ72 * activeLiquidityScalerInQ72)
     *
     *     final equation:
     *         amountLAssets = mulDiv(mulDiv(amount, Q72, sqrtPriceInXInQ72, rounding), Q72, 2 * activeLiquidityScalerInQ72, rounding);
     *
     *         or more simplified (failed for some tests)
     *         amountLAssets = mulDiv(amount, Q72 * Q72, 2 * sqrtPriceInQ72 * activeLiquidityScalerInQ72);
     */
    function convertXToL(
        uint256 amountInXAssets,
        uint256 sqrtPriceInXInQ72,
        uint256 activeLiquidityScalerInQ72,
        bool roundUp
    ) internal pure returns (uint256 amountLAssets) {
        if (amountInXAssets == 0) return 0;
        amountLAssets = Convert.mulDiv(
            Convert.mulDiv(amountInXAssets, Q72, sqrtPriceInXInQ72, roundUp), Q72, activeLiquidityScalerInQ72, roundUp
        );
    }

    function convertLToX(
        uint256 amount,
        uint256 sqrtPriceQ72,
        uint256 activeLiquidityScalerInQ72,
        bool roundUp
    ) internal pure returns (uint256 amountXAssets) {
        if (amount == 0) return 0;
        amountXAssets =
            Convert.mulDiv(Convert.mulDiv(activeLiquidityScalerInQ72, amount, Q72, roundUp), sqrtPriceQ72, Q72, roundUp);
    }

    /**
     * The simplified math: L = y * sqrt(p) / 2
     *
     *     mulDiv(amount, sqrtPriceInXInQ72, 2 * Q72, rounding);
     *
     *     amountLAssets = amount * sqrtPriceInXInQ72Scaled / (2 * Q72)
     *
     *     sqrtPriceInXInQ72Scaled = sqrtPriceInXInQ72 / activeLiquidityScalerInQ72 / Q72;
     *
     *     simplify to:
     *     amount * sqrtPriceInXInQ72 / activeLiquidityScalerInQ72 / Q72 / (2 * Q72)
     *     simplify to:
     *     (amount * sqrtPriceInXInQ72 * Q56) / (activeLiquidityScalerInQ72 * 2)
     *
     *     final equation:
     *     amountLAssets = mulDiv(amount, sqrtPriceInXInQ72 * Q56, 2 * activeLiquidityScalerInQ72, rounding);
     */
    function convertYToL(
        uint256 amountInYAssets,
        uint256 sqrtPriceInXInQ72,
        uint256 activeLiquidityScalerInQ72,
        bool roundUp // Floor xor Ceil
    ) internal pure returns (uint256 amountInLAssets) {
        if (amountInYAssets == 0) return 0;
        amountInLAssets = Convert.mulDiv(amountInYAssets, sqrtPriceInXInQ72, activeLiquidityScalerInQ72, roundUp);
    }

    function convertLToY(
        uint256 amount,
        uint256 sqrtPriceQ72,
        uint256 activeLiquidityScalerInQ72,
        bool roundUp
    ) internal pure returns (uint256 amountYAssets) {
        if (amount == 0) return 0;
        amountYAssets = Convert.mulDiv(activeLiquidityScalerInQ72, amount, sqrtPriceQ72, roundUp);
    }

    function calcDebtAndCollateral(
        CheckLtvParams memory checkLtvParams
    ) internal pure returns (uint256 debtLiquidityAssets, uint256 collateralLiquidityAssets, bool netDebtX) {
        bool xDepositIsStrictlyBigger = checkLtvParams.netDepositedXinLAssets > checkLtvParams.netBorrowedXinLAssets;
        bool yDepositIsStrictlyBigger = checkLtvParams.netDepositedYinLAssets > checkLtvParams.netBorrowedYinLAssets;

        if (!xDepositIsStrictlyBigger && !yDepositIsStrictlyBigger) {
            unchecked {
                debtLiquidityAssets = checkLtvParams.netBorrowedXinLAssets - checkLtvParams.netDepositedXinLAssets
                    + (checkLtvParams.netBorrowedYinLAssets - checkLtvParams.netDepositedYinLAssets);
            }
        } else if (!xDepositIsStrictlyBigger) {
            unchecked {
                debtLiquidityAssets = checkLtvParams.netBorrowedXinLAssets - checkLtvParams.netDepositedXinLAssets;
                collateralLiquidityAssets = checkLtvParams.netDepositedYinLAssets - checkLtvParams.netBorrowedYinLAssets;
            }
            netDebtX = true;
        } else if (!yDepositIsStrictlyBigger) {
            unchecked {
                debtLiquidityAssets = checkLtvParams.netBorrowedYinLAssets - checkLtvParams.netDepositedYinLAssets;
                collateralLiquidityAssets = checkLtvParams.netDepositedXinLAssets - checkLtvParams.netBorrowedXinLAssets;
            }
        }
    }

    function checkLtv(
        CheckLtvParams memory checkLtvParams,
        uint256 activeLiquidityAssets
    ) private pure returns (uint256 debtLiquidityAssets, uint256 collateralLiquidityAssets) {
        if (checkLtvParams.netBorrowedXinLAssets == 0 && checkLtvParams.netBorrowedYinLAssets == 0) return (0, 0);

        (debtLiquidityAssets, collateralLiquidityAssets,) = calcDebtAndCollateral(checkLtvParams);
        if (collateralLiquidityAssets == 0 && debtLiquidityAssets > 0) {
            revert AmmalgamDepositIsNotStrictlyBigger();
        }

        // Exclude current user liquidity as liquidator may sell collateral after liquidation in which case the
        // slippage would not included deposited L.
        // underflow has been checked at 'Ammalgam: Insufficient liquidity'.
        unchecked {
            debtLiquidityAssets =
                increaseForSlippage(debtLiquidityAssets, activeLiquidityAssets - checkLtvParams.depositedLAssets);

            if (collateralLiquidityAssets * LTVMAX_IN_MAG2 < debtLiquidityAssets * MAG2) revert AmmalgamLTV();
        }
    }

    /**
     * @notice Calculates the impact slippage of buying the debt in the dex using the currently
     * available liquidity $L = \sqrt{x \cdot y}$. Uses a few formulas to simplify to not need
     * reserves to calculate the required collateral to buy the debt.
     *
     * The reserves available in and out for swapping can be defined in terms of $L$, and price $p$
     *     ```math
     *     \begin{align*}
     *     reserveIn &= L \cdot \sqrt{p} \\
     *     reserveOut &= \frac{L}{ \sqrt{p} } \\
     *     \end{align*}
     *     ```
     *
     * The swap amount $in$ and $out$ can also be defined in terms of $L_{in}$ and
     * $L_{out}$
     *     ```math
     *     \begin{align*}
     *     in &= L_{in} \cdot 2 \cdot \sqrt{p} \\
     *     out &= \frac{  2 \cdot L_{out} }{ \sqrt{p} }
     *     \end{align*}
     *     ```
     *
     * Starting with our swap equation we solve for $in$
     *
     *     ```math
     *     \begin{align*}
     *     (in + reserveIn)(reserveOut - out) &= reserveOut \cdot reserveIn \\
     *     in &= \frac{reserveOut \cdot reserveIn} {reserveOut - out} - reserveIn \\
     *     in &= reserveIn \cdot \left(\frac{reserveOut } {reserveOut - out} - 1 \right) \\
     *     in &= reserveIn \cdot \frac{ reserveOut - (reserveOut - out) } { reserveOut - out } \\
     *     in &= \frac{ reserveIn \cdot out } { reserveOut - out } \\
     *     \end{align*}
     *     ```
     *
     * We now plug in liquidity values in place of $reserveIn$, $reserveOut$, $in$, and $out$.
     *     ```math
     *     \begin{align*}
     *     L_{in} \cdot 2 \cdot \sqrt{p}
     *       &=  \frac{ L \cdot \sqrt{p} \cdot \frac{  2 \cdot L_{out} }{ \sqrt{p} } }
     *        { \frac{L}{ \sqrt{p} } - \frac{ 2 \cdot L_{out} }{\sqrt{p} } } \\
     *
     *     L_{in}
     *       &= \frac{ L \cdot \sqrt{p} \cdot \frac{  2 \cdot L_{out} }{ \sqrt{p} } }
     *         { 2 \cdot \sqrt{p} \cdot  \left(\frac{L}{ \sqrt{p} } - \frac{ 2 \cdot L_{out} }{\sqrt{p} }\right)} \\
     *
     *     L_{in}
     *       &=  \frac { L \cdot  L_{out} }
     *         { (L - 2 \cdot L_{out}) } \\
     *     \end{align*}
     *     ```
     *
     * Using $L_{out}$ described in our method as `debtLiquidityAssets`, $L$ or `activeLiquidityAssets`,
     * and our fee, we use the above equation to solve for the amount of liquidity that
     * must come in to buy the debt.
     *
     * @param debtLiquidityAssets The amount of debt with units of L that will need to be purchased in case of liquidation.
     * @param activeLiquidityAssets The amount of liquidity in the pool available to swap against.
     */
    function increaseForSlippage(
        uint256 debtLiquidityAssets,
        uint256 activeLiquidityAssets
    ) internal pure returns (uint256) {
        if (debtLiquidityAssets >= activeLiquidityAssets) {
            revert AmmalgamMaxSlippage();
        }
        return Math.ceilDiv(activeLiquidityAssets * debtLiquidityAssets, (activeLiquidityAssets - debtLiquidityAssets));
    }

    function checkLeverage(
        CheckLtvParams memory checkLtvParams
    ) private pure {
        unchecked {
            uint256 totalNetDeposits = checkLtvParams.netDepositedXinLAssets + checkLtvParams.netDepositedYinLAssets;
            uint256 totalNetDebts = checkLtvParams.netBorrowedXinLAssets + checkLtvParams.netBorrowedYinLAssets;

            if (totalNetDebts > 0) {
                if (
                    totalNetDeposits < totalNetDebts
                        || (totalNetDeposits - totalNetDebts) * ALLOWED_LIQUIDITY_LEVERAGE < totalNetDeposits
                ) {
                    revert AmmalgamTooMuchLeverage();
                }
            }
        }
    }
}
