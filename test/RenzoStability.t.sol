// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {RenzoStability} from "../src/RenzoStability.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IRateProvider} from "../src/interfaces/IRateProvider.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {SwapFeeEventAsserter} from "./utils/SwapFeeEventAsserter.sol";
import {SqrtPriceLibrary} from "../src/libraries/SqrtPriceLibrary.sol";

contract RenzoStabilityTest is Deployers {
    // Hook configs. TODO: configure
    IRateProvider rateProvider = IRateProvider(makeAddr("rateProvider"));
    uint256 exchangeRate = 1046726277868365115;
    uint24 minFee = 100;
    uint24 maxFee = 10_000;

    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SwapFeeEventAsserter for Vm.Log[];

    RenzoStability hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public virtual {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        // set currency0 as ETH
        currency0 = CurrencyLibrary.ADDRESS_ZERO;

        vm.deal(address(this), 1_000_000e18);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^
                (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(
            manager,
            rateProvider,
            minFee,
            maxFee,
            Currency.unwrap(currency1)
        ); //Add all the necessary constructor arguments from the hook
        deployCodeTo(
            "RenzoStability.sol:RenzoStability",
            constructorArgs,
            flags
        );
        hook = RenzoStability(flags);

        // Create the pool
        key = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(hook)
        );

        // initial price of the pool according to exchange rate
        uint160 initialPrice = SqrtPriceLibrary.exchangeRateToSqrtPriceX96(
            exchangeRate
        );
        poolId = key.toId();
        manager.initialize(key, initialPrice);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint256 liquidityAmount = 10_000e18;
        modifyLiquidityRouter.modifyLiquidity{value: 10230964159999999999457}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidityAmount),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // mock rate provider
        vm.mockCall(
            address(rateProvider),
            abi.encodeWithSelector(IRateProvider.getRate.selector),
            abi.encode(exchangeRate)
        );
    }

    function test_fuzz_swap(bool zeroForOne, bool exactIn) public {
        int256 amountSpecified = exactIn ? -int256(1e18) : int256(1e18);
        uint256 msgValue = zeroForOne ? 2e18 : 0;
        BalanceDelta result = swapNativeInput(
            key,
            zeroForOne,
            amountSpecified,
            ZERO_BYTES,
            msgValue
        );
        if (zeroForOne) {
            exactIn
                ? assertEq(int256(result.amount0()), amountSpecified)
                : assertLt(int256(result.amount0()), amountSpecified);
            exactIn
                ? assertGt(int256(result.amount1()), 0)
                : assertEq(int256(result.amount1()), amountSpecified);
        } else {
            exactIn
                ? assertEq(int256(result.amount1()), amountSpecified)
                : assertLt(int256(result.amount1()), amountSpecified);
            exactIn
                ? assertGt(int256(result.amount0()), 0)
                : assertEq(int256(result.amount0()), amountSpecified);
        }
    }

    /// @dev swaps moving away from peg are charged a high fee
    function test_fuzz_high_fee(bool zeroForOne) public {
        vm.recordLogs();
        BalanceDelta ref = swap(key, zeroForOne, -int256(0.1e18), ZERO_BYTES);
        Vm.Log[] memory recordedLogs = vm.getRecordedLogs();
        recordedLogs.assertSwapFee(minFee);

        // move the pool price to off peg
        swap(key, zeroForOne, -int256(1000e18), ZERO_BYTES);

        // move the pool price away from peg
        vm.recordLogs();
        BalanceDelta highFeeSwap = swap(
            key,
            zeroForOne,
            -int256(0.1e18),
            ZERO_BYTES
        );
        recordedLogs = vm.getRecordedLogs();
        recordedLogs.assertSwapFee(zeroForOne ? minFee : maxFee);

        // output of the second swap is much less
        // highFeeSwap + offset < ref
        zeroForOne
            ? assertLt(highFeeSwap.amount1() + int128(0.001e18), ref.amount1())
            : assertLt(highFeeSwap.amount0() + int128(0.001e18), ref.amount0());
    }

    /// @dev swaps moving towards peg are charged a low fee
    function test_fuzz_low_fee(bool zeroForOne) public {
        // move the pool price to off peg
        swap(key, !zeroForOne, -int256(1000e18), ZERO_BYTES);

        // move the pool price away from peg
        vm.recordLogs();
        BalanceDelta highFeeSwap = swap(
            key,
            !zeroForOne,
            -int256(0.1e18),
            ZERO_BYTES
        );
        Vm.Log[] memory recordedLogs = vm.getRecordedLogs();
        uint24 higherFee = recordedLogs.getSwapFeeFromEvent();

        // swap towards the peg
        vm.recordLogs();
        BalanceDelta lowFeeSwap = swap(
            key,
            zeroForOne,
            -int256(0.1e18),
            ZERO_BYTES
        );
        recordedLogs = vm.getRecordedLogs();
        uint24 lowerFee = recordedLogs.getSwapFeeFromEvent();
        if (zeroForOne) {
            assertGt(higherFee, lowerFee);
            assertEq(lowerFee, minFee); // minFee
        } else {
            assertEq(lowerFee, minFee); // minFee
            assertEq(higherFee, minFee); // minFee
        }

        // output of the second swap is much higher
        // lowFeeSwap > highFeeSwap
        zeroForOne
            ? assertGt(lowFeeSwap.amount1(), highFeeSwap.amount1())
            : assertGt(lowFeeSwap.amount0(), highFeeSwap.amount0());
    }

    function test_fuzz_linear_fee(uint256 amount) public {
        vm.assume(0.5e18 < amount && amount <= 48.75e18);
        // move the pool price to off peg
        swap(key, false, -int256(amount), ZERO_BYTES);

        (uint160 poolSqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 absPercentageDiffWad = SqrtPriceLibrary
            .absPercentageDifferenceWad(
                uint160(poolSqrtPriceX96),
                SqrtPriceLibrary.exchangeRateToSqrtPriceX96(exchangeRate)
            );
        uint24 expectedFee = uint24(absPercentageDiffWad / 1e12);
        // move the pool price away from peg
        vm.recordLogs();
        swap(key, false, -int256(0.1e18), ZERO_BYTES);
        Vm.Log[] memory recordedLogs = vm.getRecordedLogs();
        uint24 swapFee = recordedLogs.getSwapFeeFromEvent();
        assertEq(swapFee, expectedFee);
    }
}
