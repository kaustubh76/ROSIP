// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/**
 * @title IOracle
 * @notice Interface for the cross-chain Oracle system
 * @dev This interface defines methods for acquiring and maintaining price and liquidity data across chains
 */
interface IOracle {
    /**
     * @notice Oracle data update frequency types
     */
    enum UpdateFrequency {
        REAL_TIME,      // Updated on each block
        HIGH_FREQUENCY, // Updated every few minutes
        MEDIUM,         // Updated hourly
        LOW_FREQUENCY   // Updated daily
    }
    
    /**
     * @notice Oracle data reliability levels
     */
    enum ReliabilityLevel {
        EXPERIMENTAL,   // New source, not fully validated
        VERIFIED,       // Verified but not primary
        TRUSTED,        // Trusted source
        GOLD_STANDARD   // Most reliable source
    }
    
    /**
     * @notice Oracle data source
     */
    struct OracleSource {
        address provider;           // Address of provider contract
        string sourceType;          // Type of source (e.g. "DEX", "API", "CCIP")
        uint32 chainId;             // Chain ID source is on
        UpdateFrequency frequency;  // Update frequency
        ReliabilityLevel reliability; // Reliability level
        uint256 lastUpdated;        // Last update timestamp
        bool isActive;              // Whether source is active
    }
    
    /**
     * @notice Price update data
     */
    struct PriceData {
        Currency base;              // Base asset
        Currency quote;             // Quote asset
        uint256 price;              // Price (scaled by 10^18)
        uint256 timestamp;          // Timestamp of price
        uint32 sourceChainId;       // Chain ID of the source
        address sourceAddress;      // Address that provided the data
    }
    
    /**
     * @notice Liquidity depth data
     */
    struct LiquidityDepthData {
        Currency token;              // Token
        uint32 chainId;              // Chain ID where liquidity exists
        address poolAddress;         // Address of the pool
        uint256 availableLiquidity;  // Amount of available liquidity
        uint256 utilization;         // Current utilization (scaled by 10^18 where 10^18 = 100%)
        uint256 timestamp;           // Timestamp of data
    }
    
    /**
     * @notice Chain liquidity data
     */
    struct LiquidityData {
        uint256 availableLiquidity;  // Available liquidity
        uint256 utilizationRate;     // Current utilization rate (scaled where 10000 = 100%)
        uint256 lastUpdated;         // Last updated timestamp
    }
    
    /**
     * @notice Gas price data across chains
     */
    struct GasData {
        uint32 chainId;             // Chain ID
        uint256 fastGasPrice;       // Fast gas price
        uint256 standardGasPrice;   // Standard gas price
        uint256 slowGasPrice;       // Slow gas price
        uint256 baseFee;            // Base fee if EIP-1559 chain
        uint256 timestamp;          // Timestamp of data
    }
    
    /**
     * @notice Get price for a token pair across chains
     * @param base Base token
     * @param quote Quote token
     * @param chainId Chain ID (0 for aggregated cross-chain price)
     * @return price Price of base in terms of quote (scaled by 10^18)
     * @return timestamp Timestamp of price data
     */
    function getPrice(
        Currency base,
        Currency quote,
        uint32 chainId
    ) external view returns (uint256 price, uint256 timestamp);
    
    /**
     * @notice Get liquidity depth for a token across chains
     * @param token The token to check
     * @param chainId Chain ID (0 for aggregated cross-chain data)
     * @return liquidity Total available liquidity
     * @return bestChainId Chain with the best liquidity
     * @return timestamp Timestamp of data
     */
    function getLiquidityDepth(
        Currency token,
        uint32 chainId
    ) external view returns (uint256 liquidity, uint32 bestChainId, uint256 timestamp);
    
    /**
     * @notice Get gas price for a specific chain
     * @param chainId Chain ID
     * @return fast Fast gas price
     * @return standard Standard gas price
     * @return slow Slow gas price
     * @return timestamp Timestamp of data
     */
    function getGasPrice(
        uint32 chainId
    ) external view returns (uint256 fast, uint256 standard, uint256 slow, uint256 timestamp);
    
    /**
     * @notice Get volatility for a token pair
     * @param base Base token
     * @param quote Quote token
     * @param window Time window in seconds (e.g. 3600 for hourly, 86400 for daily)
     * @return volatility Volatility value (basis points, 10000 = 100%)
     * @return timestamp Timestamp of data
     */
    function getVolatility(
        Currency base,
        Currency quote,
        uint32 window
    ) external view returns (uint256 volatility, uint256 timestamp);
    
    /**
     * @notice Register oracle data provider
     * @param provider Address of provider
     * @param sourceType Type of source
     * @param chainId Chain ID of source
     * @param frequency Update frequency
     * @param reliability Reliability level
     */
    function registerOracleSource(
        address provider,
        string calldata sourceType,
        uint32 chainId,
        UpdateFrequency frequency,
        ReliabilityLevel reliability
    ) external;
    
    /**
     * @notice Update price from authorized source
     * @param data The price data
     * @return success Whether update was successful
     */
    function updatePrice(PriceData calldata data) external returns (bool success);
    
    /**
     * @notice Update liquidity depth from authorized source
     * @param data The liquidity depth data
     * @return success Whether update was successful
     */
    function updateLiquidityDepth(LiquidityDepthData calldata data) external returns (bool success);
    
    /**
     * @notice Update gas price from authorized source
     * @param data The gas price data
     * @return success Whether update was successful
     */
    function updateGasPrice(GasData calldata data) external returns (bool success);
    
    /**
     * @notice Get chain liquidity data
     * @param chain The chain identifier
     * @param token The token to check
     * @return data Liquidity data for the chain and token
     */
    function getChainLiquidityData(
        bytes32 chain, 
        Currency token
    ) external view returns (LiquidityData memory);
}
