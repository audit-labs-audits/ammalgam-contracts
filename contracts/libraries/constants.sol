// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

/**
 * @dev This basis was a modification to Uniswap V3's basis, to fit ticks into int16 instead of
 *      int24. We use the form $$\frac{2^{9}}{2^{9}-1}$$ which is just under 1.002. This basis
 *      format gives smaller errors since the fraction is more compatible with binary Q128
 *      fractions since the base is inverted in the tick math library before multiplications are
 *      applied.
 *
 *      ```math
 *      \begin{align*}
 *      &   \frac{2^{9}}{2^{9}-1}^{-1} \cdot 2^{128}
 *      & & \frac{10001}{10000}^{-1} \cdot 2^{128}
 *      \\
 *      &   \frac{2^{9}-1}{2^{9}} \cdot 2^{256}
 *      & & \frac{10000\cdot2^{256}}{10001}
 *      \\
 *      &   339617752923046005526922703901628039168
 *      & & \frac{3402823669209384634633746074317682114560000}{10001}
 *      \\
 *      &   0xff800000000000000000000000000000
 *      & & 0xfffcb933bd6fad37aa2d162d1a594001
 *      \\
 *      \end{align*}
 *      ```
 *
 *      We use this constant outside of the tick math library, and use a Q72 as that format is
 *      easier to work with multiplication without overflows.
 *      ```python
 *      >>> hex(int(mpm.nint(mpm.fdiv(2**9, 2**9-1) * 2**72)))
 *      ```
 */
uint256 constant B_IN_Q72 = 0x1008040201008040201;

/**
 * @dev In Saturation we combine 100 ticks to make one tranche.
 *      ```python
 *      >>> hex(int(mpm.nint(mpm.fdiv(2**9, 2**9-1)**100 * 2**72)))
 *      ```
 */
uint256 constant TRANCHE_B_IN_Q72 = 0x13746bb4eee2a5b6cd4;

/**
 * @dev In Saturation we also use a quarter of a tranche to give some better fidelity without
 *      needing to add a number iterations of multiplications.
 *      ```python
 *      >>> hex(int(mpm.nint(mpm.fdiv(2**9, 2**9-1)**25 * 2**72)))
 *      ```
 */
uint256 constant TRANCHE_QUARTER_B_IN_Q72 = 0x10cd2b2ae53a69d3552;

/**
 * @dev Represents the absence of a valid lending tick, initialized to `int16` minimum value since type(int16).min < MIN_TICK
 */
int16 constant LENDING_TICK_NOT_AVAILABLE = type(int16).min;

/**
 * @dev the default zero address
 */
address constant ZERO_ADDRESS = address(0);

/**
 * @dev 2**16
 */
uint256 constant Q16 = 0x10000;

/**
 * @dev 2**32
 */
uint256 constant Q32 = 0x100000000;

/**
 * @dev 2**56.
 */
uint256 constant Q56 = 0x100000000000000;

/**
 * @dev 2**64.
 */
uint256 constant Q64 = 0x10000000000000000;

/**
 * @dev 2**72.
 */
uint256 constant Q72 = 0x1000000000000000000;

/**
 * @dev 2**112.
 */
uint256 constant Q112 = 0x10000000000000000000000000000;

/**
 *
 * @dev 2**128.
 */
uint256 constant Q128 = 0x100000000000000000000000000000000;

/**
 */
uint256 constant Q144 = 0x1000000000000000000000000000000000000;

/**
 * @dev number of bips in 1, 1 bips = 0.01%.
 */
uint256 constant BIPS = 10_000;

/**
 * @dev Default mid-term interval config used at the time of GeometricTWAP initialization.
 */
uint16 constant DEFAULT_MID_TERM_INTERVAL = 8;

/**
 * @dev minimum liquidity to initialize a pool, amount is burned to eliminate the threat of
 *      donation attacks.
 */
uint256 constant MINIMUM_LIQUIDITY = 1000;

/**
 * @dev Represents the minimum time period required between recorded long-term intervals.
 * Calculated as the product of `DEFAULT_MID_TERM_INTERVAL` and `GeometricTWAP.
 * MINIMUM_LONG_TERM_INTERVAL_FACTOR`.
 */
uint24 constant MINIMUM_LONG_TERM_TIME_UPDATE_CONFIG = 112;

/**
 * @dev `MAX_TICK_DELTA` limits the `newTick` to be within the outlier range of the current mid-term price.
 */
int256 constant MAX_TICK_DELTA = 10;

/**
 * @dev `DEFAULT_TICK_DELTA_FACTOR` is used when the long-term buffer is initialized.
 */
int256 constant DEFAULT_TICK_DELTA_FACTOR = 1;

/**
 * @dev the system loan to value minimum, 75% * 100.
 */
uint256 constant LTVMAX_IN_MAG2 = 75;

/**
 * @dev the system allowed leverage exposures with similar underlying assets, ie L is half X and
 * half Y, so we allow 100X leverage of borrowed X and Y against L.
 */
uint256 constant ALLOWED_LIQUIDITY_LEVERAGE = 100;

/**
 * @dev Allowed leverage minus one.
 */
uint256 constant ALLOWED_LIQUIDITY_LEVERAGE_MINUS_ONE = 99;

/**
 * @dev constant used in Quadratic swap fees that controls the speed at which fees increase with
 * respect to the price change.
 */
uint256 constant N_TIMES_FEE = 20;

/**
 * @dev Magnitude 1
 */
uint256 constant MAG1 = 10;

/**
 * @dev Magnitude 2
 */
uint256 constant MAG2 = 100;

/**
 * @dev Magnitude 4
 */
uint256 constant MAG4 = 10_000;

/**
 * @dev Magnitude 6
 */
uint256 constant MAG6 = 1_000_000;

/**
 * @dev Saturation percentages in WADs
 */
uint256 constant SAT_PERCENTAGE_DELTA_4_WAD = 94.1795538580338563e16;
uint256 constant SAT_PERCENTAGE_DELTA_5_WAD = 92.3156868017020937e16;
uint256 constant SAT_PERCENTAGE_DELTA_6_WAD = 90.4887067368814135e16;
uint256 constant SAT_PERCENTAGE_DELTA_7_WAD = 88.6978836489829983e16;
uint256 constant SAT_PERCENTAGE_DELTA_8_WAD = 86.9425019708228757e16;
uint256 constant SAT_PERCENTAGE_DELTA_DEFAULT_WAD = 95e16;

uint256 constant LIQUIDITY_INTEREST_RATE_MAGNIFICATION = 5;
/**
 * @dev Maximum percentage for the saturation allowed, used to limit the maximum saturation per tranche.
 */
uint256 constant MAX_SATURATION_PERCENT_IN_WAD = 0.95e18; // 95%

/**
 * @dev Maximum percentage for the utilization allowed.
 */
uint256 constant MAX_UTILIZATION_PERCENT_IN_WAD = 0.9e18; // 90%

uint128 constant SECONDS_IN_YEAR = 365 days;
