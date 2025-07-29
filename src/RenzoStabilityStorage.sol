// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRateProvider} from "./interfaces/IRateProvider.sol";

abstract contract RenzoStabilityStorageV1 {
    IRateProvider public rateProvider;

    uint24 public maxFeeBps;

    uint24 public minFeeBps;

    address public ezETH;
}
