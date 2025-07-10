// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';

import {AmmalgamPair} from 'contracts/AmmalgamPair.sol';
import {ISaturationAndGeometricTWAPState} from 'contracts/interfaces/ISaturationAndGeometricTWAPState.sol';
import {IAmmalgamFactory, IPairFactory} from 'contracts/interfaces/factories/IAmmalgamFactory.sol';
import {IFactoryCallback} from 'contracts/interfaces/factories/IFactoryCallback.sol';
import {IAmmalgamERC20} from 'contracts/interfaces/tokens/IAmmalgamERC20.sol';
import {INewTokensFactory} from 'contracts/interfaces/factories/INewTokensFactory.sol';
import {ZERO_ADDRESS} from 'contracts/libraries/constants.sol';

contract AmmalgamFactory is IAmmalgamFactory {
    address public immutable tokenFactory;
    address public immutable pairFactory;
    address public immutable pluginRegistry;
    address public feeTo;
    address public feeToSetter;
    ISaturationAndGeometricTWAPState public immutable saturationAndGeometricTWAPState;

    IFactoryCallback.TokenFactoryConfig private config;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event NewFeeTo(address indexed feeTo);
    event NewFeeToSetter(address indexed feeToSetter);

    error IdenticalAddresses();
    error ZeroAddress();
    error FeeToIsZeroAddress();
    error FeeToSetterIsZeroAddress();
    error PairExists();
    error BytecodeLengthZero();
    error FailedOnDeploy();
    error Forbidden();
    error NewTokensFailed();

    modifier onlyFeeToSetter() {
        if (msg.sender != feeToSetter) {
            revert Forbidden();
        }
        _;
    }

    constructor(
        address _feeToSetter,
        address _tokenFactory,
        address _pairFactory,
        address _pluginRegistry,
        address _saturationAndGeometricTWAPState
    ) {
        if (_feeToSetter == ZERO_ADDRESS) {
            revert FeeToSetterIsZeroAddress();
        }
        if (_tokenFactory == ZERO_ADDRESS || _pairFactory == ZERO_ADDRESS || _pluginRegistry == ZERO_ADDRESS) {
            revert ZeroAddress();
        }
        if (_saturationAndGeometricTWAPState == ZERO_ADDRESS) {
            revert ZeroAddress();
        }
        feeToSetter = _feeToSetter;
        tokenFactory = _tokenFactory;
        pairFactory = _pairFactory;
        pluginRegistry = _pluginRegistry;
        saturationAndGeometricTWAPState = ISaturationAndGeometricTWAPState(_saturationAndGeometricTWAPState);
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        if (tokenA == tokenB) {
            revert IdenticalAddresses();
        }
        (address tokenX, address tokenY) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        if (tokenX == ZERO_ADDRESS) {
            revert ZeroAddress();
        }

        if (getPair[tokenX][tokenY] != ZERO_ADDRESS) {
            // single check is sufficient
            revert PairExists();
        }

        bytes32 salt = keccak256(abi.encodePacked(tokenX, tokenY));

        config = IFactoryCallback.TokenFactoryConfig({tokenX: tokenX, tokenY: tokenY, factory: tokenFactory});

        // This contract must be constructed properly using a known trusted pair
        // factory contract.
        // slither-disable-start controlled-delegatecall,reentrancy-benign,reentrancy-no-eth,reentrancy-events,low-level-calls
        (bool success, bytes memory data) =
            pairFactory.delegatecall(abi.encodeWithSelector(IPairFactory.createPair.selector, salt));
        // slither-disable-end controlled-delegatecall,low-level-calls
        pair = abi.decode(data, (address));
        if (!success || pair == ZERO_ADDRESS) {
            revert FailedOnDeploy();
        }

        delete config;
        // slither-disable-end reentrancy-benign,reentrancy-no-eth
        getPair[tokenX][tokenY] = pair;
        getPair[tokenY][tokenX] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(tokenX, tokenY, pair, allPairs.length);
        // slither-disable-end reentrancy-events
    }

    function getConfig() private view returns (IFactoryCallback.TokenFactoryConfig memory) {
        if (config.tokenX == ZERO_ADDRESS || config.tokenY == ZERO_ADDRESS || config.factory == ZERO_ADDRESS) {
            revert ZeroAddress();
        }
        return config;
    }

    function generateTokensWithinFactory() external returns (IERC20, IERC20, IAmmalgamERC20[6] memory) {
        IFactoryCallback.TokenFactoryConfig memory _config = getConfig();
        // msg.sender == pair
        // address(this) == factory
        IAmmalgamERC20[6] memory tokens =
            INewTokensFactory(tokenFactory).createAllTokens(msg.sender, pluginRegistry, _config.tokenX, _config.tokenY);

        // slither-disable-next-line reentrancy-events
        emit LendingTokensCreated(
            msg.sender,
            address(tokens[0]),
            address(tokens[1]),
            address(tokens[2]),
            address(tokens[3]),
            address(tokens[4]),
            address(tokens[5])
        );

        return (IERC20(_config.tokenX), IERC20(_config.tokenY), tokens);
    }

    function setFeeTo(
        address newFeeTo
    ) external onlyFeeToSetter {
        if (newFeeTo == ZERO_ADDRESS) {
            revert FeeToIsZeroAddress();
        }
        feeTo = newFeeTo;
        emit NewFeeTo(newFeeTo);
    }

    function setFeeToSetter(
        address newFeeToSetter
    ) external onlyFeeToSetter {
        if (newFeeToSetter == ZERO_ADDRESS) {
            revert FeeToSetterIsZeroAddress();
        }
        feeToSetter = newFeeToSetter;
        emit NewFeeToSetter(newFeeToSetter);
    }
}

/**
 * @title PairFactory
 * @notice Implementation of the for the IPairFactory interface.
 */
contract PairFactory is IPairFactory {
    function createPair(
        bytes32 salt
    ) external returns (address pair) {
        // slither-disable-next-line too-many-digits
        bytes memory bytecode = type(AmmalgamPair).creationCode;
        // slither-disable-start assembly
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        // slither-disable-end assembly
    }
}
