// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

import {ITokenFactory} from 'contracts/interfaces/factories/ITokenFactory.sol';
import {IAmmalgamERC20} from 'contracts/interfaces/tokens/IAmmalgamERC20.sol';
import {INewTokensFactory} from 'contracts/interfaces/factories/INewTokensFactory.sol';
import {ERC20LiquidityTokenFactory} from 'contracts/factories/ERC20LiquidityTokenFactory.sol';
import {ERC20DebtLiquidityTokenFactory} from 'contracts/factories/ERC20DebtLiquidityTokenFactory.sol';
import {ERC4626DepositTokenFactory} from 'contracts/factories/ERC4626DepositTokenFactory.sol';
import {ERC4626DebtTokenFactory} from 'contracts/factories/ERC4626DebtTokenFactory.sol';
import {
    BORROW_L,
    BORROW_X,
    BORROW_Y,
    DEPOSIT_L,
    DEPOSIT_X,
    DEPOSIT_Y
} from 'contracts/interfaces/tokens/ITokenController.sol';
import {TokenSymbol} from 'contracts/libraries/TokenSymbol.sol';
import {ERC20BaseConfig} from 'contracts/tokens/ERC20Base.sol';
import {ZERO_ADDRESS} from 'contracts/libraries/constants.sol';

contract NewTokensFactory is INewTokensFactory {
    //Note: without immutable key word:  create2 pair will be 0 address and revert FailedOnDeploy
    ITokenFactory private immutable liquidityTokenFactory;
    ITokenFactory private immutable depositTokenFactory;
    ITokenFactory private immutable debtTokenFactory;
    ITokenFactory private immutable liquidityDebtTokenFactory;

    error ERC20TokenFactoryFailed();

    constructor(
        ITokenFactory _liquidityTokenFactory,
        ITokenFactory _depositTokenFactory,
        ITokenFactory _borrowTokenFactory,
        ITokenFactory _liquidityDebtTokenFactory
    ) {
        liquidityTokenFactory = _liquidityTokenFactory;
        depositTokenFactory = _depositTokenFactory;
        debtTokenFactory = _borrowTokenFactory;
        liquidityDebtTokenFactory = _liquidityDebtTokenFactory;
    }

    function createAllTokens(
        address pair,
        address pluginRegistry,
        address tokenX,
        address tokenY
    ) external returns (IAmmalgamERC20[6] memory tokens) {
        string memory symbolX = TokenSymbol.uniSymbol(tokenX);
        string memory symbolY = TokenSymbol.uniSymbol(tokenY);
        string memory symbolXAndY = string.concat(symbolX, '-', symbolY);

        tokens[DEPOSIT_L] = createToken(
            address(liquidityTokenFactory),
            ZERO_ADDRESS,
            ERC20BaseConfig(
                pair,
                pluginRegistry,
                string.concat('Ammalgam Liquidity ', symbolXAndY),
                string.concat('AMG-', symbolXAndY),
                DEPOSIT_L
            )
        );
        tokens[DEPOSIT_X] = createToken(
            address(depositTokenFactory),
            tokenX,
            ERC20BaseConfig(
                pair,
                pluginRegistry,
                string.concat('Ammalgam Deposited ', symbolX),
                string.concat('AMG-', symbolX),
                DEPOSIT_X
            )
        );
        tokens[DEPOSIT_Y] = createToken(
            address(depositTokenFactory),
            tokenY,
            ERC20BaseConfig(
                pair,
                pluginRegistry,
                string.concat('Ammalgam Deposited ', symbolY),
                string.concat('AMG-', symbolY),
                DEPOSIT_Y
            )
        );
        tokens[BORROW_X] = createToken(
            address(debtTokenFactory),
            tokenX,
            ERC20BaseConfig(
                pair,
                pluginRegistry,
                string.concat('Ammalgam Borrowed ', symbolX),
                string.concat('AMGB-', symbolX),
                BORROW_X
            )
        );
        tokens[BORROW_Y] = createToken(
            address(debtTokenFactory),
            tokenY,
            ERC20BaseConfig(
                pair,
                pluginRegistry,
                string.concat('Ammalgam Borrowed ', symbolY),
                string.concat('AMGB-', symbolY),
                BORROW_Y
            )
        );
        tokens[BORROW_L] = createToken(
            address(liquidityDebtTokenFactory),
            ZERO_ADDRESS,
            ERC20BaseConfig(
                pair,
                pluginRegistry,
                string.concat('Ammalgam Borrowed Liquidity ', symbolXAndY),
                string.concat('AMGB-', symbolXAndY),
                BORROW_L
            )
        );
    }

    function createToken(
        address tokenFactory,
        address asset,
        ERC20BaseConfig memory config
    ) private returns (IAmmalgamERC20) {
        // The factory called here is an immutable address stored at
        // construction. A trusted and properly verified deployment of this
        // contract ensures these calls are safe.
        // slither-disable-next-line low-level-calls,controlled-delegatecall
        (bool success, bytes memory data) =
            tokenFactory.delegatecall(abi.encodeWithSelector(ITokenFactory.createToken.selector, config, asset));
        if (!success) {
            revert ERC20TokenFactoryFailed();
        }
        return abi.decode(data, (IAmmalgamERC20));
    }
}
