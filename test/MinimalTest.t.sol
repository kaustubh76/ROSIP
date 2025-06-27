// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title MinimalTest
 * @notice Basic test to verify foundry setup works
 */
contract MinimalTest is Test {
    MockERC20 public token;
    
    function setUp() public {
        token = new MockERC20("Test Token", "TEST", 18);
    }
    
    function test_TokenDeployment() public {
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 18);
    }
    
    function test_Minting() public {
        uint256 amount = 1000 * 1e18;
        token.mint(address(this), amount);
        assertEq(token.balanceOf(address(this)), amount);
    }
    
    function test_BasicFunctionality() public {
        // Test that the testing framework is working
        assertTrue(true);
        assertFalse(false);
        assertEq(uint256(1 + 1), uint256(2));
    }
}
