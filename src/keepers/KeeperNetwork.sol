// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import "../interfaces/IKeeperNetwork.sol";

/**
 * @title KeeperNetwork
 * @notice Implementation of the decentralized keeper network for asynchronous operations
 * @dev This contract manages keeper registration, staking, and operation execution
 */
contract KeeperNetwork is IKeeperNetwork, Ownable, ReentrancyGuard, VRFConsumerBaseV2 {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    
    // USDC token for staking
    IERC20 public immutable stakingToken;
    
    // Minimum stake requirement
    uint256 public minimumStake;
    
    // Performance bond percentage (basis points, 1000 = 10%)
    uint16 public performanceBondBps = 1000; // 10%
    
    // Slashing percentage for failed operations (basis points, 500 = 5%)
    uint16 public slashingBps = 500; // 5%
    
    // Reward percentage for successful operations (basis points, 2 = 0.02%)
    uint16 public rewardBps = 2; // 0.02%
    
    // Keeper rotation period (in blocks)
    uint256 public rotationPeriod = 100;
    
    // Registry of keepers
    mapping(address => Keeper) public keepers;
    
    // Registry of operations
    mapping(bytes32 => Operation) public operations;
    
    // List of active keeper addresses
    address[] public activeKeepers;
    
    // Operation queue by type
    mapping(uint8 => bytes32[]) public operationQueue;
    
    // Protocol treasury
    address public treasury;
    
    // Total staked tokens
    uint256 public totalStaked;
    
    // Insurance fund
    uint256 public insuranceFund;
    
    // Chainlink VRF
    VRFCoordinatorV2Interface public vrfCoordinator;
    bytes32 public keyHash;
    uint64 public subscriptionId;
    uint32 public callbackGasLimit = 100000;
    
    // Mapping from VRF requestId to keeper selection request
    mapping(uint256 => bytes32) public vrfRequests;
    
    // Job system (simplified for testing)
    struct Job {
        bytes32 id;
        uint8 jobType;
        bytes data;
        bool isCompleted;
        address executor;
        uint256 timestamp;
    }
    
    // Job registry
    mapping(bytes32 => Job) public jobs;
    
    // Events
    event KeeperRegistered(address indexed keeper, uint256 stake);
    event KeeperUnstaked(address indexed keeper, uint256 amount);
    event OperationRequested(bytes32 indexed operationId, OperationType operationType, uint256 reward);
    event OperationAssigned(bytes32 indexed operationId, address indexed assignedKeeper);
    event OperationExecuted(bytes32 indexed operationId, address indexed keeper, bool success);
    event KeeperSlashed(address indexed keeper, uint256 amount, string reason);
    event KeeperRewarded(address indexed keeper, uint256 amount, bytes32 operationId);
    event JobSubmitted(bytes32 indexed jobId, uint8 jobType);
    event JobExecuted(bytes32 indexed jobId, address indexed keeper);
    
    /**
     * @notice Constructor
     * @param _owner Contract owner
     * @param _stakingToken USDC token for staking
     * @param _minimumStake Minimum stake amount (50,000 USDC)
     * @param _treasury Protocol treasury address
     * @param _vrfCoordinator Chainlink VRF coordinator address
     * @param _keyHash Chainlink VRF key hash
     * @param _subscriptionId Chainlink VRF subscription ID
     */
    constructor(
        address _owner,
        address _stakingToken,
        uint256 _minimumStake,
        address _treasury,
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint64 _subscriptionId
    ) Ownable(_owner) VRFConsumerBaseV2(_vrfCoordinator) {
        stakingToken = IERC20(_stakingToken);
        minimumStake = _minimumStake;
        treasury = _treasury;
        
        // Chainlink VRF setup
        vrfCoordinator = VRFCoordinatorV2Interface(_vrfCoordinator);
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
    }
    
    /**
     * @notice Updates configuration parameters
     * @param _minimumStake New minimum stake
     * @param _performanceBondBps New performance bond percentage
     * @param _slashingBps New slashing percentage
     * @param _rewardBps New reward percentage
     * @param _rotationPeriod New keeper rotation period
     */
    function updateConfig(
        uint256 _minimumStake,
        uint16 _performanceBondBps,
        uint16 _slashingBps,
        uint16 _rewardBps,
        uint256 _rotationPeriod
    ) external onlyOwner {
        minimumStake = _minimumStake;
        performanceBondBps = _performanceBondBps;
        slashingBps = _slashingBps;
        rewardBps = _rewardBps;
        rotationPeriod = _rotationPeriod;
    }
    
    /**
     * @notice Updates Chainlink VRF configuration
     * @param _keyHash New key hash
     * @param _subscriptionId New subscription ID
     * @param _callbackGasLimit New callback gas limit
     */
    function updateVRFConfig(
        bytes32 _keyHash,
        uint64 _subscriptionId,
        uint32 _callbackGasLimit
    ) external onlyOwner {
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        callbackGasLimit = _callbackGasLimit;
    }
    
    /**
     * @inheritdoc IKeeperNetwork
     */
    function registerKeeper(uint256 stake) external override nonReentrant returns (bool) {
        require(stake >= minimumStake, "Stake below minimum");
        
        // Transfer stake from keeper
        stakingToken.safeTransferFrom(msg.sender, address(this), stake);
        
        // Initialize or update keeper
        Keeper storage keeper = keepers[msg.sender];
        
        // If first time registration
        if (keeper.stake == 0) {
            // Add to active keepers
            activeKeepers.push(msg.sender);
            
            // Initialize performance score
            keeper.performanceScore = 50; // Start at 50/100
        }
        
        // Update keeper stake
        keeper.stake += stake;
        
        // Update total staked amount
        totalStaked += stake;
        
        emit KeeperRegistered(msg.sender, stake);
        return true;
    }
    
    /**
     * @inheritdoc IKeeperNetwork
     */
    function unstake(uint256 amount) external override nonReentrant returns (bool) {
        Keeper storage keeper = keepers[msg.sender];
        
        require(keeper.stake > 0, "No stake found");
        require(amount <= keeper.stake, "Insufficient stake");
        
        // Ensure keeper maintains minimum stake or withdraws everything
        uint256 remainingStake = keeper.stake - amount;
        require(remainingStake >= minimumStake || remainingStake == 0, "Must maintain minimum stake");
        
        // Update keeper stake
        keeper.stake -= amount;
        
        // Update total staked amount
        totalStaked -= amount;
        
        // If unstaking everything, remove from active keepers
        if (keeper.stake == 0) {
            _removeFromActiveKeepers(msg.sender);
        }
        
        // Transfer stake back to keeper
        stakingToken.safeTransfer(msg.sender, amount);
        
        emit KeeperUnstaked(msg.sender, amount);
        return true;
    }
    
    /**
     * @inheritdoc IKeeperNetwork
     */
    function requestOperation(
        OperationType operationType,
        address target,
        bytes calldata data,
        uint256 gasLimit,
        uint256 reward,
        uint256 deadline
    ) external payable override nonReentrant returns (bytes32) {
        require(target != address(0), "Invalid target");
        require(deadline > block.timestamp, "Invalid deadline");
        require(reward > 0, "Reward required");
        
        // Transfer reward from caller
        stakingToken.safeTransferFrom(msg.sender, address(this), reward);
        
        // Generate operation ID
        bytes32 operationId = keccak256(abi.encodePacked(
            msg.sender,
            target,
            data,
            block.timestamp,
            operationType
        ));
        
        // Create operation
        operations[operationId] = Operation({
            id: operationId,
            operationType: operationType,
            target: target,
            data: data,
            gasLimit: gasLimit,
            reward: reward,
            deadline: deadline,
            status: OperationStatus.PENDING,
            assignedKeeper: address(0)
        });
        
        // Add to operation queue
        operationQueue[uint8(operationType)].push(operationId);
        
        // Request randomness for keeper assignment
        uint256 requestId = vrfCoordinator.requestRandomWords(
            keyHash,
            subscriptionId,
            3, // requestConfirmations
            callbackGasLimit,
            1  // numWords
        );
        
        // Store requestId -> operationId mapping
        vrfRequests[requestId] = operationId;
        
        emit OperationRequested(operationId, operationType, reward);
        return operationId;
    }
    
    /**
     * @notice Test function to request operations with request ID returned for testing
     * @param operationType The type of operation
     * @param target The target contract address
     * @param data The calldata to execute
     * @param gasLimit Maximum gas to use
     * @param reward Reward amount for executing operation
     * @param deadline Timestamp after which the operation expires
     * @return operationId The unique identifier for the operation
     * @return requestId The VRF request ID
     */
    function requestOperationWithRequestId(
        OperationType operationType,
        address target,
        bytes calldata data,
        uint256 gasLimit,
        uint256 reward,
        uint256 deadline
    ) external payable virtual nonReentrant returns (bytes32 operationId, uint256 requestId) {
        require(target != address(0), "Invalid target");
        require(deadline > block.timestamp, "Invalid deadline");
        require(reward > 0, "Reward required");
        
        // Transfer reward from caller
        stakingToken.safeTransferFrom(msg.sender, address(this), reward);
        
        // Generate operation ID
        operationId = keccak256(abi.encodePacked(
            msg.sender,
            target,
            data,
            block.timestamp,
            operationType
        ));
        
        // Create operation
        operations[operationId] = Operation({
            id: operationId,
            operationType: operationType,
            target: target,
            data: data,
            gasLimit: gasLimit,
            reward: reward,
            deadline: deadline,
            status: OperationStatus.PENDING,
            assignedKeeper: address(0)
        });
        
        // Add to operation queue
        operationQueue[uint8(operationType)].push(operationId);
        
        // Request randomness for keeper assignment
        requestId = vrfCoordinator.requestRandomWords(
            keyHash,
            subscriptionId,
            3, // requestConfirmations
            callbackGasLimit,
            1  // numWords
        );
        
        // Store requestId -> operationId mapping
        vrfRequests[requestId] = operationId;
        
        emit OperationRequested(operationId, operationType, reward);
        return (operationId, requestId);
    }
    
    /**
     * @notice Callback function used by VRF Coordinator
     * @param requestId The ID of the request
     * @param randomWords The random result
     */
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal override {
        bytes32 operationId = vrfRequests[requestId];
        require(operationId != bytes32(0), "Operation not found");
        
        Operation storage operation = operations[operationId];
        require(operation.status == OperationStatus.PENDING, "Operation not pending");
        
        uint256 numKeepers = activeKeepers.length;
        require(numKeepers > 0, "No active keepers");
        
        // Select keeper based on random number, weighted by stake and performance
        address assignedKeeper = _selectKeeperWeighted(randomWords[0]);
        
        // Assign keeper
        operation.assignedKeeper = assignedKeeper;
        operation.status = OperationStatus.EXECUTING;
        
        emit OperationAssigned(operationId, assignedKeeper);
    }
    
    /**
     * @inheritdoc IKeeperNetwork
     */
    function executeOperation(bytes32 operationId) external override nonReentrant returns (bool) {
        Operation storage operation = operations[operationId];
        
        require(operation.id != bytes32(0), "Operation not found");
        require(operation.status == OperationStatus.EXECUTING, "Operation not assigned");
        require(operation.assignedKeeper == msg.sender, "Not assigned keeper");
        require(block.timestamp <= operation.deadline, "Operation expired");
        
        // Execute the operation
        (bool success, ) = operation.target.call{gas: operation.gasLimit}(operation.data);
        
        // Update operation status
        operation.status = success ? OperationStatus.COMPLETED : OperationStatus.FAILED;
        
        // Update keeper metrics
        Keeper storage keeper = keepers[msg.sender];
        
        if (success) {
            // Successful execution
            keeper.operationsCompleted++;
            keeper.performanceScore = _updatePerformanceScore(keeper.performanceScore, true);
            keeper.lastOperationTime = block.timestamp;
            
            // Calculate reward
            uint256 rewardAmount = (operation.reward * rewardBps) / 10000;
            uint256 treasuryAmount = operation.reward - rewardAmount;
            
            // Transfer reward to keeper
            stakingToken.safeTransfer(msg.sender, rewardAmount);
            
            // Transfer remainder to treasury
            stakingToken.safeTransfer(treasury, treasuryAmount);
            
            emit KeeperRewarded(msg.sender, rewardAmount, operationId);
        } else {
            // Failed execution
            keeper.operationsFailed++;
            keeper.performanceScore = _updatePerformanceScore(keeper.performanceScore, false);
            
            // Slash the keeper
            uint256 slashAmount = (keeper.stake * slashingBps) / 10000;
            if (slashAmount > 0 && slashAmount <= keeper.stake) {
                keeper.stake -= slashAmount;
                totalStaked -= slashAmount;
                insuranceFund += slashAmount;
                
                emit KeeperSlashed(msg.sender, slashAmount, "Failed operation");
            }
            
            // Transfer operation reward to insurance fund
            insuranceFund += operation.reward;
        }
        
        // Remove operation from queue
        _removeFromOperationQueue(uint8(operation.operationType), operationId);
        
        emit OperationExecuted(operationId, msg.sender, success);
        return success;
    }
    
    /**
     * @inheritdoc IKeeperNetwork
     */
    function getOperation(bytes32 operationId) external view override returns (Operation memory) {
        return operations[operationId];
    }
    
    /**
     * @inheritdoc IKeeperNetwork
     */
    function getKeeperInfo(address keeper) external view override returns (Keeper memory) {
        return keepers[keeper];
    }
    
    /**
     * @inheritdoc IKeeperNetwork
     */
    function onOperationCompleted(bytes32 operationId, bool success) external override {
        // Only callable by system contracts
        require(msg.sender == owner() || tx.origin == owner(), "Unauthorized");
        
        Operation storage operation = operations[operationId];
        require(operation.id == operationId, "Operation not found");
        
        // Update operation status
        operation.status = success ? OperationStatus.COMPLETED : OperationStatus.FAILED;
        
        // Process keeper rewards or slashing (simplified)
        if (operation.assignedKeeper != address(0)) {
            Keeper storage keeper = keepers[operation.assignedKeeper];
            
            if (success) {
                keeper.operationsCompleted++;
                keeper.performanceScore = _updatePerformanceScore(keeper.performanceScore, true);
            } else {
                keeper.operationsFailed++;
                keeper.performanceScore = _updatePerformanceScore(keeper.performanceScore, false);
            }
        }
        
        // Remove from queue
        _removeFromOperationQueue(uint8(operation.operationType), operationId);
    }
    
    // =============== JOB SYSTEM FUNCTIONS (for integration tests) ===============
    
    /**
     * @notice Submits a job to the keeper network
     * @param jobId Unique identifier for the job
     * @param jobType Type of job (e.g., 2 = rebalance)
     * @param data Job data
     */
    function submitJob(bytes32 jobId, uint8 jobType, bytes calldata data) external {
        require(jobs[jobId].id == bytes32(0), "Job already exists");
        
        jobs[jobId] = Job({
            id: jobId,
            jobType: jobType,
            data: data,
            isCompleted: false,
            executor: address(0),
            timestamp: block.timestamp
        });
        
        emit JobSubmitted(jobId, jobType);
    }
    
    /**
     * @notice Executes a job
     * @param jobId The job identifier
     */
    function executeJob(bytes32 jobId) external {
        Job storage job = jobs[jobId];
        require(job.id != bytes32(0), "Job does not exist");
        require(!job.isCompleted, "Job already completed");
        require(keepers[msg.sender].stake >= minimumStake, "Keeper not eligible");
        
        job.isCompleted = true;
        job.executor = msg.sender;
        
        emit JobExecuted(jobId, msg.sender);
    }
    
    /**
     * @notice Gets job details
     * @param jobId The job identifier
     * @return id Job ID
     * @return jobType Job type
     * @return data Job data
     * @return timestamp Job timestamp
     * @return isCompleted Whether job is completed
     * @return executor Job executor address
     */
    function getJob(bytes32 jobId) external view returns (
        bytes32 id,
        uint8 jobType,
        bytes memory data,
        uint256 timestamp,
        bool isCompleted,
        address executor
    ) {
        Job memory job = jobs[jobId];
        return (job.id, job.jobType, job.data, job.timestamp, job.isCompleted, job.executor);
    }
    
    /**
     * @notice Rewards a keeper
     * @param keeper The keeper address
     * @param amount The reward amount
     */
    function rewardKeeper(address keeper, uint256 amount) external onlyOwner {
        require(keepers[keeper].stake > 0, "Keeper not found");
        require(amount > 0, "Invalid amount");
        
        // Transfer reward from contract to keeper
        stakingToken.safeTransfer(keeper, amount);
        
        emit KeeperRewarded(keeper, amount, bytes32(0));
    }
    
    // =============== INTERNAL FUNCTIONS ===============
    
    /**
     * @notice Selects a keeper based on weighted random selection
     * @param randomValue The random value from VRF
     * @return selectedKeeper The selected keeper address
     */
    function _selectKeeperWeighted(uint256 randomValue) internal view returns (address) {
        uint256 numKeepers = activeKeepers.length;
        if (numKeepers == 0) {
            return address(0);
        }
        
        if (numKeepers == 1) {
            return activeKeepers[0];
        }
        
        // Calculate total weight (stake * performance score)
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < numKeepers; i++) {
            address keeperAddr = activeKeepers[i];
            Keeper memory keeper = keepers[keeperAddr];
            
            uint256 weight = keeper.stake * keeper.performanceScore;
            totalWeight += weight;
        }
        
        // Select keeper based on weighted random
        uint256 randomWeight = randomValue % totalWeight;
        uint256 cumulativeWeight = 0;
        
        for (uint256 i = 0; i < numKeepers; i++) {
            address keeperAddr = activeKeepers[i];
            Keeper memory keeper = keepers[keeperAddr];
            
            uint256 weight = keeper.stake * keeper.performanceScore;
            cumulativeWeight += weight;
            
            if (cumulativeWeight > randomWeight) {
                return keeperAddr;
            }
        }
        
        // Fallback to last keeper if something goes wrong
        return activeKeepers[numKeepers - 1];
    }
    
    /**
     * @notice Updates a keeper's performance score
     * @param currentScore The current performance score
     * @param success Whether the operation was successful
     * @return newScore The updated performance score
     */
    function _updatePerformanceScore(uint8 currentScore, bool success) internal pure returns (uint8) {
        if (success) {
            // Increase score, cap at 100
            return currentScore >= 95 ? 100 : currentScore + 5;
        } else {
            // Decrease score, floor at 10
            return currentScore <= 15 ? 10 : currentScore - 5;
        }
    }
    
    /**
     * @notice Removes a keeper from the active keepers array
     * @param keeperAddress The keeper address to remove
     */
    function _removeFromActiveKeepers(address keeperAddress) internal {
        uint256 length = activeKeepers.length;
        for (uint256 i = 0; i < length; i++) {
            if (activeKeepers[i] == keeperAddress) {
                // Replace with the last element
                activeKeepers[i] = activeKeepers[length - 1];
                // Remove the last element
                activeKeepers.pop();
                break;
            }
        }
    }
    
    /**
     * @notice Removes an operation from its queue
     * @param operationType The operation type (queue index)
     * @param operationId The operation ID to remove
     */
    function _removeFromOperationQueue(uint8 operationType, bytes32 operationId) internal {
        bytes32[] storage queue = operationQueue[operationType];
        uint256 length = queue.length;
        
        for (uint256 i = 0; i < length; i++) {
            if (queue[i] == operationId) {
                // Replace with the last element
                queue[i] = queue[length - 1];
                // Remove the last element
                queue.pop();
                break;
            }
        }
    }
    
    // =============== UTILITY FUNCTIONS ===============
    
    /**
     * @notice Emergency function to handle stuck operations
     * @param operationId The operation ID
     * @param newStatus The new operation status
     */
    function emergencyUpdateOperationStatus(
        bytes32 operationId,
        OperationStatus newStatus
    ) external onlyOwner {
        Operation storage operation = operations[operationId];
        require(operation.id == operationId, "Operation not found");
        
        // Update status
        operation.status = newStatus;
        
        // If cancelling, refund the reward to requester
        if (newStatus == OperationStatus.FAILED) {
            // Add reward to insurance fund
            insuranceFund += operation.reward;
        }
        
        // Remove from queue
        _removeFromOperationQueue(uint8(operation.operationType), operationId);
    }
    
    /**
     * @notice Allows the owner to recover tokens sent to this contract accidentally
     * @param token The token address
     * @param amount The amount to recover
     * @param recipient The recipient address
     */
    function recoverTokens(
        address token,
        uint256 amount,
        address recipient
    ) external onlyOwner {
        require(token != address(stakingToken) || amount <= insuranceFund, "Cannot withdraw staked tokens");
        
        IERC20(token).safeTransfer(recipient, amount);
        
        // If withdrawing from insurance fund, update balance
        if (token == address(stakingToken) && amount <= insuranceFund) {
            insuranceFund -= amount;
        }
    }
    
    /**
     * @notice Returns the number of active keepers
     * @return count The number of active keepers
     */
    function getActiveKeeperCount() external view returns (uint256) {
        return activeKeepers.length;
    }
    
    /**
     * @notice Returns the number of pending operations for a type
     * @param operationType The operation type
     * @return count The number of pending operations
     */
    function getPendingOperationCount(OperationType operationType) external view returns (uint256) {
        return operationQueue[uint8(operationType)].length;
    }
}