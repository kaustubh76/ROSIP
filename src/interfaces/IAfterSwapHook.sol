// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/**
 * @title IAfterSwapHook
 * @notice Interface for the afterSwap hook that handles post-trade rebalancing and yield optimization
 */
interface IAfterSwapHook {
    /**
     * @notice Rebalancing actions that can be triggered after a swap
     */
    enum RebalancingAction {
        NONE,
        REPLENISH_LIQUIDITY,
        OPTIMIZE_YIELD,
        REBALANCE_ACROSS_POOLS
    }
    
    /**
     * @notice Pool state assessment
     * @param isLiquidityDepleted Whether the pool's liquidity is significantly depleted
     * @param hasExcessLiquidity Whether the pool has excess liquidity that could be optimized
     * @param optimalLiquidityLevel The calculated optimal liquidity level
     * @param recommendedAction The recommended rebalancing action
     */
    struct PoolStateAssessment {
        bool isLiquidityDepleted;
        bool hasExcessLiquidity;
        uint256 optimalLiquidityLevel;
        RebalancingAction recommendedAction;
    }
    
    /**
     * @notice Assesses the pool state after a swap
     * @param key The pool key
     * @param balanceDelta The balance change from the swap
     * @return assessment The pool state assessment
     */
    function assessPoolState(
        PoolKey calldata key,
        BalanceDelta balanceDelta
    ) external view returns (PoolStateAssessment memory assessment);
    
    /**
     * @notice Triggers a rebalancing operation via the keeper network
     * @param key The pool key
     * @param action The rebalancing action to perform
     * @return operationId The ID of the keeper operation
     */
    function triggerRebalancing(
        PoolKey calldata key,
        RebalancingAction action
    ) external returns (bytes32 operationId);
    
    /**
     * @notice Finds the optimal yield opportunity for excess liquidity
     * @param token The token to optimize
     * @param amount The amount available
     * @return chainId The target chain ID with best yield
     * @return protocol The yield protocol address
     * @return expectedAPY The expected APY in basis points
     */
    function findOptimalYieldOpportunity(
        Currency token,
        uint256 amount
    ) external view returns (uint32 chainId, address protocol, uint256 expectedAPY);
    
    /**
     * @notice Completes a deferred settlement
     * @param deferredId The unique ID for the deferred settlement
     * @param recipientAmount The actual amount being sent to recipient
     * @return success True if the settlement was completed successfully
     */
    function completeDeferredSettlement(
        bytes32 deferredId,
        uint256 recipientAmount
    ) external returns (bool success);
}
