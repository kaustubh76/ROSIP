// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IAfterSwapHook.sol";
import "../interfaces/ICrossChainLiquidity.sol";
import "../interfaces/IKeeperNetwork.sol";

/**
 * @title AfterSwapHook
 * @notice Hook that handles post-swap rebalancing and yield optimization
 * @dev Analyzes pool state after swaps and triggers keeper operations as needed
 */
contract AfterSwapHook is IAfterSwapHook, BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    
    // Cross-chain liquidity service
    ICrossChainLiquidity public crossChainLiquidity;
    
    // Keeper network
    IKeeperNetwork public keeperNetwork;
    
    // Pool liquidity thresholds
    struct LiquidityThresholds {
        uint256 optimalLevel;       // Optimal liquidity level
        uint256 depletionThreshold; // Below this is considered depleted
        uint256 excessThreshold;    // Above this is considered excess
    }
    
    // Yield opportunity registry
    struct YieldOpportunity {
        uint32 chainId;
        address protocol;
        uint256 apy;
        uint256 minAmount;
        uint256 maxAmount;
        bool active;
    }
    
    // Mapping of poolId to liquidity thresholds
    mapping(PoolId => LiquidityThresholds) public liquidityThresholds;
    
    // Registry of yield opportunities by token and chainId
    mapping(address => mapping(uint32 => YieldOpportunity)) public yieldOpportunities;
    
    // Operation cooldowns to prevent too frequent rebalancing
    mapping(PoolId => mapping(uint8 => uint256)) public lastOperationTime;
    
    // Cooldown period (in seconds)
    uint256 public rebalanceCooldown = 1 hours;
    uint256 public yieldOptimizeCooldown = 1 days;
    
    // Rebalancing efficiency threshold (basis points, 100 = 1%)
    // Minimum improvement required to trigger rebalancing
    uint256 public rebalancingEfficiencyThreshold = 100;
    
    // Pause state
    bool public paused;
    
    // Events
    event PoolStateAssessed(PoolId indexed poolId, bool isLiquidityDepleted, bool hasExcessLiquidity);
    event RebalancingTriggered(PoolId indexed poolId, RebalancingAction action, bytes32 operationId);
    event YieldOpportunityRegistered(address token, uint32 chainId, address protocol, uint256 apy);
    event OptimalLiquidityUpdated(PoolId indexed poolId, uint256 optimalLevel);
    
    /**
     * @notice Constructor
     * @param _poolManager Uniswap V4 pool manager
     * @param _crossChainLiquidity Cross-chain liquidity service
     * @param _keeperNetwork Keeper network
     * @param _owner Contract owner
     */
    constructor(
        IPoolManager _poolManager,
        ICrossChainLiquidity _crossChainLiquidity,
        IKeeperNetwork _keeperNetwork,
        address _owner
    ) BaseHook(_poolManager) Ownable(_owner) {
        crossChainLiquidity = _crossChainLiquidity;
        keeperNetwork = _keeperNetwork;
    }
    
    /**
     * @notice Update service addresses
     * @param _crossChainLiquidity New cross-chain liquidity service
     * @param _keeperNetwork New keeper network
     */
    function updateServices(
        ICrossChainLiquidity _crossChainLiquidity,
        IKeeperNetwork _keeperNetwork
    ) external onlyOwner {
        crossChainLiquidity = _crossChainLiquidity;
        keeperNetwork = _keeperNetwork;
    }
    
    /**
     * @notice Set liquidity thresholds for a pool
     * @param key The pool key
     * @param optimalLevel The optimal liquidity level
     * @param depletionPercentage Percentage below optimal that's considered depleted (basis points)
     * @param excessPercentage Percentage above optimal that's considered excess (basis points)
     */
    function setLiquidityThresholds(
        PoolKey calldata key,
        uint256 optimalLevel,
        uint256 depletionPercentage,
        uint256 excessPercentage
    ) external onlyOwner {
        PoolId poolId = key.toId();
        
        liquidityThresholds[poolId] = LiquidityThresholds({
            optimalLevel: optimalLevel,
            depletionThreshold: (optimalLevel * (10000 - depletionPercentage)) / 10000,
            excessThreshold: (optimalLevel * (10000 + excessPercentage)) / 10000
        });
        
        emit OptimalLiquidityUpdated(poolId, optimalLevel);
    }
    
    /**
     * @notice Register a yield opportunity for a token
     * @param token The token address
     * @param chainId The chain ID where the opportunity exists
     * @param protocol The protocol address offering yield
     * @param apy Annual percentage yield in basis points (100 = 1%)
     * @param minAmount Minimum amount required
     * @param maxAmount Maximum amount allowed
     */
    function registerYieldOpportunity(
        address token,
        uint32 chainId,
        address protocol,
        uint256 apy,
        uint256 minAmount,
        uint256 maxAmount
    ) external onlyOwner {
        yieldOpportunities[token][chainId] = YieldOpportunity({
            chainId: chainId,
            protocol: protocol,
            apy: apy,
            minAmount: minAmount,
            maxAmount: maxAmount,
            active: true
        });
        
        emit YieldOpportunityRegistered(token, chainId, protocol, apy);
    }
    
    /**
     * @notice Update cooldown periods
     * @param _rebalanceCooldown New rebalance cooldown in seconds
     * @param _yieldOptimizeCooldown New yield optimization cooldown in seconds
     */
    function setCooldownPeriods(
        uint256 _rebalanceCooldown,
        uint256 _yieldOptimizeCooldown
    ) external onlyOwner {
        rebalanceCooldown = _rebalanceCooldown;
        yieldOptimizeCooldown = _yieldOptimizeCooldown;
    }
    
    /**
     * @notice Set rebalancing efficiency threshold
     * @param _threshold New threshold in basis points
     */
    function setRebalancingEfficiencyThreshold(uint256 _threshold) external onlyOwner {
        rebalancingEfficiencyThreshold = _threshold;
    }
    
    /**
     * @notice Pause or unpause the hook
     * @param _paused New pause state
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }
    
    /**
     * @inheritdoc IAfterSwapHook
     */
    function assessPoolState(
        PoolKey calldata key,
        BalanceDelta balanceDelta
    ) public view override returns (PoolStateAssessment memory assessment) {
        if (paused) {
            // Return empty assessment when paused
            return PoolStateAssessment({
                isLiquidityDepleted: false,
                hasExcessLiquidity: false,
                optimalLiquidityLevel: 0,
                recommendedAction: RebalancingAction.NONE
            });
        }
        
        PoolId poolId = key.toId();
        LiquidityThresholds memory thresholds = liquidityThresholds[poolId];
        
        // If no thresholds set, use defaults
        if (thresholds.optimalLevel == 0) {
            return PoolStateAssessment({
                isLiquidityDepleted: false,
                hasExcessLiquidity: false,
                optimalLiquidityLevel: 0,
                recommendedAction: RebalancingAction.NONE
            });
        }
        
        // Get current liquidity levels 
        // In a real implementation, we would need to access actual pool reserves
        (uint256 token0Liquidity, uint256 token1Liquidity) = _getCurrentLiquidity(key);
        
        // For swaps that significantly reduce one side of liquidity
        bool token0Depleted = token0Liquidity < thresholds.depletionThreshold;
        bool token1Depleted = token1Liquidity < thresholds.depletionThreshold;
        
        bool token0Excess = token0Liquidity > thresholds.excessThreshold;
        bool token1Excess = token1Liquidity > thresholds.excessThreshold;
        
        // Determine recommended action
        RebalancingAction action = RebalancingAction.NONE;
        
        if (token0Depleted || token1Depleted) {
            action = RebalancingAction.REPLENISH_LIQUIDITY;
        } else if (token0Excess && token1Excess) {
            // If both tokens have excess, optimize for yield
            action = RebalancingAction.OPTIMIZE_YIELD;
        } else if (token0Excess || token1Excess) {
            // If imbalanced (one side excess, one normal), rebalance across pools
            action = RebalancingAction.REBALANCE_ACROSS_POOLS;
        }
        
        return PoolStateAssessment({
            isLiquidityDepleted: token0Depleted || token1Depleted,
            hasExcessLiquidity: token0Excess || token1Excess,
            optimalLiquidityLevel: thresholds.optimalLevel,
            recommendedAction: action
        });
    }
    
    /**
     * @inheritdoc IAfterSwapHook
     */
    function triggerRebalancing(
        PoolKey calldata key,
        RebalancingAction action
    ) external override returns (bytes32 operationId) {
        require(!paused, "Hook is paused");
        require(msg.sender == address(this) || msg.sender == owner(), "Unauthorized");
        
        PoolId poolId = key.toId();
        
        // Check cooldown
        uint256 lastOpTime = lastOperationTime[poolId][uint8(action)];
        uint256 cooldown = (action == RebalancingAction.OPTIMIZE_YIELD) ? 
            yieldOptimizeCooldown : rebalanceCooldown;
            
        require(block.timestamp > lastOpTime + cooldown, "Operation in cooldown");
        
        // Update last operation time
        lastOperationTime[poolId][uint8(action)] = block.timestamp;
        
        // Prepare operation data based on action
        bytes memory callData;
        
        if (action == RebalancingAction.REPLENISH_LIQUIDITY) {
            callData = _prepareReplenishmentOperation(key);
        } else if (action == RebalancingAction.OPTIMIZE_YIELD) {
            callData = _prepareYieldOptimizationOperation(key);
        } else if (action == RebalancingAction.REBALANCE_ACROSS_POOLS) {
            callData = _prepareRebalanceOperation(key);
        } else {
            revert("Invalid action");
        }
        
        // Submit to keeper network
        operationId = keeperNetwork.requestOperation(
            _mapRebalancingActionToOperationType(action),
            address(this),
            callData,
            1000000, // Gas limit
            1 * 10**6, // 1 USDC reward
            block.timestamp + 1 days // Deadline
        );
        
        emit RebalancingTriggered(poolId, action, operationId);
        
        return operationId;
    }
    
    /**
     * @inheritdoc IAfterSwapHook
     */
    function findOptimalYieldOpportunity(
        Currency token,
        uint256 amount
    ) external view override returns (uint32 chainId, address protocol, uint256 expectedAPY) {
        address tokenAddress = Currency.unwrap(token);
        
        uint256 bestAPY = 0;
        uint32 bestChain = 0;
        address bestProtocol = address(0);
        
        // Check local chain first (chainId = 1 in this example)
        YieldOpportunity memory localOpp = yieldOpportunities[tokenAddress][1];
        if (localOpp.active && amount >= localOpp.minAmount && amount <= localOpp.maxAmount) {
            bestAPY = localOpp.apy;
            bestChain = 1;
            bestProtocol = localOpp.protocol;
        }
        
        // Check other chains (up to chainId 100 for this example)
        for (uint32 i = 2; i <= 100; i++) {
            YieldOpportunity memory opp = yieldOpportunities[tokenAddress][i];
            
            if (opp.active && amount >= opp.minAmount && amount <= opp.maxAmount) {
                // Account for cross-chain cost (simplified)
                // In a real implementation, we would calculate the actual CCTP cost
                // and convert it to APY impact
                (uint256 crossChainFee, ) = crossChainLiquidity.estimateCrossChainCost(
                    i, tokenAddress, amount
                );
                
                // Convert fee to APY impact (simplified)
                uint256 feeToBps = (crossChainFee * 10000) / amount;
                
                // Adjust APY for cross-chain cost
                // For simplicity, assuming cross-chain transfers happen twice a year
                // So we multiply the fee by 2 to get annual impact
                uint256 adjustedAPY = opp.apy > feeToBps * 2 ? opp.apy - (feeToBps * 2) : 0;
                
                if (adjustedAPY > bestAPY) {
                    bestAPY = adjustedAPY;
                    bestChain = i;
                    bestProtocol = opp.protocol;
                }
            }
        }
        
        return (bestChain, bestProtocol, bestAPY);
    }
    
    /**
     * @inheritdoc IAfterSwapHook
     */
    function completeDeferredSettlement(
        bytes32 deferredId,
        uint256 recipientAmount
    ) external override returns (bool success) {
        require(msg.sender == address(keeperNetwork), "Only keeper network");
        
        // In a real implementation, this would validate the deferred settlement
        // and transfer the remaining tokens to the recipient
        
        return true;
    }
    
    /**
     * @notice The hook callback for after swap
     * @param sender The swap sender
     * @param key The pool key
     * @param swapData The swap parameters
     * @param delta The balance delta from the swap
     * @param hookData Additional data for the hook
     * @return The hook results
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata swapData,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        if (paused) {
            return (BaseHook.afterSwap.selector, 0);
        }
        
        // Assess pool state
        PoolStateAssessment memory assessment = assessPoolState(key, delta);
        
        // Log assessment
        emit PoolStateAssessed(
            key.toId(), 
            assessment.isLiquidityDepleted, 
            assessment.hasExcessLiquidity
        );
        
        // Trigger rebalancing if needed and cooldown has passed
        if (assessment.recommendedAction != RebalancingAction.NONE) {
            PoolId poolId = key.toId();
            uint8 actionType = uint8(assessment.recommendedAction);
            
            uint256 cooldown = (assessment.recommendedAction == RebalancingAction.OPTIMIZE_YIELD) ? 
                yieldOptimizeCooldown : rebalanceCooldown;
            
            if (block.timestamp > lastOperationTime[poolId][actionType] + cooldown) {
                try this.triggerRebalancing(key, assessment.recommendedAction) returns (bytes32) {
                    // Successfully triggered
                } catch {
                    // Failed to trigger, but we continue anyway
                }
            }
        }
        
        return (BaseHook.afterSwap.selector, 0);
    }
    
    /**
     * @notice Get hooks that this contract supports
     * @return The hook interfaces
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
    
    /**
     * @notice Maps rebalancing action to keeper operation type
     * @param action The rebalancing action
     * @return opType The corresponding keeper operation type
     */
    function _mapRebalancingActionToOperationType(
        RebalancingAction action
    ) internal pure returns (IKeeperNetwork.OperationType opType) {
        if (action == RebalancingAction.REPLENISH_LIQUIDITY) {
            return IKeeperNetwork.OperationType.LIQUIDITY_REPLENISHMENT;
        } else if (action == RebalancingAction.OPTIMIZE_YIELD) {
            return IKeeperNetwork.OperationType.YIELD_OPTIMIZATION;
        } else if (action == RebalancingAction.REBALANCE_ACROSS_POOLS) {
            return IKeeperNetwork.OperationType.LIQUIDITY_REPLENISHMENT; // Uses same operation type
        } else {
            revert("Invalid action");
        }
    }
    
    /**
     * @notice Gets current liquidity for a pool
     * @param key The pool key
     * @return token0Liquidity Token0 liquidity
     * @return token1Liquidity Token1 liquidity
     */
    function _getCurrentLiquidity(
        PoolKey calldata key
    ) internal view returns (uint256 token0Liquidity, uint256 token1Liquidity) {
        // In a real implementation, we would query actual pool reserves
        // For this example, we use a simplified approach
        
        address token0Addr = Currency.unwrap(key.currency0);
        address token1Addr = Currency.unwrap(key.currency1);
        
        if (token0Addr == address(0)) {
            // Native ETH
            token0Liquidity = address(poolManager).balance;
        } else {
            // ERC20 token
            token0Liquidity = IERC20(token0Addr).balanceOf(address(poolManager));
        }
        
        if (token1Addr == address(0)) {
            // Native ETH
            token1Liquidity = address(poolManager).balance;
        } else {
            // ERC20 token
            token1Liquidity = IERC20(token1Addr).balanceOf(address(poolManager));
        }
        
        return (token0Liquidity, token1Liquidity);
    }
    
    /**
     * @notice Prepares call data for liquidity replenishment operation
     * @param key The pool key
     * @return callData The prepared call data
     */
    function _prepareReplenishmentOperation(
        PoolKey calldata key
    ) internal view returns (bytes memory callData) {
        address token0Addr = Currency.unwrap(key.currency0);
        address token1Addr = Currency.unwrap(key.currency1);
        
        // Example implementation: prepare calldata for replenishing liquidity
        // In a real implementation, this would encode logic to:
        // 1. Determine which token needs replenishment
        // 2. Find best cross-chain liquidity source
        // 3. Initiate CCTP transfer
        
        // Simplified: Create call to a hypothetical replenishLiquidityFromCCTP function
        callData = abi.encodeWithSelector(
            bytes4(keccak256("replenishLiquidityFromCCTP(address,address,bytes32)")),
            token0Addr, 
            token1Addr,
            key.toId()
        );
        
        return callData;
    }
    
    /**
     * @notice Prepares call data for yield optimization operation
     * @param key The pool key
     * @return callData The prepared call data
     */
    function _prepareYieldOptimizationOperation(
        PoolKey calldata key
    ) internal view returns (bytes memory callData) {
        address token0Addr = Currency.unwrap(key.currency0);
        address token1Addr = Currency.unwrap(key.currency1);
        
        // Example implementation: prepare calldata for yield optimization
        // In a real implementation, this would encode logic to:
        // 1. Determine excess liquidity amounts
        // 2. Find best yield opportunities across chains
        // 3. Initiate transfers to yield protocols
        
        // Simplified: Create call to a hypothetical optimizeYield function
        callData = abi.encodeWithSelector(
            bytes4(keccak256("optimizeYield(address,address,bytes32)")),
            token0Addr, 
            token1Addr,
            key.toId()
        );
        
        return callData;
    }
    
    /**
     * @notice Prepares call data for rebalancing operation
     * @param key The pool key
     * @return callData The prepared call data
     */
    function _prepareRebalanceOperation(
        PoolKey calldata key
    ) internal view returns (bytes memory callData) {
        address token0Addr = Currency.unwrap(key.currency0);
        address token1Addr = Currency.unwrap(key.currency1);
        
        // Example implementation: prepare calldata for rebalancing
        // In a real implementation, this would encode logic to:
        // 1. Identify imbalanced liquidity
        // 2. Find complementary pools that need the excess token
        // 3. Initiate cross-pool rebalancing
        
        // Simplified: Create call to a hypothetical rebalanceAcrossPools function
        callData = abi.encodeWithSelector(
            bytes4(keccak256("rebalanceAcrossPools(address,address,bytes32)")),
            token0Addr, 
            token1Addr,
            key.toId()
        );
        
        return callData;
    }
}
