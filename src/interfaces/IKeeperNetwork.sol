// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IKeeperNetwork
 * @notice Interface for the decentralized keeper network that handles asynchronous operations
 */
interface IKeeperNetwork {
    /**
     * @notice Operation types that keepers can execute
     */
    enum OperationType {
        LIQUIDITY_REPLENISHMENT,
        YIELD_OPTIMIZATION,
        DEFERRED_SETTLEMENT,
        RISK_DATA_UPDATE
    }
    
    /**
     * @notice Status of keeper operations
     */
    enum OperationStatus {
        PENDING,
        EXECUTING,
        COMPLETED,
        FAILED
    }
    
    /**
     * @notice Represents a keeper operation request
     * @param id Unique identifier for the operation
     * @param operationType The type of operation
     * @param target The target contract address
     * @param data The calldata to execute
     * @param gasLimit Maximum gas to use
     * @param reward Reward amount for executing operation
     * @param deadline Timestamp after which the operation expires
     * @param status Current status of the operation
     * @param assignedKeeper Address of keeper assigned to this operation
     */
    struct Operation {
        bytes32 id;
        OperationType operationType;
        address target;
        bytes data;
        uint256 gasLimit;
        uint256 reward;
        uint256 deadline;
        OperationStatus status;
        address assignedKeeper;
    }
    
    /**
     * @notice Represents a registered keeper
     * @param stake Amount staked by the keeper
     * @param performanceScore Performance score (0-100)
     * @param lastOperationTime Timestamp of last completed operation
     * @param operationsCompleted Total number of operations completed
     * @param operationsFailed Total number of operations failed
     */
    struct Keeper {
        uint256 stake;
        uint8 performanceScore;
        uint256 lastOperationTime;
        uint256 operationsCompleted;
        uint256 operationsFailed;
    }
    
    /**
     * @notice Registers a new keeper with the network
     * @param stake Amount to stake (transferred from sender)
     * @return success True if registration was successful
     */
    function registerKeeper(uint256 stake) external returns (bool success);
    
    /**
     * @notice Requests an operation to be executed by the keeper network
     * @param operationType The type of operation
     * @param target The target contract address
     * @param data The calldata to execute
     * @param gasLimit Maximum gas to use
     * @param reward Reward amount for executing operation
     * @param deadline Timestamp after which the operation expires
     * @return operationId The unique identifier for the operation
     */
    function requestOperation(
        OperationType operationType,
        address target,
        bytes calldata data,
        uint256 gasLimit,
        uint256 reward,
        uint256 deadline
    ) external payable returns (bytes32 operationId);
    
    /**
     * @notice Allows a keeper to execute a pending operation
     * @param operationId The identifier of the operation to execute
     * @return success True if the operation was executed successfully
     */
    function executeOperation(bytes32 operationId) external returns (bool success);
    
    /**
     * @notice Gets the details of an operation
     * @param operationId The identifier of the operation
     * @return operation The operation details
     */
    function getOperation(bytes32 operationId) external view returns (Operation memory operation);
    
    /**
     * @notice Gets information about a registered keeper
     * @param keeper The address of the keeper
     * @return keeperInfo The keeper information
     */
    function getKeeperInfo(address keeper) external view returns (Keeper memory keeperInfo);
    
    /**
     * @notice Unstakes and withdraws funds from the keeper network
     * @param amount Amount to unstake and withdraw
     * @return success True if withdrawal was successful
     */
    function unstake(uint256 amount) external returns (bool success);
    
    /**
     * @notice Called when a cross-chain operation is completed
     * @param operationId The identifier of the completed operation
     * @param success Whether the operation was successful
     */
    function onOperationCompleted(bytes32 operationId, bool success) external;
}
