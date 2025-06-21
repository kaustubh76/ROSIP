// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/**
 * @title IBeforeSwapHook
 * @notice Interface for the beforeSwap hook that handles real-time liquidity assessment and risk scoring
 */
interface IBeforeSwapHook {
    /**
     * @notice Decision options for the beforeSwap hook
     * @param EXECUTE_LOCALLY Execute the swap using local liquidity
     * @param SOURCE_CROSS_CHAIN Pause swap and source liquidity from another chain
     * @param ADJUST_PRICE Execute with price adjustment for cross-chain costs
     * @param DEFER_SETTLEMENT Execute partially and defer remainder settlement
     */
    enum SwapDecision {
        EXECUTE_LOCALLY,
        SOURCE_CROSS_CHAIN,
        ADJUST_PRICE,
        DEFER_SETTLEMENT
    }
    
    /**
     * @notice Returns the current decision for a swap based on liquidity and risk conditions
     * @param tokenIn The input token
     * @param tokenOut The output token
     * @param amountIn The input amount
     * @return decision The swap decision
     */
    function getSwapDecision(
        Currency tokenIn,
        Currency tokenOut,
        uint256 amountIn
    ) external view returns (SwapDecision decision);
    
    /**
     * @notice Calculates the adjusted price for a swap considering cross-chain costs
     * @param tokenIn The input token
     * @param tokenOut The output token
     * @param amountIn The input amount
     * @param baseFee The base swap fee
     * @return adjustedFee The adjusted fee including risk premium
     */
    function calculateAdjustedFee(
        Currency tokenIn,
        Currency tokenOut,
        uint256 amountIn,
        uint24 baseFee
    ) external view returns (uint24 adjustedFee);
    
    /**
     * @notice Reserves a cross-chain liquidity transfer for a swap
     * @param tokenIn The input token
     * @param tokenOut The output token
     * @param amountIn The input amount
     * @param sourceChain The source chain ID
     * @return messageHash The CCTP message hash for the reserved transfer
     */
    function reserveCrossChainLiquidity(
        Currency tokenIn,
        Currency tokenOut,
        uint256 amountIn,
        uint32 sourceChain
    ) external returns (bytes32 messageHash);
    
    /**
     * @notice Creates a deferred settlement for a swap
     * @param tokenIn The input token
     * @param tokenOut The output token
     * @param amountIn The input amount
     * @param amountOutMinimum The minimum output amount
     * @param recipient The recipient address
     * @return deferredId The unique ID for the deferred settlement
     * @return partialAmountOut The partial amount that can be settled immediately
     */
    function createDeferredSettlement(
        Currency tokenIn,
        Currency tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient
    ) external returns (bytes32 deferredId, uint256 partialAmountOut);
}
