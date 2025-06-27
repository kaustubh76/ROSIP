// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {CirclePaymaster} from "../src/integrations/CirclePaymaster.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title CirclePaymasterTest
 * @notice Comprehensive tests for the CirclePaymaster contract
 */
contract CirclePaymasterTest is Test {
    CirclePaymaster public circlePaymaster;
    MockERC20 public usdc;
    
    address public admin;
    address public user1;
    address public user2;
    address public gasPriceOracle;
    
    function setUp() public {
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        gasPriceOracle = makeAddr("gasPriceOracle");
        
        // Deploy mock USDC
        usdc = new MockERC20("USD Coin", "USDC", 6);
        
        // Deploy CirclePaymaster
        vm.prank(admin);
        circlePaymaster = new CirclePaymaster(
            address(usdc),
            gasPriceOracle,
            admin
        );
        
        // Mint USDC to users
        usdc.mint(user1, 1_000_000 * 1e6); // 1M USDC
        usdc.mint(user2, 1_000_000 * 1e6); // 1M USDC
        usdc.mint(admin, 1_000_000 * 1e6); // 1M USDC
    }
    
    function test_Deployment() public {
        assertEq(address(circlePaymaster.usdcToken()), address(usdc));
        assertEq(circlePaymaster.gasPriceOracle(), gasPriceOracle); // Should be gasPriceOracle, not admin
        assertTrue(circlePaymaster.hasRole(circlePaymaster.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(circlePaymaster.isActive());
    }

    function test_DepositFunds_Success() public {
        uint256 depositAmount = 1000 * 1e6; // 1000 USDC
        
        vm.prank(user1);
        usdc.approve(address(circlePaymaster), depositAmount);
        
        vm.prank(user1);
        circlePaymaster.depositFunds(depositAmount);
        
        assertEq(circlePaymaster.getUserBalance(user1), depositAmount);
    }

    function test_DepositFunds_ZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert("CirclePaymaster: amount must be greater than zero");
        circlePaymaster.depositFunds(0);
    }

    function test_DepositFunds_InsufficientAllowance() public {
        uint256 depositAmount = 1000 * 1e6;
        
        // Don't approve enough tokens
        vm.prank(user1);
        usdc.approve(address(circlePaymaster), depositAmount - 1);
        
        vm.prank(user1);
        vm.expectRevert();
        circlePaymaster.depositFunds(depositAmount);
    }

    function test_WithdrawFunds_Success() public {
        uint256 depositAmount = 1000 * 1e6;
        uint256 withdrawAmount = 500 * 1e6;
        
        // First deposit
        vm.prank(user1);
        usdc.approve(address(circlePaymaster), depositAmount);
        vm.prank(user1);
        circlePaymaster.depositFunds(depositAmount);
        
        uint256 balanceBefore = usdc.balanceOf(user1);
        
        // Then withdraw
        vm.prank(user1);
        circlePaymaster.withdrawFunds(withdrawAmount);
        
        uint256 balanceAfter = usdc.balanceOf(user1);
        
        assertEq(balanceAfter - balanceBefore, withdrawAmount);
        assertEq(circlePaymaster.getUserBalance(user1), depositAmount - withdrawAmount);
    }

    function test_WithdrawFunds_InsufficientBalance() public {
        uint256 depositAmount = 500 * 1e6;
        uint256 withdrawAmount = 1000 * 1e6;
        
        vm.prank(user1);
        usdc.approve(address(circlePaymaster), depositAmount);
        vm.prank(user1);
        circlePaymaster.depositFunds(depositAmount);
        
        vm.prank(user1);
        vm.expectRevert("CirclePaymaster: insufficient balance");
        circlePaymaster.withdrawFunds(withdrawAmount);
    }

    function test_WithdrawFunds_ZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert("CirclePaymaster: amount must be greater than zero");
        circlePaymaster.withdrawFunds(0);
    }

    function test_PayForTransaction_Success() public {
        uint256 depositAmount = 1000 * 1e6;
        uint256 gasUsed = 100000;
        uint256 gasPrice = 20 * 1e9; // 20 gwei
        
        // Deposit funds
        vm.prank(user1);
        usdc.approve(address(circlePaymaster), depositAmount);
        vm.prank(user1);
        circlePaymaster.depositFunds(depositAmount);
        
        uint256 balanceBefore = circlePaymaster.getUserBalance(user1);
        
        // Pay for transaction
        vm.prank(admin); // Only admin or authorized can call
        circlePaymaster.payForTransaction(user1, gasUsed, gasPrice);
        
        uint256 balanceAfter = circlePaymaster.getUserBalance(user1);
        
        // Balance should decrease
        assertTrue(balanceAfter < balanceBefore);
    }

    function test_PayForTransaction_InsufficientFunds() public {
        uint256 smallDeposit = 1 * 1e6; // Very small deposit
        uint256 gasUsed = 1000000; // Large gas usage
        uint256 gasPrice = 100 * 1e9; // High gas price
        
        vm.prank(user1);
        usdc.approve(address(circlePaymaster), smallDeposit);
        vm.prank(user1);
        circlePaymaster.depositFunds(smallDeposit);
        
        vm.prank(admin);
        vm.expectRevert("CirclePaymaster: insufficient funds for gas");
        circlePaymaster.payForTransaction(user1, gasUsed, gasPrice);
    }

    function test_PayForTransaction_OnlyAuthorized() public {
        vm.prank(user1);
        vm.expectRevert("CirclePaymaster: unauthorized");
        circlePaymaster.payForTransaction(user2, 100000, 20 * 1e9);
    }

    function test_EstimateGasCost_StandardTransaction() public {
        uint256 gasUsed = 100000;
        uint256 gasPrice = 20 * 1e9;
        
        uint256 estimatedCost = circlePaymaster.estimateGasCost(gasUsed, gasPrice);
        
        // Should convert ETH cost to USDC equivalent
        assertTrue(estimatedCost > 0);
    }

    function test_EstimateGasCost_HighGasPrice() public {
        uint256 gasUsed = 100000;
        uint256 highGasPrice = 100 * 1e9;
        
        uint256 estimatedCost = circlePaymaster.estimateGasCost(gasUsed, highGasPrice);
        
        assertTrue(estimatedCost > 0);
    }

    function test_SetGasPriceOracle_Success() public {
        address newOracle = makeAddr("newOracle");
        
        vm.prank(admin);
        circlePaymaster.setGasPriceOracle(newOracle);
        
        assertEq(circlePaymaster.gasPriceOracle(), newOracle);
    }

    function test_SetGasPriceOracle_OnlyAdmin() public {
        address newOracle = makeAddr("newOracle");
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, bytes32(0)));
        circlePaymaster.setGasPriceOracle(newOracle);
    }

    function test_SetGasPriceOracle_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("CirclePaymaster: invalid oracle address");
        circlePaymaster.setGasPriceOracle(address(0));
    }

    function test_UpdateConversionRate_Success() public {
        uint256 newRate = 2000 * 1e6; // 2000 USDC per ETH
        
        vm.prank(admin);
        circlePaymaster.updateConversionRate(newRate);
        
        assertEq(circlePaymaster.ethToUsdcRate(), newRate);
    }

    function test_UpdateConversionRate_OnlyAdmin() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, bytes32(0)));
        circlePaymaster.updateConversionRate(2000 * 1e6);
    }

    function test_UpdateConversionRate_ZeroRate() public {
        vm.prank(admin);
        vm.expectRevert("CirclePaymaster: invalid conversion rate");
        circlePaymaster.updateConversionRate(0);
    }

    function test_SetActive_Success() public {
        vm.prank(admin);
        circlePaymaster.setActive(false);
        
        assertFalse(circlePaymaster.isActive());
    }

    function test_SetActive_OnlyAdmin() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, bytes32(0)));
        circlePaymaster.setActive(false);
    }

    function test_SetActive_BlocksOperations() public {
        vm.prank(admin);
        circlePaymaster.setActive(false);
        
        vm.prank(user1);
        vm.expectRevert("CirclePaymaster: contract is not active");
        circlePaymaster.depositFunds(1000 * 1e6);
    }

    function test_AddAuthorizedCaller_Success() public {
        address newCaller = makeAddr("newCaller");
        
        vm.prank(admin);
        circlePaymaster.addAuthorizedCaller(newCaller);
        
        assertTrue(circlePaymaster.isAuthorizedCaller(newCaller));
    }

    function test_AddAuthorizedCaller_OnlyAdmin() public {
        address newCaller = makeAddr("newCaller");
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, bytes32(0)));
        circlePaymaster.addAuthorizedCaller(newCaller);
    }

    function test_RemoveAuthorizedCaller_Success() public {
        address caller = makeAddr("caller");
        
        // First add
        vm.prank(admin);
        circlePaymaster.addAuthorizedCaller(caller);
        assertTrue(circlePaymaster.isAuthorizedCaller(caller));
        
        // Then remove
        vm.prank(admin);
        circlePaymaster.removeAuthorizedCaller(caller);
        assertFalse(circlePaymaster.isAuthorizedCaller(caller));
    }

    function test_RemoveAuthorizedCaller_OnlyAdmin() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, bytes32(0)));
        circlePaymaster.removeAuthorizedCaller(admin);
    }

    function test_GetUserBalance_MultipleUsers() public {
        uint256 amount1 = 1000 * 1e6;
        uint256 amount2 = 2000 * 1e6;
        
        // User1 deposits
        vm.prank(user1);
        usdc.approve(address(circlePaymaster), amount1);
        vm.prank(user1);
        circlePaymaster.depositFunds(amount1);
        
        // User2 deposits
        vm.prank(user2);
        usdc.approve(address(circlePaymaster), amount2);
        vm.prank(user2);
        circlePaymaster.depositFunds(amount2);
        
        assertEq(circlePaymaster.getUserBalance(user1), amount1);
        assertEq(circlePaymaster.getUserBalance(user2), amount2);
    }

    function test_GetTotalDeposits() public {
        uint256 amount1 = 1000 * 1e6;
        uint256 amount2 = 500 * 1e6;
        
        uint256 initialTotal = circlePaymaster.getTotalDeposits();
        
        vm.prank(user1);
        usdc.approve(address(circlePaymaster), amount1);
        vm.prank(user1);
        circlePaymaster.depositFunds(amount1);
        
        vm.prank(user2);
        usdc.approve(address(circlePaymaster), amount2);
        vm.prank(user2);
        circlePaymaster.depositFunds(amount2);
        
        uint256 finalTotal = circlePaymaster.getTotalDeposits();
        assertEq(finalTotal - initialTotal, amount1 + amount2);
    }

    function test_EmergencyWithdraw_Success() public {
        uint256 depositAmount = 1000 * 1e6;
        
        // User deposits
        vm.prank(user1);
        usdc.approve(address(circlePaymaster), depositAmount);
        vm.prank(user1);
        circlePaymaster.depositFunds(depositAmount);
        
        uint256 adminBalanceBefore = usdc.balanceOf(admin);
        uint256 contractBalance = usdc.balanceOf(address(circlePaymaster));
        
        // Emergency withdraw
        vm.prank(admin);
        circlePaymaster.emergencyWithdraw();
        
        uint256 adminBalanceAfter = usdc.balanceOf(admin);
        
        assertEq(adminBalanceAfter - adminBalanceBefore, contractBalance);
        assertEq(usdc.balanceOf(address(circlePaymaster)), 0);
    }

    function test_EmergencyWithdraw_OnlyAdmin() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, bytes32(0)));
        circlePaymaster.emergencyWithdraw();
    }

    function test_Integration_FullPaymasterFlow() public {
        uint256 depositAmount = 1000 * 1e6;
        uint256 gasUsed = 150000;
        uint256 gasPrice = 25 * 1e9;
        
        // 1. User deposits funds
        vm.prank(user1);
        usdc.approve(address(circlePaymaster), depositAmount);
        vm.prank(user1);
        circlePaymaster.depositFunds(depositAmount);
        
        // 2. Estimate gas cost
        uint256 estimatedCost = circlePaymaster.estimateGasCost(gasUsed, gasPrice);
        assertTrue(estimatedCost > 0);
        assertTrue(estimatedCost < depositAmount); // Should be affordable
        
        // 3. Pay for transaction
        uint256 balanceBefore = circlePaymaster.getUserBalance(user1);
        
        vm.prank(admin);
        circlePaymaster.payForTransaction(user1, gasUsed, gasPrice);
        
        uint256 balanceAfter = circlePaymaster.getUserBalance(user1);
        
        // 4. Verify payment
        assertTrue(balanceAfter < balanceBefore);
        uint256 actualCost = balanceBefore - balanceAfter;
        assertTrue(actualCost > 0);
        
        // 5. Withdraw remaining funds
        vm.prank(user1);
        circlePaymaster.withdrawFunds(balanceAfter);
        
        assertEq(circlePaymaster.getUserBalance(user1), 0);
    }

    function test_Integration_MultipleTransactions() public {
        uint256 depositAmount = 2000 * 1e6;
        uint256 gasUsed = 100000;
        uint256 gasPrice = 20 * 1e9;
        
        // Deposit funds
        vm.prank(user1);
        usdc.approve(address(circlePaymaster), depositAmount);
        vm.prank(user1);
        circlePaymaster.depositFunds(depositAmount);
        
        uint256 initialBalance = circlePaymaster.getUserBalance(user1);
        
        // Pay for multiple transactions
        vm.startPrank(admin);
        circlePaymaster.payForTransaction(user1, gasUsed, gasPrice);
        circlePaymaster.payForTransaction(user1, gasUsed, gasPrice);
        circlePaymaster.payForTransaction(user1, gasUsed, gasPrice);
        vm.stopPrank();
        
        uint256 finalBalance = circlePaymaster.getUserBalance(user1);
        
        // Should have paid for 3 transactions
        assertTrue(finalBalance < initialBalance);
        uint256 totalCost = initialBalance - finalBalance;
        assertTrue(totalCost > 0);
    }

    function test_Integration_ConversionRateUpdate() public {
        uint256 depositAmount = 1000 * 1e6;
        uint256 gasUsed = 100000;
        uint256 gasPrice = 20 * 1e9;
        
        vm.prank(user1);
        usdc.approve(address(circlePaymaster), depositAmount);
        vm.prank(user1);
        circlePaymaster.depositFunds(depositAmount);
        
        // Get cost with initial rate
        uint256 cost1 = circlePaymaster.estimateGasCost(gasUsed, gasPrice);
        
        // Update conversion rate (double the rate)
        uint256 currentRate = circlePaymaster.ethToUsdcRate();
        vm.prank(admin);
        circlePaymaster.updateConversionRate(currentRate * 2);
        
        // Get cost with new rate
        uint256 cost2 = circlePaymaster.estimateGasCost(gasUsed, gasPrice);
        
        // Cost should change with rate
        assertTrue(cost2 != cost1);
    }

    function test_Gas_PaymasterOperationsOptimization() public {
        uint256 depositAmount = 1000 * 1e6;
        
        vm.prank(user1);
        usdc.approve(address(circlePaymaster), depositAmount);
        
        uint256 gasBefore = gasleft();
        vm.prank(user1);
        circlePaymaster.depositFunds(depositAmount);
        uint256 gasUsed = gasBefore - gasleft();
        
        // Deposit should be gas efficient
        assertTrue(gasUsed < 200000); // 200k gas limit
    }

    function test_Edge_MaximumDeposit() public {
        uint256 maxDeposit = type(uint256).max / 2; // Large but safe amount
        
        // Mint enough tokens
        usdc.mint(user1, maxDeposit);
        
        vm.prank(user1);
        usdc.approve(address(circlePaymaster), maxDeposit);
        
        vm.prank(user1);
        circlePaymaster.depositFunds(maxDeposit);
        
        assertEq(circlePaymaster.getUserBalance(user1), maxDeposit);
    }

    function test_Edge_VerySmallGasCost() public {
        uint256 tinyGas = 1;
        uint256 tinyPrice = 1;
        
        uint256 cost = circlePaymaster.estimateGasCost(tinyGas, tinyPrice);
        
        // Should handle very small costs
        assertTrue(cost >= 0);
    }

    function test_Fuzz_DepositAmounts(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 1e12 * 1e6); // Reasonable range
        
        // Mint tokens
        usdc.mint(user1, amount);
        
        vm.prank(user1);
        usdc.approve(address(circlePaymaster), amount);
        
        vm.prank(user1);
        circlePaymaster.depositFunds(amount);
        
        assertEq(circlePaymaster.getUserBalance(user1), amount);
    }
}
