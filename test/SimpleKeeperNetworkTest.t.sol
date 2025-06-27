// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {KeeperNetwork} from "../src/keepers/KeeperNetwork.sol";
import {IKeeperNetwork} from "../src/interfaces/IKeeperNetwork.sol";

/**
 * @title SimpleKeeperNetworkTest
 * @notice Simplified tests for KeeperNetwork that don't rely on Uniswap v4 imports
 */
contract SimpleKeeperNetworkTest is Test {
    KeeperNetwork public keeperNetwork;
    MockERC20 public usdc;
    
    address public admin;
    address public user1;
    address public keeper1;
    address public treasury;
    
    uint256 public constant MINIMUM_STAKE = 1000 * 1e6; // 1000 USDC
    uint256 public constant INITIAL_BALANCE = 10000 * 1e6; // 10000 USDC
    
    function setUp() public {
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        keeper1 = makeAddr("keeper1");
        treasury = makeAddr("treasury");
        
        // Deploy USDC mock
        usdc = new MockERC20("USD Coin", "USDC", 6);
        
        // Deploy KeeperNetwork
        vm.prank(admin);
        keeperNetwork = new KeeperNetwork(
            admin,
            address(usdc),
            MINIMUM_STAKE,
            treasury,
            admin, // VRF coordinator placeholder
            bytes32(0), // Key hash placeholder
            uint64(1) // Subscription ID placeholder
        );
        
        // Mint USDC to test accounts
        usdc.mint(keeper1, INITIAL_BALANCE);
        usdc.mint(user1, INITIAL_BALANCE);
    }
    
    function test_Deployment() public {
        assertEq(keeperNetwork.minimumStake(), MINIMUM_STAKE);
        assertEq(address(keeperNetwork.stakingToken()), address(usdc));
        assertEq(keeperNetwork.treasury(), treasury);
        assertEq(keeperNetwork.owner(), admin);
    }
    
    function test_KeeperRegistration() public {
        uint256 stakeAmount = MINIMUM_STAKE;
        
        // Approve and register keeper
        vm.startPrank(keeper1);
        usdc.approve(address(keeperNetwork), stakeAmount);
        
        vm.expectEmit(true, false, false, true);
        emit KeeperRegistered(keeper1, stakeAmount);
        
        bool success = keeperNetwork.registerKeeper(stakeAmount);
        assertTrue(success);
        vm.stopPrank();
        
        // Verify keeper is registered
        IKeeperNetwork.Keeper memory keeper = keeperNetwork.getKeeperInfo(keeper1);
        assertEq(keeper.stake, stakeAmount);
        assertEq(keeper.performanceScore, 50); // Default starting score
        assertEq(keeperNetwork.getActiveKeeperCount(), 1);
    }
    
    function test_KeeperRegistration_InsufficientStake() public {
        uint256 stakeAmount = MINIMUM_STAKE - 1;
        
        vm.startPrank(keeper1);
        usdc.approve(address(keeperNetwork), stakeAmount);
        
        vm.expectRevert("Stake below minimum");
        keeperNetwork.registerKeeper(stakeAmount);
        vm.stopPrank();
    }
    
    function test_Unstaking() public {
        uint256 stakeAmount = MINIMUM_STAKE * 2;
        uint256 unstakeAmount = MINIMUM_STAKE;
        
        // Register keeper first
        vm.startPrank(keeper1);
        usdc.approve(address(keeperNetwork), stakeAmount);
        keeperNetwork.registerKeeper(stakeAmount);
        
        // Unstake partial amount
        vm.expectEmit(true, false, false, true);
        emit KeeperUnstaked(keeper1, unstakeAmount);
        
        bool success = keeperNetwork.unstake(unstakeAmount);
        assertTrue(success);
        vm.stopPrank();
        
        // Verify unstaking
        IKeeperNetwork.Keeper memory keeper = keeperNetwork.getKeeperInfo(keeper1);
        assertEq(keeper.stake, stakeAmount - unstakeAmount);
    }
    
    function test_JobSystem() public {
        // Register keeper first
        vm.startPrank(keeper1);
        usdc.approve(address(keeperNetwork), MINIMUM_STAKE);
        keeperNetwork.registerKeeper(MINIMUM_STAKE);
        vm.stopPrank();
        
        // Submit job
        bytes32 jobId = keccak256("test-job-1");
        uint8 jobType = 2; // Rebalance type
        bytes memory jobData = abi.encode("test data");
        
        vm.expectEmit(true, false, false, true);
        emit JobSubmitted(jobId, jobType);
        
        keeperNetwork.submitJob(jobId, jobType, jobData);
        
        // Verify job exists
        (
            bytes32 id,
            uint8 returnedJobType,
            bytes memory data,
            uint256 timestamp,
            bool isCompleted,
            address executor
        ) = keeperNetwork.getJob(jobId);
        
        assertEq(id, jobId);
        assertEq(returnedJobType, jobType);
        assertEq(data, jobData);
        assertFalse(isCompleted);
        assertEq(executor, address(0));
        
        // Execute job
        vm.prank(keeper1);
        vm.expectEmit(true, true, false, false);
        emit JobExecuted(jobId, keeper1);
        keeperNetwork.executeJob(jobId);
        
        // Verify job completion
        (, , , , isCompleted, executor) = keeperNetwork.getJob(jobId);
        assertTrue(isCompleted);
        assertEq(executor, keeper1);
    }
    
    function test_RewardKeeper() public {
        // Register keeper first
        vm.startPrank(keeper1);
        usdc.approve(address(keeperNetwork), MINIMUM_STAKE);
        keeperNetwork.registerKeeper(MINIMUM_STAKE);
        vm.stopPrank();
        
        // Fund the contract
        uint256 rewardAmount = 100 * 1e6; // 100 USDC
        usdc.mint(address(keeperNetwork), rewardAmount);
        
        uint256 keeperBalanceBefore = usdc.balanceOf(keeper1);
        
        // Reward keeper
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit KeeperRewarded(keeper1, rewardAmount, bytes32(0));
        keeperNetwork.rewardKeeper(keeper1, rewardAmount);
        
        uint256 keeperBalanceAfter = usdc.balanceOf(keeper1);
        assertEq(keeperBalanceAfter - keeperBalanceBefore, rewardAmount);
    }
    
    function test_ConfigurationUpdates() public {
        uint256 newMinStake = 2000 * 1e6;
        uint16 newPerformanceBond = 1500;
        uint16 newSlashing = 750;
        uint16 newReward = 3;
        uint256 newRotation = 200;
        
        vm.prank(admin);
        keeperNetwork.updateConfig(
            newMinStake,
            newPerformanceBond,
            newSlashing,
            newReward,
            newRotation
        );
        
        assertEq(keeperNetwork.minimumStake(), newMinStake);
        assertEq(keeperNetwork.performanceBondBps(), newPerformanceBond);
        assertEq(keeperNetwork.slashingBps(), newSlashing);
        assertEq(keeperNetwork.rewardBps(), newReward);
        assertEq(keeperNetwork.rotationPeriod(), newRotation);
    }
    
    function test_VRFConfigurationUpdates() public {
        bytes32 newKeyHash = keccak256("new-key-hash");
        uint64 newSubId = 123;
        uint32 newGasLimit = 200000;
        
        vm.prank(admin);
        keeperNetwork.updateVRFConfig(newKeyHash, newSubId, newGasLimit);
        
        assertEq(keeperNetwork.keyHash(), newKeyHash);
        assertEq(keeperNetwork.subscriptionId(), newSubId);
        assertEq(keeperNetwork.callbackGasLimit(), newGasLimit);
    }
    
    function test_OnlyOwnerFunctions() public {
        // Test unauthorized access
        vm.prank(user1);
        vm.expectRevert();
        keeperNetwork.updateConfig(1000, 1000, 500, 2, 100);
        
        vm.prank(user1);
        vm.expectRevert();
        keeperNetwork.updateVRFConfig(bytes32(0), 1, 100000);
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        keeperNetwork.rewardKeeper(keeper1, 100);
    }
    
    // Events for testing
    event KeeperRegistered(address indexed keeper, uint256 stake);
    event KeeperUnstaked(address indexed keeper, uint256 amount);
    event KeeperRewarded(address indexed keeper, uint256 amount, bytes32 operationId);
    event JobSubmitted(bytes32 indexed jobId, uint8 jobType);
    event JobExecuted(bytes32 indexed jobId, address indexed keeper);
}
