// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {ERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol';
import {ERC20Plugins} from '@1inch/token-plugins/contracts/ERC20Plugins.sol';
import {IERC20Permit} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol';

import {ITransferValidator} from 'contracts/interfaces/callbacks/ITransferValidator.sol';
import {IAmmalgamERC20} from 'contracts/interfaces/tokens/IAmmalgamERC20.sol';
import {FIRST_DEBT_TOKEN} from 'contracts/interfaces/tokens/ITokenController.sol';
import {IPluginRegistry} from 'contracts/interfaces/tokens/IPluginRegistry.sol';
import {ZERO_ADDRESS} from 'contracts/libraries/constants.sol';

struct ERC20BaseConfig {
    address pair;
    address pluginRegistry;
    string name;
    string symbol;
    uint256 tokenType;
}

abstract contract ERC20Base is ERC20Plugins, Ownable, ERC20Permit, IAmmalgamERC20 {
    ITransferValidator public immutable pair;
    IPluginRegistry private immutable pluginRegistry;

    uint256 public immutable tokenType;

    // slither-disable-next-line uninitialized-state default false is correct initial state
    bool transient transferPenaltyFromPairToBorrower;

    constructor(
        ERC20BaseConfig memory config
    )
        ERC20(config.name, config.symbol)
        ERC20Plugins(10, 500_000) // podsLimit, podCallGasLimit
        ERC20Permit(config.name)
        Ownable(config.pair)
    {
        pair = ITransferValidator(config.pair);
        tokenType = config.tokenType;
        pluginRegistry = IPluginRegistry(config.pluginRegistry);
    }

    // Override the nonces function explicitly for ERC20Permit
    function nonces(
        address owner
    ) public view virtual override(ERC20Permit, IERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }

    function ownerMint(address sender, address to, uint256 assets, uint256 shares) public virtual onlyOwner {}

    function ownerTransfer(address from, address to, uint256 amount) public virtual onlyOwner {}

    function balanceOf(
        address account
    ) public view virtual override(ERC20, ERC20Plugins, IERC20) returns (uint256) {
        return super.balanceOf(account);
    }

    function decimals() public view virtual override(ERC20, IERC20Metadata) returns (uint8) {
        return super.decimals();
    }

    function _update(address from, address to, uint256 amount) internal virtual override(ERC20, ERC20Plugins) {
        super._update(from, to, amount);
        if (from != ZERO_ADDRESS && to != ZERO_ADDRESS && !transferPenaltyFromPairToBorrower) {
            // slither-disable-start uninitialized-local
            address validate;
            address update;
            bool isBorrow;
            // slither-disable-end uninitialized-local
            if (tokenType < FIRST_DEBT_TOKEN) {
                validate = from;
                update = to;
            } else {
                validate = to;
                update = from;
                isBorrow = true;
            }
            pair.validateOnUpdate(validate, update, isBorrow);
        }
    }

    function addPlugin(
        address plugin
    ) public override {
        if (pluginRegistry.isPluginAllowed(plugin)) {
            super._addPlugin(msg.sender, plugin);
        }
    }
}
