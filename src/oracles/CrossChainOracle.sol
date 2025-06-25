// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import "../interfaces/IOracle.sol";
import "../interfaces/IKeeperNetwork.sol";

/**
 * @title CrossChainOracle
 * @notice Implementation of cross-chain Oracle system that aggregates data from multiple sources
 * @dev Uses a combination of on-chain and keeper-relayed off-chain data
 */
contract CrossChainOracle is IOracle, AccessControl {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;
    using CurrencyLibrary for Currency;
    
    // Role definitions
    bytes32 public constant ORACLE_PROVIDER_ROLE = keccak256("ORACLE_PROVIDER_ROLE");
    bytes32 public constant DATA_UPDATER_ROLE = keccak256("DATA_UPDATER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    // Keeper network for asynchronous updates
    IKeeperNetwork public keeperNetwork;
    
    // Registered oracle sources
    mapping(address => OracleSource) public oracleSources;
    EnumerableSet.AddressSet private registeredProviders;
    
    // Chain IDs with active oracles
    EnumerableSet.UintSet private activeChainIds;
    
    // Price data storage: base token -> quote token -> chain ID -> price data
    mapping(address => mapping(address => mapping(uint32 => PriceData))) public priceData;
    
    // Liquidity depth data: token -> chain ID -> liquidity data
    mapping(address => mapping(uint32 => LiquidityDepthData)) public liquidityData;
    
    // Gas price data: chain ID -> gas data
    mapping(uint32 => GasData) public gasData;
    
    // Volatility data: base token -> quote token -> window -> volatility
    mapping(address => mapping(address => mapping(uint32 => uint256))) public volatilityData;
    mapping(address => mapping(address => mapping(uint32 => uint256))) public volatilityTimestamp;
    
    // Chainlink price feed registry: base token -> quote token -> chain ID -> feed address
    mapping(address => mapping(address => mapping(uint32 => address))) public priceFeedRegistry;
    
    // Data staleness thresholds
    uint256 public priceStalenessThreshold = 1 hours;
    uint256 public liquidityStalenessThreshold = 15 minutes;
    uint256 public gasStalenessThreshold = 5 minutes;
    
    // Events
    event OracleSourceRegistered(address indexed provider, string sourceType, uint32 chainId);
    event PriceUpdated(address base, address quote, uint32 chainId, uint256 price);
    event LiquidityUpdated(address token, uint32 chainId, uint256 liquidity, uint256 utilization);
    event GasDataUpdated(uint32 chainId, uint256 fastGasPrice);
    event VolatilityUpdated(address base, address quote, uint32 window, uint256 volatility);
    
    /**
     * @notice Constructor
     * @param admin Admin address
     */
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        
        // Add local chain to active chains
        activeChainIds.add(block.chainid);
    }
    
    /**
     * @notice Set keeper network
     * @param _keeperNetwork Keeper network address
     */
    function setKeeperNetwork(IKeeperNetwork _keeperNetwork) external onlyRole(ADMIN_ROLE) {
        keeperNetwork = _keeperNetwork;
    }
    
    /**
     * @notice Set staleness thresholds
     * @param price Price staleness threshold in seconds
     * @param liquidity Liquidity staleness threshold in seconds
     * @param gas Gas data staleness threshold in seconds
     */
    function setStalenessThresholds(
        uint256 price,
        uint256 liquidity,
        uint256 gas
    ) external onlyRole(ADMIN_ROLE) {
        priceStalenessThreshold = price;
        liquidityStalenessThreshold = liquidity;
        gasStalenessThreshold = gas;
    }
    
    /**
     * @inheritdoc IOracle
     */
    function registerOracleSource(
        address provider,
        string calldata sourceType,
        uint32 chainId,
        UpdateFrequency frequency,
        ReliabilityLevel reliability
    ) external override onlyRole(ADMIN_ROLE) {
        oracleSources[provider] = OracleSource({
            provider: provider,
            sourceType: sourceType,
            chainId: chainId,
            frequency: frequency,
            reliability: reliability,
            lastUpdated: block.timestamp,
            isActive: true
        });
        
        registeredProviders.add(provider);
        activeChainIds.add(chainId);
        
        emit OracleSourceRegistered(provider, sourceType, chainId);
    }
    
    /**
     * @notice Register Chainlink price feed
     * @param base Base token address
     * @param quote Quote token address
     * @param chainId Chain ID
     * @param feedAddress Address of Chainlink price feed
     */
    function registerChainlinkFeed(
        address base,
        address quote,
        uint32 chainId,
        address feedAddress
    ) external onlyRole(ADMIN_ROLE) {
        require(feedAddress != address(0), "Invalid feed address");
        priceFeedRegistry[base][quote][chainId] = feedAddress;
    }
    
    /**
     * @inheritdoc IOracle
     */
    function getPrice(
        Currency base,
        Currency quote,
        uint32 chainId
    ) external view override returns (uint256 price, uint256 timestamp) {
        address baseAddr = Currency.unwrap(base);
        address quoteAddr = Currency.unwrap(quote);
        
        // If requesting from specific chain
        if (chainId != 0) {
            // Try Chainlink first if available
            address feedAddress = priceFeedRegistry[baseAddr][quoteAddr][chainId];
            
            if (feedAddress != address(0)) {
                try AggregatorV3Interface(feedAddress).latestRoundData() returns (
                    uint80 roundId,
                    int256 answer,
                    uint256 startedAt,
                    uint256 updatedAt,
                    uint80 answeredInRound
                ) {
                    if (answer > 0 && updatedAt > block.timestamp - priceStalenessThreshold) {
                        // Normalize to 18 decimals
                        uint8 decimals = AggregatorV3Interface(feedAddress).decimals();
                        uint256 normalizedPrice;
                        
                        if (decimals < 18) {
                            normalizedPrice = uint256(answer) * 10 ** (18 - decimals);
                        } else if (decimals > 18) {
                            normalizedPrice = uint256(answer) / 10 ** (decimals - 18);
                        } else {
                            normalizedPrice = uint256(answer);
                        }
                        
                        return (normalizedPrice, updatedAt);
                    }
                } catch {}
            }
            
            // Fall back to stored data
            PriceData memory data = priceData[baseAddr][quoteAddr][chainId];
            
            if (data.timestamp > block.timestamp - priceStalenessThreshold) {
                return (data.price, data.timestamp);
            }
            
            // If specific chain data is stale, revert
            revert("Price data not available or stale");
        }
        
        // For aggregated cross-chain price, find the most recent valid price
        uint256 bestPrice = 0;
        uint256 bestTimestamp = 0;
        
        // Check local chain first
        uint32 localChainId = uint32(block.chainid);
        
        // Try Chainlink for local chain
        address localFeed = priceFeedRegistry[baseAddr][quoteAddr][localChainId];
        
        if (localFeed != address(0)) {
            try AggregatorV3Interface(localFeed).latestRoundData() returns (
                uint80 roundId,
                int256 answer,
                uint256 startedAt,
                uint256 updatedAt,
                uint80 answeredInRound
            ) {
                if (answer > 0 && updatedAt > block.timestamp - priceStalenessThreshold) {
                    // Normalize to 18 decimals
                    uint8 decimals = AggregatorV3Interface(localFeed).decimals();
                    uint256 normalizedPrice;
                    
                    if (decimals < 18) {
                        normalizedPrice = uint256(answer) * 10 ** (18 - decimals);
                    } else if (decimals > 18) {
                        normalizedPrice = uint256(answer) / 10 ** (decimals - 18);
                    } else {
                        normalizedPrice = uint256(answer);
                    }
                    
                    return (normalizedPrice, updatedAt);
                }
            } catch {}
        }
        
        // Check local stored data
        PriceData memory localData = priceData[baseAddr][quoteAddr][localChainId];
        
        if (localData.timestamp > block.timestamp - priceStalenessThreshold) {
            bestPrice = localData.price;
            bestTimestamp = localData.timestamp;
        }
        
        // Check other chains
        uint256 length = activeChainIds.length();
        uint256 validPriceCount = 0;
        uint256 totalPrice = 0;
        
        for (uint256 i = 0; i < length; i++) {
            uint32 cid = uint32(activeChainIds.at(i));
            
            if (cid == localChainId) continue; // Skip local chain, already handled
            
            PriceData memory data = priceData[baseAddr][quoteAddr][cid];
            
            if (data.timestamp > block.timestamp - priceStalenessThreshold) {
                if (validPriceCount == 0 || data.timestamp > bestTimestamp) {
                    bestPrice = data.price;
                    bestTimestamp = data.timestamp;
                }
                
                totalPrice += data.price;
                validPriceCount++;
            }
        }
        
        // If no valid prices found
        if (bestTimestamp == 0) {
            revert("No valid price data available");
        }
        
        // If multiple valid prices, use average
        if (validPriceCount > 1) {
            return (totalPrice / validPriceCount, block.timestamp);
        }
        
        // Otherwise use best (most recent) price
        return (bestPrice, bestTimestamp);
    }
    
    /**
     * @inheritdoc IOracle
     */
    function getLiquidityDepth(
        Currency token,
        uint32 chainId
    ) external view override returns (uint256 liquidity, uint32 bestChainId, uint256 timestamp) {
        address tokenAddr = Currency.unwrap(token);
        
        // If requesting from specific chain
        if (chainId != 0) {
            LiquidityDepthData memory data = liquidityData[tokenAddr][chainId];
            
            if (data.timestamp > block.timestamp - liquidityStalenessThreshold) {
                return (data.availableLiquidity, chainId, data.timestamp);
            }
            
            // If specific chain data is stale, revert
            revert("Liquidity data not available or stale");
        }
        
        // For cross-chain aggregation, find best liquidity across chains
        uint256 bestLiquidity = 0;
        uint32 bestChain = 0;
        uint256 bestTimestamp = 0;
        
        // Check local chain first
        uint32 localChainId = uint32(block.chainid);
        LiquidityDepthData memory localData = liquidityData[tokenAddr][localChainId];
        
        if (localData.timestamp > block.timestamp - liquidityStalenessThreshold) {
            bestLiquidity = localData.availableLiquidity;
            bestChain = localChainId;
            bestTimestamp = localData.timestamp;
        }
        
        // Check other chains
        uint256 length = activeChainIds.length();
        
        for (uint256 i = 0; i < length; i++) {
            uint32 cid = uint32(activeChainIds.at(i));
            
            if (cid == localChainId) continue; // Skip local chain, already handled
            
            LiquidityDepthData memory data = liquidityData[tokenAddr][cid];
            
            if (data.timestamp > block.timestamp - liquidityStalenessThreshold && 
                data.availableLiquidity > bestLiquidity) {
                bestLiquidity = data.availableLiquidity;
                bestChain = cid;
                bestTimestamp = data.timestamp;
            }
        }
        
        // If no valid liquidity found
        if (bestTimestamp == 0) {
            revert("No valid liquidity data available");
        }
        
        return (bestLiquidity, bestChain, bestTimestamp);
    }
    
    /**
     * @inheritdoc IOracle
     */
    function getGasPrice(
        uint32 chainId
    ) external view override returns (uint256 fast, uint256 standard, uint256 slow, uint256 timestamp) {
        GasData memory data = gasData[chainId];
        
        if (data.timestamp > block.timestamp - gasStalenessThreshold) {
            return (data.fastGasPrice, data.standardGasPrice, data.slowGasPrice, data.timestamp);
        }
        
        revert("Gas data not available or stale");
    }
    
    /**
     * @inheritdoc IOracle
     */
    function getVolatility(
        Currency base,
        Currency quote,
        uint32 window
    ) external view override returns (uint256 volatility, uint256 timestamp) {
        address baseAddr = Currency.unwrap(base);
        address quoteAddr = Currency.unwrap(quote);
        
        // Ensure consistent token ordering
        if (baseAddr > quoteAddr) {
            (baseAddr, quoteAddr) = (quoteAddr, baseAddr);
        }
        
        uint256 ts = volatilityTimestamp[baseAddr][quoteAddr][window];
        
        // Volatility data has a different staleness threshold based on window
        uint256 staleness = window / 4; // 1/4 of the window is the staleness threshold
        
        if (ts > block.timestamp - staleness) {
            return (volatilityData[baseAddr][quoteAddr][window], ts);
        }
        
        revert("Volatility data not available or stale");
    }
    
    /**
     * @inheritdoc IOracle
     */
    function updatePrice(PriceData calldata data) external override returns (bool success) {
        require(hasRole(DATA_UPDATER_ROLE, msg.sender) || 
                msg.sender == address(keeperNetwork), "Unauthorized");
        
        address baseAddr = Currency.unwrap(data.base);
        address quoteAddr = Currency.unwrap(data.quote);
        
        // Store the price data
        priceData[baseAddr][quoteAddr][data.sourceChainId] = data;
        
        emit PriceUpdated(baseAddr, quoteAddr, data.sourceChainId, data.price);
        
        return true;
    }
    
    /**
     * @inheritdoc IOracle
     */
    function updateLiquidityDepth(LiquidityDepthData calldata data) external override returns (bool success) {
        require(hasRole(DATA_UPDATER_ROLE, msg.sender) || 
                msg.sender == address(keeperNetwork), "Unauthorized");
        
        address tokenAddr = Currency.unwrap(data.token);
        
        // Store the liquidity data
        liquidityData[tokenAddr][data.chainId] = data;
        
        emit LiquidityUpdated(tokenAddr, data.chainId, data.availableLiquidity, data.utilization);
        
        return true;
    }
    
    /**
     * @inheritdoc IOracle
     */
    function updateGasPrice(GasData calldata data) external override returns (bool success) {
        require(hasRole(DATA_UPDATER_ROLE, msg.sender) || 
                msg.sender == address(keeperNetwork), "Unauthorized");
        
        // Store the gas price data
        gasData[data.chainId] = data;
        
        emit GasDataUpdated(data.chainId, data.fastGasPrice);
        
        return true;
    }
    
    /**
     * @notice Update volatility data
     * @param base Base token
     * @param quote Quote token
     * @param window Time window in seconds
     * @param value Volatility value (basis points)
     * @return success Whether update was successful
     */
    function updateVolatility(
        Currency base,
        Currency quote,
        uint32 window,
        uint256 value
    ) external returns (bool success) {
        require(hasRole(DATA_UPDATER_ROLE, msg.sender) || 
                msg.sender == address(keeperNetwork), "Unauthorized");
        
        address baseAddr = Currency.unwrap(base);
        address quoteAddr = Currency.unwrap(quote);
        
        // Ensure consistent token ordering
        if (baseAddr > quoteAddr) {
            (baseAddr, quoteAddr) = (quoteAddr, baseAddr);
        }
        
        // Store the volatility data
        volatilityData[baseAddr][quoteAddr][window] = value;
        volatilityTimestamp[baseAddr][quoteAddr][window] = block.timestamp;
        
        emit VolatilityUpdated(baseAddr, quoteAddr, window, value);
        
        return true;
    }
    
    /**
     * @notice Request data updates from keepers
     * @param base Base token
     * @param quote Quote token
     * @param chainId Chain ID
     * @return operationId The operation ID from the keeper network
     */
    function requestDataUpdate(
        Currency base,
        Currency quote,
        uint32 chainId
    ) external returns (bytes32 operationId) {
        require(address(keeperNetwork) != address(0), "Keeper network not set");
        
        // Encode the data for the operation
        bytes memory callData = abi.encodeWithSelector(
            bytes4(keccak256("updateOracleData(address,address,uint32)")),
            Currency.unwrap(base),
            Currency.unwrap(quote),
            chainId
        );
        
        // Submit the operation to the keeper network
        operationId = keeperNetwork.requestOperation(
            IKeeperNetwork.OperationType.RISK_DATA_UPDATE,
            address(this),
            callData,
            1000000, // Gas limit
            500000,  // 0.5 USDC reward 
            block.timestamp + 5 minutes // Deadline
        );
        
        return operationId;
    }
    
    /**
     * @notice Get list of all registered provider addresses
     * @return providers Array of provider addresses
     */
    function getRegisteredProviders() external view returns (address[] memory providers) {
        uint256 length = registeredProviders.length();
        providers = new address[](length);
        
        for (uint256 i = 0; i < length; i++) {
            providers[i] = registeredProviders.at(i);
        }
        
        return providers;
    }
    
    /**
     * @notice Get list of all active chain IDs
     * @return chains Array of chain IDs
     */
    function getActiveChainIds() external view returns (uint32[] memory chains) {
        uint256 length = activeChainIds.length();
        chains = new uint32[](length);
        
        for (uint256 i = 0; i < length; i++) {
            chains[i] = uint32(activeChainIds.at(i));
        }
        
        return chains;
    }
    
    /**
     * @notice Get chain liquidity data
     * @param chain The chain identifier
     * @param token The token to check
     * @return data Liquidity data for the chain and token
     */
    function getChainLiquidityData(
        bytes32 chain, 
        Currency token
    ) external view override returns (LiquidityData memory) {
        // This is a placeholder implementation
        uint256 availableLiquidity = 1000000; // Default placeholder value
        uint256 utilizationRate = 7500; // 75% utilization rate
        
        uint32 chainId;
        if (chain == bytes32(0)) {
            chainId = 1; // Default to Ethereum mainnet
        } else {
            // Convert bytes32 to uint32 chainId
            chainId = uint32(uint256(chain));
        }
        
        // Check if we have data for this chain (commented out since it's just a placeholder)
        /*if (liquidityDepthByChain[chainId].contains(token.toId())) {
            // In a real implementation, we would fetch the actual data
            // This is just a placeholder that returns default values
        }*/
        
        return LiquidityData({
            availableLiquidity: availableLiquidity,
            utilizationRate: utilizationRate,
            lastUpdated: block.timestamp
        });
    }
}
