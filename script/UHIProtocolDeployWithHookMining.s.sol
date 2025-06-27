// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

// Core contracts
import "../src/libraries/RiskScoring.sol";
import "../src/libraries/CircleCrossChainLiquidity.sol";
import "../src/keepers/KeeperNetwork.sol";
import "../src/oracles/CrossChainOracle.sol";
import "../src/core/UniswapHookOrchestrator.sol";
import "../src/hooks/BeforeSwapHook.sol";
import "../src/hooks/AfterSwapHook.sol";
import "../src/hooks/DynamicFeeHook.sol";
import "../src/integrations/CirclePaymaster.sol";

// Interface imports
import "../src/interfaces/IRiskScoring.sol";
import "../src/interfaces/ICrossChainLiquidity.sol";
import "../src/interfaces/IKeeperNetwork.sol";

contract UHIProtocolDeployWithHookMining is Script {
    
    struct DeployedContracts {
        address poolManager;
        address riskScoring;
        address crossChainLiquidity;
        address keeperNetwork;
        address oracle;
        address orchestrator;
        address beforeSwapHook;
        address afterSwapHook;
        address dynamicFeeHook;
        address circlePaymaster;
        bytes32 orchestratorSalt;
    }
    
    DeployedContracts public contracts;
    
    address public deployer;
    address public usdcAddress;
    address public circleBridgeAddress;
    address public circleMsgAddress;
    
    event ContractDeployed(string name, address contractAddress);
    event HookAddressMined(address hookAddress, bytes32 salt);
    
    function setUp() public {
        deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        
        // Set Sepolia testnet addresses
        usdcAddress = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
        circleBridgeAddress = 0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5;
        circleMsgAddress = 0x7865fAfC2db2093669d92c0F33AeEF291086BEFD;
        
        console2.log("=== UHI Protocol Deployment with Hook Mining ===");
        console2.log("Deployer:", deployer);
        console2.log("USDC:", usdcAddress);
        console2.log("Circle Bridge:", circleBridgeAddress);
        console2.log("==============================================");
    }
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        console2.log("Starting deployment...");
        console2.log("Deployer balance:", deployer.balance / 1e18, "ETH");
        
        // Deploy PoolManager first (needed for hook mining)
        console2.log("Deploying PoolManager...");
        contracts.poolManager = address(new PoolManager(deployer));
        console2.log("PoolManager deployed:", contracts.poolManager);
        emit ContractDeployed("PoolManager", contracts.poolManager);
        
        // Mine hook address for orchestrator
        console2.log("Mining hook address for orchestrator...");
        (address minedHookAddress, bytes32 salt) = _mineHookAddress();
        contracts.orchestratorSalt = salt;
        
        console2.log("Mined hook address:", minedHookAddress);
        console2.log("Salt:", vm.toString(salt));
        emit HookAddressMined(minedHookAddress, salt);
        
        // Deploy RiskScoring
        console2.log("Deploying RiskScoring...");
        contracts.riskScoring = address(new RiskScoring(deployer));
        console2.log("RiskScoring deployed:", contracts.riskScoring);
        emit ContractDeployed("RiskScoring", contracts.riskScoring);
        
        // Deploy CrossChainLiquidity
        console2.log("Deploying CrossChainLiquidity...");
        contracts.crossChainLiquidity = address(new CircleCrossChainLiquidity(
            deployer,  // owner
            usdcAddress,
            circleMsgAddress  // CCTP message transmitter
        ));
        console2.log("CrossChainLiquidity deployed:", contracts.crossChainLiquidity);
        emit ContractDeployed("CrossChainLiquidity", contracts.crossChainLiquidity);
        
        // Deploy KeeperNetwork
        console2.log("Deploying KeeperNetwork...");
        contracts.keeperNetwork = address(new KeeperNetwork(
            deployer,           // owner
            usdcAddress,        // staking token (using USDC for simplicity)
            1000 * 10**6,       // minimum stake (1000 USDC)
            deployer,           // treasury
            deployer,           // VRF coordinator placeholder
            bytes32(0),         // Key hash placeholder
            uint64(1)           // Subscription ID placeholder
        ));
        console2.log("KeeperNetwork deployed:", contracts.keeperNetwork);
        emit ContractDeployed("KeeperNetwork", contracts.keeperNetwork);
        
        // Deploy Oracle
        console2.log("Deploying CrossChainOracle...");
        contracts.oracle = address(new CrossChainOracle(deployer));
        console2.log("CrossChainOracle deployed:", contracts.oracle);
        emit ContractDeployed("CrossChainOracle", contracts.oracle);
        
        // Deploy Orchestrator using CREATE2 with mined salt
        console2.log("Deploying UniswapHookOrchestrator at mined address...");
        console2.log("Expected address:", minedHookAddress);
        console2.log("Using salt:", vm.toString(salt));
        
        // Deploy using CREATE2 with the exact same parameters used for mining
        contracts.orchestrator = address(
            new UniswapHookOrchestrator{salt: salt}(
                IPoolManager(contracts.poolManager),
                deployer
            )
        );
        
        // Verify the deployment was successful and address matches
        console2.log("Actual deployed address:", contracts.orchestrator);
        require(contracts.orchestrator == minedHookAddress, "Orchestrator deployed at wrong address");
        
        // Double-check the hook permissions are correct (use 14 bits as per Uniswap V4 standard)
        uint160 deployedFlags = uint160(contracts.orchestrator) & uint160((1 << 14) - 1);
        uint160 expectedFlags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        require(deployedFlags == expectedFlags, "Deployed contract has wrong hook flags");
        
        console2.log("UniswapHookOrchestrator deployed successfully at:", contracts.orchestrator);
        console2.log("Hook flags verified:", deployedFlags);
        emit ContractDeployed("UniswapHookOrchestrator", contracts.orchestrator);
        
        // Deploy BeforeSwapHook with proper hook mining
        console2.log("Deploying BeforeSwapHook...");
        (address beforeSwapAddress, bytes32 beforeSwapSalt) = mineAndDeployBeforeSwapHook();
        contracts.beforeSwapHook = beforeSwapAddress;
        console2.log("BeforeSwapHook deployed:", contracts.beforeSwapHook);
        emit ContractDeployed("BeforeSwapHook", contracts.beforeSwapHook);
        
        // Deploy AfterSwapHook
        console2.log("Deploying AfterSwapHook...");
        (address afterSwapAddress, bytes32 afterSwapSalt) = mineAndDeployAfterSwapHook();
        contracts.afterSwapHook = afterSwapAddress;
        console2.log("AfterSwapHook deployed:", contracts.afterSwapHook);
        emit ContractDeployed("AfterSwapHook", contracts.afterSwapHook);
        
        // Deploy DynamicFeeHook
        console2.log("Deploying DynamicFeeHook...");
        (address dynamicFeeAddress, bytes32 dynamicFeeSalt) = mineAndDeployDynamicFeeHook();
        contracts.dynamicFeeHook = dynamicFeeAddress;
        console2.log("DynamicFeeHook deployed:", contracts.dynamicFeeHook);
        emit ContractDeployed("DynamicFeeHook", contracts.dynamicFeeHook);
        
        // Deploy CirclePaymaster
        console2.log("Deploying CirclePaymaster...");
        contracts.circlePaymaster = address(new CirclePaymaster(
            usdcAddress,
            deployer,  // gas price oracle placeholder
            deployer   // admin
        ));
        console2.log("CirclePaymaster deployed:", contracts.circlePaymaster);
        emit ContractDeployed("CirclePaymaster", contracts.circlePaymaster);
        
        // Configure contracts
        console2.log("Configuring contracts...");
        
        // Configure orchestrator with hooks
        UniswapHookOrchestrator(contracts.orchestrator).updateHooks(
            contracts.beforeSwapHook,
            contracts.afterSwapHook,
            contracts.dynamicFeeHook
        );
        console2.log("Hooks configured in orchestrator");
        
        // Configure orchestrator with services
        UniswapHookOrchestrator(contracts.orchestrator).updateServices(
            contracts.riskScoring,
            contracts.crossChainLiquidity,
            contracts.keeperNetwork,
            contracts.oracle
        );
        console2.log("Services configured in orchestrator");
        
        vm.stopBroadcast();
        
        // Print deployment summary
        _printDeploymentSummary();
        
        console2.log("Deployment completed successfully!");
    }
    
    function _mineHookAddress() internal view returns (address hookAddress, bytes32 salt) {
        // Define the required hook permissions for UniswapHookOrchestrator
        // beforeSwap: true, afterSwap: true (as defined in getHookPermissions)
        uint160 targetFlags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        
        console2.log("Target flags for orchestrator:", targetFlags);
        console2.log("BEFORE_SWAP_FLAG:", uint160(Hooks.BEFORE_SWAP_FLAG));
        console2.log("AFTER_SWAP_FLAG:", uint160(Hooks.AFTER_SWAP_FLAG));
        
        // Get constructor arguments - these must match exactly what we'll use in deployment
        bytes memory constructorArgs = abi.encode(
            IPoolManager(contracts.poolManager), 
            deployer
        );
        
        // CRITICAL: When using vm.broadcast with CREATE2, Forge uses a standard CREATE2 deployer
        // We need to use the same deployer address that Forge uses internally
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C; // Standard CREATE2 deployer
        
        console2.log("Mining hook address...");
        console2.log("Using standard CREATE2 deployer:", create2Deployer);
        console2.log("Script contract address:", address(this));
        console2.log("Target flags:", targetFlags);
        
        (hookAddress, salt) = HookMiner.find(
            create2Deployer,  // Use the standard CREATE2 deployer address
            targetFlags,
            type(UniswapHookOrchestrator).creationCode,
            constructorArgs
        );
        
        // Verify the mined address has correct flags in the last 10 bits
        uint160 addressFlags = uint160(hookAddress) & uint160((1 << 14) - 1); // Use 14 bits as per HookMiner
        require(addressFlags == targetFlags, "Mined address has incorrect flags");
        
        console2.log("Successfully mined hook address with flags:", addressFlags);
        console2.log("Address validation passed!");
    }
    
    function mineAndDeployBeforeSwapHook() internal returns (address hookAddress, bytes32 salt) {
        console2.log("Mining hook address for BeforeSwapHook...");
        
        // BeforeSwapHook only needs BEFORE_SWAP_FLAG (128)
        uint160 targetFlags = uint160(128); // BEFORE_SWAP_FLAG = 1 << 7 = 128
        
        console2.log("Target flags for BeforeSwapHook:", targetFlags);
        
        // Get constructor arguments - these must match exactly what we'll use in deployment
        bytes memory constructorArgs = abi.encode(
            IPoolManager(contracts.poolManager),
            IRiskScoring(contracts.riskScoring),
            ICrossChainLiquidity(contracts.crossChainLiquidity),
            IKeeperNetwork(contracts.keeperNetwork),
            deployer
        );
        
        // Use standard CREATE2 deployer
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        
        console2.log("Mining BeforeSwapHook address...");
        (hookAddress, salt) = HookMiner.find(
            create2Deployer,
            targetFlags,
            type(BeforeSwapHook).creationCode,
            constructorArgs
        );
        
        // Verify the mined address has correct flags
        uint160 addressFlags = uint160(hookAddress) & uint160((1 << 14) - 1);
        require(addressFlags == targetFlags, "Mined BeforeSwapHook address has incorrect flags");
        
        console2.log("Successfully mined BeforeSwapHook address with flags:", addressFlags);
        console2.log("Mined BeforeSwapHook address:", hookAddress);
        console2.log("BeforeSwapHook salt:", vm.toString(salt));
        
        emit HookAddressMined(hookAddress, salt);
        
        // Deploy using CREATE2 with the mined salt
        BeforeSwapHook hook = new BeforeSwapHook{salt: salt}(
            IPoolManager(contracts.poolManager),
            IRiskScoring(contracts.riskScoring),
            ICrossChainLiquidity(contracts.crossChainLiquidity),
            IKeeperNetwork(contracts.keeperNetwork),
            deployer
        );
        
        hookAddress = address(hook);
        
        require(hookAddress != address(0), "BeforeSwapHook deployment failed");
        
        console2.log("BeforeSwapHook deployed successfully at:", hookAddress);
        
        // Verify hook flags
        uint160 deployedFlags = uint160(hookAddress) & uint160((1 << 14) - 1);
        require(deployedFlags == targetFlags, "Deployed BeforeSwapHook has incorrect flags");
        console2.log("BeforeSwapHook flags verified:", deployedFlags);
    }
    
    function mineAndDeployAfterSwapHook() internal returns (address hookAddress, bytes32 salt) {
        console2.log("Mining hook address for AfterSwapHook...");
        
        // AfterSwapHook only needs AFTER_SWAP_FLAG (64)
        uint160 targetFlags = uint160(64); // AFTER_SWAP_FLAG = 1 << 6 = 64
        
        console2.log("Target flags for AfterSwapHook:", targetFlags);
        
        // Get constructor arguments - these must match exactly what we'll use in deployment
        bytes memory constructorArgs = abi.encode(
            IPoolManager(contracts.poolManager),
            ICrossChainLiquidity(contracts.crossChainLiquidity),
            IKeeperNetwork(contracts.keeperNetwork),
            deployer
        );
        
        // Use standard CREATE2 deployer
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        
        console2.log("Mining AfterSwapHook address...");
        (hookAddress, salt) = HookMiner.find(
            create2Deployer,
            targetFlags,
            type(AfterSwapHook).creationCode,
            constructorArgs
        );
        
        // Verify the mined address has correct flags
        uint160 addressFlags = uint160(hookAddress) & uint160((1 << 14) - 1);
        require(addressFlags == targetFlags, "Mined AfterSwapHook address has incorrect flags");
        
        console2.log("Successfully mined AfterSwapHook address with flags:", addressFlags);
        console2.log("Mined AfterSwapHook address:", hookAddress);
        console2.log("AfterSwapHook salt:", vm.toString(salt));
        
        emit HookAddressMined(hookAddress, salt);
        
        // Deploy using CREATE2 with the mined salt
        AfterSwapHook hook = new AfterSwapHook{salt: salt}(
            IPoolManager(contracts.poolManager),
            ICrossChainLiquidity(contracts.crossChainLiquidity),
            IKeeperNetwork(contracts.keeperNetwork),
            deployer
        );
        
        hookAddress = address(hook);
        
        require(hookAddress != address(0), "AfterSwapHook deployment failed");
        
        console2.log("AfterSwapHook deployed successfully at:", hookAddress);
        
        // Verify hook flags
        uint160 deployedFlags = uint160(hookAddress) & uint160((1 << 14) - 1);
        require(deployedFlags == targetFlags, "Deployed AfterSwapHook has incorrect flags");
        console2.log("AfterSwapHook flags verified:", deployedFlags);
    }

    function mineAndDeployDynamicFeeHook() internal returns (address hookAddress, bytes32 salt) {
        console2.log("Mining hook address for DynamicFeeHook...");
        
        // DynamicFeeHook only needs BEFORE_SWAP_FLAG (128)
        uint160 targetFlags = uint160(128); // BEFORE_SWAP_FLAG = 1 << 7 = 128
        
        console2.log("Target flags for DynamicFeeHook:", targetFlags);
        
        // Get constructor arguments - these must match exactly what we'll use in deployment
        bytes memory constructorArgs = abi.encode(
            IPoolManager(contracts.poolManager),
            IRiskScoring(contracts.riskScoring),
            ICrossChainLiquidity(contracts.crossChainLiquidity),
            deployer
        );
        
        // Use standard CREATE2 deployer
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        
        console2.log("Mining DynamicFeeHook address...");
        (hookAddress, salt) = HookMiner.find(
            create2Deployer,
            targetFlags,
            type(DynamicFeeHook).creationCode,
            constructorArgs
        );
        
        // Verify the mined address has correct flags
        uint160 addressFlags = uint160(hookAddress) & uint160((1 << 14) - 1);
        require(addressFlags == targetFlags, "Mined DynamicFeeHook address has incorrect flags");
        
        console2.log("Successfully mined DynamicFeeHook address with flags:", addressFlags);
        console2.log("Mined DynamicFeeHook address:", hookAddress);
        console2.log("DynamicFeeHook salt:", vm.toString(salt));
        
        emit HookAddressMined(hookAddress, salt);
        
        // Deploy using CREATE2 with the mined salt
        DynamicFeeHook hook = new DynamicFeeHook{salt: salt}(
            IPoolManager(contracts.poolManager),
            IRiskScoring(contracts.riskScoring),
            ICrossChainLiquidity(contracts.crossChainLiquidity),
            deployer
        );
        
        hookAddress = address(hook);
        
        require(hookAddress != address(0), "DynamicFeeHook deployment failed");
        
        console2.log("DynamicFeeHook deployed successfully at:", hookAddress);
        
        // Verify hook flags
        uint160 deployedFlags = uint160(hookAddress) & uint160((1 << 14) - 1);
        require(deployedFlags == targetFlags, "Deployed DynamicFeeHook has incorrect flags");
        console2.log("DynamicFeeHook flags verified:", deployedFlags);
    }
    
    function _printDeploymentSummary() internal view {
        console2.log("\n=== DEPLOYMENT SUMMARY ===");
        console2.log("PoolManager:              ", contracts.poolManager);
        console2.log("RiskScoring:              ", contracts.riskScoring);
        console2.log("CrossChainLiquidity:      ", contracts.crossChainLiquidity);
        console2.log("KeeperNetwork:            ", contracts.keeperNetwork);
        console2.log("CrossChainOracle:         ", contracts.oracle);
        console2.log("UniswapHookOrchestrator:  ", contracts.orchestrator);
        console2.log("  - Deployed with salt:   ", vm.toString(contracts.orchestratorSalt));
        console2.log("BeforeSwapHook:           ", contracts.beforeSwapHook);
        console2.log("AfterSwapHook:            ", contracts.afterSwapHook);
        console2.log("DynamicFeeHook:           ", contracts.dynamicFeeHook);
        console2.log("CirclePaymaster:          ", contracts.circlePaymaster);
        console2.log("==========================");
        
        console2.log("\nNext steps:");
        console2.log("1. Verify contracts on Etherscan");
        console2.log("2. Update .env file with deployed addresses");
        console2.log("3. Test hook functionality");
        console2.log("4. Configure keeper operations");
    }
}
