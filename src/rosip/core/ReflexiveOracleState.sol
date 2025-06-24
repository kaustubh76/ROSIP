// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title ReflexiveOracleState
 * @notice Core contract that tracks returnDelta anomalies and maintains insurance market state
 * @dev This is the heart of ROSIP - transforms returnDelta from accounting to reflexive oracle signals
 */
contract ReflexiveOracleState is AccessControl {
    bytes32 public constant HOOK_ROLE = keccak256("HOOK_ROLE");
    bytes32 public constant ORACLE_UPDATER_ROLE = keccak256("ORACLE_UPDATER_ROLE");
    
    /// @notice Severity levels for returnDelta anomalies
    enum AnomalyLevel {
        NORMAL,           // < 5% deviation from expected
        MINOR_ANOMALY,    // 5-15% deviation  
        SIGNIFICANT_ANOMALY, // 15-30% deviation
        CRITICAL_ANOMALY     // > 30% deviation
    }
    
    /// @notice Market state for insurance pricing
    enum MarketState {
        STABLE,           // Normal operations
        ELEVATED_RISK,    // Increased volatility detected
        HIGH_RISK,        // Significant anomalies present
        EMERGENCY         // Critical anomalies, halt new policies
    }
    
    /// @notice Analysis result for returnDelta evaluation
    struct ReturnDeltaAnalysis {
        int256 actualDelta;
        int256 expectedDelta;
        uint256 deviationPercentage;
        AnomalyLevel severity;
        uint256 timestamp;
        bytes32 poolId;
    }
    
    /// @notice Market risk state for specific pools/assets
    struct MarketRiskState {
        MarketState currentState;
        uint256 riskMultiplier;      // Basis points (10000 = 1x)
        uint256 lastUpdateTime;
        uint256 anomalyCount24h;
        AnomalyLevel maxAnomaly24h;
    }
    
    /// @notice Historical returnDelta data for pattern analysis
    struct HistoricalDelta {
        int256 delta;
        uint256 timestamp;
        uint256 blockNumber;
    }
    
    /// @dev Pool ID to market risk state mapping
    mapping(bytes32 => MarketRiskState) public marketStates;
    
    /// @dev Pool ID to historical delta data (circular buffer)
    mapping(bytes32 => HistoricalDelta[100]) public historicalDeltas;
    mapping(bytes32 => uint256) public historicalDeltaIndex;
    
    /// @dev Recent anomalies for statistical analysis
    mapping(bytes32 => ReturnDeltaAnalysis[]) public recentAnomalies;
    
    /// @dev Global insurance market parameters
    uint256 public constant PRECISION = 10000;
    uint256 public constant ANOMALY_THRESHOLD_MINOR = 500;    // 5%
    uint256 public constant ANOMALY_THRESHOLD_SIGNIFICANT = 1500; // 15%
    uint256 public constant ANOMALY_THRESHOLD_CRITICAL = 3000;    // 30%
    
    /// @dev Risk multiplier ranges for different market states
    uint256 public constant STABLE_MULTIPLIER = 10000;        // 1.0x
    uint256 public constant ELEVATED_MULTIPLIER = 15000;      // 1.5x
    uint256 public constant HIGH_RISK_MULTIPLIER = 25000;     // 2.5x
    uint256 public constant EMERGENCY_MULTIPLIER = 50000;     // 5.0x
    
    /// @notice Events for monitoring and analytics
    event AnomalyDetected(
        bytes32 indexed poolId,
        AnomalyLevel severity,
        int256 actualDelta,
        int256 expectedDelta,
        uint256 deviation
    );
    
    event MarketStateChanged(
        bytes32 indexed poolId,
        MarketState oldState,
        MarketState newState,
        uint256 newRiskMultiplier
    );
    
    event ReturnDeltaRecorded(
        bytes32 indexed poolId,
        int256 delta,
        uint256 timestamp
    );
    
    constructor(address _admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ORACLE_UPDATER_ROLE, _admin);
    }
    
    /**
     * @notice Record returnDelta from hook and analyze for anomalies
     * @param poolKey The pool where the swap occurred
     * @param actualDelta The actual returnDelta from the swap
     * @param expectedDelta The predicted delta (from simulation or historical average)
     * @param timestamp Block timestamp of the swap
     */
    function recordReturnDelta(
        PoolKey calldata poolKey,
        int256 actualDelta,
        int256 expectedDelta,
        uint256 timestamp
    ) external onlyRole(HOOK_ROLE) {
        bytes32 poolId = keccak256(abi.encode(poolKey));
        
        // Store historical data
        _storeHistoricalDelta(poolId, actualDelta, timestamp);
        
        // Analyze for anomalies
        ReturnDeltaAnalysis memory analysis = _analyzeReturnDelta(
            poolId, actualDelta, expectedDelta, timestamp
        );
        
        // Update market state if significant anomaly detected
        if (analysis.severity >= AnomalyLevel.SIGNIFICANT_ANOMALY) {
            _updateMarketState(poolId, analysis);
        }
        
        emit ReturnDeltaRecorded(poolId, actualDelta, timestamp);
    }
    
    /**
     * @notice Get current risk multiplier for insurance premium calculations
     * @param poolKey The pool to check
     * @return multiplier Risk multiplier in basis points (10000 = 1x)
     */
    function getCurrentRiskMultiplier(PoolKey calldata poolKey) 
        external 
        view 
        returns (uint256 multiplier) 
    {
        bytes32 poolId = keccak256(abi.encode(poolKey));
        MarketRiskState memory state = marketStates[poolId];
        
        // Return current multiplier or default to stable if no data
        return state.riskMultiplier > 0 ? state.riskMultiplier : STABLE_MULTIPLIER;
    }
    
    /**
     * @notice Get current market state for a pool
     * @param poolKey The pool to check
     * @return state Current market state
     */
    function getMarketState(PoolKey calldata poolKey) 
        external 
        view 
        returns (MarketState state) 
    {
        bytes32 poolId = keccak256(abi.encode(poolKey));
        return marketStates[poolId].currentState;
    }
    
    /**
     * @notice Check if new insurance policies should be halted for a pool
     * @param poolKey The pool to check
     * @return halted True if new policies should be halted
     */
    function shouldHaltNewPolicies(PoolKey calldata poolKey) 
        external 
        view 
        returns (bool halted) 
    {
        bytes32 poolId = keccak256(abi.encode(poolKey));
        return marketStates[poolId].currentState == MarketState.EMERGENCY;
    }
    
    /**
     * @notice Get recent anomaly history for a pool
     * @param poolKey The pool to check
     * @return anomalies Array of recent anomalies
     */
    function getRecentAnomalies(PoolKey calldata poolKey) 
        external 
        view 
        returns (ReturnDeltaAnalysis[] memory anomalies) 
    {
        bytes32 poolId = keccak256(abi.encode(poolKey));
        return recentAnomalies[poolId];
    }
    
    /**
     * @notice Manual override for emergency situations
     * @param poolKey The pool to update
     * @param newState New market state to set
     */
    function emergencySetMarketState(
        PoolKey calldata poolKey,
        MarketState newState
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 poolId = keccak256(abi.encode(poolKey));
        MarketRiskState storage state = marketStates[poolId];
        
        MarketState oldState = state.currentState;
        state.currentState = newState;
        state.riskMultiplier = _getMultiplierForState(newState);
        state.lastUpdateTime = block.timestamp;
        
        emit MarketStateChanged(poolId, oldState, newState, state.riskMultiplier);
    }
    
    /**
     * @notice Update market state by pool ID (for testing and direct updates)
     * @param poolId Pool identifier
     * @param newState New market state
     * @param reason Reason for the state change
     */
    function updateMarketStateByPoolId(
        bytes32 poolId,
        MarketState newState,
        string calldata reason
    ) external onlyRole(ORACLE_UPDATER_ROLE) {
        MarketRiskState storage state = marketStates[poolId];
        MarketState oldState = state.currentState;
        
        state.currentState = newState;
        state.riskMultiplier = _getMultiplierForState(newState);
        state.lastUpdateTime = block.timestamp;
        
        emit MarketStateChanged(poolId, oldState, newState, state.riskMultiplier);
    }
    
    /**
     * @notice Get market state by pool ID
     * @param poolId Pool identifier
     * @return Current market state
     */
    function getMarketStateByPoolId(bytes32 poolId) external view returns (MarketState) {
        return marketStates[poolId].currentState;
    }
    
    /**
     * @dev Store returnDelta in circular buffer for historical analysis
     */
    function _storeHistoricalDelta(
        bytes32 poolId,
        int256 delta,
        uint256 timestamp
    ) internal {
        uint256 index = historicalDeltaIndex[poolId];
        historicalDeltas[poolId][index] = HistoricalDelta({
            delta: delta,
            timestamp: timestamp,
            blockNumber: block.number
        });
        
        historicalDeltaIndex[poolId] = (index + 1) % 100;
    }
    
    /**
     * @dev Analyze returnDelta for anomalies using statistical methods
     */
    function _analyzeReturnDelta(
        bytes32 poolId,
        int256 actualDelta,
        int256 expectedDelta,
        uint256 timestamp
    ) internal returns (ReturnDeltaAnalysis memory analysis) {
        
        // Calculate deviation percentage
        uint256 deviation = 0;
        if (expectedDelta != 0) {
            int256 diff = actualDelta - expectedDelta;
            if (diff < 0) diff = -diff; // Absolute value
            deviation = (uint256(diff) * PRECISION) / uint256(expectedDelta < 0 ? -expectedDelta : expectedDelta);
        }
        
        // Determine anomaly severity
        AnomalyLevel severity = AnomalyLevel.NORMAL;
        if (deviation >= ANOMALY_THRESHOLD_CRITICAL) {
            severity = AnomalyLevel.CRITICAL_ANOMALY;
        } else if (deviation >= ANOMALY_THRESHOLD_SIGNIFICANT) {
            severity = AnomalyLevel.SIGNIFICANT_ANOMALY;
        } else if (deviation >= ANOMALY_THRESHOLD_MINOR) {
            severity = AnomalyLevel.MINOR_ANOMALY;
        }
        
        analysis = ReturnDeltaAnalysis({
            actualDelta: actualDelta,
            expectedDelta: expectedDelta,
            deviationPercentage: deviation,
            severity: severity,
            timestamp: timestamp,
            poolId: poolId
        });
        
        // Store significant anomalies
        if (severity >= AnomalyLevel.SIGNIFICANT_ANOMALY) {
            recentAnomalies[poolId].push(analysis);
            
            // Keep only last 50 anomalies
            if (recentAnomalies[poolId].length > 50) {
                for (uint i = 0; i < 49; i++) {
                    recentAnomalies[poolId][i] = recentAnomalies[poolId][i + 1];
                }
                recentAnomalies[poolId].pop();
            }
        }
        
        emit AnomalyDetected(poolId, severity, actualDelta, expectedDelta, deviation);
    }
    
    /**
     * @dev Update market state based on detected anomaly
     */
    function _updateMarketState(
        bytes32 poolId,
        ReturnDeltaAnalysis memory analysis
    ) internal {
        MarketRiskState storage state = marketStates[poolId];
        MarketState oldState = state.currentState;
        
        // Count recent anomalies (last 24 hours)
        uint256 recentAnomalyCount = 0;
        AnomalyLevel maxRecentAnomaly = AnomalyLevel.NORMAL;
        
        uint256 cutoffTime = block.timestamp - 24 hours;
        for (uint i = 0; i < recentAnomalies[poolId].length; i++) {
            if (recentAnomalies[poolId][i].timestamp >= cutoffTime) {
                recentAnomalyCount++;
                if (recentAnomalies[poolId][i].severity > maxRecentAnomaly) {
                    maxRecentAnomaly = recentAnomalies[poolId][i].severity;
                }
            }
        }
        
        // Determine new market state
        MarketState newState = oldState;
        
        if (analysis.severity == AnomalyLevel.CRITICAL_ANOMALY || recentAnomalyCount >= 5) {
            newState = MarketState.EMERGENCY;
        } else if (analysis.severity == AnomalyLevel.SIGNIFICANT_ANOMALY || recentAnomalyCount >= 3) {
            newState = MarketState.HIGH_RISK;
        } else if (recentAnomalyCount >= 2) {
            newState = MarketState.ELEVATED_RISK;
        } else if (recentAnomalyCount == 0 && block.timestamp - state.lastUpdateTime > 4 hours) {
            newState = MarketState.STABLE; // Cooldown to stable state
        }
        
        // Update state
        state.currentState = newState;
        state.riskMultiplier = _getMultiplierForState(newState);
        state.lastUpdateTime = block.timestamp;
        state.anomalyCount24h = recentAnomalyCount;
        state.maxAnomaly24h = maxRecentAnomaly;
        
        if (newState != oldState) {
            emit MarketStateChanged(poolId, oldState, newState, state.riskMultiplier);
        }
    }
    
    /**
     * @dev Get risk multiplier for a given market state
     */
    function _getMultiplierForState(MarketState state) internal pure returns (uint256) {
        if (state == MarketState.EMERGENCY) return EMERGENCY_MULTIPLIER;
        if (state == MarketState.HIGH_RISK) return HIGH_RISK_MULTIPLIER;
        if (state == MarketState.ELEVATED_RISK) return ELEVATED_MULTIPLIER;
        return STABLE_MULTIPLIER;
    }
}
