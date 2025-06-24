// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {InsurancePolicyNFT} from "../core/InsurancePolicyNFT.sol";
import {ReflexiveOracleState} from "../core/ReflexiveOracleState.sol";

/**
 * @title ParameterizedInsurance
 * @notice Enables users to purchase specific, parameterized insurance policies for DeFi risks
 * @dev Integrates with reflexive oracle for dynamic pricing and risk assessment
 */
contract ParameterizedInsurance is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    bytes32 public constant ORCHESTRATOR_ROLE = keccak256("ORCHESTRATOR_ROLE");
    bytes32 public constant PRICE_UPDATER_ROLE = keccak256("PRICE_UPDATER_ROLE");
    
    /// @notice The USDC token used for premiums and payouts
    IERC20 public immutable USDC;
    
    /// @notice The policy NFT contract
    InsurancePolicyNFT public immutable policyNFT;
    
    /// @notice The reflexive oracle for market state
    ReflexiveOracleState public immutable reflexiveOracle;
    
    /// @notice Insurance collateral pool contract
    address public insurancePool;
    
    /// @notice Premium calculation parameters for each insurance type
    struct PremiumParameters {
        uint256 basePremiumBPS;      // Base premium in basis points per hour
        uint256 riskMultiplierMin;   // Minimum risk multiplier
        uint256 riskMultiplierMax;   // Maximum risk multiplier
        uint256 maxCoverage;         // Maximum coverage amount in USDC
        uint256 minDuration;         // Minimum coverage duration in seconds
        uint256 maxDuration;         // Maximum coverage duration in seconds
        bool enabled;                // Whether this insurance type is available
    }
    
    /// @notice Insurance purchase parameters
    struct InsurancePurchase {
        InsurancePolicyNFT.InsuranceType insuranceType;
        address asset;               // Asset being insured
        uint256 coverageAmount;      // Desired coverage in USDC
        uint256 duration;            // Coverage period in seconds
        uint256 triggerPrice;        // Price trigger (for depeg/volatility insurance)
        uint256 thresholdPercent;    // Percentage threshold (for IL insurance)
        PoolKey poolKey;             // Associated Uniswap pool
        bytes additionalParams;      // Type-specific parameters
        uint256 maxPremium;          // Maximum acceptable premium (slippage protection)
    }
    
    /// @notice Market capacity tracking
    struct MarketCapacity {
        uint256 totalCoverage;       // Total active coverage amount
        uint256 availableCapacity;   // Available insurance capacity
        uint256 utilizationRate;     // Current utilization percentage
        uint256 lastUpdate;          // Last capacity update time
    }
    
    /// @dev Insurance type to premium parameters mapping
    mapping(InsurancePolicyNFT.InsuranceType => PremiumParameters) public premiumParams;
    
    /// @dev Pool to market capacity mapping
    mapping(bytes32 => MarketCapacity) public marketCapacity;
    
    /// @dev Asset to price feed mapping (for external oracle integration)
    mapping(address => address) public priceFeeds;
    
    /// @dev Total premium collected per insurance type
    mapping(InsurancePolicyNFT.InsuranceType => uint256) public totalPremiumCollected;
    
    /// @dev Total claims paid per insurance type
    mapping(InsurancePolicyNFT.InsuranceType => uint256) public totalClaimsPaid;
    
    /// @notice Events for insurance lifecycle
    event InsurancePurchased(
        uint256 indexed policyId,
        address indexed buyer,
        InsurancePolicyNFT.InsuranceType insuranceType,
        uint256 coverageAmount,
        uint256 premium,
        uint256 duration
    );
    
    event PremiumParametersUpdated(
        InsurancePolicyNFT.InsuranceType indexed insuranceType,
        uint256 newBasePremium,
        uint256 newMaxCoverage
    );
    
    event MarketCapacityUpdated(
        bytes32 indexed poolId,
        uint256 newTotalCoverage,
        uint256 newAvailableCapacity
    );
    
    event InsuranceTypeEnabled(InsurancePolicyNFT.InsuranceType indexed insuranceType);
    event InsuranceTypeDisabled(InsurancePolicyNFT.InsuranceType indexed insuranceType);
    
    constructor(
        address _usdc,
        address _policyNFT,
        address _reflexiveOracle,
        address _admin
    ) {
        USDC = IERC20(_usdc);
        policyNFT = InsurancePolicyNFT(_policyNFT);
        reflexiveOracle = ReflexiveOracleState(_reflexiveOracle);
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ORCHESTRATOR_ROLE, _admin);
        _grantRole(PRICE_UPDATER_ROLE, _admin);
        
        // Initialize default premium parameters
        _initializeDefaultParameters();
    }
    
    /**
     * @notice Purchase parameterized insurance policy
     * @param purchase Insurance purchase parameters
     * @return policyId The ID of the created policy NFT
     */
    function purchaseInsurance(
        InsurancePurchase calldata purchase
    ) external nonReentrant returns (uint256 policyId) {
        
        // Validate insurance type is enabled
        require(premiumParams[purchase.insuranceType].enabled, "Insurance type disabled");
        
        // Validate parameters
        _validatePurchaseParameters(purchase);
        
        // Calculate premium based on market conditions
        uint256 premium = calculatePremium(purchase);
        
        // Check slippage protection
        require(premium <= purchase.maxPremium, "Premium exceeds maximum");
        
        // Check market capacity
        bytes32 poolId = keccak256(abi.encode(purchase.poolKey));
        _checkAndUpdateMarketCapacity(poolId, purchase.coverageAmount);
        
        // Collect premium
        USDC.safeTransferFrom(msg.sender, insurancePool, premium);
        
        // Create policy NFT
        InsurancePolicyNFT.InsurancePolicy memory policy = InsurancePolicyNFT.InsurancePolicy({
            insuranceType: purchase.insuranceType,
            status: InsurancePolicyNFT.PolicyStatus.ACTIVE,
            beneficiary: msg.sender,
            asset: purchase.asset,
            coverageAmount: purchase.coverageAmount,
            premium: premium,
            startTime: block.timestamp,
            duration: purchase.duration,
            triggerPrice: purchase.triggerPrice,
            thresholdPercent: purchase.thresholdPercent,
            poolId: poolId,
            additionalParams: purchase.additionalParams
        });
        
        policyId = policyNFT.mintPolicy(msg.sender, policy);
        
        // Update statistics
        totalPremiumCollected[purchase.insuranceType] += premium;
        
        emit InsurancePurchased(
            policyId,
            msg.sender,
            purchase.insuranceType,
            purchase.coverageAmount,
            premium,
            purchase.duration
        );
    }
    
    /**
     * @notice Calculate premium for insurance purchase
     * @param purchase Insurance purchase parameters
     * @return premium Premium amount in USDC
     */
    function calculatePremium(
        InsurancePurchase calldata purchase
    ) public view returns (uint256 premium) {
        
        PremiumParameters memory params = premiumParams[purchase.insuranceType];
        require(params.enabled, "Insurance type not enabled");
        
        // Base premium calculation (per hour basis)
        uint256 hourlyRate = (purchase.coverageAmount * params.basePremiumBPS) / 10000;
        uint256 hoursDuration = (purchase.duration + 3599) / 3600; // Round up to nearest hour
        uint256 basePremium = hourlyRate * hoursDuration;
        
        // Get market risk multiplier from reflexive oracle
        bytes32 poolId = keccak256(abi.encode(purchase.poolKey));
        uint256 riskMultiplier = reflexiveOracle.getCurrentRiskMultiplier(purchase.poolKey);
        
        // Apply capacity utilization multiplier
        MarketCapacity memory capacity = marketCapacity[poolId];
        uint256 utilizationMultiplier = _calculateUtilizationMultiplier(capacity.utilizationRate);
        
        // Asset-specific risk multiplier (could be based on external oracles)
        uint256 assetRiskMultiplier = _getAssetRiskMultiplier(purchase.asset, purchase.insuranceType);
        
        // Duration risk multiplier (longer duration = higher risk)
        uint256 durationMultiplier = _calculateDurationMultiplier(purchase.duration);
        
        // Combine all multipliers
        uint256 totalMultiplier = (riskMultiplier * utilizationMultiplier * assetRiskMultiplier * durationMultiplier) / (10000 * 10000 * 10000);
        
        // Clamp multiplier to min/max bounds
        if (totalMultiplier < params.riskMultiplierMin) {
            totalMultiplier = params.riskMultiplierMin;
        } else if (totalMultiplier > params.riskMultiplierMax) {
            totalMultiplier = params.riskMultiplierMax;
        }
        
        premium = (basePremium * totalMultiplier) / 10000;
        
        // Minimum premium of 1 USDC (6 decimals)
        if (premium < 1000000) {
            premium = 1000000;
        }
    }
    
    /**
     * @notice Get quote for insurance purchase (view function)
     * @param purchase Insurance purchase parameters
     * @return premium Quoted premium amount
     * @return riskLevel Current risk level for the asset/pool
     * @return availableCapacity Available insurance capacity
     */
    function getInsuranceQuote(
        InsurancePurchase calldata purchase
    ) external view returns (
        uint256 premium,
        ReflexiveOracleState.MarketState riskLevel,
        uint256 availableCapacity
    ) {
        premium = calculatePremium(purchase);
        riskLevel = reflexiveOracle.getMarketState(purchase.poolKey);
        
        bytes32 poolId = keccak256(abi.encode(purchase.poolKey));
        availableCapacity = marketCapacity[poolId].availableCapacity;
    }
    
    /**
     * @notice Set premium parameters for an insurance type
     * @param insuranceType The insurance type to configure
     * @param params New premium parameters
     */
    function setPremiumParameters(
        InsurancePolicyNFT.InsuranceType insuranceType,
        PremiumParameters calldata params
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        premiumParams[insuranceType] = params;
        
        emit PremiumParametersUpdated(
            insuranceType,
            params.basePremiumBPS,
            params.maxCoverage
        );
    }
    
    /**
     * @notice Enable/disable specific insurance types
     * @param insuranceType The insurance type to toggle
     * @param enabled Whether to enable or disable
     */
    function setInsuranceTypeEnabled(
        InsurancePolicyNFT.InsuranceType insuranceType,
        bool enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        premiumParams[insuranceType].enabled = enabled;
        
        if (enabled) {
            emit InsuranceTypeEnabled(insuranceType);
        } else {
            emit InsuranceTypeDisabled(insuranceType);
        }
    }
    
    /**
     * @notice Set insurance pool address
     * @param _insurancePool New insurance pool address
     */
    function setInsurancePool(address _insurancePool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_insurancePool != address(0), "Invalid pool address");
        insurancePool = _insurancePool;
    }
    
    /**
     * @notice Update market capacity for a pool
     * @param poolId Pool identifier
     * @param totalCoverage New total coverage amount
     * @param availableCapacity New available capacity
     */
    function updateMarketCapacity(
        bytes32 poolId,
        uint256 totalCoverage,
        uint256 availableCapacity
    ) external onlyRole(ORCHESTRATOR_ROLE) {
        MarketCapacity storage capacity = marketCapacity[poolId];
        capacity.totalCoverage = totalCoverage;
        capacity.availableCapacity = availableCapacity;
        capacity.utilizationRate = totalCoverage > 0 ? 
            (totalCoverage * 10000) / (totalCoverage + availableCapacity) : 0;
        capacity.lastUpdate = block.timestamp;
        
        emit MarketCapacityUpdated(poolId, totalCoverage, availableCapacity);
    }
    
    /**
     * @dev Validate insurance purchase parameters
     */
    function _validatePurchaseParameters(InsurancePurchase calldata purchase) internal view {
        PremiumParameters memory params = premiumParams[purchase.insuranceType];
        
        require(purchase.coverageAmount > 0, "Coverage amount must be positive");
        require(purchase.coverageAmount <= params.maxCoverage, "Coverage exceeds maximum");
        require(purchase.duration >= params.minDuration, "Duration below minimum");
        require(purchase.duration <= params.maxDuration, "Duration exceeds maximum");
        
        // Type-specific validations
        if (purchase.insuranceType == InsurancePolicyNFT.InsuranceType.DEPEG_PROTECTION) {
            require(purchase.triggerPrice > 0, "Trigger price required for depeg insurance");
        }
        
        if (purchase.insuranceType == InsurancePolicyNFT.InsuranceType.IMPERMANENT_LOSS) {
            require(purchase.thresholdPercent > 0 && purchase.thresholdPercent <= 10000, 
                   "Invalid threshold percentage");
        }
    }
    
    /**
     * @dev Check and update market capacity
     */
    function _checkAndUpdateMarketCapacity(bytes32 poolId, uint256 coverageAmount) internal {
        MarketCapacity storage capacity = marketCapacity[poolId];
        
        require(capacity.availableCapacity >= coverageAmount, "Insufficient market capacity");
        
        capacity.totalCoverage += coverageAmount;
        capacity.availableCapacity -= coverageAmount;
        capacity.utilizationRate = (capacity.totalCoverage * 10000) / 
            (capacity.totalCoverage + capacity.availableCapacity);
        capacity.lastUpdate = block.timestamp;
    }
    
    /**
     * @dev Calculate utilization multiplier based on market capacity usage
     */
    function _calculateUtilizationMultiplier(uint256 utilizationRate) internal pure returns (uint256) {
        // Linear increase: 1x at 0% utilization, 2x at 100% utilization
        return 10000 + utilizationRate; // utilizationRate is in basis points
    }
    
    /**
     * @dev Get asset-specific risk multiplier
     */
    function _getAssetRiskMultiplier(
        address asset,
        InsurancePolicyNFT.InsuranceType insuranceType
    ) internal view returns (uint256) {
        // Default multiplier
        uint256 multiplier = 10000; // 1x
        
        // Asset-specific adjustments would go here
        // For now, using simple heuristics
        
        // Stablecoins generally have lower risk for most insurance types
        // (This would typically integrate with external risk scoring systems)
        
        return multiplier;
    }
    
    /**
     * @dev Calculate duration-based risk multiplier
     */
    function _calculateDurationMultiplier(uint256 duration) internal pure returns (uint256) {
        // Longer duration = higher risk
        // Base: 1x for 1 hour, increases with square root of duration
        uint256 hoursDuration = duration / 3600;
        if (hoursDuration <= 1) return 10000;
        
        // Simplified square root approximation for duration risk
        // Real implementation would use more sophisticated models
        uint256 multiplier = 10000 + (hoursDuration * 100); // 1% increase per hour
        
        // Cap at 5x for very long durations
        if (multiplier > 50000) multiplier = 50000;
        
        return multiplier;
    }
    
    /**
     * @dev Initialize default premium parameters for all insurance types
     */
    function _initializeDefaultParameters() internal {
        // Depeg Protection
        premiumParams[InsurancePolicyNFT.InsuranceType.DEPEG_PROTECTION] = PremiumParameters({
            basePremiumBPS: 10,          // 0.1% per hour
            riskMultiplierMin: 5000,     // 0.5x minimum
            riskMultiplierMax: 50000,    // 5x maximum  
            maxCoverage: 1000000 * 1e6,  // 1M USDC
            minDuration: 3600,           // 1 hour
            maxDuration: 30 * 24 * 3600, // 30 days
            enabled: true
        });
        
        // Impermanent Loss
        premiumParams[InsurancePolicyNFT.InsuranceType.IMPERMANENT_LOSS] = PremiumParameters({
            basePremiumBPS: 25,          // 0.25% per hour
            riskMultiplierMin: 8000,     // 0.8x minimum
            riskMultiplierMax: 30000,    // 3x maximum
            maxCoverage: 500000 * 1e6,   // 500K USDC
            minDuration: 24 * 3600,      // 24 hours
            maxDuration: 90 * 24 * 3600, // 90 days
            enabled: true
        });
        
        // Volatility Cap
        premiumParams[InsurancePolicyNFT.InsuranceType.VOLATILITY_CAP] = PremiumParameters({
            basePremiumBPS: 50,          // 0.5% per hour
            riskMultiplierMin: 10000,    // 1x minimum
            riskMultiplierMax: 40000,    // 4x maximum
            maxCoverage: 250000 * 1e6,   // 250K USDC
            minDuration: 3600,           // 1 hour
            maxDuration: 7 * 24 * 3600,  // 7 days
            enabled: true
        });
        
        // Bridge Protection
        premiumParams[InsurancePolicyNFT.InsuranceType.BRIDGE_PROTECTION] = PremiumParameters({
            basePremiumBPS: 5,           // 0.05% per hour
            riskMultiplierMin: 10000,    // 1x minimum
            riskMultiplierMax: 20000,    // 2x maximum
            maxCoverage: 2000000 * 1e6,  // 2M USDC
            minDuration: 600,            // 10 minutes
            maxDuration: 24 * 3600,      // 24 hours
            enabled: true
        });
    }
}
