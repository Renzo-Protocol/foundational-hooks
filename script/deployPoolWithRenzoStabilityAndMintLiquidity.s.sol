// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {RenzoStability} from "../src/RenzoStability.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SqrtPriceLibrary} from "../src/libraries/SqrtPriceLibrary.sol";
import {IRateProvider} from "../src/interfaces/IRateProvider.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "./unichain/Constants.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Config} from "./unichain/Config.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

contract CreatePoolAndAddLiquidityScript is Script, Constants, Config {
    using CurrencyLibrary for Currency;

    /////////////////////////////////////
    // --- Parameters to Configure --- //
    /////////////////////////////////////

    // TODO: configure 0 values

    // Hook configuration
    IRateProvider rateProvider =
        IRateProvider(0xDb6df3559D2d96985062F0824442550CA7715960);
    uint24 minFee = 100;
    uint24 maxFee = 10_000;
    address ezETH = 0x2416092f143378750bb29b79eD961ab195CcEea5;
    address payable recipient =
        payable(0xAdef586efB3287Da4d7d1cbe15F12E0Be69e0DF0);

    // --- pool configuration --- //
    // fees paid by swappers that accrue to liquidity providers
    uint24 lpFee = LPFeeLibrary.DYNAMIC_FEE_FLAG; // Dynamic fee through hook
    int24 tickSpacing = 1;

    // starting price of the pool, in sqrtPriceX96
    uint160 startingPrice;

    // --- liquidity position configuration --- //
    uint256 public token0Amount = 1e18;
    uint256 public token1Amount;

    // range of the position
    uint256 liquidityPriceRange = 0.01e18; // 1% range where 1e18 is 100%
    int24 tickLower; // must be a multiple of tickSpacing
    int24 tickUpper; // must be a multiple of tickSpacing
    /////////////////////////////////////

    function run() external {
        startingPrice = SqrtPriceLibrary.exchangeRateToSqrtPriceX96(
            rateProvider.getRate()
        );

        token1Amount = (token0Amount * 1e18) / rateProvider.getRate();

        // deployHook;
        hookContract = IHooks(_deployHook());

        // tokens should be sorted
        PoolKey memory pool = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });
        bytes memory hookData = new bytes(0);

        // --------------------------------- //
        // get tick range
        (tickLower, tickUpper) = _getTickRange(pool, startingPrice);
        console2.log("Lower tick for liquidity -> ", tickLower);
        console2.log("Upper tick for liquidity -> ", tickUpper);

        // Converts token amounts to liquidity units
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            startingPrice,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            token0Amount,
            token1Amount
        );

        // slippage limits
        uint256 amount0Max = token0Amount + 1 wei;
        uint256 amount1Max = token1Amount + 1 wei;

        (
            bytes memory actions,
            bytes[] memory mintParams
        ) = _mintLiquidityParams(
                pool,
                tickLower,
                tickUpper,
                liquidity,
                amount0Max,
                amount1Max,
                recipient,
                hookData
            );

        // multicall parameters
        bytes[] memory params = new bytes[](2);

        // initialize pool
        params[0] = abi.encodeWithSelector(
            posm.initializePool.selector,
            pool,
            startingPrice
        );

        // mint liquidity
        params[1] = abi.encodeWithSelector(
            posm.modifyLiquidities.selector,
            abi.encode(actions, mintParams),
            block.timestamp + 60
        );

        // if the pool is an ETH pair, native tokens are to be transferred
        uint256 valueToPass = currency0.isAddressZero() ? amount0Max : 0;

        vm.startBroadcast();
        tokenApprovals(amount0Max, amount1Max);
        vm.stopBroadcast();

        // multicall to atomically create pool & add liquidity
        vm.startBroadcast();
        posm.multicall{value: valueToPass}(params);
        vm.stopBroadcast();

        console2.log("poolId of the deployed pool - ");
        console2.logBytes32(PoolId.unwrap(pool.toId()));
    }

    function _deployHook() internal returns (address) {
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
            CREATE2_DEPLOYER,
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
        vm.stopBroadcast();
        // check that the hook was deployed at the expected address
        require(
            address(renzoStability) == hookAddress,
            "RenzoStability: hook address mismatch"
        );

        // log the address of the deployed hook
        console2.log("RenzoStability hook deployed at - ");
        console2.logAddress(address(renzoStability));
        return address(renzoStability);
    }

    /// @dev helper function for encoding mint liquidity operation
    /// @dev does NOT encode SWEEP, developers should take care when minting liquidity on an ETH pair
    function _mintLiquidityParams(
        PoolKey memory poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        address _recipient,
        bytes memory hookData
    ) internal pure returns (bytes memory, bytes[] memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.SWEEP)
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            poolKey,
            _tickLower,
            _tickUpper,
            liquidity,
            amount0Max,
            amount1Max,
            _recipient,
            hookData
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        params[2] = abi.encode(poolKey.currency0, _recipient);
        return (actions, params);
    }

    function tokenApprovals(
        uint256 _token0Amount,
        uint256 _token1Amount
    ) public {
        if (!currency0.isAddressZero()) {
            token0.approve(address(PERMIT2), _token0Amount);
            // PERMIT2 only supports uint160 for the amount, so we need to cap it
            uint160 _token0PermitAmount = _token0Amount > type(uint160).max
                ? type(uint160).max
                : uint160(_token0Amount);
            PERMIT2.approve(
                address(token0),
                address(posm),
                _token0PermitAmount,
                type(uint48).max
            );
        }
        if (!currency1.isAddressZero()) {
            token1.approve(address(PERMIT2), _token1Amount);
            // PERMIT2 only supports uint160 for the amount, so we need to cap it
            uint160 _token1PermitAmount = _token1Amount > type(uint160).max
                ? type(uint160).max
                : uint160(_token1Amount);
            PERMIT2.approve(
                address(token1),
                address(posm),
                _token1PermitAmount,
                type(uint48).max
            );
        }
    }

    function _getTickRange(
        PoolKey memory poolKey,
        uint160 sqrtPriceX96
    ) internal view returns (int24 _tickLower, int24 _tickUpper) {
        // calculating sqrt(price * 0.9e18/1e18) * Q96 is the same as
        // (sqrt(price) * Q96) * (sqrt(0.9e18/1e18))
        // (sqrt(price) * Q96) * (sqrt(0.9e18) / sqrt(1e18))
        uint160 _sqrtPriceLower = uint160(
            FixedPointMathLib.mulDivDown(
                uint256(sqrtPriceX96),
                FixedPointMathLib.sqrt(1e18 - liquidityPriceRange),
                FixedPointMathLib.sqrt(1e18)
            )
        );

        // calculating sqrt(price * 1.1) * Q96 is the same as
        // (sqrt(price) * Q96) * (sqrt(1.1e18/1e18))
        // (sqrt(price) * Q96) * (sqrt(1.1e18) / sqrt(1e18))
        uint160 _sqrtPriceUpper = uint160(
            FixedPointMathLib.mulDivDown(
                uint256(sqrtPriceX96),
                FixedPointMathLib.sqrt(1e18 + liquidityPriceRange),
                FixedPointMathLib.sqrt(1e18)
            )
        );

        int24 _tickLowerUnaligned = TickMath.getTickAtSqrtPrice(
            _sqrtPriceLower
        );
        int24 _tickUpperUnaligned = TickMath.getTickAtSqrtPrice(
            _sqrtPriceUpper
        );

        // align the ticks to the tick spacing
        int24 _tickSpacing = poolKey.tickSpacing;
        _tickLower = _alignTick(_tickLowerUnaligned, _tickSpacing);
        _tickUpper = _alignTick(_tickUpperUnaligned, _tickSpacing);
    }

    function _alignTick(
        int24 tick,
        int24 _tickSpacing
    ) internal pure returns (int24) {
        return (tick / _tickSpacing) * _tickSpacing;
    }
}
