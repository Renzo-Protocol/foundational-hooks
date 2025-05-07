// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {RenzoStability} from "../src/RenzoStability.sol";
import {SqrtPriceLibrary} from "../src/libraries/SqrtPriceLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IRateProvider} from "../src/interfaces/IRateProvider.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

import {Constants} from "./mainnet/Constants.sol";
import {Config} from "./mainnet/Config.sol";

/// @notice Mines the address and deploys the RenzoStability.sol Hook contract
contract RenzoStabilityScript is Script, Constants, Config {
    // TODO: configure 0 values
    // mainnet configurations
    IRateProvider rateProvider = IRateProvider(address(0));
    uint24 minFee = 0;
    uint24 maxFee = 0;
    address ezETH = address(0);

    // Pool configs
    // TODO: configure 0 zero values
    int24 tickSpacing = 1;
    uint160 startingPrice; // starting price in sqrtPriceX96

    function run() public {
        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        );

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(
            POOLMANAGER,
            rateProvider,
            minFee,
            maxFee,
            ezETH
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY,
            flags,
            type(RenzoStability).creationCode,
            constructorArgs
        );

        startingPrice = SqrtPriceLibrary.exchangeRateToSqrtPriceX96(
            rateProvider.getRate()
        );
        // Deploy the hook using CREATE2
        vm.startBroadcast();
        RenzoStability renzoStability = new RenzoStability{salt: salt}(
            POOLMANAGER,
            rateProvider,
            minFee,
            maxFee,
            ezETH
        );
        require(
            address(renzoStability) == hookAddress,
            "RenzoStability: hook address mismatch"
        );

        // log the address of the deployed hook
        console2.log("RenzoStability hook deployed at - ");
        console2.logAddress(address(renzoStability));

        //  deploy pool
        PoolKey memory pool = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(renzoStability))
        });

        POOLMANAGER.initialize(pool, startingPrice);
        vm.stopBroadcast();

        console2.log("poolId of the deployed pool - ");
        console2.logBytes32(PoolId.unwrap(pool.toId()));
    }
}
