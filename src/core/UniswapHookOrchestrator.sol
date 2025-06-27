// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import "../interfaces/IBeforeSwapHook.sol";
import "../interfaces/IAfterSwapHook.sol";
import "../interfaces/IDynamicFeeHook.sol";
import "../interfaces/IRiskScoring.sol";
import "../interfaces/ICrossChainLiquidity.sol";
import "../interfaces/IKeeperNetwork.sol";
import "../interfaces/IOracle.sol";

/**
 * @title UniswapHookOrchestrator
 * @notice Central manager contract that orchestrates all hooks for Uniswap v4
 * @dev Manages hook permissioning, integration, and interaction between components
 */
contract UniswapHookOrchestrator is BaseHook, AccessControl {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    
    // Role constants
    bytes32 public constant HOOK_MANAGER_ROLE = keccak256("HOOK_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    // Hooks
    IBeforeSwapHook public beforeSwapHook;
    IAfterSwapHook public afterSwapHook;
    IDynamicFeeHook public dynamicFeeHook;
    
    // Services
    IRiskScoring public riskScoring;
    ICrossChainLiquidity public crossChainLiquidity;
    IKeeperNetwork public keeperNetwork;
    IOracle public oracle;
    
    // Pool settings
    struct PoolSettings {
        bool beforeSwapEnabled;      // Whether to use beforeSwap hook
        bool afterSwapEnabled;       // Whether to use afterSwap hook
        bool dynamicFeesEnabled;     // Whether to use dynamic fees
        uint24 defaultStaticFee;     // Default static fee if dynamic fees not used
        uint256 optimalLiquidity;    // Optimal liquidity level
        uint256 maxSlippage;         // Maximum allowed slippage (bps)
    }
    
    // Pool settings by pool ID
    mapping(PoolId => PoolSettings) public poolSettings;
    
    // Quick lookup of pools by tokens
    mapping(address => mapping(address => PoolId[])) public tokenToPools;
    
    // Paused state
    bool public emergencyPaused;
    
    // Events
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
    
    event PoolSettingsUpdated(
        PoolId indexed poolId,
        bool beforeSwapEnabled,
        bool afterSwapEnabled,
        bool dynamicFeesEnabled,
        uint24 defaultStaticFee
    );
    
    event EmergencyPaused(bool paused);
    
    /**
     * @notice Constructor
     * @param _poolManager Uniswap V4 pool manager
     * @param _admin Initial admin address (receives all roles)
     */
    constructor(IPoolManager _poolManager, address _admin) BaseHook(_poolManager) {
        require(_admin != address(0), "UniswapHookOrchestrator: admin cannot be zero address");
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(HOOK_MANAGER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
    }
    
    /**
     * @notice Update hook contracts
     * @param _beforeSwapHook Before swap hook
     * @param _afterSwapHook After swap hook
     * @param _dynamicFeeHook Dynamic fee hook
     */
    function updateHooks(
        address _beforeSwapHook,
        address _afterSwapHook,
        address _dynamicFeeHook
    ) external onlyRole(HOOK_MANAGER_ROLE) {
        beforeSwapHook = IBeforeSwapHook(_beforeSwapHook);
        afterSwapHook = IAfterSwapHook(_afterSwapHook);
        dynamicFeeHook = IDynamicFeeHook(_dynamicFeeHook);
        
        emit HooksUpdated(_beforeSwapHook, _afterSwapHook, _dynamicFeeHook);
    }
    
    /**
     * @notice Update service contracts
     * @param _riskScoring Risk scoring service
     * @param _crossChainLiquidity Cross-chain liquidity service
     * @param _keeperNetwork Keeper network
     * @param _oracle Oracle
     */
    function updateServices(
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
     * @notice Configure settings for a specific pool
     * @param key Pool key
     * @param beforeSwapEnabled Enable before swap hook
     * @param afterSwapEnabled Enable after swap hook
     * @param dynamicFeesEnabled Enable dynamic fees
     * @param defaultStaticFee Default static fee
     * @param optimalLiquidity Optimal liquidity level
     * @param maxSlippage Maximum allowed slippage (bps)
     */
    function configurePool(
        PoolKey calldata key,
        bool beforeSwapEnabled,
        bool afterSwapEnabled,
        bool dynamicFeesEnabled,
        uint24 defaultStaticFee,
        uint256 optimalLiquidity,
        uint256 maxSlippage
    ) external onlyRole(HOOK_MANAGER_ROLE) {
        PoolId poolId = key.toId();
        
        poolSettings[poolId] = PoolSettings({
            beforeSwapEnabled: beforeSwapEnabled,
            afterSwapEnabled: afterSwapEnabled,
            dynamicFeesEnabled: dynamicFeesEnabled,
            defaultStaticFee: defaultStaticFee,
            optimalLiquidity: optimalLiquidity,
            maxSlippage: maxSlippage
        });
        
        // Add to token lookup
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        
        _addPoolToTokenLookup(token0, token1, poolId);
        
        emit PoolSettingsUpdated(
            poolId,
            beforeSwapEnabled,
            afterSwapEnabled,
            dynamicFeesEnabled,
            defaultStaticFee
        );
    }
    
    /**
     * @notice Set emergency pause state
     * @param paused Whether to pause all hooks
     */
    function setEmergencyPaused(bool paused) external onlyRole(EMERGENCY_ROLE) {
        emergencyPaused = paused;
        emit EmergencyPaused(paused);
    }
    
    /**
     * @notice Calculate the fee for a swap
     * @param key Pool key
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param amountIn Input amount
     * @return fee The fee
     */
    function getFee(
        PoolKey calldata key,
        Currency tokenIn,
        Currency tokenOut,
        uint256 amountIn
    ) public view returns (uint24 fee) {
        PoolId poolId = key.toId();
        PoolSettings memory settings = poolSettings[poolId];
        
        // If dynamic fees disabled or emergency paused, use static fee
        if (emergencyPaused || !settings.dynamicFeesEnabled || address(dynamicFeeHook) == address(0)) {
            return settings.defaultStaticFee;
        }
        
        try dynamicFeeHook.calculateDynamicFee(key, tokenIn, tokenOut, amountIn) returns (uint24 dynamicFee) {
            return dynamicFee;
        } catch {
            // Fallback to default fee on failure
            return settings.defaultStaticFee;
        }
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
     * @notice Hook triggered before swap
     * @param sender The swap sender
     * @param key The pool key
     * @param swapParams The swap parameters
     * @param hookData Additional data for the hook
     * @return The hook result
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // If emergency paused, just return selector
        if (emergencyPaused) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }
        
        PoolId poolId = key.toId();
        PoolSettings memory settings = poolSettings[poolId];
        
        // If beforeSwap not enabled for this pool, just return selector
        if (!settings.beforeSwapEnabled || address(beforeSwapHook) == address(0)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }
        
        // For simplicity, we're not fully implementing the delegation behavior with proper return values
        // In a production environment, we would need to handle BeforeSwapDelta and fee properly
        return (BaseHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }
    
    /**
     * @notice Hook triggered after swap
     * @param sender The swap sender
     * @param key The pool key
     * @param swapParams The swap parameters
     * @param delta The balance delta from the swap
     * @param hookData Additional data for the hook
     * @return The hook result
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // If emergency paused, just return selector
        if (emergencyPaused) {
            return (BaseHook.afterSwap.selector, 0);
        }
        
        PoolId poolId = key.toId();
        PoolSettings memory settings = poolSettings[poolId];
        
        // If afterSwap not enabled for this pool, just return selector
        if (!settings.afterSwapEnabled || address(afterSwapHook) == address(0)) {
            return (BaseHook.afterSwap.selector, 0);
        }
        
        // For simplicity, we're not fully implementing the delegation behavior with proper return values
        // In a production environment, we would handle int128 delta return value properly
        return (BaseHook.afterSwap.selector, 0);
    }
    
    /**
     * @notice Initialize a pool with hooks
     * @param key Pool key
     * @param sqrtPriceX96 Initial sqrt price
     * @param hookData Hook data
     */
    function initialize(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        bytes calldata hookData
    ) external returns (int24 tick) {
        return poolManager.initialize(key, sqrtPriceX96);
    }
    
    /**
     * @notice Add liquidity to a pool
     * @param key Pool key
     * @param params Liquidity parameters
     * @param hookData Hook data
     * @return delta Balance delta
     */
    function addLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (BalanceDelta delta) {
        (BalanceDelta callerDelta, ) = poolManager.modifyLiquidity(key, params, hookData);
        return callerDelta;
    }
    
    /**
     * @notice Remove liquidity from a pool
     * @param key Pool key
     * @param params Liquidity parameters
     * @param hookData Hook data
     * @return delta Balance delta
     */
    function removeLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (BalanceDelta delta) {
        (BalanceDelta callerDelta, ) = poolManager.modifyLiquidity(key, params, hookData);
        return callerDelta;
    }
    
    /**
     * @notice Perform a swap
     * @param key Pool key
     * @param params Swap parameters
     * @param hookData Hook data
     * @return delta Balance delta
     */
    function swap(
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external returns (BalanceDelta delta) {
        // Dynamic fee setting
        if (poolSettings[key.toId()].dynamicFeesEnabled && address(dynamicFeeHook) != address(0)) {
            // Calculate dynamic fee
            Currency tokenIn = params.zeroForOne ? key.currency0 : key.currency1;
            Currency tokenOut = params.zeroForOne ? key.currency1 : key.currency0;
            
            uint24 dynamicFee = getFee(key, tokenIn, tokenOut, 0); // We don't know the exact amount yet
            
            // Create modified key with dynamic fee
            PoolKey memory modifiedKey = key;
            modifiedKey.fee = dynamicFee;
            
            return poolManager.swap(modifiedKey, params, hookData);
        } else {
            return poolManager.swap(key, params, hookData);
        }
    }
    
    /**
     * @notice Get all pools that contain a specific token
     * @param token Token address
     * @return poolIds List of pool IDs
     */
    function getPoolsForToken(address token) external view returns (PoolId[] memory poolIds) {
        uint256 count = 0;
        
        // First pass to count
        for (uint256 i = 0; i < tokenToPools[token][address(0)].length; i++) {
            count++;
        }
        
        // Second pass to get values
        poolIds = new PoolId[](count);
        for (uint256 i = 0; i < count; i++) {
            poolIds[i] = tokenToPools[token][address(0)][i];
        }
        
        return poolIds;
    }
    
    /**
     * @notice Get pool for a token pair
     * @param tokenA First token
     * @param tokenB Second token
     * @return poolId Pool ID 
     */
    function getPoolForPair(address tokenA, address tokenB) external view returns (PoolId poolId) {
        // Ensure consistent ordering
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        
        if (tokenToPools[token0][token1].length > 0) {
            return tokenToPools[token0][token1][0]; // Return first pool
        }
        
        revert("No pool found for pair");
    }
    
    /**
     * @notice Internal function to add pool to token lookup
     * @param token0 Token0 address
     * @param token1 Token1 address
     * @param poolId Pool ID
     */
    function _addPoolToTokenLookup(address token0, address token1, PoolId poolId) internal {
        // Add to token-specific lookups
        tokenToPools[token0][token1].push(poolId);
        tokenToPools[token1][token0].push(poolId);
        
        // Add to single token lookups for queries
        tokenToPools[token0][address(0)].push(poolId);
        tokenToPools[token1][address(0)].push(poolId);
    }
}
