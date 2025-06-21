// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import "../interfaces/IDynamicFeeHook.sol";
import "../interfaces/IRiskScoring.sol";
import "../interfaces/ICrossChainLiquidity.sol";

/**
 * @title DynamicFeeHook
 * @notice Implementation of a dynamic fee calculator for Uniswap V4 pools
 * @dev This hook calculates fees based on multiple dimensions: volatility, risk, liquidity, and cross-chain costs
 */
contract DynamicFeeHook is IDynamicFeeHook, BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    
    // Risk scoring service
    IRiskScoring public riskScoring;
    
    // Cross-chain liquidity service
    ICrossChainLiquidity public crossChainLiquidity;
    
    // Volatility tracking
    struct VolatilityData {
        uint256 volatility24h;   // 24-hour volatility (in basis points, 10000 = 100%)
        uint256 volatility1h;    // 1-hour volatility
        uint256 lastUpdate;      // Timestamp of last update
    }
    
    // Liquidity depth tracking
    struct LiquidityData {
        uint256 optimalLiquidity;    // Optimal liquidity level
        uint256 currentLiquidity;    // Current liquidity level
        uint256 lastUpdate;          // Timestamp of last update
    }
    
    // Regulatory compliance settings
    struct ComplianceSettings {
        bool enhancedDueDiligence;   // Whether EDD is required
        uint24 complianceFee;        // Additional fee for compliance
        bool active;                 // Whether compliance fee is active
    }
    
    // Fee weight configuration (out of 10000)
    struct FeeWeights {
        uint16 volatilityWeight;     // Weight for volatility component
        uint16 riskWeight;           // Weight for risk premium component
        uint16 crossChainWeight;     // Weight for cross-chain cost component
        uint16 liquidityWeight;      // Weight for liquidity urgency component
        uint16 complianceWeight;     // Weight for compliance cost component
    }
    
    // Fee distribution configuration (out of 10000)
    struct FeeDistribution {
        uint16 lpShare;              // Share for liquidity providers
        uint16 crossChainShare;      // Share for cross-chain operations
        uint16 insuranceShare;       // Share for insurance fund
        uint16 protocolShare;        // Share for protocol treasury
    }
    
    // Maximum fee caps
    struct FeeCaps {
        uint24 maxVolatilityFee;     // Max fee for volatility
        uint24 maxRiskFee;           // Max fee for risk premium
        uint24 maxCrossChainFee;     // Max fee for cross-chain cost
        uint24 maxLiquidityFee;      // Max fee for liquidity urgency
        uint24 maxComplianceFee;     // Max fee for compliance
        uint24 absoluteMaxFee;       // Absolute maximum total fee
    }
    
    // Pool specific base fees
    mapping(PoolId => uint24) public poolBaseFees;
    
    // Volatility data by token pair
    mapping(address => mapping(address => VolatilityData)) public volatilityData;
    
    // Liquidity data by pool
    mapping(PoolId => LiquidityData) public liquidityData;
    
    // Compliance settings by token
    mapping(address => ComplianceSettings) public complianceSettings;
    
    // Fee weights (defaults)
    FeeWeights public feeWeights;
    
    // Fee distribution (defaults)
    FeeDistribution public feeDistribution;
    
    // Fee caps
    FeeCaps public feeCapSettings;
    
    // Default base fee (used if pool specific fee not set)
    uint24 public defaultBaseFee = 500; // 0.05% (in 100ths of a bip)
    
    /**
     * @notice Returns the fee caps structure for testing
     */
    function feeCaps() external view returns (FeeCaps memory) {
        return feeCapSettings;
    }
    
    // Pause state
    bool public paused;
    
    // Events
    event DynamicFeeCalculated(PoolId indexed poolId, uint24 fee, Currency tokenIn, Currency tokenOut);
    event VolatilityUpdated(address indexed token0, address indexed token1, uint256 volatility, uint32 window);
    event LiquidityDataUpdated(PoolId indexed poolId, uint256 optimalLiquidity, uint256 currentLiquidity);
    event FeeWeightsUpdated(uint16 volatilityWeight, uint16 riskWeight, uint16 crossChainWeight, uint16 liquidityWeight, uint16 complianceWeight);
    event FeeDistributionUpdated(uint16 lpShare, uint16 crossChainShare, uint16 insuranceShare, uint16 protocolShare);
    event ComplianceSettingsUpdated(address indexed token, bool enhancedDueDiligence, uint24 complianceFee, bool active);
    
    /**
     * @notice Constructor
     * @param _poolManager Uniswap V4 pool manager
     * @param _riskScoring Risk scoring service
     * @param _crossChainLiquidity Cross-chain liquidity service
     * @param _owner Contract owner
     */
    constructor(
        IPoolManager _poolManager,
        IRiskScoring _riskScoring,
        ICrossChainLiquidity _crossChainLiquidity,
        address _owner
    ) BaseHook(_poolManager) Ownable(_owner) {
        riskScoring = _riskScoring;
        crossChainLiquidity = _crossChainLiquidity;
        
        // Set default fee weights (total must be 10000)
        feeWeights = FeeWeights({
            volatilityWeight: 3000,    // 30%
            riskWeight: 2000,          // 20%
            crossChainWeight: 1500,    // 15%
            liquidityWeight: 2500,     // 25%
            complianceWeight: 1000     // 10%
        });
        
        // Set default fee distribution (total must be 10000)
        feeDistribution = FeeDistribution({
            lpShare: 7000,            // 70%
            crossChainShare: 1000,    // 10%
            insuranceShare: 1000,     // 10%
            protocolShare: 1000       // 10%
        });
        
        // Set default fee caps
        feeCapSettings = FeeCaps({
            maxVolatilityFee: 5000,   // 0.5%
            maxRiskFee: 3000,         // 0.3%
            maxCrossChainFee: 2000,   // 0.2%
            maxLiquidityFee: 4000,    // 0.4%
            maxComplianceFee: 1000,   // 0.1%
            absoluteMaxFee: 10000     // 1.0% absolute max
        });
    }
    
    /**
     * @notice Update service addresses
     * @param _riskScoring New risk scoring service
     * @param _crossChainLiquidity New cross-chain liquidity service
     */
    function updateServices(
        IRiskScoring _riskScoring,
        ICrossChainLiquidity _crossChainLiquidity
    ) external onlyOwner {
        riskScoring = _riskScoring;
        crossChainLiquidity = _crossChainLiquidity;
    }
    
    /**
     * @notice Set pool base fee
     * @param key Pool key
     * @param baseFee Base fee (in 100ths of a bip)
     */
    function setPoolBaseFee(PoolKey calldata key, uint24 baseFee) external onlyOwner {
        poolBaseFees[key.toId()] = baseFee;
    }
    
    /**
     * @notice Set default base fee
     * @param fee Default base fee
     */
    function setDefaultBaseFee(uint24 fee) external onlyOwner {
        defaultBaseFee = fee;
    }
    
    /**
     * @notice Update fee weights
     * @param volatility Weight for volatility component
     * @param risk Weight for risk premium component
     * @param crossChain Weight for cross-chain cost component
     * @param liquidity Weight for liquidity urgency component
     * @param compliance Weight for compliance cost component
     */
    function setFeeWeights(
        uint16 volatility,
        uint16 risk,
        uint16 crossChain,
        uint16 liquidity,
        uint16 compliance
    ) external onlyOwner {
        // Ensure weights sum to 10000 (100%)
        require(volatility + risk + crossChain + liquidity + compliance == 10000, "Weights must sum to 10000");
        
        feeWeights = FeeWeights({
            volatilityWeight: volatility,
            riskWeight: risk,
            crossChainWeight: crossChain,
            liquidityWeight: liquidity,
            complianceWeight: compliance
        });
        
        emit FeeWeightsUpdated(volatility, risk, crossChain, liquidity, compliance);
    }
    
    /**
     * @notice Update fee distribution
     * @param lp Share for liquidity providers
     * @param crossChain Share for cross-chain operations
     * @param insurance Share for insurance fund
     * @param protocol Share for protocol treasury
     */
    function setFeeDistribution(
        uint16 lp,
        uint16 crossChain,
        uint16 insurance,
        uint16 protocol
    ) external onlyOwner {
        // Ensure shares sum to 10000 (100%)
        require(lp + crossChain + insurance + protocol == 10000, "Shares must sum to 10000");
        
        feeDistribution = FeeDistribution({
            lpShare: lp,
            crossChainShare: crossChain,
            insuranceShare: insurance,
            protocolShare: protocol
        });
        
        emit FeeDistributionUpdated(lp, crossChain, insurance, protocol);
    }
    
    /**
     * @notice Set fee caps
     * @param volatilityFee Max fee for volatility
     * @param riskFee Max fee for risk premium
     * @param crossChainFee Max fee for cross-chain cost
     * @param liquidityFee Max fee for liquidity urgency
     * @param complianceFee Max fee for compliance
     * @param absoluteMax Absolute maximum total fee
     */
    function setFeeCaps(
        uint24 volatilityFee,
        uint24 riskFee,
        uint24 crossChainFee,
        uint24 liquidityFee,
        uint24 complianceFee,
        uint24 absoluteMax
    ) external onlyOwner {
        feeCapSettings = FeeCaps({
            maxVolatilityFee: volatilityFee,
            maxRiskFee: riskFee,
            maxCrossChainFee: crossChainFee,
            maxLiquidityFee: liquidityFee,
            maxComplianceFee: complianceFee,
            absoluteMaxFee: absoluteMax
        });
    }
    
    /**
     * @notice Set compliance settings for a token
     * @param token Token address
     * @param enhancedDueDiligence Whether EDD is required
     * @param complianceFee Fee for compliance
     * @param active Whether compliance fee is active
     */
    function setComplianceSettings(
        address token,
        bool enhancedDueDiligence,
        uint24 complianceFee,
        bool active
    ) external onlyOwner {
        require(complianceFee <= feeCapSettings.maxComplianceFee, "Fee exceeds cap");
        
        complianceSettings[token] = ComplianceSettings({
            enhancedDueDiligence: enhancedDueDiligence,
            complianceFee: complianceFee,
            active: active
        });
        
        emit ComplianceSettingsUpdated(token, enhancedDueDiligence, complianceFee, active);
    }
    
    /**
     * @notice Update liquidity data for a pool
     * @param key Pool key
     * @param optimalLiquidity Optimal liquidity level
     * @param currentLiquidity Current liquidity level
     */
    function updateLiquidityData(
        PoolKey calldata key,
        uint256 optimalLiquidity,
        uint256 currentLiquidity
    ) external onlyOwner {
        PoolId poolId = key.toId();
        
        liquidityData[poolId] = LiquidityData({
            optimalLiquidity: optimalLiquidity,
            currentLiquidity: currentLiquidity,
            lastUpdate: block.timestamp
        });
        
        emit LiquidityDataUpdated(poolId, optimalLiquidity, currentLiquidity);
    }
    
    /**
     * @notice Pause or unpause the hook
     * @param _paused New pause state
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }
    
    /**
     * @inheritdoc IDynamicFeeHook
     */
    function calculateDynamicFee(
        PoolKey calldata key,
        Currency tokenIn,
        Currency tokenOut,
        uint256 amountIn
    ) external view override returns (uint24 fee) {
        if (paused) {
            return defaultBaseFee;
        }
        
        // Get fee components
        FeeComponents memory components = getFeeComponents(key, tokenIn, tokenOut, amountIn);
        
        // Emit fee calculation event
        PoolId poolId = key.toId();
        
        // Return total fee (capped)
        return components.totalFee;
    }
    
    /**
     * @inheritdoc IDynamicFeeHook
     */
    function getFeeComponents(
        PoolKey calldata key,
        Currency tokenIn,
        Currency tokenOut,
        uint256 amountIn
    ) public view override returns (FeeComponents memory components) {
        PoolId poolId = key.toId();
        
        // Get pool's base fee or default if not set
        uint24 baseFee = poolBaseFees[poolId];
        if (baseFee == 0) {
            baseFee = defaultBaseFee;
        }
        
        // Initialize with base fee
        components.baseFee = baseFee;
        
        if (paused) {
            components.totalFee = baseFee;
            return components;
        }
        
        // Get token addresses
        address tokenInAddr = Currency.unwrap(tokenIn);
        address tokenOutAddr = Currency.unwrap(tokenOut);
        
        // 1. Calculate volatility fee
        components.volatilityFee = _calculateVolatilityFee(tokenInAddr, tokenOutAddr);
        
        // 2. Calculate risk premium
        components.riskPremium = _calculateRiskPremium(tokenIn, tokenOut);
        
        // 3. Calculate cross-chain cost
        components.crossChainCost = _calculateCrossChainFee(tokenIn, tokenOut, amountIn);
        
        // 4. Calculate liquidity urgency fee
        components.liquidityUrgency = _calculateLiquidityFee(key, tokenIn, tokenOut);
        
        // 5. Calculate compliance cost
        components.complianceCost = _calculateComplianceFee(tokenIn, tokenOut);
        
        // Calculate total fee based on weighted components
        uint256 weightedTotal = 
            (uint256(components.volatilityFee) * feeWeights.volatilityWeight +
             uint256(components.riskPremium) * feeWeights.riskWeight +
             uint256(components.crossChainCost) * feeWeights.crossChainWeight +
             uint256(components.liquidityUrgency) * feeWeights.liquidityWeight +
             uint256(components.complianceCost) * feeWeights.complianceWeight) / 10000;
        
        // Add base fee
        uint256 totalFee = baseFee + weightedTotal;
        
        // Cap the total fee
        if (totalFee > feeCapSettings.absoluteMaxFee) {
            totalFee = feeCapSettings.absoluteMaxFee;
        }
        
        components.totalFee = uint24(totalFee);
        
        return components;
    }
    
    /**
     * @inheritdoc IDynamicFeeHook
     */
    function getFeeDistribution(uint24 fee) external view override returns (
        uint16 lpShare,
        uint16 crossChainShare,
        uint16 insuranceShare,
        uint16 protocolShare
    ) {
        return (
            feeDistribution.lpShare,
            feeDistribution.crossChainShare,
            feeDistribution.insuranceShare,
            feeDistribution.protocolShare
        );
    }
    
    /**
     * @inheritdoc IDynamicFeeHook
     */
    function updateVolatilityMeasurement(
        Currency token0,
        Currency token1,
        uint256 volatility,
        uint32 window
    ) external override {
        // Only owner or authorized oracle can update volatility
        require(msg.sender == owner() || msg.sender == address(this), "Unauthorized");
        
        address token0Addr = Currency.unwrap(token0);
        address token1Addr = Currency.unwrap(token1);
        
        // Ensure token0 < token1 for consistent mapping
        if (token0Addr > token1Addr) {
            (token0Addr, token1Addr) = (token1Addr, token0Addr);
        }
        
        // Update volatility data based on window
        if (window == 86400) { // 24 hours
            volatilityData[token0Addr][token1Addr].volatility24h = volatility;
            volatilityData[token0Addr][token1Addr].lastUpdate = block.timestamp;
        } else if (window == 3600) { // 1 hour
            volatilityData[token0Addr][token1Addr].volatility1h = volatility;
            volatilityData[token0Addr][token1Addr].lastUpdate = block.timestamp;
        }
        
        emit VolatilityUpdated(token0Addr, token1Addr, volatility, window);
    }
    
    /**
     * @notice The hook callback for before swap
     * @param sender The swap sender
     * @param key The pool key
     * @param swapParams The swap parameters
     * @param hookData Additional data for the hook
     * @return The hook results
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // The fee is set when the pool is initialized, so we don't need to do anything here
        // However, we could update volatility data here if needed
        
        return (BaseHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
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
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
    
    /**
     * @notice Calculate volatility fee component
     * @param tokenInAddr Input token address
     * @param tokenOutAddr Output token address
     * @return fee The volatility fee component
     */
    function _calculateVolatilityFee(
        address tokenInAddr, 
        address tokenOutAddr
    ) internal view returns (uint24 fee) {
        // Ensure consistent ordering for mapping lookup
        if (tokenInAddr > tokenOutAddr) {
            (tokenInAddr, tokenOutAddr) = (tokenOutAddr, tokenInAddr);
        }
        
        // Get volatility data
        VolatilityData memory data = volatilityData[tokenInAddr][tokenOutAddr];
        
        // If no data or stale data, return 0
        if (data.lastUpdate == 0 || block.timestamp > data.lastUpdate + 1 days) {
            return 0;
        }
        
        // Calculate fee based on volatility (higher volatility = higher fee)
        // Use 24h volatility with more weight and 1h volatility with less weight
        uint256 weightedVolatility = (data.volatility24h * 7 + data.volatility1h * 3) / 10;
        
        // Convert to fee (simplified example)
        // For instance, 10% volatility (1000 bps) might correspond to 0.1% fee (100 in fee units)
        uint256 calculatedFee = weightedVolatility / 10;
        
        // Cap the fee
        if (calculatedFee > feeCapSettings.maxVolatilityFee) {
            calculatedFee = feeCapSettings.maxVolatilityFee;
        }
        
        return uint24(calculatedFee);
    }
    
    /**
     * @notice Calculate risk premium fee component
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @return fee The risk premium fee component
     */
    function _calculateRiskPremium(
        Currency tokenIn, 
        Currency tokenOut
    ) internal view returns (uint24 fee) {
        // If risk scoring service is not set, return 0
        if (address(riskScoring) == address(0)) {
            return 0;
        }
        
        try riskScoring.getRiskScore(Currency.unwrap(tokenIn)) returns (uint256 tokenInRisk) {
            try riskScoring.getRiskScore(Currency.unwrap(tokenOut)) returns (uint256 tokenOutRisk) {
                // Calculate average risk score (both are 0-10000 where 10000 is highest risk)
                uint256 avgRisk = (tokenInRisk + tokenOutRisk) / 2;
                
                // Convert to fee (simplified example)
                // For instance, risk score of 5000 (medium risk) might mean a 0.1% fee add-on
                uint256 calculatedFee = avgRisk / 50;
                
                // Cap the fee
                if (calculatedFee > feeCapSettings.maxRiskFee) {
                    calculatedFee = feeCapSettings.maxRiskFee;
                }
                
                return uint24(calculatedFee);
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }
    
    /**
     * @notice Calculate cross-chain cost fee component
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param amountIn Input amount
     * @return fee The cross-chain cost fee component
     */
    function _calculateCrossChainFee(
        Currency tokenIn,
        Currency tokenOut,
        uint256 amountIn
    ) internal view returns (uint24 fee) {
        // If cross-chain liquidity service is not set, return 0
        if (address(crossChainLiquidity) == address(0)) {
            return 0;
        }
        
        // Try to estimate cross-chain costs
        try crossChainLiquidity.estimateCrossChainCost(
            1, // Assuming source chain is 1
            Currency.unwrap(tokenIn),
            amountIn
        ) returns (uint256 crossChainFee, uint32 estimatedTime) {
            if (estimatedTime == 0) {
                return 0;
            }
            
            // Convert cross chain cost to fee percentage
            uint256 calculatedFee = (crossChainFee * 10000) / amountIn;
            
            // Cap the fee
            if (calculatedFee > feeCapSettings.maxCrossChainFee) {
                calculatedFee = feeCapSettings.maxCrossChainFee;
            }
            
            return uint24(calculatedFee);
        } catch {
            return 0;
        }
    }
    
    /**
     * @notice Calculate liquidity urgency fee component
     * @param key Pool key
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @return fee The liquidity urgency fee component
     */
    function _calculateLiquidityFee(
        PoolKey calldata key,
        Currency tokenIn,
        Currency tokenOut
    ) internal view returns (uint24 fee) {
        PoolId poolId = key.toId();
        
        // Get liquidity data
        LiquidityData memory data = liquidityData[poolId];
        
        // If no data or stale data, return 0
        if (data.lastUpdate == 0 || block.timestamp > data.lastUpdate + 1 days) {
            return 0;
        }
        
        // Calculate fee based on liquidity ratio
        if (data.optimalLiquidity == 0) {
            return 0;
        }
        
        // Calculate ratio (10000 = 100%)
        uint256 ratio = (data.currentLiquidity * 10000) / data.optimalLiquidity;
        
        uint256 calculatedFee;
        
        // Determine fee based on ratio
        if (ratio < 5000) { // Less than 50% of optimal
            // Higher fee for severely depleted liquidity
            calculatedFee = feeCapSettings.maxLiquidityFee;
        } else if (ratio < 8000) { // 50% to 80% of optimal
            // Scaled fee based on depletion level
            calculatedFee = feeCapSettings.maxLiquidityFee * (8000 - ratio) / 3000;
        } else {
            calculatedFee = 0;
        }
        
        return uint24(calculatedFee);
    }
    
    /**
     * @notice Calculate compliance fee component
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @return fee The compliance fee component
     */
    function _calculateComplianceFee(
        Currency tokenIn,
        Currency tokenOut
    ) internal view returns (uint24 fee) {
        address tokenInAddr = Currency.unwrap(tokenIn);
        address tokenOutAddr = Currency.unwrap(tokenOut);
        
        // Check if either token has compliance requirements
        ComplianceSettings memory inSettings = complianceSettings[tokenInAddr];
        ComplianceSettings memory outSettings = complianceSettings[tokenOutAddr];
        
        // Return the higher compliance fee if either token requires it
        if (inSettings.active && outSettings.active) {
            return inSettings.complianceFee > outSettings.complianceFee ? 
                   inSettings.complianceFee : outSettings.complianceFee;
        } else if (inSettings.active) {
            return inSettings.complianceFee;
        } else if (outSettings.active) {
            return outSettings.complianceFee;
        } else {
            return 0;
        }
    }
}
