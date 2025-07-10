// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

import {ITokenFactory} from 'contracts/interfaces/factories/ITokenFactory.sol';
import {IAmmalgamERC20} from 'contracts/interfaces/tokens/IAmmalgamERC20.sol';
import {ERC20DebtLiquidityToken} from 'contracts/tokens/ERC20DebtLiquidityToken.sol';
import {ERC20BaseConfig} from 'contracts/tokens/ERC20Base.sol';

contract ERC20DebtLiquidityTokenFactory is ITokenFactory {
    function createToken(ERC20BaseConfig memory config, address /*asset*/ ) public returns (IAmmalgamERC20) {
        return new ERC20DebtLiquidityToken(config);
    }
}
