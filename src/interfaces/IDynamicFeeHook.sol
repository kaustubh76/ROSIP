// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/**
 * @title IDynamicFeeHook
 * @notice Interface for the dynamic fee hook that calculates multi-dimensional fees
 * @dev This interface defines the methods for a hook that can dynamically adjust swap fees
 */
interface IDynamicFeeHook {
    /**
     * @notice Fee component breakdown structure
     * @param baseFee The standard base fee from pool configuration
     * @param volatilityFee Fee component based on market volatility
     * @param riskPremium Fee component based on asset risk scores
     * @param crossChainCost Fee component for cross-chain operations
     * @param liquidityUrgency Fee component based on liquidity depletion
     * @param complianceCost Fee component for compliance/regulatory requirements
     * @param totalFee The sum of all fee components
     */
    struct FeeComponents {
        uint24 baseFee;
        uint24 volatilityFee;
        uint24 riskPremium;
        uint24 crossChainCost;
        uint24 liquidityUrgency;
        uint24 complianceCost;
        uint24 totalFee;
    }
    
    /**
     * @notice Calculates the dynamic fee for a swap
     * @param key The pool key
     * @param tokenIn The input token
     * @param tokenOut The output token
     * @param amountIn The input amount
     * @return fee The calculated dynamic fee
     */
    function calculateDynamicFee(
        PoolKey calldata key,
        Currency tokenIn,
        Currency tokenOut,
        uint256 amountIn
    ) external view returns (uint24 fee);
    
    /**
     * @notice Returns the detailed breakdown of fee components
     * @param key The pool key
     * @param tokenIn The input token
     * @param tokenOut The output token
     * @param amountIn The input amount
     * @return components The fee component breakdown
     */
    function getFeeComponents(
        PoolKey calldata key,
        Currency tokenIn,
        Currency tokenOut,
        uint256 amountIn
    ) external view returns (FeeComponents memory components);
    
    /**
     * @notice Gets the fee distribution for a swap
     * @param fee The total fee amount
     * @return lpShare Percentage allocated to LPs (in basis points, 10000 = 100%)
     * @return crossChainShare Percentage for cross-chain operations
     * @return insuranceShare Percentage for risk insurance fund
     * @return protocolShare Percentage for protocol treasury
     */
    function getFeeDistribution(uint24 fee) external view returns (
        uint16 lpShare,
        uint16 crossChainShare,
        uint16 insuranceShare,
        uint16 protocolShare
    );
    
    /**
     * @notice Updates the volatility measurement for a token pair
     * @param token0 The first token
     * @param token1 The second token
     * @param volatility The new volatility value (in basis points, 10000 = 100%)
     * @param window The time window in seconds (e.g., 86400 for 24h volatility)
     */
    function updateVolatilityMeasurement(
        Currency token0,
        Currency token1,
        uint256 volatility,
        uint32 window
    ) external;
}