// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

import {Convert} from 'contracts/libraries/Convert.sol';

/**
 * @title QuadraticSwapFees
 * @author Will
 * @notice A library to calculate fees that grow quadratically with respect to price, square root
 *   price to be exact. This library relies on a reference reserve from the start of the block to
 *   determine what the overall growth in price has been in the current block. If one swap were to
 *   pay one fee, that same swap broken into two swaps would pay two fees that would add up to the
 *   one. If the price moves away from the reserve, and then back towards the reserve, the fee is
 *   minimal until the price again crosses the starting price.
 */
library QuadraticSwapFees {
    /**
     * @notice Minimum fee is one tenth of a basis point.
     */
    uint256 public constant MIN_FEE_Q64 = 0x1999999999999999;

    /**
     * @notice 10000 bips per 100 percent in Q64.
     */
    uint256 public constant BIPS_Q64 = 0x27100000000000000000;

    /**
     * @notice Max percent fee growing at a quadratic rate. After this the growths slows down.
     */
    uint256 internal constant MAX_QUADRATIC_FEE_PERCENT = 40;

    /**
     * @notice A scaler that controls how fast the fee grows, at 20, 9x price change will be
     *   a 40% fee.
     */
    uint256 internal constant N = 20;

    /**
     * @notice the $$\sqrt{price}$$ at which we switch from quadratic fee to a more linear fee.
     *   ```math
     *     (MAX_QUADRATIC_FEE_PERCENT + N) / N
     *   ```
     */
    uint256 private constant LINEAR_START_REFERENCE_SCALER = 3;

    /**
     * @notice the fee at `LINEAR_START_REFERENCE_SCALER` in bips
     */
    uint256 private constant MAX_QUADRATIC_FEE_PERCENT_BIPS = 4000;

    /**
     * @notice $$ N * 100 * Q64 $$ or `N` times bips in one percent in Q64
     */
    uint256 private constant N_TIMES_BIPS_Q64_PER_PERCENT = 0x7d00000000000000000;

    /**
     * @notice 2 times Q64 or Q65
     */
    uint256 private constant TWO_Q64 = 0x20000000000000000;

    /**
     * @notice `MAX_QUADRATIC_FEE_PERCENT` in Q64, $$ MAX_QUADRATIC_FEE_PERCENT * Q64 $$
     */
    uint256 private constant MAX_QUADRATIC_FEE_Q64 = 0x280000000000000000;

    /**
     * @notice Returns a swap fee given the current reserve reference.
     */
    function calculateSwapFeeBipsQ64(
        uint256 input,
        uint256 referenceReserve,
        uint256 currentReserve
    ) internal pure returns (uint256 fee) {
        if (input == 0) {
            return 0;
        }
        if (currentReserve < referenceReserve) {
            // We are moving back towards the price
            if (input + currentReserve > referenceReserve) {
                // the input moves from the current reserve past the starting reserve, we charge a
                // weighted fee based on how far past the starting reserve we are
                uint256 pastBy = input + currentReserve - referenceReserve;
                if (input + currentReserve > referenceReserve * LINEAR_START_REFERENCE_SCALER) {
                    // This swap has moved beyond the max quadratic fee
                    fee = MAX_QUADRATIC_FEE_PERCENT_BIPS
                        * (TWO_Q64 - Convert.mulDiv(referenceReserve, MAX_QUADRATIC_FEE_Q64, N * pastBy, false));
                } else {
                    // this fee is still in the quadratic range
                    fee = Convert.mulDiv(N_TIMES_BIPS_Q64_PER_PERCENT, pastBy, referenceReserve, false);
                }
                fee = Convert.mulDiv(fee, pastBy, input, false);
            } else {
                // we have not reached the starting reserve, we charge the minimum fee
                fee = QuadraticSwapFees.MIN_FEE_Q64;
            }
        } else if (input + currentReserve > referenceReserve * LINEAR_START_REFERENCE_SCALER) {
            // This swap passes beyond the max quadratic fee
            fee = MAX_QUADRATIC_FEE_PERCENT_BIPS
                * (
                    TWO_Q64
                        - Convert.mulDiv(
                            referenceReserve,
                            MAX_QUADRATIC_FEE_Q64,
                            N * (input + 2 * (currentReserve - referenceReserve)),
                            false
                        )
                );
        } else {
            // this swap is still in the quadratic range
            fee = Convert.mulDiv(
                N_TIMES_BIPS_Q64_PER_PERCENT, 2 * (currentReserve - referenceReserve) + input, referenceReserve, false
            );
        }
    }
}
