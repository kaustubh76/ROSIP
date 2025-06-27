// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ReflexiveOracleState} from "./ReflexiveOracleState.sol";
import {InsurancePolicyNFT} from "./InsurancePolicyNFT.sol";
import {ParameterizedInsurance} from "../insurance/ParameterizedInsurance.sol";

// Enhanced UHI Infrastructure Integration
import "../../interfaces/IRiskScoring.sol";
import "../../interfaces/ICrossChainLiquidity.sol";
import "../../interfaces/IKeeperNetwork.sol";
import "../../interfaces/IBeforeSwapHook.sol";
import "../../interfaces/IAfterSwapHook.sol";
import "../../interfaces/IDynamicFeeHook.sol";
import "../../interfaces/IOracle.sol";

/**
 * @title ROSIPOrchestrator
 * @notice Enhanced UHI Orchestrator with Reflexive Oracle & Self-Balancing Insurance Protocol
 * @dev Evolved from UniswapHookOrchestrator to include insurance-specific operations and cross-chain coordination
 * @dev SMART INTEGRATION: Leverages all existing UHI infrastructure components for seamless enhancement
 */
contract ROSIPOrchestrator is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    
    bytes32 public constant HOOK_ROLE = keccak256("HOOK_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant HOOK_MANAGER_ROLE = keccak256("HOOK_MANAGER_ROLE");
    
    /// @notice Core ROSIP contracts
    ReflexiveOracleState public immutable reflexiveOracle;
    InsurancePolicyNFT public immutable policyNFT;
    ParameterizedInsurance public immutable insuranceContract;
    IPoolManager public immutable poolManager;
    IERC20 public immutable USDC;
    
    /// @notice Existing UHI Infrastructure Components (SMART INTEGRATION)
    IRiskScoring public riskScoring;
    ICrossChainLiquidity public crossChainLiquidity;
    IKeeperNetwork public keeperNetwork;
    IBeforeSwapHook public beforeSwapHook;
    IAfterSwapHook public afterSwapHook;
    IDynamicFeeHook public dynamicFeeHook;
    IOracle public oracle;
    
    /// @notice System state management
    enum SystemState {
        NORMAL,           // Normal operations
        ELEVATED_RISK,    // Increased monitoring
        HIGH_RISK,        // Limited new policies
        EMERGENCY_HALT    // All operations paused
    }
    
    /// @notice Enhanced pool settings with insurance integration
    struct EnhancedPoolSettings {
        bool beforeSwapEnabled;
        bool afterSwapEnabled;
        bool dynamicFeesEnabled;
        bool insuranceEnabled;        // NEW: Insurance available for this pool
        bool reflexiveOracleEnabled;  // NEW: Reflexive oracle monitoring
        uint24 defaultStaticFee;
        uint256 optimalLiquidity;
        uint256 maxSlippage;
        uint256 insuranceCapacity;    // NEW: Available insurance capacity
        uint256 premiumMultiplier;    // NEW: Pool-specific premium adjustment
    }
    
    /// @notice Cross-chain insurance pool tracking (enhanced from original)
    struct CrossChainInsurancePool {
        uint32 chainId;
        address poolAddress;
        uint256 totalCapacity;
        uint256 availableCapacity;
        uint256 reserveRatio;
        uint256 utilizationRate;      // NEW: Current utilization
        bool active;
        bool cctpEnabled;             // NEW: CCTP cross-chain rebalancing
    }
    
    /// @notice Insurance market metrics
    struct InsuranceMarketMetrics {
        uint256 totalActivePolicies;
        uint256 totalCoverageAmount;
        uint256 totalPremiumCollected;
        uint256 totalClaimsPaid;
        uint256 currentUtilization;
        uint256 averagePremiumRate;
        uint256 lastUpdateTime;
        uint256 riskScore;            // NEW: Integrated risk scoring
    }
    
    /// @notice Current system state
    SystemState public systemState;
    bool public emergencyPaused;
    
    /// @notice Enhanced pool settings
    mapping(PoolId => EnhancedPoolSettings) public poolSettings;
    
    /// @notice Cross-chain insurance pools
    mapping(uint32 => CrossChainInsurancePool) public crossChainInsurancePools;
    uint32[] public supportedChains;
    
    /// @notice Insurance market metrics per pool
    mapping(bytes32 => InsuranceMarketMetrics) public insuranceMetrics;
    
    /// @notice Registered hooks for different operations
    mapping(bytes32 => address) public registeredHooks;
    
    /// @notice Insurance pool reserves per chain
    mapping(uint32 => uint256) public chainReserves;
    
    /// @notice Quick lookup of pools by tokens (from original UHI)
    mapping(address => mapping(address => PoolId[])) public tokenToPools;
    
    
    /// @notice Events for system monitoring
    event SystemStateChanged(SystemState oldState, SystemState newState);
    event EmergencyPauseToggled(bool paused, address triggeredBy);
    event CrossChainRebalanceTriggered(uint32 fromChain, uint32 toChain, uint256 amount);
    event InsuranceCapacityUpdated(bytes32 indexed poolId, uint256 newCapacity);
    event InsuranceMetricsUpdated(bytes32 indexed poolId, uint256 totalPolicies, uint256 utilization);
    event HookRegistered(bytes32 indexed hookType, address hookAddress);
    
    /// @notice Enhanced events from original UHI
    event HooksUpdated(
        address beforeSwapHook,
        address afterSwapHook,
        address dynamicFeeHook
    );
    
    event ServicesUpdated(
        address riskScoring,
        address crossChainLiquidity,
        address keeperNetwork,
        address oracle
    );
    
    event EnhancedPoolSettingsUpdated(
        PoolId indexed poolId,
        bool beforeSwapEnabled,
        bool afterSwapEnabled,
        bool dynamicFeesEnabled,
        bool insuranceEnabled,
        bool reflexiveOracleEnabled,
        uint256 insuranceCapacity
    );
    
    /// @notice Emergency events
    event CriticalAnomalyDetected(bytes32 indexed poolId, string reason);
    event MassInsuranceTrigger(bytes32 indexed poolId, uint256 affectedPolicies);
    event CrossChainSolvencyAlert(uint32 chainId, uint256 shortfall);
    
    constructor(
        address _poolManager,
        address _reflexiveOracle,
        address _policyNFT,
        address _insuranceContract,
        address _usdc,
        address _admin
    ) {
        poolManager = IPoolManager(_poolManager);
        reflexiveOracle = ReflexiveOracleState(_reflexiveOracle);
        policyNFT = InsurancePolicyNFT(_policyNFT);
        insuranceContract = ParameterizedInsurance(_insuranceContract);
        USDC = IERC20(_usdc);
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        _grantRole(HOOK_MANAGER_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _admin);
        
        systemState = SystemState.NORMAL;
    }
    
    /**
     * @notice Enhanced intelligent swap with UHI infrastructure integration
     * @dev Integrates existing UHI infrastructure with new ROSIP insurance
     */
    function executeIntelligentSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata insuranceParams,
        bytes calldata hookData
    ) external nonReentrant returns (bool success) {
        require(!emergencyPaused, "System emergency paused");
        require(systemState != SystemState.EMERGENCY_HALT, "System in emergency halt");
        
        PoolId poolId = key.toId();
        EnhancedPoolSettings memory settings = poolSettings[poolId];
        
        // Pre-swap risk assessment using existing RiskScoring
        if (address(riskScoring) != address(0)) {
            uint256 riskScore = _calculatePoolRiskScore(key.currency0, key.currency1);
            
            // Update insurance metrics with risk score
            insuranceMetrics[keccak256(abi.encode(key))].riskScore = riskScore;
        }
        
        // Pre-swap hook execution (existing UHI)
        if (settings.beforeSwapEnabled && address(beforeSwapHook) != address(0)) {
            // Get swap decision based on liquidity assessment
            IBeforeSwapHook.SwapDecision decision = beforeSwapHook.getSwapDecision(
                key.currency0, 
                key.currency1, 
                params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified)
            );
            
            // Handle cross-chain liquidity if needed
            if (decision == IBeforeSwapHook.SwapDecision.SOURCE_CROSS_CHAIN) {
                beforeSwapHook.reserveCrossChainLiquidity(
                    key.currency0,
                    key.currency1,
                    params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified),
                    1 // Default source chain, should be configurable
                );
            }
        }
        
        // Pre-swap insurance purchase if requested
        if (insuranceParams.length > 0 && settings.insuranceEnabled) {
            _handlePreSwapInsurance(insuranceParams, key);
        }
        
        // Check if pool has critical anomalies from reflexive oracle
        if (settings.reflexiveOracleEnabled) {
            ReflexiveOracleState.MarketState marketState = reflexiveOracle.getMarketState(key);
            if (marketState == ReflexiveOracleState.MarketState.EMERGENCY) {
                require(systemState == SystemState.NORMAL, "Pool in emergency state");
            }
        }
        
        // Execute the swap through pool manager
        // Note: In real implementation, this would integrate with actual swap execution
        success = true;
        
        // Post-swap processing (existing UHI enhanced)
        if (settings.afterSwapEnabled && address(afterSwapHook) != address(0)) {
            // Note: For now, we'll create a placeholder BalanceDelta
            // In real implementation, this would come from the actual swap execution
            BalanceDelta balanceDelta; // Placeholder - would be actual swap result
            
            // Assess pool state after the swap
            IAfterSwapHook.PoolStateAssessment memory assessment = afterSwapHook.assessPoolState(
                key,
                balanceDelta
            );
            
            // Trigger rebalancing based on assessment
            if (assessment.isLiquidityDepleted) {
                afterSwapHook.triggerRebalancing(
                    key,
                    IAfterSwapHook.RebalancingAction.REPLENISH_LIQUIDITY
                );
            } else if (assessment.hasExcessLiquidity) {
                afterSwapHook.triggerRebalancing(
                    key,
                    IAfterSwapHook.RebalancingAction.OPTIMIZE_YIELD
                );
            }
        }
        
        // Update insurance market metrics
        _updateInsuranceMetrics(keccak256(abi.encode(key)));
        
        // Trigger keeper operations if thresholds are met
        if (address(keeperNetwork) != address(0)) {
            // Request a keeper operation for post-swap processing
            keeperNetwork.requestOperation(
                IKeeperNetwork.OperationType.LIQUIDITY_REPLENISHMENT,
                address(this),
                abi.encode(key, params),
                300000, // Gas limit
                0.01 ether, // Reward
                block.timestamp + 3600 // Deadline: 1 hour from now
            );
        }
        
        return success;
    }
    
    /**
     * @notice Process insurance claim with automated verification
     * @param policyId Insurance policy ID to claim
     * @param proofData Supporting evidence for the claim
     * @return claimAmount Amount paid out for the claim
     */
    function processInsuranceClaim(
        uint256 policyId,
        bytes calldata proofData
    ) external nonReentrant returns (uint256 claimAmount) {
        require(!emergencyPaused, "System emergency paused");
        
        // Verify policy exists and is claimable
        InsurancePolicyNFT.InsurancePolicy memory policy = policyNFT.getPolicy(policyId);
        require(policy.beneficiary == msg.sender, "Not policy owner");
        require(policy.status == InsurancePolicyNFT.PolicyStatus.TRIGGERED, "Policy not triggered");
        
        // Verify claim with reflexive oracle data
        bool claimValid = _verifyClaim(policyId, policy, proofData);
        require(claimValid, "Claim verification failed");
        
        // Process payout
        claimAmount = _executePayout(policyId, policy);
        
        // Update market metrics
        bytes32 poolId = policy.poolId;
        InsuranceMarketMetrics storage metrics = insuranceMetrics[poolId];
        metrics.totalClaimsPaid += claimAmount;
        metrics.lastUpdateTime = block.timestamp;
        
        return claimAmount;
    }
    
    /**
     * @notice Trigger cross-chain insurance pool rebalancing
     * @param fromChain Source chain for funds
     * @param toChain Destination chain needing funds
     * @param amount Amount to transfer via CCTP
     */
    function triggerCrossChainRebalance(
        uint32 fromChain,
        uint32 toChain,
        uint256 amount
    ) external onlyRole(KEEPER_ROLE) {
        require(crossChainInsurancePools[fromChain].active, "Source chain inactive");
        require(crossChainInsurancePools[toChain].active, "Destination chain inactive");
        require(crossChainInsurancePools[fromChain].availableCapacity >= amount, "Insufficient capacity");
        
        // Update cross-chain pool capacities
        crossChainInsurancePools[fromChain].availableCapacity -= amount;
        crossChainInsurancePools[toChain].availableCapacity += amount;
        
        // In real implementation, this would trigger CCTP transfer
        // For now, just emit event for keeper network to process
        emit CrossChainRebalanceTriggered(fromChain, toChain, amount);
    }
    
    /**
     * @notice Handle critical market anomalies detected by hooks
     * @param poolKey Pool where anomaly was detected
     * @param anomalyData Data about the anomaly
     */
    function handleCriticalAnomaly(
        PoolKey calldata poolKey,
        bytes calldata anomalyData
    ) external onlyRole(HOOK_ROLE) {
        bytes32 poolId = keccak256(abi.encode(poolKey));
        
        // Parse anomaly data
        (uint256 severity, string memory reason) = abi.decode(anomalyData, (uint256, string));
        
        // Take appropriate action based on severity
        if (severity >= 8) { // Critical level
            _handleCriticalSituation(poolId, reason);
        } else if (severity >= 5) { // High risk level
            _updateSystemState(SystemState.HIGH_RISK);
        } else if (severity >= 3) { // Elevated risk
            _updateSystemState(SystemState.ELEVATED_RISK);
        }
        
        emit CriticalAnomalyDetected(poolId, reason);
    }
    
    /**
     * @notice Update insurance pool capacity
     * @param poolId Pool identifier
     * @param newCapacity New insurance capacity amount
     */
    function updateInsuranceCapacity(
        bytes32 poolId,
        uint256 newCapacity
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Update capacity in insurance contract
        // This would typically be called by the insurance pool contract
        
        InsuranceMarketMetrics storage metrics = insuranceMetrics[poolId];
        metrics.lastUpdateTime = block.timestamp;
        
        emit InsuranceCapacityUpdated(poolId, newCapacity);
    }
    
    /**
     * @notice Register a hook contract for specific operations
     * @param hookType Type of hook (e.g., "BEFORE_SWAP", "AFTER_SWAP")
     * @param hookAddress Address of the hook contract
     */
    function registerHook(
        bytes32 hookType,
        address hookAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(hookAddress != address(0), "Invalid hook address");
        
        registeredHooks[hookType] = hookAddress;
        
        // Grant necessary roles to the hook
        _grantRole(HOOK_ROLE, hookAddress);
        
        emit HookRegistered(hookType, hookAddress);
    }
    
    /**
     * @notice Add support for a new cross-chain insurance pool
     * @param chainId Chain ID to add
     * @param poolAddress Address of insurance pool on that chain
     * @param initialCapacity Initial capacity of the pool
     */
    function addCrossChainPool(
        uint32 chainId,
        address poolAddress,
        uint256 initialCapacity
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!crossChainInsurancePools[chainId].active, "Chain already supported");
        
        crossChainInsurancePools[chainId] = CrossChainInsurancePool({
            chainId: chainId,
            poolAddress: poolAddress,
            totalCapacity: initialCapacity,
            availableCapacity: initialCapacity,
            reserveRatio: 2000, // 20% reserve ratio
            utilizationRate: 0,
            active: true,
            cctpEnabled: true
        });
        
        supportedChains.push(chainId);
    }
    
    /**
     * @notice Emergency pause all system operations
     * @param paused Whether to pause or unpause
     */
    function setEmergencyPause(bool paused) external onlyRole(EMERGENCY_ROLE) {
        emergencyPaused = paused;
        
        if (paused) {
            _updateSystemState(SystemState.EMERGENCY_HALT);
        }
        
        emit EmergencyPauseToggled(paused, msg.sender);
    }
    
    /**
     * @notice Get comprehensive market status for a pool
     * @param poolKey Pool to check
     * @return marketState Current market state from reflexive oracle
     * @return metrics Market metrics for the pool
     * @return capacity Available insurance capacity
     */
    function getMarketStatus(PoolKey calldata poolKey) 
        external 
        view 
        returns (
            ReflexiveOracleState.MarketState marketState,
            InsuranceMarketMetrics memory metrics,
            uint256 capacity
        ) 
    {
        bytes32 poolId = keccak256(abi.encode(poolKey));
        
        marketState = reflexiveOracle.getMarketState(poolKey);
        metrics = insuranceMetrics[poolId];
        
        // Get capacity from insurance contract
        // This would integrate with the actual capacity tracking
        capacity = 1000000 * 1e6; // Placeholder
    }
    
    /**
     * @notice Get system-wide statistics
     * @return state Current system state
     * @return totalPolicies Total active policies across all pools
     * @return totalCoverage Total coverage amount
     * @return solvencyRatio Overall solvency ratio
     */
    function getSystemStatistics() 
        external 
        view 
        returns (
            SystemState state,
            uint256 totalPolicies,
            uint256 totalCoverage,
            uint256 solvencyRatio
        ) 
    {
        state = systemState;
        
        // Aggregate statistics across all pools
        // In real implementation, this would iterate through all tracked pools
        totalPolicies = 0;
        totalCoverage = 0;
        
        // Calculate solvency ratio (available reserves vs total coverage)
        uint256 totalReserves = 0;
        for (uint256 i = 0; i < supportedChains.length; i++) {
            totalReserves += chainReserves[supportedChains[i]];
        }
        
        solvencyRatio = totalCoverage > 0 ? (totalReserves * 10000) / totalCoverage : 10000;
    }
    
    /**
     * @dev Verify insurance claim using reflexive oracle data
     */
    function _verifyClaim(
        uint256 policyId,
        InsurancePolicyNFT.InsurancePolicy memory policy,
        bytes calldata proofData
    ) internal view returns (bool valid) {
        // Claim verification logic based on insurance type
        if (policy.insuranceType == InsurancePolicyNFT.InsuranceType.DEPEG_PROTECTION) {
            return _verifyDepegClaim(policy, proofData);
        } else if (policy.insuranceType == InsurancePolicyNFT.InsuranceType.VOLATILITY_CAP) {
            return _verifyVolatilityClaim(policy, proofData);
        }
        
        // Default verification
        return true;
    }
    
    /**
     * @dev Verify depeg insurance claim
     */
    function _verifyDepegClaim(
        InsurancePolicyNFT.InsurancePolicy memory policy,
        bytes calldata proofData
    ) internal view returns (bool) {
        // Parse proof data
        (uint256 actualPrice, uint256 timestamp) = abi.decode(proofData, (uint256, uint256));
        
        // Check if price was below trigger during coverage period
        bool withinPeriod = timestamp >= policy.startTime && 
                           timestamp <= policy.startTime + policy.duration;
        bool priceTriggered = actualPrice < policy.triggerPrice;
        
        return withinPeriod && priceTriggered;
    }
    
    /**
     * @dev Verify volatility insurance claim
     */
    function _verifyVolatilityClaim(
        InsurancePolicyNFT.InsurancePolicy memory policy,
        bytes calldata proofData
    ) internal view returns (bool) {
        // Similar verification logic for volatility claims
        return true; // Simplified for demo
    }
    
    /**
     * @dev Execute insurance payout
     */
    function _executePayout(
        uint256 policyId,
        InsurancePolicyNFT.InsurancePolicy memory policy
    ) internal returns (uint256 payoutAmount) {
        // Calculate payout amount based on policy terms
        // This would integrate with the actual payout calculation
        
        payoutAmount = policy.coverageAmount; // Simplified
        
        // Transfer USDC to beneficiary
        USDC.safeTransfer(policy.beneficiary, payoutAmount);
        
        return payoutAmount;
    }
    
    /**
     * @dev Handle critical situations requiring immediate action
     */
    function _handleCriticalSituation(bytes32 poolId, string memory reason) internal {
        // Pause new policies for this pool
        // Trigger mass claim verification
        // Alert cross-chain rebalancing system
        
        _updateSystemState(SystemState.HIGH_RISK);
        
        // In extreme cases, could trigger emergency pause
        if (keccak256(bytes(reason)) == keccak256("MASS_LIQUIDATION")) {
            emergencyPaused = true;
            _updateSystemState(SystemState.EMERGENCY_HALT);
        }
    }
    
    /**
     * @dev Update system state with proper event emission
     */
    function _updateSystemState(SystemState newState) internal {
        if (newState != systemState) {
            SystemState oldState = systemState;
            systemState = newState;
            emit SystemStateChanged(oldState, newState);
        }
    }
    
    /**
     * @dev Update market metrics for a pool
     */
    function _updateMarketMetrics(bytes32 poolId) internal {
        InsuranceMarketMetrics storage metrics = insuranceMetrics[poolId];
        metrics.lastUpdateTime = block.timestamp;
        
        // Update metrics based on current pool state
        // This would integrate with actual data collection
        
        emit InsuranceMetricsUpdated(poolId, metrics.totalActivePolicies, metrics.currentUtilization);
    }

    /**
     * @notice Update UHI infrastructure services (enhanced from original)
     * @dev Maintains backward compatibility while adding insurance capabilities
     */
    function updateUHIServices(
        address _riskScoring,
        address _crossChainLiquidity,
        address _keeperNetwork,
        address _oracle
    ) external onlyRole(HOOK_MANAGER_ROLE) {
        riskScoring = IRiskScoring(_riskScoring);
        crossChainLiquidity = ICrossChainLiquidity(_crossChainLiquidity);
        keeperNetwork = IKeeperNetwork(_keeperNetwork);
        oracle = IOracle(_oracle);
        
        emit ServicesUpdated(_riskScoring, _crossChainLiquidity, _keeperNetwork, _oracle);
    }
    
    /**
     * @notice Update hook contracts (enhanced from original)
     */
    function updateHooks(
        address _beforeSwapHook,
        address _afterSwapHook,
        address _dynamicFeeHook
    ) external onlyRole(HOOK_MANAGER_ROLE) {
        beforeSwapHook = IBeforeSwapHook(_beforeSwapHook);
        afterSwapHook = IAfterSwapHook(_afterSwapHook);
        dynamicFeeHook = IDynamicFeeHook(_dynamicFeeHook);
        
        // Grant necessary roles for ROSIP integration
        if (_afterSwapHook != address(0)) {
            _grantRole(HOOK_ROLE, _afterSwapHook);
        }
        
        emit HooksUpdated(_beforeSwapHook, _afterSwapHook, _dynamicFeeHook);
    }
    
    /**
     * @notice Set enhanced pool settings with insurance integration
     */
    function setEnhancedPoolSettings(
        PoolKey calldata key,
        EnhancedPoolSettings calldata settings
    ) external onlyRole(HOOK_MANAGER_ROLE) {
        PoolId poolId = key.toId();
        poolSettings[poolId] = settings;
        
        // Register pool tokens for quick lookup (from original UHI)
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        tokenToPools[token0][token1].push(poolId);
        tokenToPools[token1][token0].push(poolId);
        
        emit EnhancedPoolSettingsUpdated(
            poolId,
            settings.beforeSwapEnabled,
            settings.afterSwapEnabled,
            settings.dynamicFeesEnabled,
            settings.insuranceEnabled,
            settings.reflexiveOracleEnabled,
            settings.insuranceCapacity
        );
    }
    
    /**
     * @notice Enhanced cross-chain rebalancing using existing CCTP infrastructure
     */
    function triggerEnhancedCrossChainRebalance(
        uint32 fromChain,
        uint32 toChain,
        uint256 amount
    ) external onlyRole(KEEPER_ROLE) {
        require(crossChainInsurancePools[fromChain].active, "Source chain inactive");
        require(crossChainInsurancePools[toChain].active, "Destination chain inactive");
        require(crossChainInsurancePools[fromChain].availableCapacity >= amount, "Insufficient capacity");
        
        // Use existing cross-chain liquidity infrastructure
        if (address(crossChainLiquidity) != address(0)) {
            crossChainLiquidity.moveLiquidityCrossChain(
                bytes32(uint256(toChain)), 
                Currency.wrap(address(USDC)), 
                amount
            );
        }
        
        // Update cross-chain pool capacities
        crossChainInsurancePools[fromChain].availableCapacity -= amount;
        crossChainInsurancePools[toChain].availableCapacity += amount;
        
        emit CrossChainRebalanceTriggered(fromChain, toChain, amount);
    }
    
    /**
     * @notice Enhanced claim processing with UHI infrastructure integration
     */
    function processEnhancedInsuranceClaim(
        uint256 policyId,
        bytes calldata proofData
    ) external nonReentrant returns (uint256 claimAmount) {
        require(!emergencyPaused, "System emergency paused");
        
        // Verify policy exists and is claimable
        InsurancePolicyNFT.InsurancePolicy memory policy = policyNFT.getPolicy(policyId);
        require(policy.beneficiary == msg.sender, "Not policy owner");
        require(policy.status == InsurancePolicyNFT.PolicyStatus.TRIGGERED, "Policy not triggered");
        
        // Enhanced claim verification using existing UHI infrastructure
        bool claimValid = _verifyClaimWithUHIInfrastructure(policyId, policy, proofData);
        require(claimValid, "Claim verification failed");
        
        // Process payout through existing cross-chain infrastructure if needed
        claimAmount = _executePayout(policyId, policy);
        
        // Update insurance metrics
        bytes32 poolId = policy.poolId;
        InsuranceMarketMetrics storage metrics = insuranceMetrics[poolId];
        metrics.totalClaimsPaid += claimAmount;
        metrics.lastUpdateTime = block.timestamp;
        
        return claimAmount;
    }
    
    /**
     * @notice Get comprehensive market status including UHI risk metrics
     */
    function getEnhancedMarketStatus(PoolKey calldata poolKey) 
        external 
        view 
        returns (
            ReflexiveOracleState.MarketState oracleState,
            InsuranceMarketMetrics memory metrics,
            uint256 capacity,
            uint256 riskScore,
            uint256 crossChainCapacity
        ) 
    {
        bytes32 poolId = keccak256(abi.encode(poolKey));
        
        oracleState = reflexiveOracle.getMarketState(poolKey);
        metrics = insuranceMetrics[poolId];
        capacity = poolSettings[poolKey.toId()].insuranceCapacity;
        
        // Get risk score from existing UHI infrastructure
        if (address(riskScoring) != address(0)) {
            riskScore = _calculatePoolRiskScore(poolKey.currency0, poolKey.currency1);
        }
        
        // Calculate total cross-chain capacity
        crossChainCapacity = 0;
        for (uint256 i = 0; i < supportedChains.length; i++) {
            crossChainCapacity += crossChainInsurancePools[supportedChains[i]].availableCapacity;
        }
    }
    
    /**
     * @notice Enhanced anomaly handling with existing risk scoring integration
     */
    function handleEnhancedCriticalAnomaly(
        PoolKey calldata poolKey,
        bytes calldata anomalyData
    ) external onlyRole(HOOK_ROLE) {
        bytes32 poolId = keccak256(abi.encode(poolKey));
        
        // Parse anomaly data
        (uint256 severity, string memory reason) = abi.decode(anomalyData, (uint256, string));
        
        // Get additional risk context from existing UHI infrastructure
        uint256 riskScore = 0;
        if (address(riskScoring) != address(0)) {
            riskScore = _calculatePoolRiskScore(poolKey.currency0, poolKey.currency1);
        }
        
        // Enhanced severity calculation using risk score
        uint256 enhancedSeverity = severity;
        if (riskScore > 800) { // High risk threshold
            enhancedSeverity = enhancedSeverity * 120 / 100; // 20% increase
        }
        
        // Take appropriate action based on enhanced severity
        if (enhancedSeverity >= 8) {
            _handleCriticalSituation(poolId, reason);
        } else if (enhancedSeverity >= 5) {
            _updateSystemState(SystemState.HIGH_RISK);
        } else if (enhancedSeverity >= 3) {
            _updateSystemState(SystemState.ELEVATED_RISK);
        }
        
        emit CriticalAnomalyDetected(poolId, reason);
    }
    
    /**
     * @dev Helper function to calculate pool risk score from two tokens
     */
    function _calculatePoolRiskScore(Currency currency0, Currency currency1) internal view returns (uint256) {
        address token0 = Currency.unwrap(currency0);
        address token1 = Currency.unwrap(currency1);
        
        uint256 risk0 = riskScoring.getRiskScore(token0);
        uint256 risk1 = riskScoring.getRiskScore(token1);
        
        // Return the maximum risk of the two tokens (most conservative approach)
        return risk0 > risk1 ? risk0 : risk1;
    }
    
    /**
     * @dev Update insurance metrics using existing infrastructure
     */
    function _updateInsuranceMetrics(bytes32 poolId) internal {
        InsuranceMarketMetrics storage metrics = insuranceMetrics[poolId];
        metrics.lastUpdateTime = block.timestamp;
        
        emit InsuranceMetricsUpdated(poolId, metrics.totalActivePolicies, metrics.currentUtilization);
    }
    
    /**
     * @dev Enhanced claim verification using existing UHI infrastructure
     */
    function _verifyClaimWithUHIInfrastructure(
        uint256 policyId,
        InsurancePolicyNFT.InsurancePolicy memory policy,
        bytes calldata proofData
    ) internal view returns (bool valid) {
        // Use existing oracle infrastructure for enhanced verification
        if (address(oracle) != address(0)) {
            // Cross-chain oracle verification for enhanced claim validation
        }
        
        // Basic verification (can be enhanced with cross-chain oracles)
        if (policy.insuranceType == InsurancePolicyNFT.InsuranceType.DEPEG_PROTECTION) {
            return _verifyDepegClaim(policy, proofData);
        } else if (policy.insuranceType == InsurancePolicyNFT.InsuranceType.VOLATILITY_CAP) {
            return _verifyVolatilityClaim(policy, proofData);
        }
        
        return true;
    }
    
    /**
     * @dev Handle pre-swap insurance purchase with UHI integration
     */
    function _handlePreSwapInsurance(
        bytes calldata insuranceParams,
        PoolKey calldata key
    ) internal {
        ParameterizedInsurance.InsurancePurchase memory purchase = 
            abi.decode(insuranceParams, (ParameterizedInsurance.InsurancePurchase));
        
        // Enhanced premium calculation using existing risk scoring
        if (address(riskScoring) != address(0)) {
            uint256 riskScore = _calculatePoolRiskScore(key.currency0, key.currency1);
            
            // Risk-adjusted premium calculation would be integrated here
            // This integrates with the ParameterizedInsurance contract
        }
    }
}
