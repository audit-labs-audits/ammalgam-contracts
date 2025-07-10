// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

/**
 * @title ICallback Interface
 * @dev This interface should be implemented by anyone wishing to use callbacks in the
 * `swap`, `borrow`, and `borrowLiquidity` functions in the  IAmmalgamPair interface.
 */
interface ICallback {
    /**
     * @notice Handles a swap call in the Ammalgam protocol.
     * @dev Callback passed as calldata to `swap` functions in `IAmmalgamPair`.
     * @param sender The address of the sender initiating the swap call.
     * @param amountXAssets The amount of token X involved in the swap.
     * @param amountYAssets The amount of token Y involved in the swap.
     * @param data The calldata provided to the swap function.
     */
    function ammalgamSwapCallV1(
        address sender,
        uint256 amountXAssets,
        uint256 amountYAssets,
        bytes calldata data
    ) external;

    /**
     * @param amountXAssets The amount of token X involved in the borrow.
     * @param amountYAssets The amount of token Y involved in the borrow.
     * @param amountXShares The shares of token X involved in the borrow.
     * @param amountYShares The shares of token Y involved in the borrow.
     * @param data The calldata provided to the borrow function.
     */
    function ammalgamBorrowCallV1(
        address sender,
        uint256 amountXAssets,
        uint256 amountYAssets,
        uint256 amountXShares,
        uint256 amountYShares,
        bytes calldata data
    ) external;

    /**
     * @param amountXAssets The amount of token X involved in the borrow.
     * @param amountYAssets The amount of token Y involved in the borrow.
     * @param amountLShares The shares of liquidity involved in the borrow.
     * @param data The calldata provided to the borrow function.
     */
    function ammalgamBorrowLiquidityCallV1(
        address sender,
        uint256 amountXAssets,
        uint256 amountYAssets,
        uint256 amountLShares,
        bytes calldata data
    ) external;

    /**
     * @notice Handles a liquidate call in the Ammalgam protocol. The callback is expected to transfer repayXInXAssets and repayYInYAssets from the liquidator to the pair.
     * @param repayXInXAssets The amount of token X the liquidator should transfer to the pair.
     * @param repayYInYAssets The amount of token Y the liquidator should transfer to the pair.
     */
    function ammalgamLiquidateCallV1(uint256 repayXInXAssets, uint256 repayYInYAssets) external;
}
