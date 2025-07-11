// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {MathLib, WAD} from '@morpho-org/morpho-blue/src/libraries/MathLib.sol';

import {TickMath} from 'contracts/libraries/TickMath.sol';

import {
    DEPOSIT_L,
    DEPOSIT_X,
    DEPOSIT_Y,
    BORROW_L,
    BORROW_X,
    BORROW_Y,
    FIRST_DEBT_TOKEN
} from 'contracts/interfaces/tokens/ITokenController.sol';
import {
    B_IN_Q72,
    Q72,
    Q128,
    LIQUIDITY_INTEREST_RATE_MAGNIFICATION,
    MAX_SATURATION_PERCENT_IN_WAD,
    MAX_UTILIZATION_PERCENT_IN_WAD,
    SECONDS_IN_YEAR
} from 'contracts/libraries/constants.sol';
import {Convert} from 'contracts/libraries/Convert.sol';

/**
 * @title Interest Library
 * @notice This library is used for calculating and accruing interest.
 * @dev many calculations are unchecked because we asset values are stored as uint128. We also limit
 *      the max amount amount of interest to ensure that it can not overflow when added to the
 *      current assets.
 *
 */
library Interest {
    using MathLib for uint256;
    using MathLib for uint128;

    struct AccrueInterestParams {
        uint256 duration;
        int16 lendingStateTick;
        uint256 adjustedActiveLiquidity;
        uint112[6] shares;
        uint256 satPercentageInWads;
    }

    uint128 internal constant OPTIMAL_UTILIZATION = 0.8e18; //  80%
    uint128 internal constant DANGER_UTILIZATION = 0.925e18; // 92.5%
    uint128 internal constant SLOPE1 = 0.1e18;
    uint128 internal constant SLOPE2 = 2e18;
    uint128 internal constant SLOPE3 = 20e18;
    uint128 internal constant BASE_OPTIMAL_UTILIZATION = 0.08e18; // 8%
    uint128 internal constant BASE_DANGER_UTILIZATION = 0.33e18; // 33%

    uint128 internal constant LENDING_FEE_RATE = 10;
    uint256 private constant MAX_UINT112 = type(uint112).max;
    uint256 private constant LAST_DEPOSIT = 2; // FIRST_DEBT_TOKEN - 1;

    /**
     * @dev Maximum percentage for the penalty saturation allowed.
     * This is used to prevent excessive penalties in case of high utilization.
     */
    uint256 private constant PENALTY_SATURATION_PERCENT_IN_WAD = 0.85e18; // 85%

    /**
     * @dev `MAX_SATURATION_PERCENT_IN_WAD` - `PENALTY_SATURATION_PERCENT_IN_WAD`
     */
    uint256 private constant SATURATION_PENALTY_BUFFER_IN_WAD = 0.1e18;

    event InterestAccrued(
        uint128 depositLAssets,
        uint128 depositXAssets,
        uint128 depositYAssets,
        uint128 borrowLAssets,
        uint128 borrowXAssets,
        uint128 borrowYAssets
    );

    function accrueInterestAndUpdateReservesWithAssets(
        uint128[6] storage assets,
        AccrueInterestParams memory accrueInterestParams
    ) external returns (uint256 interestXForLP, uint256 interestYForLP, uint256[3] memory protocolFeeAssets) {
        if (accrueInterestParams.duration > 0) {
            uint128[6] memory newAssets;
            (newAssets, interestXForLP, interestYForLP, protocolFeeAssets) =
                accrueInterestWithAssets(assets, accrueInterestParams);
            for (uint256 i; i < newAssets.length; i++) {
                assets[i] = newAssets[i];
            }
            emit InterestAccrued(
                newAssets[DEPOSIT_L],
                newAssets[DEPOSIT_X],
                newAssets[DEPOSIT_Y],
                newAssets[BORROW_L],
                newAssets[BORROW_X],
                newAssets[BORROW_Y]
            );
        }
    }

    /**
     * @notice we approximate the reserves based on an average tick value since the last lending
     *         state update.
     * @dev this will never return values greater than uint112 max when used correctly. The reserve
     *      values are underestimated due to a tick being an approximate price. We use a smaller
     *      value when multiplying and a larger when dividing to ensure that we do not overflow.
     * @param activeLiquidityAssets active L where $\sqrt(reserveX * reserveY) = L$
     * @param lendingStateTick Average tick value since last lending state update.
     * @return reserveXAssets approximate average reserve since last lending state update.
     * @return reserveYAssets approximate average reserve since last lending state update.
     */
    function getReservesAtTick(
        uint256 activeLiquidityAssets,
        int16 lendingStateTick
    ) internal pure returns (uint256 reserveXAssets, uint256 reserveYAssets) {
        // calculate reserves at lending state tick
        uint256 sqrtPriceAtLendingStateTickMinInQ72 = TickMath.getSqrtPriceAtTick(lendingStateTick);
        uint256 sqrtPriceAtLendingStateTickMaxInQ72 =
            Convert.mulDiv(sqrtPriceAtLendingStateTickMinInQ72, B_IN_Q72, Q72, true);

        unchecked {
            // x = L * sqrt(p)
            reserveXAssets = Convert.mulDiv(activeLiquidityAssets, sqrtPriceAtLendingStateTickMinInQ72, Q72, false);

            // y = L / sqrt(p)
            reserveYAssets = Convert.mulDiv(activeLiquidityAssets, Q72, sqrtPriceAtLendingStateTickMaxInQ72, false);
        }

        return (reserveXAssets, reserveYAssets);
    }

    function getUtilizationsInWads(
        uint128[6] memory startingAssets,
        uint256 reservesXAssets,
        uint256 reservesYAssets,
        uint256 satPercentageInWads
    ) internal pure returns (uint256[3] memory utilizationInWads) {
        uint256 missingLXAssets;
        uint256 missingLYAssets;

        unchecked {
            // Calculate missing assets in a block scope to reduce stack depth
            {
                uint256 depositedLAssets = startingAssets[DEPOSIT_L];
                uint256 borrowedLAssets = startingAssets[BORROW_L];
                uint256 activeLiquidity = depositedLAssets - borrowedLAssets;

                // overflow not possible on multiplication, and underflow caught by conditions
                if (startingAssets[BORROW_X] > startingAssets[DEPOSIT_X]) {
                    missingLXAssets = Math.ceilDiv(
                        (startingAssets[BORROW_X] - startingAssets[DEPOSIT_X]) * activeLiquidity, reservesXAssets
                    );
                }
                if (startingAssets[BORROW_Y] > startingAssets[DEPOSIT_Y]) {
                    missingLYAssets = Math.ceilDiv(
                        (startingAssets[BORROW_Y] - startingAssets[DEPOSIT_Y]) * activeLiquidity, reservesYAssets
                    );
                }
            }

            // Calculate utilizations in separate block scope
            {
                utilizationInWads = [
                    mutateUtilizationForSaturation(
                        getUtilizationInWads(
                            startingAssets[BORROW_L] + Math.max(missingLXAssets, missingLYAssets), startingAssets[DEPOSIT_L]
                        ),
                        satPercentageInWads
                    ),
                    getUtilizationInWads(startingAssets[BORROW_X], startingAssets[DEPOSIT_X] + reservesXAssets),
                    getUtilizationInWads(startingAssets[BORROW_Y], startingAssets[DEPOSIT_Y] + reservesYAssets)
                ];
            }
        }
    }

    function accrueInterestWithAssets(
        uint128[6] memory assets,
        AccrueInterestParams memory params
    )
        public
        pure
        returns (
            uint128[6] memory newAssets,
            uint256 interestXPortionForLP,
            uint256 interestYPortionForLP,
            uint256[3] memory protocolFeeAssets
        )
    {
        uint128[6] memory startingAssets = assets;
        uint256[3] memory interestAssetSet;
        uint256 swapFeeGrowth;
        {
            (uint256 averageReservesX, uint256 averageReservesY) =
                getReservesAtTick(startingAssets[DEPOSIT_L] - startingAssets[BORROW_L], params.lendingStateTick);
            {
                uint256[3] memory utilizationsInWads = getUtilizationsInWads(
                    startingAssets, averageReservesX, averageReservesY, params.satPercentageInWads
                );

                // for loop overhead not worth it for three loops.
                interestAssetSet = [
                    // Magnify interest on liquidity by 5x what x and y rates for the same utilization.
                    LIQUIDITY_INTEREST_RATE_MAGNIFICATION
                        * computeInterestAssets(
                            params.duration, utilizationsInWads[DEPOSIT_L], startingAssets[BORROW_L], startingAssets[DEPOSIT_L]
                        ),
                    computeInterestAssets(
                        params.duration, utilizationsInWads[DEPOSIT_X], startingAssets[BORROW_X], startingAssets[DEPOSIT_X]
                    ),
                    computeInterestAssets(
                        params.duration, utilizationsInWads[DEPOSIT_Y], startingAssets[BORROW_Y], startingAssets[DEPOSIT_Y]
                    )
                ];
            }

            unchecked {
                protocolFeeAssets = [
                    Convert.mulDiv(interestAssetSet[DEPOSIT_L], LENDING_FEE_RATE, 100, false),
                    Convert.mulDiv(interestAssetSet[DEPOSIT_X], LENDING_FEE_RATE, 100, false),
                    Convert.mulDiv(interestAssetSet[DEPOSIT_Y], LENDING_FEE_RATE, 100, false)
                ];

                interestAssetSet = [
                    interestAssetSet[DEPOSIT_L] - protocolFeeAssets[DEPOSIT_L],
                    interestAssetSet[DEPOSIT_X] - protocolFeeAssets[DEPOSIT_X],
                    interestAssetSet[DEPOSIT_Y] - protocolFeeAssets[DEPOSIT_Y]
                ];

                // G = RL_1 * ALA_0 / (RL_0 * ALA_1)
                uint256 oneOverGQ128 = Convert.mulDiv(
                    startingAssets[DEPOSIT_L] - startingAssets[BORROW_L], Q128, params.adjustedActiveLiquidity, false
                );
                swapFeeGrowth = Convert.mulDiv(startingAssets[BORROW_L], Q128 - oneOverGQ128, Q128, false);

                interestXPortionForLP = Convert.mulDiv(
                    interestAssetSet[DEPOSIT_X], averageReservesX, startingAssets[DEPOSIT_X] + averageReservesX, false
                );
                interestYPortionForLP = Convert.mulDiv(
                    interestAssetSet[DEPOSIT_Y], averageReservesY, startingAssets[DEPOSIT_Y] + averageReservesY, false
                );
            }
        }

        // DEPOSIT_L and BORROW_Y are the first and last indices.
        for (uint256 i = DEPOSIT_L; i <= BORROW_Y; i++) {
            uint256 swapFeeGrowthToRemoveFromLp;
            uint256 interestPortionForLP;
            uint256 protocolFees;
            uint256 shortArrayIndex = i % FIRST_DEBT_TOKEN;

            if (i == DEPOSIT_L) {
                swapFeeGrowthToRemoveFromLp = swapFeeGrowth;
            } else if (i == DEPOSIT_X) {
                interestPortionForLP = interestXPortionForLP;
            } else if (i == DEPOSIT_Y) {
                interestPortionForLP = interestYPortionForLP;
            } else if (i > LAST_DEPOSIT) {
                // add protocol fees to all borrows.
                protocolFees = protocolFeeAssets[shortArrayIndex];
                if (i == BORROW_L) swapFeeGrowthToRemoveFromLp = swapFeeGrowth;
            }
            newAssets[i] = addInterestToAssets(
                startingAssets[i] - swapFeeGrowthToRemoveFromLp,
                interestAssetSet[shortArrayIndex]
                // Back out lp interest being attributed to reserves
                - interestPortionForLP
                // add protocol fees to all borrows.
                + protocolFees
            );
        }
    }

    function getUtilizationInWads(
        uint256 totalBorrowedAssets,
        uint256 totalDepositedAssets
    ) internal pure returns (uint256 utilization) {
        if (totalDepositedAssets > 0) {
            // assets are both 128 and will not overflow.
            unchecked {
                // assets are uint128, cant overflow.
                utilization = Math.ceilDiv(totalBorrowedAssets * WAD, totalDepositedAssets);
            }
        }
    }

    /**
     * @notice Adjusts utilization based on saturation to calculate interest penalties
     * @dev When saturation exceeds `PENALTY_SATURATION_PERCENT_IN_WAD`, utilization is increased
     *      to apply higher interest rates as a penalty for high saturation
     * @param utilization Current utilization of `L`, `X`, or `Y` assets
     * @param maxSatInWads Saturation utilization
     * @return The adjusted utilization value
     */
    function mutateUtilizationForSaturation(
        uint256 utilization,
        uint256 maxSatInWads
    ) internal pure returns (uint256) {
        // Early return, if saturation is above or below defined threshold
        if (maxSatInWads <= PENALTY_SATURATION_PERCENT_IN_WAD) {
            return utilization;
        } else if (maxSatInWads >= MAX_SATURATION_PERCENT_IN_WAD) {
            return MAX_UTILIZATION_PERCENT_IN_WAD;
        }

        // Calculate adjustment based on formula:
        // min(max((maxSatInWads - MAX_SATURATION_PERCENT) * (MAX_UTILIZATION - utilization) /
        //     (MAX_SATURATION_PERCENT - PENALTY_SATURATION_PERCENT) + MAX_UTILIZATION, utilization), MAX_UTILIZATION)
        uint256 adjustedUtilization = MAX_UTILIZATION_PERCENT_IN_WAD
            - Convert.mulDiv(
                MAX_SATURATION_PERCENT_IN_WAD - maxSatInWads,
                MAX_UTILIZATION_PERCENT_IN_WAD - utilization,
                SATURATION_PENALTY_BUFFER_IN_WAD,
                false
            );

        return Math.min(Math.max(adjustedUtilization, utilization), MAX_UTILIZATION_PERCENT_IN_WAD);
    }

    function computeInterestAssets(
        uint256 duration,
        uint256 utilization,
        uint256 borrowedAssets,
        uint256 depositedAssets
    ) internal pure returns (uint256) {
        uint256 baseRateInWads = getAnnualInterestRatePerSecondInWads(utilization);
        return computeInterestAssetsGivenRate(duration, borrowedAssets, depositedAssets, baseRateInWads);
    }

    function computeInterestAssetsGivenRate(
        uint256 duration,
        uint256 borrowedAssets,
        uint256 depositedAssets,
        uint256 rateInWads
    ) internal pure returns (uint256) {
        // max amount of interest that can accrue is uint128 max to prevent overflows
        // this means that once an asset hits the max, interest will no longer accrue.
        unchecked {
            return Math.min(
                Convert.mulDiv(MathLib.wTaylorCompounded(rateInWads, duration), borrowedAssets, WAD, false),
                type(uint128).max - Math.max(depositedAssets, borrowedAssets)
            );
        }
    }

    function addInterestToAssets(uint256 prevAssets, uint256 interest) internal pure returns (uint128) {
        // safe down cast because interest <= type(uint128).max - max(depositedAssets, borrowedAssets)
        unchecked {
            return uint128(prevAssets + interest);
        }
    }

    /**
     * @notice Gets the annual interest rate for a given utilization
     * @dev Same as getAnnualInterestRatePerSecondInWads but without dividing by SECONDS_IN_YEAR
     * @param utilizationInWads The utilization rate in WADs
     * @return interestRate The annual interest rate in WADs
     */
    function getAnnualInterestRatePerSecondInWads(
        uint256 utilizationInWads
    ) internal pure returns (uint256 interestRate) {
        if (utilizationInWads <= OPTIMAL_UTILIZATION) {
            interestRate = utilizationInWads.wMulDown(SLOPE1);
        } else if (utilizationInWads <= DANGER_UTILIZATION) {
            interestRate = (utilizationInWads - OPTIMAL_UTILIZATION).wMulDown(SLOPE2) + BASE_OPTIMAL_UTILIZATION;
        } else {
            interestRate = (utilizationInWads - DANGER_UTILIZATION).wMulDown(SLOPE3) + BASE_DANGER_UTILIZATION;
        }
        interestRate /= SECONDS_IN_YEAR;
    }
}
