// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Shared constants used in scripts
contract Constants {
    address constant CREATE2_DEPLOYER =
        address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    /// @dev populated with default anvil addresses
    IPoolManager constant POOLMANAGER =
        IPoolManager(address(0x000000000004444c5dc75cB358380D2e3dE08A90));
    PositionManager constant posm =
        PositionManager(
            payable(address(0xbd216513d74c8cf14cf4747e6aaa6420ff64ee9e))
        );
    IAllowanceTransfer constant PERMIT2 =
        IAllowanceTransfer(address(0x000000000022D473030F116dDEE9F6B43aC78BA3));
}
