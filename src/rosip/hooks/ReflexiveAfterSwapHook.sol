// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ReflexiveOracleState} from "../core/ReflexiveOracleState.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title ReflexiveAfterSwapHook
 * @notice Revolutionary hook that transforms returnDelta into insurance oracle signals
 * @dev This is the core innovation of ROSIP - using swap accounting data as reflexive oracle input
 */
contract ReflexiveAfterSwapHook is BaseHook, AccessControl {
    using PoolIdLibrary for PoolKey;
    
    bytes32 public constant ORCHESTRATOR_ROLE = keccak256("ORCHESTRATOR_ROLE");
    
    /// @notice The reflexive oracle state contract
    ReflexiveOracleState public immutable reflexiveOracle;
    
    /// @notice Expected delta calculation parameters
    struct DeltaExpectation {
        int256 baseExpectedDelta;
        uint256 volatilityFactor;     // Basis points
        uint256 liquidityDepth;       // Pool liquidity depth
        uint256 lastUpdateTime;
    }
    
    /// @notice Statistical data for delta prediction
    struct PoolStatistics {
        int256 averageDelta;          // Rolling average of recent deltas
        uint256 deltaVariance;        // Variance for anomaly detection
        uint256 swapCount;            // Total swaps processed
        uint256 lastStatUpdate;       // Last statistics update time
    }
    
    /// @dev Pool-specific delta expectations
    mapping(PoolId => DeltaExpectation) public deltaExpectations;
    
    /// @dev Pool-specific statistics for pattern recognition
    mapping(PoolId => PoolStatistics) public poolStatistics;
    
    /// @dev Historical deltas for moving averages (last 20 swaps)
    mapping(PoolId => int256[20]) public historicalDeltas;
    mapping(PoolId => uint256) public historicalDeltaIndex;
    
    /// @dev Emergency pause for specific pools
    mapping(PoolId => bool) public poolEmergencyPaused;
    
    /// @notice Events for monitoring and analytics
    event DeltaAnomalyDetected(
        PoolId indexed poolId,
        int256 actualDelta,
        int256 expectedDelta,
        uint256 deviationPercent,
        ReflexiveOracleState.AnomalyLevel severity
    );
    
    event PoolStatisticsUpdated(
        PoolId indexed poolId,
        int256 newAverageDelta,
        uint256 newVariance,
        uint256 swapCount
    );
    
    event EmergencyPoolPause(PoolId indexed poolId, string reason);
    
    constructor(
        IPoolManager _poolManager,
        ReflexiveOracleState _reflexiveOracle,
        address _admin
    ) BaseHook(_poolManager) {
        reflexiveOracle = _reflexiveOracle;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ORCHESTRATOR_ROLE, _admin);
    }
    
    /// @notice Returns the hook's permissions
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,  // THIS IS THE KEY INNOVATION
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
    
    /// @notice Initialize pool statistics after pool creation
    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        
        // Initialize default delta expectations
        deltaExpectations[poolId] = DeltaExpectation({
            baseExpectedDelta: 0,
            volatilityFactor: 1000, // 10% default volatility factor
            liquidityDepth: 0,      // Will be updated on first swap
            lastUpdateTime: block.timestamp
        });
        
        // Initialize statistics
        poolStatistics[poolId] = PoolStatistics({
            averageDelta: 0,
            deltaVariance: 0,
            swapCount: 0,
            lastStatUpdate: block.timestamp
        });
        
        return BaseHook.afterInitialize.selector;
    }
    
    /**
     * @notice THE CORE INNOVATION: Process returnDelta as reflexive oracle input
     * @dev This transforms Uniswap v4's accounting into insurance market intelligence
     */
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        
        // Check for emergency pause
        if (poolEmergencyPaused[poolId]) {
            return (BaseHook.afterSwap.selector, 0);
        }
        
        // Extract actual returnDelta from the swap
        int256 actualDelta = _extractReturnDelta(delta, params);
        
        // Calculate expected delta based on pool statistics and market conditions
        int256 expectedDelta = _calculateExpectedDelta(poolId, params, hookData);
        
        // Update pool statistics with new data
        _updatePoolStatistics(poolId, actualDelta);
        
        // Analyze delta for anomalies
        ReflexiveOracleState.AnomalyLevel anomalyLevel = _analyzeDeltaAnomaly(
            poolId, actualDelta, expectedDelta
        );
        
        // Report to reflexive oracle if significant
        if (anomalyLevel >= ReflexiveOracleState.AnomalyLevel.MINOR_ANOMALY) {
            reflexiveOracle.recordReturnDelta(
                key,
                actualDelta,
                expectedDelta,
                block.timestamp
            );
            
            emit DeltaAnomalyDetected(
                poolId,
                actualDelta,
                expectedDelta,
                _calculateDeviationPercent(actualDelta, expectedDelta),
                anomalyLevel
            );
        }
        
        // Handle emergency situations
        if (anomalyLevel == ReflexiveOracleState.AnomalyLevel.CRITICAL_ANOMALY) {
            _handleCriticalAnomaly(poolId, actualDelta, expectedDelta);
        }
        
        // No delta modification for normal operations
        return (BaseHook.afterSwap.selector, 0);
    }
    
    /**
     * @notice Extract meaningful returnDelta from swap result
     * @dev Analyzes the BalanceDelta to understand the economic impact
     */
    function _extractReturnDelta(
        BalanceDelta delta,
        SwapParams calldata params
    ) internal pure returns (int256 returnDelta) {
        
        // For exact input swaps, focus on output amount variance
        if (params.amountSpecified > 0) {
            returnDelta = delta.amount1(); // Output token delta
        } else {
            returnDelta = delta.amount0(); // Input token delta
        }
        
        // Normalize based on swap direction and magnitude
        if (params.zeroForOne) {
            returnDelta = delta.amount1(); // Getting token1 for token0
        } else {
            returnDelta = delta.amount0(); // Getting token0 for token1
        }
    }
    
    /**
     * @notice Calculate expected delta based on historical patterns and market conditions
     * @dev Uses statistical models and pool-specific factors
     */
    function _calculateExpectedDelta(
        PoolId poolId,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal view returns (int256 expectedDelta) {
        
        DeltaExpectation memory expectation = deltaExpectations[poolId];
        PoolStatistics memory stats = poolStatistics[poolId];
        
        // Start with historical average
        expectedDelta = stats.averageDelta;
        
        // Adjust for swap size (larger swaps may have different patterns)
        int256 swapAmount = params.amountSpecified;
        if (swapAmount != 0) {
            // Scale expectation based on swap size relative to typical swaps
            int256 sizeAdjustment = (swapAmount * 1000) / (swapAmount + 1000000); // Sigmoid-like adjustment
            expectedDelta = (expectedDelta * (1000 + sizeAdjustment)) / 1000;
        }
        
        // Apply volatility factor
        expectedDelta = (expectedDelta * int256(expectation.volatilityFactor)) / 10000;
        
        // Additional adjustments can be added here based on:
        // - Time of day patterns
        // - Market volatility indicators
        // - Pool-specific historical behavior
    }
    
    /**
     * @notice Update statistical models with new swap data
     * @dev Maintains rolling averages and variance calculations
     */
    function _updatePoolStatistics(PoolId poolId, int256 actualDelta) internal {
        PoolStatistics storage stats = poolStatistics[poolId];
        
        // Update historical deltas (circular buffer)
        uint256 index = historicalDeltaIndex[poolId];
        historicalDeltas[poolId][index] = actualDelta;
        historicalDeltaIndex[poolId] = (index + 1) % 20;
        
        // Increment swap count
        stats.swapCount++;
        
        // Update rolling average (exponential moving average)
        if (stats.swapCount == 1) {
            stats.averageDelta = actualDelta;
        } else {
            // EMA with alpha = 0.1 (gives more weight to recent values)
            stats.averageDelta = (stats.averageDelta * 9 + actualDelta) / 10;
        }
        
        // Update variance (simplified calculation)
        int256 deviation = actualDelta - stats.averageDelta;
        uint256 squaredDeviation = uint256(deviation * deviation);
        stats.deltaVariance = (stats.deltaVariance * 9 + squaredDeviation) / 10;
        
        stats.lastStatUpdate = block.timestamp;
        
        emit PoolStatisticsUpdated(poolId, stats.averageDelta, stats.deltaVariance, stats.swapCount);
    }
    
    /**
     * @notice Analyze delta for anomalies using statistical methods
     * @dev Determines severity of deviation from expected patterns
     */
    function _analyzeDeltaAnomaly(
        PoolId poolId,
        int256 actualDelta,
        int256 expectedDelta
    ) internal view returns (ReflexiveOracleState.AnomalyLevel) {
        
        if (expectedDelta == 0) {
            return ReflexiveOracleState.AnomalyLevel.NORMAL;
        }
        
        // Calculate percentage deviation
        uint256 deviationPercent = _calculateDeviationPercent(actualDelta, expectedDelta);
        
        // Use pool-specific variance for adaptive thresholds
        PoolStatistics memory stats = poolStatistics[poolId];
        uint256 varianceMultiplier = 10000; // Base case
        
        if (stats.deltaVariance > 0 && stats.swapCount > 5) {
            // Adjust thresholds based on pool's historical volatility
            varianceMultiplier = (stats.deltaVariance / 1000) + 5000; // Scale factor
        }
        
        // Adaptive thresholds based on pool behavior
        uint256 minorThreshold = (500 * varianceMultiplier) / 10000;     // ~5% base
        uint256 significantThreshold = (1500 * varianceMultiplier) / 10000; // ~15% base
        uint256 criticalThreshold = (3000 * varianceMultiplier) / 10000;    // ~30% base
        
        if (deviationPercent >= criticalThreshold) {
            return ReflexiveOracleState.AnomalyLevel.CRITICAL_ANOMALY;
        } else if (deviationPercent >= significantThreshold) {
            return ReflexiveOracleState.AnomalyLevel.SIGNIFICANT_ANOMALY;
        } else if (deviationPercent >= minorThreshold) {
            return ReflexiveOracleState.AnomalyLevel.MINOR_ANOMALY;
        }
        
        return ReflexiveOracleState.AnomalyLevel.NORMAL;
    }
    
    /**
     * @notice Calculate percentage deviation between actual and expected delta
     */
    function _calculateDeviationPercent(
        int256 actualDelta,
        int256 expectedDelta
    ) internal pure returns (uint256 percent) {
        if (expectedDelta == 0) return 0;
        
        int256 diff = actualDelta - expectedDelta;
        if (diff < 0) diff = -diff; // Absolute value
        
        // Calculate percentage in basis points
        percent = (uint256(diff) * 10000) / uint256(expectedDelta < 0 ? -expectedDelta : expectedDelta);
    }
    
    /**
     * @notice Handle critical anomalies that may indicate market manipulation or system risk
     */
    function _handleCriticalAnomaly(
        PoolId poolId,
        int256 actualDelta,
        int256 expectedDelta
    ) internal {
        // For now, just emit event and potentially pause pool
        // In production, this could trigger:
        // - Increased monitoring
        // - Insurance premium adjustments
        // - Liquidity provider notifications
        // - Emergency insurance payouts
        
        emit EmergencyPoolPause(poolId, "Critical delta anomaly detected");
        
        // Could pause pool if deviation is extreme
        uint256 deviation = _calculateDeviationPercent(actualDelta, expectedDelta);
        if (deviation > 5000) { // 50% deviation
            poolEmergencyPaused[poolId] = true;
        }
    }
    
    /**
     * @notice Emergency pause/unpause for specific pools (admin only)
     */
    function setPoolEmergencyPause(
        PoolId poolId,
        bool paused
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        poolEmergencyPaused[poolId] = paused;
        
        if (paused) {
            emit EmergencyPoolPause(poolId, "Manual emergency pause");
        }
    }
    
    /**
     * @notice Update delta expectations for a pool (orchestrator only)
     */
    function updateDeltaExpectation(
        PoolId poolId,
        DeltaExpectation calldata newExpectation
    ) external onlyRole(ORCHESTRATOR_ROLE) {
        deltaExpectations[poolId] = newExpectation;
        deltaExpectations[poolId].lastUpdateTime = block.timestamp;
    }
    
    /**
     * @notice Get current pool statistics for monitoring
     */
    function getPoolStatistics(PoolId poolId) 
        external 
        view 
        returns (PoolStatistics memory stats) 
    {
        return poolStatistics[poolId];
    }
    
    /**
     * @notice Get recent historical deltas for a pool
     */
    function getHistoricalDeltas(PoolId poolId) 
        external 
        view 
        returns (int256[20] memory deltas, uint256 currentIndex) 
    {
        return (historicalDeltas[poolId], historicalDeltaIndex[poolId]);
    }
}
