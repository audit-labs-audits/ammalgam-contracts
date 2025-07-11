// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {Q56, Q72, MAG2} from 'contracts/libraries/constants.sol';
import {ROUNDING_UP} from 'contracts/interfaces/tokens/ITokenController.sol';

library Convert {
    uint256 private constant BUFFER = 95;

    function toLiquidityAssets(
        uint256 liquidityShares,
        uint256 reservesAssets,
        uint256 activeLiquidityAssets,
        uint256 depositLiquidityAssets,
        uint256 depositLiquidityShares
    ) internal pure returns (uint256) {
        // all shares are max uint112 and all assets are max uint128 so no overflow
        unchecked {
            // This calculation is derived from the original formula:
            // amountAssets = amountShares * (depositLiquidityAssets / depositLiquidityShares) * reservesAssets / activeLiquidityAssets.
            return Convert.mulDiv(
                Convert.mulDiv(liquidityShares, reservesAssets, activeLiquidityAssets, false),
                depositLiquidityAssets,
                depositLiquidityShares,
                false
            );
        }
    }

    function toAssets(
        uint256 shares,
        uint256 totalAssets,
        uint256 totalShares,
        bool roundingUp
    ) internal pure returns (uint256 _assets) {
        if (totalShares == 0) {
            return shares; // If no shares, assets are equal to shares.
        }
        return mulDiv(shares, totalAssets, totalShares, roundingUp);
    }

    function toShares(
        uint256 assets,
        uint256 totalAssets,
        uint256 totalShares,
        bool roundingUp
    ) internal pure returns (uint256 _shares) {
        if (totalAssets == 0) {
            return assets; // If no assets, shares are equal to assets.
        }
        return mulDiv(assets, totalShares, totalAssets, roundingUp);
    }

    function mulDiv(uint256 x, uint256 y, uint256 z, bool roundingUp) internal pure returns (uint256 result) {
        result = x * y;
        result = roundingUp ? Math.ceilDiv(result, z) : result / z;
    }

    function calcLiquidityConsideringDepletion(
        uint256 amountOfAssets,
        uint256 reserveAssets,
        uint256 _missingAssets,
        uint256 activeLiquidityAssets,
        uint256 depositedLiquidityAssets,
        uint256 depositedLiquidityShares,
        bool isRoundingUp
    ) internal pure returns (uint256 liquidityAssets, uint256 liquidityShares) {
        // convert amountOfAssets in X or Y assets to L assets
        liquidityAssets = mulDiv(amountOfAssets, activeLiquidityAssets, reserveAssets, isRoundingUp);

        (liquidityAssets, liquidityShares) = reserveAssets * BUFFER >= _missingAssets * MAG2
            ? (
                liquidityAssets,
                // convert amountOf L Assets to L shares, always rounding down for both deposit and borrow
                toShares(liquidityAssets, depositedLiquidityAssets, depositedLiquidityShares, !ROUNDING_UP)
            )
            : (
                depletionReserveAdjustmentWhenLiquidityIsAdded(
                    amountOfAssets,
                    reserveAssets,
                    _missingAssets,
                    activeLiquidityAssets,
                    depositedLiquidityAssets,
                    depositedLiquidityShares,
                    isRoundingUp
                )
            );
    }

    /**
     * @dev Minting when assets depleted requires less of the depleted asset as we
     * give extra credit to minter for bringing the scarce asset. We account
     * for liquidity as if moving from the unmodified invariant prior to mint
     * to the where it would move after the mint including the extra credited
     * scarce asset.
     *
     * I continue to update the Desmos to help create test cases with easier
     * numbers to reason about, The current version of desmos is linked below.
     * The chart could use some clean up and reorganization to be clearer, will
     * do in the future.
     *
     * https://www.desmos.com/calculator/etzuxkjeig
     */
    function depletionReserveAdjustmentWhenLiquidityIsAdded(
        uint256 amountAssets,
        uint256 reserveAssets,
        uint256 _missingAssets,
        uint256 activeLiquidityAssets,
        uint256 depositedLAssets,
        uint256 depositedLShares,
        bool roundingUp
    ) private pure returns (uint256 liquidityAssets, uint256 liquidityShares) {
        // If the current reserve (plus amount) is sufficient to cover the missing amount with some buffer,
        // calculate the partial replenishment using a simplified formula involving active liquidity.
        // Otherwise, calculate the replenishment based on the remaining reserves and active
        // liquidity.

        // all shares are max uint112 and all assets are max uint128 so no overflow
        unchecked {
            liquidityAssets = reserveAssets + amountAssets;
            if (liquidityAssets * BUFFER >= _missingAssets * MAG2) {
                liquidityAssets = Convert.mulDiv(liquidityAssets, MAG2 - BUFFER, MAG2, false);
            } else {
                liquidityAssets = (liquidityAssets - _missingAssets);
            }
            liquidityAssets = mulDiv(liquidityAssets, activeLiquidityAssets, reserveAssets - _missingAssets, roundingUp)
                - activeLiquidityAssets;
            liquidityShares = toShares(liquidityAssets, depositedLAssets, depositedLShares, roundingUp);
        }
    }
}
