// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.28;

import {ExcessivelySafeCall} from 'lib/ExcessivelySafeCall/src/ExcessivelySafeCall.sol';

library TokenSymbol {
    /**
     * @dev adapted from https://github.com/1inch/mooniswap/blob/master/contracts/libraries/UniERC20.sol
     * @param token address of the token
     */
    function uniSymbol(
        address token
    ) internal view returns (string memory) {
        (bool success, bytes memory data) = ExcessivelySafeCall.excessivelySafeStaticCall(
            token,
            20_000,
            96, // Maximum number of bytes to copy
            abi.encodeWithSignature('symbol()')
        );

        if (!success) {
            (success, data) = ExcessivelySafeCall.excessivelySafeStaticCall(
                token,
                20_000,
                96, // Maximum number of bytes to copy
                abi.encodeWithSignature('SYMBOL()')
            );
        }

        if (success && data.length == 96) {
            (uint256 offset, uint256 len) = abi.decode(data, (uint256, uint256));
            if (offset == 0x20 && len > 0) {
                // Use min function to ensure the symbol length does not exceed 32
                len = min(len, 32);
                bytes memory symbolData = new bytes(len);
                assembly {
                    // Copy the symbol data directly to the new bytes array
                    mstore(add(symbolData, 32), mload(add(data, 96)))
                }
                return string(symbolData);
            }
        }

        if (success && data.length == 32) {
            uint256 len = 0;
            while (len < data.length && data[len] >= 0x20 && data[len] <= 0x7E) {
                len++;
            }

            if (len > 0) {
                bytes memory result = new bytes(len);
                for (uint256 i = 0; i < len; i++) {
                    result[i] = data[i];
                }
                return string(result);
            }
        }

        return toHex(token);
    }

    function toHex(
        address account
    ) internal pure returns (string memory) {
        return _toHex(abi.encodePacked(account));
    }

    function _toHex(
        bytes memory data
    ) private pure returns (string memory) {
        bytes memory str = new bytes(2 + data.length * 2);
        str[0] = '0';
        str[1] = 'x';
        uint256 j = 2;
        for (uint256 i = 0; i < data.length; i++) {
            uint256 a = uint8(data[i]) >> 4;
            uint256 b = uint8(data[i]) & 0x0f;
            // slither-disable-start divide-before-multiply
            str[j++] = bytes1(uint8(a + 48 + (a / 10) * 39));
            str[j++] = bytes1(uint8(b + 48 + (b / 10) * 39));
            // slither-disable-end divide-before-multiply
        }

        return string(str);
    }

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
