// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {
    BIPS,
    MAG1,
    ALLOWED_LIQUIDITY_LEVERAGE,
    ALLOWED_LIQUIDITY_LEVERAGE_MINUS_ONE
} from 'contracts/libraries/constants.sol';
import {Convert} from 'contracts/libraries/Convert.sol';
import {Saturation} from 'contracts/libraries/Saturation.sol';
import {Validation} from 'contracts/libraries/Validation.sol';
import {ISaturationAndGeometricTWAPState} from 'contracts/interfaces/ISaturationAndGeometricTWAPState.sol';
import {DEPOSIT_L, DEPOSIT_X, DEPOSIT_Y} from 'contracts/interfaces/tokens/ITokenController.sol';

library Liquidation {
    // constants

    uint256 internal constant START_NEGATIVE_PREMIUM_LTV_BIPS = 6000; // == 0.6
    uint256 private constant START_PREMIUM_LTV_BIPS = 7500; // == 0.75
    uint256 private constant NEGATIVE_PREMIUM_SLOPE_IN_BIPS = 66_667; // 20/3
    uint256 private constant NEGATIVE_PREMIUM_INTERCEPT_IN_BIPS = 40_000; // == -4 (subtracted since stored positively)
    uint256 private constant POSITIVE_PREMIUM_SLOPE_IN_BIPS = 7408; // == 20/27
    uint256 private constant POSITIVE_PREMIUM_INTERCEPT_IN_BIPS = 4444; // == 4/9
    uint256 private constant LEVERAGE_LIQUIDATION_BREAK_EVEN_FACTOR = 5;
    uint256 private constant MAX_PREMIUM_IN_BIPS = 11_111; // == 10 * BIPS / 9

    uint256 internal constant HARD = 0;
    uint256 internal constant SOFT = 1;
    uint256 internal constant LEVERAGE = 2;

    // structs

    struct LeveragedLiquidationParams {
        uint256 closeInLAssets;
        uint256 closeInXAssets;
        uint256 closeInYAssets;
        uint256 premiumInLAssets;
        uint256 premiumLInXAssets;
        uint256 premiumLInYAssets;
        bool badDebt;
    }

    struct HardLiquidationParams {
        uint256 depositLToBeTransferredInLAssets;
        uint256 depositXToBeTransferredInXAssets;
        uint256 depositYToBeTransferredInYAssets;
        uint256 repayLXInXAssets;
        uint256 repayLYInYAssets;
        uint256 repayXInXAssets;
        uint256 repayYInYAssets;
    }

    // errors

    error LiquidationPremiumTooHigh();
    error NotEnoughRepaidForLiquidation();
    error TooMuchDepositToTransferForLeverageLiquidation();

    function checkHardPremiums(
        uint256 repaidDebtInL,
        uint256 seizedCollateralValueInL,
        uint256 maxPremiumInBips
    ) internal pure returns (bool maxPremiumExceeded) {
        uint256 premiumInBips = calcHardPremiumInBips(repaidDebtInL, seizedCollateralValueInL);

        if (maxPremiumInBips < premiumInBips) revert LiquidationPremiumTooHigh();

        // Bad debt case by checking the premium is above the break even threshold
        if (premiumInBips > MAX_PREMIUM_IN_BIPS) maxPremiumExceeded = true;
    }

    function calculateNetDebtAndSeizedDeposits(
        Validation.InputParams memory inputParams,
        HardLiquidationParams memory hardLiquidationParams,
        uint256 actualRepaidLiquidityAssets
    ) internal pure returns (uint256 netDebtInLAssets, uint256 netCollateralInLAssets, bool netDebtX) {
        // Use userAssets to calculate premium on repay amount.
        uint256[6] memory oldUserAssets = inputParams.userAssets;
        inputParams.userAssets = [
            hardLiquidationParams.depositLToBeTransferredInLAssets,
            hardLiquidationParams.depositXToBeTransferredInXAssets,
            hardLiquidationParams.depositYToBeTransferredInYAssets,
            actualRepaidLiquidityAssets, // repayL
            hardLiquidationParams.repayXInXAssets,
            hardLiquidationParams.repayYInYAssets
        ];

        Validation.CheckLtvParams memory checkLtvParams = Validation.getCheckLtvParams(inputParams);
        (netDebtInLAssets, netCollateralInLAssets, netDebtX) = Validation.calcDebtAndCollateral(checkLtvParams);

        // Reset `userAssets` to borrower's `userAssets`
        inputParams.userAssets = oldUserAssets;
    }

    function checkSoftPremiums(
        ISaturationAndGeometricTWAPState saturationAndGeometricTWAPState,
        Validation.InputParams memory inputParams,
        address borrower,
        uint256 depositLToTransferInLAssets,
        uint256 depositXToTransferInXAssets,
        uint256 depositYToTransferInYAssets
    ) external view {
        if (
            calcSoftMaxPremiumInBips(saturationAndGeometricTWAPState, inputParams, borrower)
                < calcSoftPremiumBips(
                    inputParams, depositLToTransferInLAssets, depositXToTransferInXAssets, depositYToTransferInYAssets
                )
        ) revert LiquidationPremiumTooHigh();
    }

    /**
     * @notice Calculate the amount to be closed (from both deposit and borrow) and premium to be
     *         paid.
     * @param inputParams The params representing the position of the borrower.
     * @param depositL Flag indicating whether the liquidator is transferring depositL.
     * @param repayL Flag indicating whether the liquidator is repaying borrowL.
     * @return leveragedLiquidationParams a struct of type LeveragedLiquidationParams containing
     *         the amounts to be closed and the premium to be paid.
     */
    function liquidateLeverageCalcDeltaAndPremium(
        Validation.InputParams memory inputParams,
        bool depositL,
        bool repayL
    ) external pure returns (LeveragedLiquidationParams memory leveragedLiquidationParams) {
        {
            uint256 netDepositInLAssets;
            uint256 netBorrowInLAssets;
            {
                // overestimates borrow and underestimates deposit as we do in validation
                Validation.CheckLtvParams memory checkLtvParams = Validation.getCheckLtvParams(inputParams);
                // We average the two since both are in L assets.
                netDepositInLAssets =
                    (checkLtvParams.netDepositedXinLAssets + checkLtvParams.netDepositedYinLAssets) / 2;
                netBorrowInLAssets = (checkLtvParams.netBorrowedXinLAssets + checkLtvParams.netBorrowedYinLAssets) / 2;
            }
            if (
                // guarantee that premium > 0;
                ALLOWED_LIQUIDITY_LEVERAGE * netBorrowInLAssets
                    > ALLOWED_LIQUIDITY_LEVERAGE_MINUS_ONE * netDepositInLAssets
            ) {
                // Premium schedule https://www.desmos.com/calculator/ihte8xjcho
                leveragedLiquidationParams.premiumInLAssets = Convert.mulDiv(
                    LEVERAGE_LIQUIDATION_BREAK_EVEN_FACTOR,
                    ALLOWED_LIQUIDITY_LEVERAGE * netBorrowInLAssets
                        - ALLOWED_LIQUIDITY_LEVERAGE_MINUS_ONE * netDepositInLAssets,
                    ALLOWED_LIQUIDITY_LEVERAGE,
                    false
                );

                if (netDepositInLAssets < leveragedLiquidationParams.premiumInLAssets) {
                    // extreme, unlikely, case when the premium is greater than all deposits
                    leveragedLiquidationParams.premiumInLAssets = netDepositInLAssets;
                } else {
                    // start  close assets as the remaining deposits after premium.
                    leveragedLiquidationParams.closeInLAssets =
                        netDepositInLAssets - leveragedLiquidationParams.premiumInLAssets;
                }

                if (netBorrowInLAssets < leveragedLiquidationParams.closeInLAssets) {
                    // the position can be de leveraged to meet leverage requirements.
                    leveragedLiquidationParams.closeInLAssets -=
                        ALLOWED_LIQUIDITY_LEVERAGE * (leveragedLiquidationParams.closeInLAssets - netBorrowInLAssets);
                } else {
                    leveragedLiquidationParams.badDebt = true;
                }

                if (!depositL || !repayL) {
                    uint256 totalXAssets = Validation.convertLToX(
                        leveragedLiquidationParams.closeInLAssets + leveragedLiquidationParams.premiumInLAssets,
                        inputParams.sqrtPriceMinInQ72,
                        inputParams.activeLiquidityScalerInQ72,
                        false
                    );

                    leveragedLiquidationParams.premiumLInXAssets = Convert.mulDiv(
                        totalXAssets,
                        leveragedLiquidationParams.premiumInLAssets,
                        leveragedLiquidationParams.closeInLAssets + leveragedLiquidationParams.premiumInLAssets,
                        false
                    );

                    leveragedLiquidationParams.closeInXAssets =
                        totalXAssets - leveragedLiquidationParams.premiumLInXAssets;

                    uint256 totalYAssets = Validation.convertLToY(
                        leveragedLiquidationParams.closeInLAssets + leveragedLiquidationParams.premiumInLAssets,
                        inputParams.sqrtPriceMaxInQ72,
                        inputParams.activeLiquidityScalerInQ72,
                        false
                    );

                    leveragedLiquidationParams.premiumLInYAssets = Convert.mulDiv(
                        totalYAssets,
                        leveragedLiquidationParams.premiumInLAssets,
                        leveragedLiquidationParams.closeInLAssets + leveragedLiquidationParams.premiumInLAssets,
                        false
                    );
                    leveragedLiquidationParams.closeInYAssets =
                        totalYAssets - leveragedLiquidationParams.premiumLInYAssets;
                }
            }
        }
    }

    /**
     * @notice Calculate the maximum premium the liquidator may receive given the LTV of the borrower.
     * @dev We min the result to favor the borrower.
     * @param inputParams Params containing the prices to be used.
     * @return maxPremiumInBips The max premium allowed to be received by the liquidator.
     */
    function calcHardMaxPremiumInBips(
        Validation.InputParams memory inputParams
    ) internal pure returns (uint256 maxPremiumInBips) {
        // Calculate max premium before repay
        (uint256 netDebtInLAssets, uint256 netCollateralInLAssets) = calculateNetDebtAndCollateral(inputParams);

        // Exclude current user liquidity as liquidator may sell collateral after liquidation in which case the
        // slippage would not included deposited L.
        // underflow has been checked at 'Ammalgam: Insufficient liquidity'.
        unchecked {
            maxPremiumInBips = convertLtvToPremium(
                0 < netCollateralInLAssets ? Convert.mulDiv(netDebtInLAssets, BIPS, netCollateralInLAssets, false) : 0
            );
        }
    }

    /**
     * @notice Calculate the premium being afforded to the liquidator given the repay and depositToTransfer amounts.
     * @dev We use prices to maximize the `premiumInBips` to favor the borrower
     * @param repaidDebtInL The amount of debt being repaid in L assets.
     * @param seizedCollateralValueInL The value of the collateral being seized in L assets.
     * @return premiumInBips The premium being received by the liquidator.
     */
    function calcHardPremiumInBips(
        uint256 repaidDebtInL,
        uint256 seizedCollateralValueInL
    ) internal pure returns (uint256 premiumInBips) {
        // If nothing is being or can be liquidated, premium is infinite, we will revert
        if (repaidDebtInL == 0) {
            return type(uint256).max;
        }

        // Calculate premium in bips
        unchecked {
            premiumInBips = Convert.mulDiv(seizedCollateralValueInL, BIPS, repaidDebtInL, false);
        }
    }

    /**
     * @notice Calculate the maximum premium the liquidator should receive based on the LTV of the borrower.
     * maxPremiumInBips is linear in between the following points
     * ```math
     *   \begin{equation*}
     *   0 <= LTV < START_NEGATIVE_PREMIUM_LTV_BIPS => maxPremiumInBips = 0 \\
     *   START_NEGATIVE_PREMIUM_LTV_BIPS = LTV => maxPremiumInBips == 0 (negative premium) \\
     *   START_PREMIUM_LTV_BIPS = LTV => maxPremiumInBips == 1 (no premium) \\
     *   0.9 = LTV => maxPremiumInBips == 1/0.9 (full premium)
     *   \end{equation*}
     * ```
     * @dev internal for testing only
     * @param ltvBips LTV of the borrower.
     * @return maxPremiumInBips The maximum premium for the liquidator.
     */
    function convertLtvToPremium(
        uint256 ltvBips
    ) internal pure returns (uint256 maxPremiumInBips) {
        if (ltvBips > START_NEGATIVE_PREMIUM_LTV_BIPS) {
            if (ltvBips < START_PREMIUM_LTV_BIPS) {
                // negative premium <=> maxPremiumInBips < 1
                // linear function going thru (START_NEGATIVE_PREMIUM_LTV_BIPS, 0) and (START_PREMIUM_LTV_BIPS, 1)
                maxPremiumInBips = Convert.mulDiv(NEGATIVE_PREMIUM_SLOPE_IN_BIPS, ltvBips, BIPS, false)
                    - NEGATIVE_PREMIUM_INTERCEPT_IN_BIPS;
            } else {
                // positive premium <=> 1 <= maxPremiumInBips
                // linear function going thru (START_LIQUIDATION_PREMIUM_LTV, 1) and (0.9, 1/0.9)
                maxPremiumInBips = Convert.mulDiv(POSITIVE_PREMIUM_SLOPE_IN_BIPS, ltvBips, BIPS, false)
                    + POSITIVE_PREMIUM_INTERCEPT_IN_BIPS;
            }
        }
    }

    function calculateNetDebtAndCollateral(
        Validation.InputParams memory inputParams
    ) internal pure returns (uint256 netDebtInLAssets, uint256 netCollateralInLAssets) {
        // Calculate max premium before repay
        Validation.CheckLtvParams memory checkLtvParams = Validation.getCheckLtvParams(inputParams);

        (netDebtInLAssets, netCollateralInLAssets,) = Validation.calcDebtAndCollateral(checkLtvParams);

        // Exclude current user liquidity as liquidator may sell collateral after liquidation in which case the
        // slippage would not included deposited L.
        // underflow has been checked at 'Ammalgam: Insufficient liquidity'.
        netDebtInLAssets = Validation.increaseForSlippage(
            netDebtInLAssets, inputParams.activeLiquidityAssets - checkLtvParams.depositedLAssets
        );
    }

    // soft

    /**
     * @notice Calculate the premium the soft liquidator is receiving given the borrowers deposit and the depositToTransfer to the liquidator.
     * The end premium is the max of the premiums in L, X, Y
     * If no soft liq is requested (liquidationParams.softDepositLToBeTransferred==liquidationParams.softDepositXToBeTransferred==liquidationParams.softDepositYToBeTransferred==0), the premium will be 0
     * @param inputParams The params containing the position of the borrower.
     * @return premiumInBips The premium being received by the liquidator.
     */
    function calcSoftPremiumBips(
        Validation.InputParams memory inputParams,
        uint256 depositLToTransferInLAssets,
        uint256 depositXToTransferInXAssets,
        uint256 depositYToTransferInYAssets
    ) internal pure returns (uint256 premiumInBips) {
        uint256 depositedLAssets = inputParams.userAssets[DEPOSIT_L];
        uint256 depositedXAssets = inputParams.userAssets[DEPOSIT_X];
        uint256 depositedYAssets = inputParams.userAssets[DEPOSIT_Y];

        if (
            (depositedLAssets == 0 && 0 < depositLToTransferInLAssets)
                || (depositedXAssets == 0 && 0 < depositXToTransferInXAssets)
                || (depositedYAssets == 0 && 0 < depositYToTransferInYAssets)
        ) {
            return type(uint256).max;
        }

        unchecked {
            if (0 < depositedLAssets) {
                premiumInBips = Convert.mulDiv(depositLToTransferInLAssets, BIPS, depositedLAssets, false);
            }
            if (0 < depositedXAssets) {
                premiumInBips += Convert.mulDiv(depositXToTransferInXAssets, BIPS, depositedXAssets, false);
            }
            if (0 < depositedYAssets) {
                premiumInBips += Convert.mulDiv(depositYToTransferInYAssets, BIPS, depositedYAssets, false);
            }
        }
    }

    /**
     * @notice Calculate the max premium the soft liquidator can receive given position of `account`.
     * @param saturationAndGeometricTWAPState The contract containing the saturation state.
     * @param inputParams The params containing the position of `account`.
     * @param account The account of the borrower.
     * @return maxPremiumBips The max premium for the liquidator.
     */
    function calcSoftMaxPremiumInBips(
        ISaturationAndGeometricTWAPState saturationAndGeometricTWAPState,
        Validation.InputParams memory inputParams,
        address account
    ) internal view returns (uint256 maxPremiumBips) {
        // calculate ratio of new sat vs old sat
        (uint256 netXLiqSqrtPriceInXInQ72, uint256 netYLiqSqrtPriceInXInQ72) =
            Saturation.calcLiqSqrtPriceQ72(inputParams.userAssets);

        // use max of netX vs netY
        uint256 ratioNetXBips;
        uint256 ratioNetYBips;
        if (0 < netXLiqSqrtPriceInXInQ72 || 0 < netYLiqSqrtPriceInXInQ72) {
            (ratioNetXBips, ratioNetYBips) = saturationAndGeometricTWAPState.calcSatChangeRatioBips(
                inputParams, netXLiqSqrtPriceInXInQ72, netYLiqSqrtPriceInXInQ72, address(this), account
            );
        }
        uint256 ratioBips = Math.max(ratioNetXBips, ratioNetYBips);

        // if the saturation has decreased, no soft liquidation (maxPremium == 0)
        if (ratioBips < BIPS) return 0;

        // calculate premium
        unchecked {
            maxPremiumBips = (ratioBips - BIPS) / MAG1;
        }
    }
}
