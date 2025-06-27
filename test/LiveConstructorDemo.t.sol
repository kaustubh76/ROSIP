// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

import "../src/core/UniswapHookOrchestrator.sol";
import "../src/libraries/RiskScoring.sol";
import "../src/libraries/CircleCrossChainLiquidity.sol";
import "../src/keepers/KeeperNetwork.sol";
import "../src/integrations/CirclePaymaster.sol";
import "../src/oracles/CrossChainOracle.sol";
import "./mocks/MockERC20.sol";

/**
 * @title LiveConstructorDemo
 * @notice Live demonstration of all UHI component constructors
 */
contract LiveConstructorDemo is Test {
    
    // Test addresses
    address admin;
    address treasury;
    address user1;
    address user2;
    
    // Core components
    MockERC20 usdc;
    MockERC20 stakingToken;
    IPoolManager poolManager;
    
    // UHI Protocol Components
    RiskScoring riskScoring;
    CircleCrossChainLiquidity crossChainLiquidity;
    KeeperNetwork keeperNetwork;
    CirclePaymaster paymaster;
    CrossChainOracle oracle;
    UniswapHookOrchestrator orchestrator;

    event ComponentDeployed(string component, address contractAddress);
    event ConstructorValidated(string component, string validation);

    function setUp() public {
        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        
        vm.deal(admin, 100 ether);
        vm.deal(treasury, 10 ether);
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        
        console.log("=== UHI Protocol Constructor Demo Setup Complete ===");
        console.log("Admin address:", admin);
        console.log("Treasury address:", treasury);
    }

    function test_LiveDemo_01_Infrastructure() public {
        console.log("\n[STEP 1] Deploying Basic Infrastructure");
        
        vm.startPrank(admin);
        
        // Deploy USDC token with constructor validation
        usdc = new MockERC20("USD Coin", "USDC", 6);
        console.log("[SUCCESS] USDC Token deployed at:", address(usdc));
        
        // Deploy staking token
        stakingToken = new MockERC20("Staking Token", "STAKE", 18);
        console.log("[SUCCESS] Staking Token deployed at:", address(stakingToken));
        
        // Deploy Pool Manager
        poolManager = new PoolManager(admin);
        console.log("[SUCCESS] Pool Manager deployed at:", address(poolManager));
        
        // Mint tokens
        usdc.mint(admin, 1000000 * 1e6);
        stakingToken.mint(admin, 1000000 * 1e18);
        console.log("[INFO] Minted 1M tokens to admin");
        
        vm.stopPrank();
        
        // Validate all deployments
        assertNotEq(address(usdc), address(0));
        assertNotEq(address(stakingToken), address(0));
        assertNotEq(address(poolManager), address(0));
        console.log("[SUCCESS] Infrastructure deployed and validated");
    }

    function test_LiveDemo_02_RiskScoring() public {
        test_LiveDemo_01_Infrastructure();
        
        console.log("\n[STEP 2] Deploying Risk Scoring System");
        
        vm.startPrank(admin);
        
        // Test constructor validation - zero address should fail
        console.log("[TEST] Testing zero address validation...");
        vm.expectRevert("Ownable: new owner is the zero address");
        new RiskScoring(address(0));
        console.log("[SUCCESS] Zero address validation works");
        
        // Deploy valid risk scoring
        riskScoring = new RiskScoring(admin);
        console.log("[SUCCESS] Risk Scoring deployed at:", address(riskScoring));
        
        // Test functionality
        assertTrue(riskScoring.active());
        riskScoring.setTokenRiskLevel(address(usdc), 1);
        console.log("[SUCCESS] Risk scoring configured and tested");
        
        vm.stopPrank();
    }

    function test_LiveDemo_03_CrossChainLiquidity() public {
        test_LiveDemo_02_RiskScoring();
        
        console.log("\n[STEP 3] Deploying Cross-Chain Liquidity");
        
        vm.startPrank(admin);
        
        // Test constructor validations
        console.log("[TEST] Testing constructor validations...");
        
        vm.expectRevert("Owner cannot be zero address");
        new CircleCrossChainLiquidity(address(0), address(usdc), address(0x123));
        console.log("[SUCCESS] Zero owner validation works");
        
        vm.expectRevert("USDC token cannot be zero address");
        new CircleCrossChainLiquidity(admin, address(0), address(0x123));
        console.log("[SUCCESS] Zero USDC validation works");
        
        // Deploy valid cross-chain liquidity
        address messageTransmitter = 0x7865fAfC2db2093669d92c0F33AeEF291086BEFD;
        crossChainLiquidity = new CircleCrossChainLiquidity(
            admin,
            address(usdc),
            messageTransmitter
        );
        console.log("[SUCCESS] Cross-Chain Liquidity deployed at:", address(crossChainLiquidity));
        
        // Validate ownership
        assertEq(crossChainLiquidity.owner(), admin);
        console.log("[SUCCESS] Ownership validated");
        
        vm.stopPrank();
    }

    function test_LiveDemo_04_KeeperNetwork() public {
        test_LiveDemo_03_CrossChainLiquidity();
        
        console.log("\n[STEP 4] Deploying Keeper Network");
        
        vm.startPrank(admin);
        
        // Test constructor validations
        console.log("[TEST] Testing keeper network constructor validations...");
        
        vm.expectRevert("Owner cannot be zero address");
        new KeeperNetwork(address(0), address(stakingToken), 1000 * 1e18, treasury, admin, bytes32(0), 1);
        console.log("[SUCCESS] Zero owner validation works");
        
        vm.expectRevert("Staking token cannot be zero address");
        new KeeperNetwork(admin, address(0), 1000 * 1e18, treasury, admin, bytes32(0), 1);
        console.log("[SUCCESS] Zero staking token validation works");
        
        // Deploy valid keeper network
        keeperNetwork = new KeeperNetwork(
            admin,
            address(stakingToken),
            1000 * 1e18,
            treasury,
            admin,
            bytes32(0x474e34a077df58807dbe9c96d3c009b23b3c6d0cce433e59bbf5b34f823bc56c),
            1
        );
        console.log("[SUCCESS] Keeper Network deployed at:", address(keeperNetwork));
        
        // Validate configuration
        assertEq(keeperNetwork.owner(), admin);
        assertEq(keeperNetwork.stakingToken(), address(stakingToken));
        assertEq(keeperNetwork.minimumStake(), 1000 * 1e18);
        console.log("[SUCCESS] Keeper network configuration validated");
        
        vm.stopPrank();
    }

    function test_LiveDemo_05_CirclePaymaster() public {
        test_LiveDemo_04_KeeperNetwork();
        
        console.log("\n[STEP 5] Deploying Circle Paymaster");
        
        vm.startPrank(admin);
        
        // Test constructor validation
        console.log("[TEST] Testing paymaster constructor validation...");
        vm.expectRevert("USDC token cannot be zero address");
        new CirclePaymaster(address(0), admin);
        console.log("[SUCCESS] Zero USDC validation works");
        
        // Deploy valid paymaster
        paymaster = new CirclePaymaster(address(usdc), admin);
        console.log("[SUCCESS] Circle Paymaster deployed at:", address(paymaster));
        
        // Validate configuration
        assertTrue(paymaster.hasRole(paymaster.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(address(paymaster.usdcToken()), address(usdc));
        assertTrue(paymaster.active());
        console.log("[SUCCESS] Paymaster configuration validated");
        
        vm.stopPrank();
    }

    function test_LiveDemo_06_CrossChainOracle() public {
        test_LiveDemo_05_CirclePaymaster();
        
        console.log("\n[STEP 6] Deploying Cross-Chain Oracle");
        
        vm.startPrank(admin);
        
        // Test constructor validation
        console.log("[TEST] Testing oracle constructor validation...");
        vm.expectRevert();
        new CrossChainOracle(address(0));
        console.log("[SUCCESS] Zero admin validation works");
        
        // Deploy valid oracle
        oracle = new CrossChainOracle(admin);
        console.log("[SUCCESS] Cross-Chain Oracle deployed at:", address(oracle));
        
        // Validate configuration
        assertTrue(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), admin));
        console.log("[SUCCESS] Oracle configuration validated");
        
        vm.stopPrank();
    }

    function test_LiveDemo_07_UniswapOrchestrator() public {
        test_LiveDemo_06_CrossChainOracle();
        
        console.log("\n[STEP 7] Deploying Uniswap Hook Orchestrator");
        
        vm.startPrank(admin);
        
        // Test constructor validation
        console.log("[TEST] Testing orchestrator constructor validation...");
        vm.expectRevert("Pool manager cannot be zero address");
        new UniswapHookOrchestrator(
            IPoolManager(address(0)),
            riskScoring,
            crossChainLiquidity,
            keeperNetwork,
            paymaster,
            oracle,
            admin
        );
        console.log("[SUCCESS] Zero pool manager validation works");
        
        // Deploy valid orchestrator
        orchestrator = new UniswapHookOrchestrator(
            poolManager,
            riskScoring,
            crossChainLiquidity,
            keeperNetwork,
            paymaster,
            oracle,
            admin
        );
        console.log("[SUCCESS] Orchestrator deployed at:", address(orchestrator));
        
        // Validate configuration
        assertTrue(orchestrator.hasRole(orchestrator.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(address(orchestrator.poolManager()), address(poolManager));
        assertEq(address(orchestrator.riskScoring()), address(riskScoring));
        console.log("[SUCCESS] Orchestrator configuration validated");
        
        vm.stopPrank();
    }

    function test_LiveDemo_08_FullSystemValidation() public {
        test_LiveDemo_07_UniswapOrchestrator();
        
        console.log("\n[STEP 8] Full System Integration Test");
        
        vm.startPrank(admin);
        
        // Test all component connections
        console.log("[TEST] Validating component interconnections...");
        
        assertNotEq(address(orchestrator.riskScoring()), address(0));
        assertNotEq(address(orchestrator.crossChainLiquidity()), address(0));
        assertNotEq(address(orchestrator.keeperNetwork()), address(0));
        console.log("[SUCCESS] All orchestrator service references valid");
        
        // Test risk scoring functionality
        uint256 riskScore = riskScoring.assessRisk(user1, address(usdc), address(stakingToken), 1000 * 1e6);
        assertTrue(riskScore > 0);
        console.log("[SUCCESS] Risk scoring functional, score:", riskScore);
        
        // Test paymaster deposit
        usdc.approve(address(paymaster), 10000 * 1e6);
        paymaster.depositFunds(10000 * 1e6);
        assertTrue(paymaster.getUserBalance(admin) > 0);
        console.log("[SUCCESS] Paymaster deposit working, balance:", paymaster.getUserBalance(admin));
        
        // Test keeper registration
        stakingToken.approve(address(keeperNetwork), 2000 * 1e18);
        keeperNetwork.registerKeeper(2000 * 1e18);
        (uint256 stake, bool active,) = keeperNetwork.getKeeperInfo(admin);
        assertTrue(stake > 0 && active);
        console.log("[SUCCESS] Keeper registration working, stake:", stake, "active:", active);
        
        vm.stopPrank();
        
        console.log("\n[COMPLETE] Full UHI Protocol Deployment Successful!");
        console.log("All components deployed and validated:");
        console.log("- Risk Scoring:", address(riskScoring));
        console.log("- Cross-Chain Liquidity:", address(crossChainLiquidity));
        console.log("- Keeper Network:", address(keeperNetwork));
        console.log("- Circle Paymaster:", address(paymaster));
        console.log("- Cross-Chain Oracle:", address(oracle));
        console.log("- Hook Orchestrator:", address(orchestrator));
    }

    function test_LiveDemo_09_UserInteractions() public {
        test_LiveDemo_08_FullSystemValidation();
        
        console.log("\n[STEP 9] Live User Interaction Demo");
        
        // Setup user funds
        vm.startPrank(admin);
        usdc.mint(user1, 50000 * 1e6);
        stakingToken.mint(user2, 5000 * 1e18);
        vm.stopPrank();
        
        // User 1: Paymaster interaction
        vm.startPrank(user1);
        console.log("[USER1] Depositing to paymaster...");
        usdc.approve(address(paymaster), 1000 * 1e6);
        paymaster.depositFunds(1000 * 1e6);
        uint256 user1Balance = paymaster.getUserBalance(user1);
        console.log("[SUCCESS] User1 paymaster balance:", user1Balance);
        vm.stopPrank();
        
        // User 2: Keeper registration
        vm.startPrank(user2);
        console.log("[USER2] Registering as keeper...");
        stakingToken.approve(address(keeperNetwork), 2000 * 1e18);
        keeperNetwork.registerKeeper(2000 * 1e18);
        (uint256 stake, bool active,) = keeperNetwork.getKeeperInfo(user2);
        console.log("[SUCCESS] User2 keeper - Stake:", stake, "Active:", active);
        vm.stopPrank();
        
        // Risk assessment
        vm.startPrank(admin);
        console.log("[ADMIN] Assessing user transaction risk...");
        uint256 user1Risk = riskScoring.assessRisk(user1, address(usdc), address(stakingToken), 5000 * 1e6);
        console.log("[SUCCESS] User1 risk score for 5k USDC:", user1Risk);
        
        riskScoring.updateUserReputation(user1, 50);
        console.log("[SUCCESS] Updated user1 reputation");
        vm.stopPrank();
        
        console.log("\n[COMPLETE] Live interaction demo finished!");
        console.log("System is fully functional with real user interactions!");
    }
}
