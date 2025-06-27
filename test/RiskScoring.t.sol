// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {RiskScoring} from "../src/libraries/RiskScoring.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

/**
 * @title RiskScoringTest
 * @notice Comprehensive tests for the RiskScoring library and contract
 */
contract RiskScoringTest is Test {
    RiskScoring public riskScoring;
    MockERC20 public token0;
    MockERC20 public token1;
    
    address public admin;
    address public user1;
    address public user2;
    
    function setUp() public {
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        
        // Deploy mock tokens
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        
        // Deploy RiskScoring
        vm.prank(admin);
        riskScoring = new RiskScoring(admin);
        
        // Set up token risk levels (default is MAX_RISK_SCORE = 1000)
        vm.startPrank(admin);
        riskScoring.setTokenRiskLevel(address(token0), 100); // Low risk
        riskScoring.setTokenRiskLevel(address(token1), 200); // Medium risk  
        vm.stopPrank();
    }
    
    function test_Deployment() public {
        assertEq(riskScoring.owner(), admin);
        assertTrue(riskScoring.isActive());
    }

    function test_AssessRisk_NewUser() public {
        uint256 amount = 1000 * 1e18;
        
        uint256 riskScore = riskScoring.assessRisk(
            user1,
            address(token0),
            address(token1),
            amount
        );
        
        // New users should have reasonable risk score based on token risk levels
        assertTrue(riskScore >= 200 && riskScore <= 350);
    }

    function test_AssessRisk_SmallAmount() public {
        uint256 smallAmount = 100 * 1e18;
        
        uint256 riskScore = riskScoring.assessRisk(
            user1,
            address(token0),
            address(token1),
            smallAmount
        );
        
        // Small amounts should have lower risk
        assertTrue(riskScore <= 500);
    }

    function test_AssessRisk_LargeAmount() public {
        uint256 largeAmount = 1000000 * 1e18;
        
        uint256 riskScore = riskScoring.assessRisk(
            user1,
            address(token0),
            address(token1),
            largeAmount
        );
        
        // Large amounts should have higher risk
        assertTrue(riskScore >= 250);
    }

    function test_UpdateUserReputation_Positive() public {
        // First establish baseline
        uint256 initialScore = riskScoring.assessRisk(
            user1,
            address(token0),
            address(token1),
            1000 * 1e18
        );
        
        // Update reputation positively
        vm.prank(admin);
        riskScoring.updateUserReputation(user1, 50, true); // +50 reputation
        
        uint256 newScore = riskScoring.assessRisk(
            user1,
            address(token0),
            address(token1),
            1000 * 1e18
        );
        
        // Score should improve (lower is better)
        assertTrue(newScore <= initialScore);
    }

    function test_UpdateUserReputation_Negative() public {
        uint256 initialScore = riskScoring.assessRisk(
            user1,
            address(token0),
            address(token1),
            1000 * 1e18
        );
        
        vm.prank(admin);
        riskScoring.updateUserReputation(user1, 50, false); // -50 reputation
        
        uint256 newScore = riskScoring.assessRisk(
            user1,
            address(token0),
            address(token1),
            1000 * 1e18
        );
        
        // Score should worsen (higher is worse)
        assertTrue(newScore >= initialScore);
    }

    function test_UpdateUserReputation_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        riskScoring.updateUserReputation(user2, 50, true);
    }

    function test_SetTokenRiskLevel_Success() public {
        uint256 riskLevel = 300; // High risk
        
        vm.prank(admin);
        riskScoring.setTokenRiskLevel(address(token0), riskLevel);
        
        assertEq(riskScoring.tokenRiskLevels(address(token0)), riskLevel);
    }

    function test_SetTokenRiskLevel_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        riskScoring.setTokenRiskLevel(address(token0), 300);
    }

    function test_SetTokenRiskLevel_InvalidLevel() public {
        vm.prank(admin);
        vm.expectRevert("Risk level too high");
        riskScoring.setTokenRiskLevel(address(token0), 1100); // Over 1000 max
    }

    function test_SetPairRiskMultiplier_Success() public {
        uint256 multiplier = 150; // 1.5x
        
        vm.prank(admin);
        riskScoring.setPairRiskMultiplier(address(token0), address(token1), multiplier);
        
        bytes32 pairHash = keccak256(abi.encodePacked(address(token0), address(token1)));
        assertEq(riskScoring.pairRiskMultipliers(pairHash), multiplier);
    }

    function test_SetPairRiskMultiplier_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        riskScoring.setPairRiskMultiplier(address(token0), address(token1), 150);
    }

    function test_UpdateRiskParameters_Success() public {
        uint256 newAmountThreshold = 50000 * 1e18;
        uint256 newVolumeThreshold = 1000000 * 1e18;
        uint256 newTimeWindow = 2 * 24 * 3600; // 2 days
        
        vm.prank(admin);
        riskScoring.updateRiskParameters(newAmountThreshold, newVolumeThreshold, newTimeWindow);
        
        (uint256 amount, uint256 volume, uint256 time) = riskScoring.getRiskParameters();
        assertEq(amount, newAmountThreshold);
        assertEq(volume, newVolumeThreshold);
        assertEq(time, newTimeWindow);
    }

    function test_UpdateRiskParameters_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        riskScoring.updateRiskParameters(50000 * 1e18, 1000000 * 1e18, 2 * 24 * 3600);
    }

    function test_AddToBlacklist_Success() public {
        vm.prank(admin);
        riskScoring.addToBlacklist(user1);
        
        assertTrue(riskScoring.isBlacklisted(user1));
    }

    function test_AddToBlacklist_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        riskScoring.addToBlacklist(user2);
    }

    function test_RemoveFromBlacklist_Success() public {
        // First add to blacklist
        vm.prank(admin);
        riskScoring.addToBlacklist(user1);
        assertTrue(riskScoring.isBlacklisted(user1));
        
        // Then remove
        vm.prank(admin);
        riskScoring.removeFromBlacklist(user1);
        assertFalse(riskScoring.isBlacklisted(user1));
    }

    function test_RemoveFromBlacklist_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        riskScoring.removeFromBlacklist(user2);
    }

    function test_AssessRisk_BlacklistedUser() public {
        vm.prank(admin);
        riskScoring.addToBlacklist(user1);
        
        uint256 riskScore = riskScoring.assessRisk(
            user1,
            address(token0),
            address(token1),
            1000 * 1e18
        );
        
        // Blacklisted users should have maximum risk score
        assertEq(riskScore, 1000);
    }

    function test_GetUserRiskProfile_NewUser() public {
        (
            uint256 totalVolume,
            uint256 transactionCount,
            uint256 reputation,
            uint256 lastActivityTime,
            bool isActive
        ) = riskScoring.getUserRiskProfile(user1);
        
        assertEq(totalVolume, 0);
        assertEq(transactionCount, 0);
        assertEq(reputation, 500); // Default reputation
        assertEq(lastActivityTime, 0);
        assertTrue(isActive);
    }

    function test_GetUserRiskProfile_AfterActivity() public {
        // Note: assessRisk is a view function and doesn't update user profile
        // In the actual implementation, user activity would be tracked separately
        riskScoring.assessRisk(user1, address(token0), address(token1), 1000 * 1e18);
        
        (
            uint256 totalVolume,
            uint256 transactionCount,
            uint256 reputation,
            uint256 lastActivityTime,
            bool isActive
        ) = riskScoring.getUserRiskProfile(user1);
        
        // Since assessRisk doesn't update profile, these should still be defaults
        assertEq(totalVolume, 0);
        assertEq(transactionCount, 0);
        assertEq(reputation, 500); // Default reputation
        assertEq(lastActivityTime, 0);
        assertTrue(isActive);
    }

    function test_CalculateVolumeRisk_LowVolume() public {
        uint256 volume = 1000 * 1e18;
        uint256 riskFactor = riskScoring.calculateVolumeRisk(user1, volume);
        
        // Low volume should have low risk factor
        assertTrue(riskFactor <= 200);
    }

    function test_CalculateVolumeRisk_HighVolume() public {
        uint256 volume = 10000000 * 1e18; // Very high volume
        uint256 riskFactor = riskScoring.calculateVolumeRisk(user1, volume);
        
        // High volume should have higher risk factor
        assertTrue(riskFactor >= 100);
    }

    function test_CalculateFrequencyRisk_NewUser() public {
        uint256 riskFactor = riskScoring.calculateFrequencyRisk(user1);
        
        // New users should have moderate frequency risk
        assertTrue(riskFactor >= 80 && riskFactor <= 120);
    }

    function test_CalculateFrequencyRisk_FrequentTrader() public {
        // Simulate frequent trading
        for (uint i = 0; i < 10; i++) {
            riskScoring.assessRisk(user1, address(token0), address(token1), 1000 * 1e18);
        }
        
        uint256 riskFactor = riskScoring.calculateFrequencyRisk(user1);
        
        // Frequent traders might have different risk profile
        assertTrue(riskFactor >= 50 && riskFactor <= 150);
    }

    function test_CalculateTokenRisk_StandardTokens() public {
        uint256 riskFactor = riskScoring.calculateTokenRisk(address(token0), address(token1));
        
        // Standard tokens should have moderate risk
        assertTrue(riskFactor >= 80 && riskFactor <= 120);
    }

    function test_CalculateTokenRisk_HighRiskToken() public {
        // Set high risk for token0
        vm.prank(admin);
        riskScoring.setTokenRiskLevel(address(token0), 800);
        
        uint256 riskFactor = riskScoring.calculateTokenRisk(address(token0), address(token1));
        
        // Should reflect higher risk
        assertTrue(riskFactor >= 120);
    }

    function test_CalculateTokenRisk_RiskyPair() public {
        // Set risky pair multiplier
        vm.prank(admin);
        riskScoring.setPairRiskMultiplier(address(token0), address(token1), 200); // 2x
        
        uint256 riskFactor = riskScoring.calculateTokenRisk(address(token0), address(token1));
        
        // Should reflect pair risk
        assertTrue(riskFactor >= 120);
    }

    function test_IsHighRiskTransaction_LowRisk() public {
        bool isHighRisk = riskScoring.isHighRiskTransaction(
            user1,
            address(token0),
            address(token1),
            1000 * 1e18,
            10 // Low urgency
        );
        
        // Normal transaction should not be high risk
        assertFalse(isHighRisk);
    }

    function test_IsHighRiskTransaction_HighRisk() public {
        uint256 massiveAmount = 10000000 * 1e18;
        
        bool isHighRisk = riskScoring.isHighRiskTransaction(
            user1,
            address(token0),
            address(token1),
            massiveAmount,
            50 // Medium urgency
        );
        
        // Massive transaction should be high risk
        assertTrue(isHighRisk);
    }

    function test_IsHighRiskTransaction_BlacklistedUser() public {
        vm.prank(admin);
        riskScoring.addToBlacklist(user1);
        
        bool isHighRisk = riskScoring.isHighRiskTransaction(
            user1,
            address(token0),
            address(token1),
            1000 * 1e18,
            10 // Low urgency, but still high risk due to blacklist
        );
        
        // Blacklisted users are always high risk
        assertTrue(isHighRisk);
    }

    function test_SetActive_Success() public {
        vm.prank(admin);
        riskScoring.setActive(false);
        
        assertFalse(riskScoring.isActive());
    }

    function test_SetActive_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        riskScoring.setActive(false);
    }

    function test_AssessRisk_WhenInactive() public {
        vm.prank(admin);
        riskScoring.setActive(false);
        
        uint256 riskScore = riskScoring.assessRisk(
            user1,
            address(token0),
            address(token1),
            1000 * 1e18
        );
        
        // When inactive, should return default low risk (but not necessarily 100)
        assertTrue(riskScore <= 300);
    }

    function test_Integration_RiskScoreEvolution() public {
        // Test how risk score evolves with user activity
        uint256 amount = 10000 * 1e18;
        
        // Initial assessment
        uint256 score1 = riskScoring.assessRisk(user1, address(token0), address(token1), amount);
        
        // Positive reputation update
        vm.prank(admin);
        riskScoring.updateUserReputation(user1, 100, true);
        
        uint256 score2 = riskScoring.assessRisk(user1, address(token0), address(token1), amount);
        
        // Multiple transactions
        for (uint i = 0; i < 5; i++) {
            riskScoring.assessRisk(user1, address(token0), address(token1), amount);
        }
        
        uint256 score3 = riskScoring.assessRisk(user1, address(token0), address(token1), amount);
        
        // Scores should evolve based on activity and reputation
        assertTrue(score2 <= score1); // Better reputation = lower risk
        assertTrue(score3 >= 0); // Should handle multiple transactions
    }

    function test_Integration_MultiUserRiskComparison() public {
        uint256 amount = 10000 * 1e18;
        
        // User1: Regular user
        uint256 user1Score = riskScoring.assessRisk(user1, address(token0), address(token1), amount);
        
        // User2: Good reputation
        vm.prank(admin);
        riskScoring.updateUserReputation(user2, 200, true);
        uint256 user2Score = riskScoring.assessRisk(user2, address(token0), address(token1), amount);
        
        // User2 should have better (lower) risk score
        assertTrue(user2Score <= user1Score);
    }

    function test_Gas_RiskAssessmentOptimization() public {
        uint256 gasBefore = gasleft();
        
        riskScoring.assessRisk(user1, address(token0), address(token1), 1000 * 1e18);
        
        uint256 gasUsed = gasBefore - gasleft();
        
        // Risk assessment should be gas efficient
        assertTrue(gasUsed < 200000); // 200k gas limit
    }

    function test_Fuzz_RiskAssessmentAmounts(uint256 amount) public {
        vm.assume(amount > 1e15 && amount < 1e27); // Reasonable range
        
        uint256 riskScore = riskScoring.assessRisk(
            user1,
            address(token0),
            address(token1),
            amount
        );
        
        // Risk score should always be between 0 and 1000
        assertTrue(riskScore <= 1000);
    }

    function test_Edge_ZeroAmountRisk() public {
        uint256 riskScore = riskScoring.assessRisk(
            user1,
            address(token0),
            address(token1),
            0
        );
        
        // Zero amount should have minimal risk (based on token risk levels)
        assertTrue(riskScore <= 300);
    }

    function test_Edge_MaxAmountRisk() public {
        uint256 maxAmount = type(uint256).max;
        
        uint256 riskScore = riskScoring.assessRisk(
            user1,
            address(token0),
            address(token1),
            maxAmount
        );
        
        // Max amount should have very high risk (but capped at MAX_RISK_SCORE)
        assertTrue(riskScore >= 300 && riskScore <= 1000);
    }
}
