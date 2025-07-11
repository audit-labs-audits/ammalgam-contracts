// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

import {GeometricTWAP} from 'contracts/libraries/GeometricTWAP.sol';
import {Liquidation} from 'contracts/libraries/Liquidation.sol';
import {Saturation} from 'contracts/libraries/Saturation.sol';
import {Validation} from 'contracts/libraries/Validation.sol';
import {ISaturationAndGeometricTWAPState} from 'contracts/interfaces/ISaturationAndGeometricTWAPState.sol';

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

contract SaturationAndGeometricTWAPState is ISaturationAndGeometricTWAPState, Ownable {
    // main state

    uint24 public immutable midTermIntervalConfig;
    uint24 public immutable longTermIntervalConfig;

    // slither-disable-next-line uninitialized-state
    mapping(address => Saturation.SaturationStruct) internal satDataGivenPair;
    mapping(address => GeometricTWAP.Observations) internal TWAPDataGivenPair;
    mapping(address => mapping(address => uint256)) maxNewPositionSaturationInMAG2; // pair => account => value
    mapping(address => bool) internal isPairInitialized;

    constructor(uint24 _midTermIntervalConfig, uint24 _longTermIntervalConfig) Ownable(msg.sender) {
        midTermIntervalConfig = _midTermIntervalConfig;
        longTermIntervalConfig = _longTermIntervalConfig;
    }

    modifier isInitialized() {
        _isInitialized();
        _;
    }

    function _isInitialized() internal view {
        if (!isPairInitialized[msg.sender]) revert PairDoesNotExist();
    }

    /**
     * @notice  initializes the sat and TWAP struct
     * @dev     initCheck can be removed once the tree structure is fixed
     */
    function init(
        int16 firstTick
    ) external {
        if (isPairInitialized[msg.sender]) revert PairAlreadyExists();
        Saturation.SaturationStruct storage satStruct = satDataGivenPair[msg.sender];
        GeometricTWAP.Observations storage observations = TWAPDataGivenPair[msg.sender];

        Saturation.initializeSaturationStruct(satStruct);
        GeometricTWAP.initializeObservationStruct(observations, midTermIntervalConfig, longTermIntervalConfig);
        isPairInitialized[msg.sender] = true;

        GeometricTWAP.addObservationAndSetLendingState(TWAPDataGivenPair[msg.sender], firstTick);
    }

    // saturation

    function setNewPositionSaturation(address pair, uint256 maxDesiredSaturationMag2) external {
        if (!isPairInitialized[pair]) revert PairDoesNotExist();
        if (maxDesiredSaturationMag2 > Saturation.MAX_INITIAL_SATURATION_MAG2 || maxDesiredSaturationMag2 == 0) {
            revert InvalidUserConfiguration();
        }
        maxNewPositionSaturationInMAG2[pair][msg.sender] = maxDesiredSaturationMag2;
    }

    function getNewPositionSaturation(
        address pair,
        address account
    ) internal view returns (uint256 maxDesiredSaturationInMAG2) {
        maxDesiredSaturationInMAG2 = maxNewPositionSaturationInMAG2[pair][account];
        if (maxDesiredSaturationInMAG2 == 0) {
            maxDesiredSaturationInMAG2 = Saturation.START_SATURATION_PENALTY_RATIO_IN_MAG2;
        }
    }

    function getTree(address pairAddress, bool netDebtX) private view returns (Saturation.Tree storage) {
        Saturation.SaturationStruct storage satStruct = satDataGivenPair[pairAddress];
        return netDebtX ? satStruct.netXTree : satStruct.netYTree;
    }

    function getLeafDetails(
        address pairAddress,
        bool netDebtX,
        uint256 leafIndex
    )
        external
        view
        returns (
            Saturation.SaturationPair memory saturation,
            uint256 currentPenaltyInBorrowLSharesPerSatInQ72,
            uint16[] memory tranches
        )
    {
        Saturation.Leaf storage leaf = getTree(pairAddress, netDebtX).leafs[leafIndex];
        saturation = leaf.leafSatPair;
        currentPenaltyInBorrowLSharesPerSatInQ72 = leaf.penaltyInBorrowLSharesPerSatInQ72;
        tranches = leaf.tranches.keyList;
    }

    function getTreeDetails(address pairAddress, bool netDebtX) external view returns (uint16, uint128) {
        Saturation.Tree storage tree = getTree(pairAddress, netDebtX);
        return (tree.highestSetLeaf, tree.totalSatInLAssets);
    }

    function getTrancheDetails(
        address pairAddress,
        bool netDebtX,
        int16 tranche
    ) external view returns (uint16 leaf, Saturation.SaturationPair memory saturation) {
        Saturation.Tree storage tree = getTree(pairAddress, netDebtX);
        leaf = tree.trancheToLeaf[tranche];
        saturation = tree.trancheToSaturation[tranche];
    }

    function getAccount(
        address pairAddress,
        bool netDebtX,
        address accountAddress
    ) external view returns (Saturation.Account memory) {
        return getTree(pairAddress, netDebtX).accountData[accountAddress];
    }

    /**
     * @notice  update the borrow position of an account and potentially check (and revert) if the resulting sat is too high
     * @dev     run accruePenalties before running this function
     * @param   inputParams  contains the position and pair params, like account borrows/deposits, current price and active liquidity
     * @param   account  for which is position is being updated
     */
    function update(Validation.InputParams memory inputParams, address account) external virtual {
        _update(inputParams, account);
    }

    function _update(Validation.InputParams memory inputParams, address account) internal isInitialized {
        Saturation.update(
            satDataGivenPair[msg.sender], inputParams, account, getNewPositionSaturation(msg.sender, account)
        );
    }

    /**
     * @notice  accrue penalties since last accrual based on all over saturated positions
     *
     * @param   externalLiquidity  Swap liquidity outside this pool
     * @param   duration  since last accrual of penalties
     * @param   allAssetsDepositL  allAsset[DEPOSIT_L]
     * @param   allAssetsBorrowL  allAsset[BORROW_L]
     * @param   allSharesBorrowL  allShares[BORROW_L]
     */
    function accruePenalties(
        address account,
        uint256 externalLiquidity,
        uint256 duration,
        uint256 allAssetsDepositL,
        uint256 allAssetsBorrowL,
        uint256 allSharesBorrowL
    ) external isInitialized returns (uint112 penaltyInBorrowLShares, uint112 accountPenaltyInBorrowLShares) {
        // slither-disable-next-line unused-return false positive
        return Saturation.accruePenalties(
            satDataGivenPair[msg.sender],
            account,
            externalLiquidity,
            duration,
            allAssetsDepositL,
            allAssetsBorrowL,
            allSharesBorrowL
        );
    }

    /**
     * @notice Calculate the ratio by which the saturation has changed for `account`.
     * @param inputParams The params containing the position of `account`.
     * @param liqSqrtPriceInXInQ72 The liquidation price.
     * @param pairAddress The address of the pair
     * @param account The account for which we are calculating the saturation change ratio.
     * @return ratioNetXBips The ratio representing the change in netX saturation for account.
     * @return ratioNetYBips The ratio representing the change in netY saturation for account.
     */
    function calcSatChangeRatioBips(
        Validation.InputParams memory inputParams,
        uint256 liqSqrtPriceInXInQ72,
        uint256 liqSqrtPriceInYInQ72,
        address pairAddress,
        address account
    ) external view virtual isInitialized returns (uint256 ratioNetXBips, uint256 ratioNetYBips) {
        Saturation.SaturationStruct storage satStruct = satDataGivenPair[pairAddress];
        uint256 desiredSaturationInMAG2 = getNewPositionSaturation(pairAddress, account);
        // slither-disable-next-line unused-return false positive
        return Saturation.calcSatChangeRatioBips(
            satStruct, inputParams, liqSqrtPriceInXInQ72, liqSqrtPriceInYInQ72, account, desiredSaturationInMAG2
        );
    }

    // twap
    // view

    function getObservations(
        address pairAddress
    ) external view returns (GeometricTWAP.Observations memory) {
        return TWAPDataGivenPair[pairAddress];
    }

    /**
     * @notice Configures the interval of long-term observations.
     * @dev This function is used to set the long-term interval between observations for the long-term buffer.
     * @param pairAddress The address of the pair for which the long-term interval is being configured.
     * @param _longTermIntervalConfig The desired duration for each long-term period.
     *      The size is set as a factor of the mid-term interval to ensure a sufficient buffer, requiring
     *      at least 16 * 12 = 192 seconds per period, resulting in a total of ~25 minutes (192 * 8 = 1536 seconds)
     *      for the long-term buffer.
     */
    function configLongTermInterval(address pairAddress, uint24 _longTermIntervalConfig) external onlyOwner {
        GeometricTWAP.configLongTermInterval(TWAPDataGivenPair[pairAddress], _longTermIntervalConfig);
    }

    /**
     * @notice Records a new observation tick value and updates the observation data.
     * @dev This function is used to record new observation data for the contract. It ensures that
     *      the provided tick value is stored appropriately in both mid-term and long-term
     *      observations, updates interval counters, and handles tick cumulative values based
     *      on the current interval configuration. Ensures that this function is called in
     *      chronological order, with increasing timestamps. Returns in case the
     *      provided block timestamp is less than or equal to the last recorded timestamp.
     * @param newTick The new tick value to be recorded, representing the most recent update of
     *      reserveXAssets and reserveYAssets.
     * @param timeElapsed The time elapsed since the last observation.
     * @return bool indicating whether the observation was recorded or not.
     */
    function recordObservation(int16 newTick, uint32 timeElapsed) external isInitialized returns (bool) {
        return GeometricTWAP.recordObservation(TWAPDataGivenPair[msg.sender], newTick, timeElapsed);
    }

    /**
     * @notice Gets the min and max range of tick values from the stored oracle observations.
     * @dev This function calculates the minimum and maximum tick values among three observed ticks:
     *          long-term tick, mid-term tick, and current tick.
     * @param pair The address of the pair for which the tick range is being calculated.
     * @param currentTick The current (most recent) tick based on the current reserves.
     * @param includeLongTermTick Boolean value indicating whether to include the long-term tick in the range.
     * @return minTick The minimum tick value among the three observed ticks.
     * @return maxTick The maximum tick value among the three observed ticks.
     */
    function getTickRange(
        address pair,
        int16 currentTick,
        bool includeLongTermTick
    ) external view virtual returns (int16, int16) {
        return _getTickRange(pair, currentTick, includeLongTermTick);
    }

    function _getTickRange(
        address pair,
        int16 currentTick,
        bool includeLongTermTick
    ) internal view returns (int16, int16) {
        // slither-disable-next-line unused-return false positive.
        return includeLongTermTick
            ? GeometricTWAP.getTickRange(TWAPDataGivenPair[pair], currentTick)
            : GeometricTWAP.getTickRangeWithoutLongTerm(TWAPDataGivenPair[pair]);
    }

    /**
     * @notice Gets the tick value representing the TWAP since the last
     *         lending update and checkpoints the current lending cumulative sum
     *         as `self.lendingCumulativeSum` and the current block timestamp as `self.lastLendingTimestamp`.
     * @dev See `getLendingStateTick` for implementation details which was
     *      separated to allow view access without any state updates.
     * @param timeElapsedSinceUpdate The time elapsed since the last price update.
     * @param timeElapsedSinceLendingUpdate The time elapsed since the last lending update.
     * @return lendingStateTick The tick value representing the TWAP since the last lending update.
     */
    function getLendingStateTickAndCheckpoint(
        uint32 timeElapsedSinceUpdate,
        uint32 timeElapsedSinceLendingUpdate
    ) external isInitialized returns (int16 lendingStateTick, uint256 maxSatInWads) {
        lendingStateTick = GeometricTWAP.getLendingStateTickAndCheckpoint(
            TWAPDataGivenPair[msg.sender], timeElapsedSinceUpdate, timeElapsedSinceLendingUpdate
        );
        maxSatInWads = Saturation.getSatPercentageInWads(satDataGivenPair[msg.sender]);
    }

    /**
     * @dev Retrieves the mid-term tick value based on the stored observations.
     * @param isLongTermBufferInitialized Boolean value which represents whether long-term buffer is filled or not.
     * @return midTermTick The mid-term tick value.
     */
    function getObservedMidTermTick(
        bool isLongTermBufferInitialized
    ) external view returns (int16) {
        return GeometricTWAP.getObservedMidTermTick(TWAPDataGivenPair[msg.sender], isLongTermBufferInitialized);
    }

    /**
     * @dev The function ensures that `newTick` stays within the bounds
     *      determined by `lastTick` and a dynamically calculated factor.
     * @param newTick The proposed new tick value to be adjusted within valid bounds.
     * @return The adjusted tick value constrained within the allowable range.
     */
    function boundTick(
        int16 newTick
    ) external view returns (int16) {
        return GeometricTWAP.boundTick(TWAPDataGivenPair[msg.sender], newTick);
    }

    /**
     * @notice Gets the tick value representing the TWAP since the last lending update.
     * @param newTick The new tick value to be recorded, representing the most recent update of reserveXAssets and reserveYAssets.
     * @param timeElapsedSinceUpdate The time elapsed since the last price update.
     * @param timeElapsedSinceLendingUpdate The time elapsed since the last lending update.
     * @return lendingStateTick The tick value representing the TWAP since the last lending update.
     * @return maxSatInWads The maximum saturation in WADs.
     */
    function getLendingStateTick(
        int56 newTick,
        uint32 timeElapsedSinceUpdate,
        uint32 timeElapsedSinceLendingUpdate
    ) external view returns (int16 lendingStateTick, uint256 maxSatInWads) {
        // slither-disable-next-line unused-return false positive.
        (lendingStateTick,) = GeometricTWAP.getLendingStateTick(
            TWAPDataGivenPair[msg.sender], newTick, timeElapsedSinceUpdate, timeElapsedSinceLendingUpdate, true
        );
        maxSatInWads = Saturation.getSatPercentageInWads(satDataGivenPair[msg.sender]);
    }

    // liquidation

    function liquidationCheckHardPremiums(
        Validation.InputParams memory inputParams,
        address borrower,
        Liquidation.HardLiquidationParams memory hardLiquidationParams,
        uint256 actualRepaidLiquidityAssets
    ) external view returns (bool badDebt) {
        // swap price to use the trailing mid term tick rather than the leading price.
        uint256 inputParamsSqrtPriceMinInQ72 = inputParams.sqrtPriceMinInQ72;
        inputParams.sqrtPriceMinInQ72 = inputParams.sqrtPriceMaxInQ72;
        inputParams.sqrtPriceMaxInQ72 = inputParamsSqrtPriceMinInQ72;

        (uint256 netDebtRepaidInLAssets, uint256 netDepositsSeizedInLAssets, bool netDebtX) = Liquidation
            .calculateNetDebtAndSeizedDeposits(inputParams, hardLiquidationParams, actualRepaidLiquidityAssets);

        (uint256 maxPremiumInBips, bool allAssetsSeized) = Saturation.calculateHardLiquidationPremium(
            satDataGivenPair[msg.sender],
            inputParams,
            borrower,
            netDebtRepaidInLAssets,
            netDepositsSeizedInLAssets,
            netDebtX
        );

        bool maxPremiumExceeded =
            Liquidation.checkHardPremiums(netDebtRepaidInLAssets, netDepositsSeizedInLAssets, maxPremiumInBips);

        badDebt = maxPremiumExceeded && allAssetsSeized;

        // swap min and max price back
        inputParams.sqrtPriceMaxInQ72 = inputParams.sqrtPriceMinInQ72;
        inputParams.sqrtPriceMinInQ72 = inputParamsSqrtPriceMinInQ72;
    }
}
