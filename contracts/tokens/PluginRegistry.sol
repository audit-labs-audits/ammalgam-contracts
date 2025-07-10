// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {IPluginRegistry} from 'contracts/interfaces/tokens/IPluginRegistry.sol';

contract PluginRegistry is IPluginRegistry, Ownable {
    mapping(address => bool) allowedPlugins;

    constructor() Ownable(msg.sender) {}

    function updatePlugin(address plugin, bool allowed) public onlyOwner {
        allowedPlugins[plugin] = allowed;
    }

    function isPluginAllowed(
        address plugin
    ) public view onlyOwner returns (bool) {
        return allowedPlugins[plugin];
    }
}
