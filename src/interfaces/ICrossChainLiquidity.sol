// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/**
 * @title ICrossChainLiquidity
 * @notice Interface for cross-chain liquidity management using CCTP
 */
interface ICrossChainLiquidity {
    /**
     * @notice Represents the result of a liquidity assessment
     * @param sufficientLocalLiquidity Whether there's enough liquidity locally
     * @param recommendedSourceChain Recommended chain to source liquidity from if local is insufficient
     * @param estimatedCrossChainFee Estimated fee for cross-chain liquidity sourcing
     * @param estimatedCrossChainTime Estimated time for cross-chain liquidity to arrive (in seconds)
     * @param shouldDeferSettlement Whether the settlement should be deferred
     */
    struct LiquidityAssessment {
        bool sufficientLocalLiquidity;
        bytes32 recommendedSourceChain;
        uint256 estimatedCrossChainFee;
        uint256 estimatedCrossChainTime;
        bool shouldDeferSettlement;
    }
    
    /**
     * @notice Represents a cross-chain liquidity source
     * @param chainId The ID of the source chain
     * @param poolAddress The address of the pool on the source chain
     * @param availableLiquidity The available liquidity amount
     * @param transferFee Estimated fee to transfer liquidity from source to destination
     * @param estimatedTime Estimated time to complete transfer (in seconds)
     */
    struct LiquiditySource {
        uint32 chainId;
        address poolAddress;
        uint256 availableLiquidity;
        uint256 transferFee;
        uint32 estimatedTime;
    }

    /**
     * @notice Returns available liquidity sources for a token across supported chains
     * @param token The address of the token to check
     * @param minAmount Minimum liquidity amount required
     * @return sources Array of liquidity sources across chains
     */
    function getAvailableLiquiditySources(
        address token,
        uint256 minAmount
    ) external view returns (LiquiditySource[] memory sources);
    
    /**
     * @notice Initiates a cross-chain liquidity transfer using CCTP
     * @param sourceChain The source chain ID
     * @param sourcePool The source pool address on the source chain
     * @param token The token address to transfer
     * @param amount The amount to transfer
     * @param recipient The recipient address on the destination chain
     * @return messageHash The CCTP message hash that can be used to track the transfer
     */
    function initiateCrossChainTransfer(
        uint32 sourceChain,
        address sourcePool,
        address token,
        uint256 amount,
        address recipient
    ) external returns (bytes32 messageHash);
    
    /**
     * @notice Checks the status of a cross-chain transfer
     * @param messageHash The CCTP message hash from initiateCrossChainTransfer
     * @return status 0=pending, 1=completed, 2=failed
     */
    function checkTransferStatus(bytes32 messageHash) external view returns (uint8 status);
    
    /**
     * @notice Estimates the cost of a cross-chain transfer
     * @param sourceChain The source chain ID
     * @param token The token address to transfer
     * @param amount The amount to transfer
     * @return fee The estimated fee in native tokens
     * @return estimatedTime The estimated time to complete transfer (in seconds)
     */
    function estimateCrossChainCost(
        uint32 sourceChain,
        address token,
        uint256 amount
    ) external view returns (uint256 fee, uint32 estimatedTime);
    
    /**
     * @notice Called when a CCTP transfer is received from another chain
     * @param sourceChain The source chain ID
     * @param sourcePool The source pool address
     * @param token The token address received
     * @param amount The amount received
     * @param messageHash The CCTP message hash
     */
    function onCCTPTransferReceived(
        uint32 sourceChain,
        address sourcePool,
        address token,
        uint256 amount,
        bytes32 messageHash
    ) external;
    
    /**
     * @notice Assesses liquidity needs for a swap
     * @param tokenIn The input token
     * @param tokenOut The output token
     * @param amountIn The amount of input token
     * @param amountOutMin The minimum amount of output token expected
     * @return assessment A LiquidityAssessment struct with the assessment results
     */
    function assessLiquidityNeeds(
        Currency tokenIn,
        Currency tokenOut,
        uint256 amountIn,
        uint256 amountOutMin
    ) external view returns (LiquidityAssessment memory);
    
    /**
     * @notice Moves liquidity cross-chain from this chain to another chain
     * @param targetChain The target chain to move liquidity to
     * @param token The token to move
     * @param amount The amount to move
     * @return success Whether the operation was initiated successfully
     */
    function moveLiquidityCrossChain(
        bytes32 targetChain,
        Currency token,
        uint256 amount
    ) external returns (bool);
    
    /**
     * @notice Handles receiving liquidity from another chain
     * @param sourceChain The source chain where the liquidity came from
     * @param token The token received
     * @param amount The amount received
     * @return success Whether the reception was processed successfully
     */
    function receiveLiquidityFromCrossChain(
        bytes32 sourceChain,
        Currency token,
        uint256 amount
    ) external returns (bool);
}
