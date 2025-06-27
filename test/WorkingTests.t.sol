// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {KeeperNetwork} from "../src/keepers/KeeperNetwork.sol";
import {RiskScoring} from "../src/libraries/RiskScoring.sol";
import {CirclePaymaster} from "../src/integrations/CirclePaymaster.sol";
import {IKeeperNetwork} from "../src/interfaces/IKeeperNetwork.sol";

/**
 * @title WorkingTests
 * @notice Consolidated test file for components that don't depend on Uniswap v4-core
 * @dev This bypasses the function overload clash in v4-core dependencies
 */
contract WorkingTestsContract is Test {
    MockERC20 public token;
    KeeperNetwork public keeperNetwork;
    RiskScoring public riskScoring;
    CirclePaymaster public paymaster;
    
    address public admin;
    address public user1;
    address public user2;
    address public treasury;
    
    // Mock VRF Coordinator for testing
    address public mockVRFCoordinator = address(0x123);
    bytes32 public mockKeyHash = bytes32(uint256(0x456));
    uint64 public mockSubscriptionId = 1;
    
    uint256 public constant MINIMUM_STAKE = 50000 * 1e6; // 50,000 USDC
    
    function setUp() public {
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        treasury = makeAddr("treasury");
        
        // Deploy mock USDC token
        token = new MockERC20("USDC", "USDC", 6);
        
        // Deploy RiskScoring
        vm.prank(admin);
        riskScoring = new RiskScoring(admin);
        
        // Deploy KeeperNetwork
        vm.prank(admin);
        keeperNetwork = new KeeperNetwork(
            admin,
            address(token),
            MINIMUM_STAKE,
            treasury,
            mockVRFCoordinator,
            mockKeyHash,
            mockSubscriptionId
        );
        
        // Deploy CirclePaymaster (needs oracle address)
        vm.prank(admin);
        paymaster = new CirclePaymaster(
            address(token),
            makeAddr("mockOracle"), // Mock oracle address
            admin
        );
        
        // Mint tokens for testing
        token.mint(user1, 1000000 * 1e6); // 1M USDC
        token.mint(user2, 1000000 * 1e6); // 1M USDC
        token.mint(admin, 1000000 * 1e6);  // 1M USDC
    }
    
    // =============== BASIC FUNCTIONALITY TESTS ===============
    
    function test_BasicSetup() public {
        assertEq(token.name(), "USDC");
        assertEq(token.symbol(), "USDC");
        assertEq(token.decimals(), 6);
        assertEq(token.balanceOf(user1), 1000000 * 1e6);
    }
    
    // =============== KEEPER NETWORK TESTS ===============
    
    function test_KeeperNetwork_Deployment() public {
        assertEq(keeperNetwork.owner(), admin);
        assertEq(address(keeperNetwork.stakingToken()), address(token));
        assertEq(keeperNetwork.minimumStake(), MINIMUM_STAKE);
        assertEq(keeperNetwork.treasury(), treasury);
    }
    
    function test_KeeperNetwork_RegisterKeeper() public {
        vm.startPrank(user1);
        token.approve(address(keeperNetwork), MINIMUM_STAKE);
        
        bool success = keeperNetwork.registerKeeper(MINIMUM_STAKE);
        assertTrue(success);
        
        IKeeperNetwork.Keeper memory keeper = keeperNetwork.getKeeperInfo(user1);
        assertEq(keeper.stake, MINIMUM_STAKE);
        assertEq(keeper.performanceScore, 50); // Initial score
        vm.stopPrank();
    }
    
    function test_KeeperNetwork_UnstakeKeeper() public {
        // First register
        vm.startPrank(user1);
        token.approve(address(keeperNetwork), MINIMUM_STAKE);
        keeperNetwork.registerKeeper(MINIMUM_STAKE);
        
        // Then unstake
        uint256 balanceBefore = token.balanceOf(user1);
        bool success = keeperNetwork.unstake(MINIMUM_STAKE);
        assertTrue(success);
        
        uint256 balanceAfter = token.balanceOf(user1);
        assertEq(balanceAfter - balanceBefore, MINIMUM_STAKE);
        
        IKeeperNetwork.Keeper memory keeper = keeperNetwork.getKeeperInfo(user1);
        assertEq(keeper.stake, 0);
        vm.stopPrank();
    }
    
    function test_KeeperNetwork_JobSubmission() public {
        bytes32 jobId = keccak256("test-job");
        uint8 jobType = 2; // Rebalance
        bytes memory jobData = abi.encode("test-data");
        
        keeperNetwork.submitJob(jobId, jobType, jobData);
        
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
    }
    
    function test_KeeperNetwork_JobExecution() public {
        // Register keeper first
        vm.prank(user1);
        token.approve(address(keeperNetwork), MINIMUM_STAKE);
        vm.prank(user1);
        keeperNetwork.registerKeeper(MINIMUM_STAKE);
        
        // Submit job
        bytes32 jobId = keccak256("test-job");
        keeperNetwork.submitJob(jobId, 2, abi.encode("test-data"));
        
        // Execute job
        vm.prank(user1);
        keeperNetwork.executeJob(jobId);
        
        (, , , , bool isCompleted, address executor) = keeperNetwork.getJob(jobId);
        assertTrue(isCompleted);
        assertEq(executor, user1);
    }
    
    // =============== RISK SCORING TESTS ===============
    
    function test_RiskScoring_Deployment() public {
        assertEq(riskScoring.owner(), admin);
        assertTrue(riskScoring.isActive());
    }
    
    function test_RiskScoring_AssessRisk() public {
        uint256 riskScore = riskScoring.assessRisk(
            user1,
            address(0x1), // token0
            address(0x2), // token1
            1000 * 1e6    // amount
        );
        
        // Should return a reasonable risk score
        assertTrue(riskScore >= 0 && riskScore <= 1000);
    }
    
    function test_RiskScoring_UpdateUserReputation() public {
        // Set up tokens with moderate risk levels so reputation can make a difference
        vm.prank(admin);
        riskScoring.setTokenRiskLevel(address(0x1), 300); // Moderate risk
        vm.prank(admin);
        riskScoring.setTokenRiskLevel(address(0x2), 300); // Moderate risk
        
        // First establish baseline with moderate-risk tokens
        uint256 initialScore = riskScoring.assessRisk(
            user1,
            address(0x1),
            address(0x2),
            1000 * 1e6
        );
        
        // Update reputation positively
        vm.prank(admin);
        riskScoring.updateUserReputation(user1, 200, true); // +200 reputation
        
        uint256 newScore = riskScoring.assessRisk(
            user1,
            address(0x1),
            address(0x2),
            1000 * 1e6
        );
        
        // New score should be lower (better) than initial score due to improved reputation
        assertTrue(newScore < initialScore);
    }
    
    // =============== CIRCLE PAYMASTER TESTS ===============
    
    function test_CirclePaymaster_Deployment() public {
        assertEq(paymaster.owner(), admin);
        assertEq(address(paymaster.usdcToken()), address(token));
    }
    
    function test_CirclePaymaster_DepositFunds() public {
        uint256 depositAmount = 1000 * 1e6;
        
        vm.startPrank(user1);
        token.approve(address(paymaster), depositAmount);
        paymaster.depositFunds(depositAmount);
        
        assertEq(paymaster.userBalances(user1), depositAmount);
        vm.stopPrank();
    }
    
    function test_CirclePaymaster_WithdrawFunds() public {
        uint256 depositAmount = 1000 * 1e6;
        
        // First deposit
        vm.startPrank(user1);
        token.approve(address(paymaster), depositAmount);
        paymaster.depositFunds(depositAmount);
        
        // Then withdraw
        uint256 balanceBefore = token.balanceOf(user1);
        paymaster.withdrawFunds(depositAmount);
        uint256 balanceAfter = token.balanceOf(user1);
        
        assertEq(balanceAfter - balanceBefore, depositAmount);
        assertEq(paymaster.userBalances(user1), 0);
        vm.stopPrank();
    }
    
    function test_CirclePaymaster_ProcessPayment() public {
        uint256 depositAmount = 1000 * 1e6;
        uint256 paymentAmount = 100 * 1e6;
        
        // Deposit funds for user1
        vm.startPrank(user1);
        token.approve(address(paymaster), depositAmount);
        paymaster.depositFunds(depositAmount);
        vm.stopPrank();
        
        // Simulate gas payment for user1
        vm.prank(admin);
        paymaster.payForTransaction(user1, 21000, 20 gwei); // Standard gas usage
        
        // Check that user balance decreased
        assertTrue(paymaster.userBalances(user1) < depositAmount);
    }
    
    // =============== INTEGRATION TESTS ===============
    
    function test_Integration_KeeperNetworkWithRiskScoring() public {
        // Register keeper
        vm.startPrank(user1);
        token.approve(address(keeperNetwork), MINIMUM_STAKE);
        keeperNetwork.registerKeeper(MINIMUM_STAKE);
        vm.stopPrank();
        
        // Check risk score for keeper
        uint256 riskScore = riskScoring.assessRisk(
            user1,
            address(token),
            address(0x1),
            10000 * 1e6 // Large amount
        );
        
        // Should have reasonable risk score
        assertTrue(riskScore > 0 && riskScore <= 1000);
        
        // Verify keeper is registered
        IKeeperNetwork.Keeper memory keeper = keeperNetwork.getKeeperInfo(user1);
        assertEq(keeper.stake, MINIMUM_STAKE);
    }
    
    function test_Integration_PaymasterWithKeeperRewards() public {
        // Setup paymaster balance
        vm.startPrank(admin);
        token.approve(address(paymaster), 1000000 * 1e6);
        paymaster.depositFunds(1000000 * 1e6);
        vm.stopPrank();
        
        // Register keeper
        vm.startPrank(user1);
        token.approve(address(keeperNetwork), MINIMUM_STAKE);
        keeperNetwork.registerKeeper(MINIMUM_STAKE);
        vm.stopPrank();
        
        // Admin rewards keeper
        uint256 rewardAmount = 100 * 1e6;
        uint256 balanceBefore = token.balanceOf(user1);
        
        vm.prank(admin);
        keeperNetwork.rewardKeeper(user1, rewardAmount);
        
        uint256 balanceAfter = token.balanceOf(user1);
        assertEq(balanceAfter - balanceBefore, rewardAmount);
    }
}
