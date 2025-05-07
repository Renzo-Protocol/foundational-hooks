// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @notice Shared configuration between scripts
contract Config {
    /// @dev populated with default anvil addresses
    IERC20 constant token0 = IERC20(address(0)); // token 1 ETH
    IERC20 constant token1 =
        IERC20(address(0xbf5495Efe5DB9ce00f80364C8B423567e58d2110)); // ezETH address on mainnet

    // TODO: configure hook contract address
    IHooks hookContract = IHooks(address(0));

    Currency constant currency0 = Currency.wrap(address(token0));
    Currency constant currency1 = Currency.wrap(address(token1));
}
