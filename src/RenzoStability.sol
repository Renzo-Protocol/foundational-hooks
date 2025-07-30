// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PegStabilityHook} from "./PegStabilityHook.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {SqrtPriceLibrary} from "./libraries/SqrtPriceLibrary.sol";
import {IRateProvider} from "./interfaces/IRateProvider.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import "openzeppelin-contracts/access/Ownable2Step.sol";

/// @title RenzoStability
/// @notice A peg stability hook, for pairs that trade at a 1:1 ratio
/// The hook charges 1 bip for trades moving towards the peg
/// otherwise it charges a linearly-scaled fee based on the distance from the peg
/// i.e. if the pool price is off by 0.05% the fee is 0.05%, if the price is off by 0.50% the fee is 0.5%
/// In the associated pool, Token 0 should be ETH and Token 1 should be ezETH
contract RenzoStability is PegStabilityHook, Ownable2Step {
    using LPFeeLibrary for uint24;

    // Fee bps range where 1_000_000 = 100 %
    uint24 public constant MAX_FEE_BPS = 10_000; // 1% max fee allowed, 1% = 10_000
    uint24 public constant MIN_FEE_BPS = 100; // 0.01% min fee allowed
    uint24 public immutable defaultFeeBps; // default fee bps to charge if the pool price is off by less than maxDynamicFeeBps

    IRateProvider public rateProvider;
    uint24 public maxDynamicFeeBps;
    uint24 public minDynamicFeeBps;

    address public ezETH;

    // Errors
    // @dev error when Invalid zero input params
    error InvalidZeroInput();

    /// @dev Error when custom max fee overflow
    error InvalidMaxFee();

    /// @dev Error when min fee overflow
    error InvalidMinFee();

    /// @dev Error when Invalid Currency in Pool
    error InvalidPoolCurrency();

    /// @dev Error when default fee is not in range
    error InvalidDefaultFee();

    constructor(
        IPoolManager _poolManager,
        IRateProvider _rateProvider,
        uint24 _defaultFeeBps,
        uint24 _minDynamicFee,
        uint24 _maxDynamicFee,
        address _ezETH,
        address _initialOwner
    ) PegStabilityHook(_poolManager) Ownable(_initialOwner) {
        // check for 0 value inputs
        if (
            address(_rateProvider) == address(0) ||
            _minDynamicFee == 0 ||
            _maxDynamicFee == 0 ||
            _defaultFeeBps == 0 ||
            _ezETH == address(0)
        ) revert InvalidZeroInput();

        // check for default fee range, MIN_FEE_BPS <= defaultFeeBps <= maxFee
        if (_defaultFeeBps < MIN_FEE_BPS || _defaultFeeBps > _minDynamicFee)
            revert InvalidDefaultFee();

        // check for maxFee, _maxDynamicFee <= MAX_FEE_BPS
        if (_maxDynamicFee > MAX_FEE_BPS) revert InvalidMaxFee();

        // check for minFee range, MIN_FEE_BPS <= _minDynamicFee <= _maxDynamicFee
        if (_minDynamicFee > _maxDynamicFee || _minDynamicFee < MIN_FEE_BPS)
            revert InvalidMinFee();

        rateProvider = _rateProvider;
        defaultFeeBps = _defaultFeeBps;
        minDynamicFeeBps = _minDynamicFee;
        maxDynamicFeeBps = _maxDynamicFee;
        ezETH = _ezETH;
    }

    function configureFee(
        uint24 _minDynamicFee,
        uint24 _maxDynamicFee
    ) external onlyOwner {
        // check for 0 value inputs
        if (_minDynamicFee == 0 || _maxDynamicFee == 0)
            revert InvalidZeroInput();

        // check for maxFee
        if (_maxDynamicFee > MAX_FEE_BPS) revert InvalidMaxFee();

        // check for minFee range
        if (
            _minDynamicFee > _maxDynamicFee ||
            _minDynamicFee < MIN_FEE_BPS ||
            _minDynamicFee < defaultFeeBps
        ) revert InvalidMinFee();

        minDynamicFeeBps = _minDynamicFee;
        maxDynamicFeeBps = _maxDynamicFee;
    }

    /**
     * @dev Check that the pool key has a dynamic fee.
     * @dev Check that pair is ETH/ezETH
     */
    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24
    ) internal virtual override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        // check that pool pair should be ETH/ezETH
        if (
            Currency.unwrap(key.currency0) != address(0) ||
            Currency.unwrap(key.currency1) != ezETH
        ) revert InvalidPoolCurrency();
        return this.afterInitialize.selector;
    }

    /**
     * @notice  Get the reference price of ezETH
     * @dev     The reference price is stored in the rate provider.  It then converts to 1/ezETH price to match the pool price which is priced in ezETH
     * @return  uint160  .
     */
    function _referencePriceX96(
        Currency,
        Currency
    ) internal view override returns (uint160) {
        // strongly pegged pools, the reference price is from rateProvider
        // returned in sqrtX96 format
        return
            SqrtPriceLibrary.exchangeRateToSqrtPriceX96(rateProvider.getRate());
    }

    /// @dev

    /**
     * @notice  Calculates the price for a swap
     * @dev      linearly scale the swap fee as a tenth of the percentage difference between pool price and reference price
     *           i.e. if pool price is off by 0.05% the fee is 0.05%, if the price is off by 0.50% the fee is 0.5%
     * @param   zeroForOne  True if buying ezETH, false if selling ezETH
     * @param   poolSqrtPriceX96  Current pool price
     * @param   referenceSqrtPriceX96  Reference price obtained from the rate provider
     * @return  uint24  Fee charged to the user - fee in pips, i.e. 3000 = 0.3%
     */
    function _calculateFee(
        Currency,
        Currency,
        bool zeroForOne,
        uint160 poolSqrtPriceX96,
        uint160 referenceSqrtPriceX96
    ) internal view override returns (uint24) {
        // pool price is less than reference price (over pegged), or zeroForOne trades are moving towards the reference price
        if (zeroForOne || poolSqrtPriceX96 < referenceSqrtPriceX96)
            return defaultFeeBps; // minFee bip

        // computes the absolute percentage difference between the pool price and the reference price
        // i.e. 0.005e18 = 0.50% difference between pool price and reference price
        uint256 absPercentageDiffWad = SqrtPriceLibrary
            .absPercentageDifferenceWad(
                uint160(poolSqrtPriceX96),
                referenceSqrtPriceX96
            );

        // convert percentage WAD to pips, i.e. 0.05e18 = 5% = 50_000
        // the fee itself is the percentage difference
        uint24 fee = uint24(absPercentageDiffWad / 1e12);
        if (fee < minDynamicFeeBps) {
            // if % depeg is less than min fee %. charge default fee
            fee = defaultFeeBps;
        } else if (fee > maxDynamicFeeBps) {
            // if % depeg is more than max fee %. charge maxFee
            fee = maxDynamicFeeBps;
        }
        return fee;
    }
}
