// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "../interfaces/IRiskScoring.sol";

/**
 * @title RiskScoring
 * @notice Implementation of the multi-dimensional risk scoring algorithm for SDEO
 * @dev This library evaluates asset risk across 5 critical dimensions with dynamic weighting
 */
contract RiskScoring is IRiskScoring, Ownable {
    // Weighting factors for risk components (sum = 100%)
    uint16 public constant VOLATILITY_WEIGHT = 30;
    uint16 public constant LIQUIDITY_WEIGHT = 25;
    uint16 public constant SMART_CONTRACT_WEIGHT = 20;
    uint16 public constant COUNTERPARTY_WEIGHT = 15;
    uint16 public constant REGULATORY_WEIGHT = 10;
    
    // Maximum risk score value (1000 = maximum risk)
    uint16 public constant MAX_RISK_SCORE = 1000;
    
    // Time decay thresholds in seconds
    uint32 public constant TIME_DECAY_THRESHOLD_1 = 6 hours;
    uint32 public constant TIME_DECAY_THRESHOLD_2 = 24 hours;
    uint32 public constant TIME_DECAY_THRESHOLD_3 = 7 days;
    uint32 public constant TIME_DECAY_THRESHOLD_4 = 30 days;
    
    // Time decay factors (in basis points, 10000 = 100%)
    uint16 public constant TIME_DECAY_FACTOR_1 = 9500; // 5% penalty
    uint16 public constant TIME_DECAY_FACTOR_2 = 9000; // 10% penalty
    uint16 public constant TIME_DECAY_FACTOR_3 = 8000; // 20% penalty
    uint16 public constant TIME_DECAY_FACTOR_4 = 6000; // 40% penalty
    
    // Volatility thresholds (daily % change, scaled by 10000)
    uint16 public constant VOLATILITY_THRESHOLD_LOW = 200;     // 2%
    uint16 public constant VOLATILITY_THRESHOLD_MEDIUM = 500;  // 5%
    uint16 public constant VOLATILITY_THRESHOLD_HIGH = 1000;   // 10%
    
    // Market cap thresholds in USD
    uint256 public constant MCAP_THRESHOLD_MEGA = 10000000000; // $10B
    uint256 public constant MCAP_THRESHOLD_LARGE = 1000000000; // $1B
    uint256 public constant MCAP_THRESHOLD_MEDIUM = 100000000; // $100M
    uint256 public constant MCAP_THRESHOLD_SMALL = 10000000;   // $10M
    
    // Chainlink price feed interfaces for volatile assets
    mapping(address => AggregatorV3Interface) public priceFeed;
    
    // Risk profiles for each token
    mapping(address => RiskProfile) private riskProfiles;
    
    // Token metadata for risk analysis
    struct TokenMetadata {
        // 0 = Unknown, 1 = Native, 2 = Decentralized Stablecoin, 3 = Centralized Stablecoin, 4 = Governance Token
        uint8 tokenType;
        uint8 auditCount;
        uint32 lastAuditTimestamp;
        bool hasBugBounty;
        uint256 marketCap;
        uint256 dailyVolume;
    }
    
    // Token metadata
    mapping(address => TokenMetadata) public tokenMetadata;
    
    // List of whitelisted oracles/keepers that can update risk data
    mapping(address => bool) public whitelistedUpdaters;
    
    // Events
    event RiskProfileUpdated(address indexed token, uint256 compositeScore);
    event TokenMetadataUpdated(address indexed token, uint8 tokenType, uint8 auditCount);
    event UpdaterWhitelisted(address indexed updater, bool status);

    /**
     * @notice Constructor
     * @param _owner Initial owner of the contract
     */
    constructor(address _owner) Ownable(_owner) {}

    /**
     * @notice Add a whitelisted updater
     * @param updater Address allowed to update risk profiles
     * @param status True to whitelist, false to remove
     */
    function setWhitelistedUpdater(address updater, bool status) external onlyOwner {
        whitelistedUpdaters[updater] = status;
        emit UpdaterWhitelisted(updater, status);
    }
    
    /**
     * @notice Set a price feed for a token
     * @param token The token address
     * @param feedAddress The Chainlink price feed address
     */
    function setPriceFeed(address token, address feedAddress) external onlyOwner {
        priceFeed[token] = AggregatorV3Interface(feedAddress);
    }
    
    /**
     * @notice Set token metadata for risk assessment
     * @param token The token address
     * @param tokenType Type classification of the token
     * @param auditCount Number of audits
     * @param lastAuditTimestamp Timestamp of the most recent audit
     * @param hasBugBounty Whether the token has an active bug bounty program
     * @param marketCap Current market cap in USD (scaled by 1e18)
     * @param dailyVolume Daily trading volume in USD (scaled by 1e18)
     */
    function setTokenMetadata(
        address token,
        uint8 tokenType,
        uint8 auditCount,
        uint32 lastAuditTimestamp,
        bool hasBugBounty,
        uint256 marketCap,
        uint256 dailyVolume
    ) external onlyOwner {
        tokenMetadata[token] = TokenMetadata({
            tokenType: tokenType,
            auditCount: auditCount,
            lastAuditTimestamp: lastAuditTimestamp,
            hasBugBounty: hasBugBounty,
            marketCap: marketCap,
            dailyVolume: dailyVolume
        });
        
        emit TokenMetadataUpdated(token, tokenType, auditCount);
    }

    /**
     * @inheritdoc IRiskScoring
     */
    function getRiskScore(address token) external view override returns (uint256 score) {
        RiskProfile memory profile = riskProfiles[token];
        
        if (profile.lastUpdated == 0) {
            // Return max risk score for tokens without risk data
            return MAX_RISK_SCORE;
        }
        
        // Calculate combined score with weightings
        score = 
            (uint256(profile.volatilityScore) * VOLATILITY_WEIGHT +
            uint256(profile.liquidityDepthScore) * LIQUIDITY_WEIGHT +
            uint256(profile.smartContractScore) * SMART_CONTRACT_WEIGHT +
            uint256(profile.counterpartyScore) * COUNTERPARTY_WEIGHT +
            uint256(profile.regulatoryScore) * REGULATORY_WEIGHT) / 100;
        
        // Apply time decay factor
        uint256 decayFactor = getTimeDecayFactor(profile.lastUpdated);
        score = (score * decayFactor) / 10000;
        
        return score > MAX_RISK_SCORE ? MAX_RISK_SCORE : score;
    }
    
    /**
     * @inheritdoc IRiskScoring
     */
    function getRiskProfile(address token) external view override returns (RiskProfile memory profile) {
        return riskProfiles[token];
    }
    
    /**
     * @inheritdoc IRiskScoring
     */
    function updateRiskProfile(address token, RiskProfile calldata profile) external override {
        require(whitelistedUpdaters[msg.sender] || owner() == msg.sender, "Not authorized");
        
        // Validate risk scores
        require(profile.volatilityScore <= MAX_RISK_SCORE, "Invalid volatility score");
        require(profile.liquidityDepthScore <= MAX_RISK_SCORE, "Invalid liquidity depth score");
        require(profile.smartContractScore <= MAX_RISK_SCORE, "Invalid smart contract score");
        require(profile.counterpartyScore <= MAX_RISK_SCORE, "Invalid counterparty score");
        require(profile.regulatoryScore <= MAX_RISK_SCORE, "Invalid regulatory score");
        
        // Update profile
        riskProfiles[token] = profile;
        
        // Calculate and emit the composite score
        uint256 compositeScore = 
            (uint256(profile.volatilityScore) * VOLATILITY_WEIGHT +
            uint256(profile.liquidityDepthScore) * LIQUIDITY_WEIGHT +
            uint256(profile.smartContractScore) * SMART_CONTRACT_WEIGHT +
            uint256(profile.counterpartyScore) * COUNTERPARTY_WEIGHT +
            uint256(profile.regulatoryScore) * REGULATORY_WEIGHT) / 100;
            
        emit RiskProfileUpdated(token, compositeScore);
    }
    
    /**
     * @inheritdoc IRiskScoring
     */
    function calculateRiskPremium(
        address token,
        uint256 amount,
        uint256 volatility
    ) external view override returns (uint256 riskFee) {
        uint256 riskScore = this.getRiskScore(token);
        
        // Base risk premium: 0.5 basis points per risk score unit (10 = full 1000 risk score)
        riskFee = (riskScore * 5) / 1000;
        
        // Add volatility premium if provided
        if (volatility > 0) {
            // Add 0.1 basis point per 0.1% of volatility
            riskFee += volatility / 10;
        }
        
        // Scale by amount (larger amounts get slightly higher premiums)
        // For amounts > $1M, add 1 basis point per million
        TokenMetadata memory meta = tokenMetadata[token];
        if (meta.marketCap > 0 && amount > 0) {
            uint256 amountInUsd = estimateValueInUsd(token, amount);
            if (amountInUsd > 1000000 * 10**18) {
                riskFee += (amountInUsd / (1000000 * 10**18));
            }
        }
        
        return riskFee;
    }

    /**
     * @inheritdoc IRiskScoring
     */
    function getTimeDecayFactor(uint32 lastUpdated) public view override returns (uint256 decayFactor) {
        if (lastUpdated == 0) return 10000; // No decay for default value
        
        uint256 timeSinceUpdate = block.timestamp - lastUpdated;
        
        if (timeSinceUpdate < TIME_DECAY_THRESHOLD_1) {
            return 10000; // No decay for fresh data
        } else if (timeSinceUpdate < TIME_DECAY_THRESHOLD_2) {
            return TIME_DECAY_FACTOR_1; // 5% penalty for 6-24 hours
        } else if (timeSinceUpdate < TIME_DECAY_THRESHOLD_3) {
            return TIME_DECAY_FACTOR_2; // 10% penalty for 1-7 days
        } else if (timeSinceUpdate < TIME_DECAY_THRESHOLD_4) {
            return TIME_DECAY_FACTOR_3; // 20% penalty for 7-30 days
        } else {
            return TIME_DECAY_FACTOR_4; // 40% penalty for >30 days
        }
    }

    /**
     * @notice Generates a volatility score based on price data
     * @param _24hVolatility 24 hour volatility in basis points (10000 = 100%)
     * @param _7dVolatility 7 day volatility in basis points
     * @param _30dVolatility 30 day volatility in basis points
     * @return volatilityScore The calculated volatility score (0-1000)
     */
    function calculateVolatilityScore(
        uint256 _24hVolatility,
        uint256 _7dVolatility,
        uint256 _30dVolatility
    ) public pure returns (uint16 volatilityScore) {
        // Weight the volatility measures
        // 50% for 24h, 30% for 7d, 20% for 30d
        uint256 weightedVolatility = 
            (_24hVolatility * 50 + 
            _7dVolatility * 30 + 
            _30dVolatility * 20) / 100;
        
        // Scale volatility to score
        if (weightedVolatility <= VOLATILITY_THRESHOLD_LOW * 100) {
            // 0-2% volatility (0-50 score)
            return uint16((weightedVolatility * 50) / (VOLATILITY_THRESHOLD_LOW * 100));
        } else if (weightedVolatility <= VOLATILITY_THRESHOLD_MEDIUM * 100) {
            // 2-5% volatility (50-500 score)
            return uint16(50 + (weightedVolatility - VOLATILITY_THRESHOLD_LOW * 100) * 450 / 
                ((VOLATILITY_THRESHOLD_MEDIUM - VOLATILITY_THRESHOLD_LOW) * 100));
        } else if (weightedVolatility <= VOLATILITY_THRESHOLD_HIGH * 100) {
            // 5-10% volatility (500-900 score)
            return uint16(500 + (weightedVolatility - VOLATILITY_THRESHOLD_MEDIUM * 100) * 400 / 
                ((VOLATILITY_THRESHOLD_HIGH - VOLATILITY_THRESHOLD_MEDIUM) * 100));
        } else {
            // >10% volatility (900-1000 score)
            uint256 excessVolatility = weightedVolatility - VOLATILITY_THRESHOLD_HIGH * 100;
            uint16 additionalScore = uint16((excessVolatility * 100) / (VOLATILITY_THRESHOLD_HIGH * 100));
            if (additionalScore > 100) additionalScore = 100;
            return 900 + additionalScore;
        }
    }

    /**
     * @notice Calculates liquidity depth score based on market cap and volume
     * @param marketCap Market cap in USD (scaled by 1e18)
     * @param dailyVolume 24h trading volume in USD (scaled by 1e18)
     * @return liquidityScore The calculated liquidity score (0-1000)
     */
    function calculateLiquidityScore(
        uint256 marketCap,
        uint256 dailyVolume
    ) public pure returns (uint16 liquidityScore) {
        // Start with market cap score
        uint16 marketCapScore;
        
        if (marketCap >= MCAP_THRESHOLD_MEGA) {
            marketCapScore = 50;  // Ultra-safe (BTC, ETH level)
        } else if (marketCap >= MCAP_THRESHOLD_LARGE) {
            marketCapScore = 150; // Blue chip DeFi
        } else if (marketCap >= MCAP_THRESHOLD_MEDIUM) {
            marketCapScore = 300; // Established projects
        } else if (marketCap >= MCAP_THRESHOLD_SMALL) {
            marketCapScore = 600; // Emerging projects
        } else {
            marketCapScore = 900; // High risk
        }
        
        // Analyze volume/market cap ratio (if market cap > 0)
        if (marketCap > 0 && dailyVolume > 0) {
            // Calculate volume/mcap ratio (in basis points)
            uint256 volumeRatio = (dailyVolume * 10000) / marketCap;
            
            if (volumeRatio >= 1000) {
                // >10% daily volume: Excellent liquidity, reduce score by 30%
                return uint16((marketCapScore * 70) / 100);
            } else if (volumeRatio >= 500) {
                // 5-10% daily volume: Good liquidity, reduce score by 20%
                return uint16((marketCapScore * 80) / 100);
            } else if (volumeRatio >= 100) {
                // 1-5% daily volume: Moderate liquidity, reduce score by 10%
                return uint16((marketCapScore * 90) / 100);
            } else {
                // <1% daily volume: Poor liquidity, increase score by 20%
                uint256 adjustedScore = marketCapScore * 120 / 100;
                return adjustedScore > MAX_RISK_SCORE ? MAX_RISK_SCORE : uint16(adjustedScore);
            }
        }
        
        return marketCapScore;
    }

    /**
     * @notice Calculates smart contract risk score based on audit history
     * @param auditCount Number of security audits
     * @param lastAuditTimestamp Timestamp of the most recent audit
     * @param hasBugBounty Whether token has active bug bounty program
     * @return smartContractScore The calculated smart contract risk score (0-1000)
     */
    function calculateSmartContractScore(
        uint8 auditCount,
        uint32 lastAuditTimestamp,
        bool hasBugBounty
    ) public view returns (uint16 smartContractScore) {
        // Base score: unaudited contracts start at 800
        if (auditCount == 0) {
            return 800;
        }
        
        // Start with decreasing score based on audit count
        uint256 baseScore;
        if (auditCount == 1) {
            baseScore = 500;
        } else if (auditCount == 2) {
            baseScore = 400;
        } else if (auditCount >= 3) {
            baseScore = 300;
        }
        
        // Recent audit bonus (within 6 months)
        if (lastAuditTimestamp > 0 && (block.timestamp - lastAuditTimestamp) < 180 days) {
            baseScore = (baseScore * 90) / 100; // 10% reduction
        }
        
        // Bug bounty bonus
        if (hasBugBounty) {
            baseScore = (baseScore * 80) / 100; // 20% reduction
        }
        
        return uint16(baseScore);
    }

    /**
     * @notice Calculates counterparty risk score based on token type and centralization
     * @param tokenType The type of token (1=native, 2=decentralized stablecoin, etc)
     * @return counterpartyScore The calculated counterparty risk score (0-1000)
     */
    function calculateCounterpartyScore(
        uint8 tokenType
    ) public pure returns (uint16 counterpartyScore) {
        if (tokenType == 1) {
            return 100;  // Native blockchain tokens (ETH)
        } else if (tokenType == 2) {
            return 200;  // Decentralized stablecoins (DAI)
        } else if (tokenType == 3) {
            return 300;  // Centralized stablecoins (USDC)
        } else if (tokenType == 4) {
            return 500;  // Governance tokens
        } else {
            return 700;  // Unknown or other
        }
    }

    /**
     * @notice Calculates regulatory risk score based on token type
     * @param tokenType The type of token
     * @return regulatoryScore The calculated regulatory risk score (0-1000)
     */
    function calculateRegulatoryScore(
        uint8 tokenType
    ) public pure returns (uint16 regulatoryScore) {
        if (tokenType == 3) {
            return 100;  // Compliant stablecoins
        } else if (tokenType == 1) {
            return 300;  // Native tokens
        } else if (tokenType == 2) {
            return 200;  // Decentralized stablecoins
        } else if (tokenType == 4) {
            return 400;  // Standard utility/governance tokens
        } else {
            return 700;  // Unknown or other
        }
    }
    
    /**
     * @notice Estimates USD value of a token amount using price feeds
     * @param token The token address
     * @param amount The token amount (in token decimals)
     * @return valueInUsd The estimated USD value (scaled by 1e18)
     */
    function estimateValueInUsd(address token, uint256 amount) public view returns (uint256 valueInUsd) {
        AggregatorV3Interface feed = priceFeed[token];
        
        // If we have a price feed
        if (address(feed) != address(0)) {
            (, int256 price, , , ) = feed.latestRoundData();
            if (price > 0) {
                // Calculate USD value
                // Note: Need to adjust for token and price feed decimals in production!
                return (uint256(price) * amount) / 10**8;
            }
        }
        
        // Fallback: use market cap / supply ratio if available
        TokenMetadata memory meta = tokenMetadata[token];
        return meta.marketCap > 0 ? amount : 0;
    }
}