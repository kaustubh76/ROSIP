// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CirclePaymaster
 * @notice Integration with Circle for gas abstraction using USDC payments
 * @dev This contract allows users to pay gas fees in USDC
 */
contract CirclePaymaster is AccessControl, ReentrancyGuard {
    // Roles
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    
    // Token used for payments (USDC)
    IERC20 public usdcToken;
    
    // Gas price oracle
    address public gasPriceOracle;
    
    // Exchange rate between tokens and gas (how many wei of gas 1 token unit can buy)
    uint256 public tokenToGasExchangeRate;
    
    // Fee structure
    struct FeeConfig {
        uint256 baseGasOverhead;    // Base gas overhead per transaction
        uint256 feeMultiplier;      // Fee multiplier (scaled by 10000)
        uint256 minFee;             // Minimum fee in USDC (6 decimals)
    }
    
    // Fee configuration
    FeeConfig public feeConfig;
    
    // Pre-funded transactions
    struct PreFundedTx {
        address user;               // User address
        uint256 fundingAmount;      // Amount of USDC pre-funded
        uint256 gasLimit;           // Maximum gas to use
        uint256 expiry;             // Expiry timestamp
        bool used;                  // Whether tx has been executed
    }
    
    // Transaction authorization
    mapping(bytes32 => PreFundedTx) public authorizedTxs;
    
    // Total fees collected
    uint256 public totalFeesCollected;
    
    // Gas credits for users
    mapping(address => uint256) public gasCredits;
    
    // User balances (deposited USDC)
    mapping(address => uint256) public userBalances;
    
    // Total deposits across all users
    uint256 public totalDeposits;
    
    // ETH to USDC conversion rate (USDC per ETH, scaled by 1e6)
    uint256 public ethToUsdcRate;
    
    // Authorized callers for payForTransaction
    mapping(address => bool) public authorizedCallers;
    
    // Store admin address for owner() function
    address private _admin;
    
    // Contract active state
    bool private _active;
    
    // Events
    event TransactionPreFunded(bytes32 indexed txId, address indexed user, uint256 fundingAmount);
    event TransactionExecuted(bytes32 indexed txId, address indexed user, uint256 gasUsed, uint256 feeCharged);
    event FeesWithdrawn(address indexed receiver, uint256 amount);
    event FeeConfigUpdated(uint256 baseGasOverhead, uint256 feeMultiplier, uint256 minFee);
    event GasPaymentReceived(address indexed user, address indexed token, uint256 tokenAmount, uint256 gasAmount);
    event ActiveStateChanged(bool active);
    
    /**
     * @notice Constructor
     * @param _usdcToken USDC token address
     * @param _gasPriceOracle Gas price oracle address
     * @param admin Admin address
     */
    constructor(
        address _usdcToken,
        address _gasPriceOracle,
        address admin
    ) {
        usdcToken = IERC20(_usdcToken);
        gasPriceOracle = _gasPriceOracle;
        _admin = admin;
        _active = true; // Start active by default
        ethToUsdcRate = 3000 * 1e6; // Default: 3000 USDC per ETH
        authorizedCallers[admin] = true; // Admin is authorized by default
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FEE_MANAGER_ROLE, admin);
        _grantRole(RELAYER_ROLE, admin);
        
        // Default fee config
        feeConfig = FeeConfig({
            baseGasOverhead: 50000,
            feeMultiplier: 12000, // 1.2x (20% premium)
            minFee: 100000 // 0.1 USDC
        });
        
        // Default exchange rate: 1 USDC (1e6) = 20,000 GWEI of gas
        tokenToGasExchangeRate = 20000 * 10**6;
    }
    
    /**
     * @notice Deposit USDC funds for paying gas
     * @param amount Amount of USDC to deposit (6 decimals)
     */
    function depositFunds(uint256 amount) external whenActive {
        require(amount > 0, "CirclePaymaster: amount must be greater than zero");
        
        // Transfer USDC from user
        require(usdcToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        userBalances[msg.sender] += amount;
        totalDeposits += amount;
    }
    
    /**
     * @notice Withdraw USDC funds
     * @param amount Amount of USDC to withdraw (6 decimals)
     */
    function withdrawFunds(uint256 amount) external {
        require(amount > 0, "CirclePaymaster: amount must be greater than zero");
        require(userBalances[msg.sender] >= amount, "CirclePaymaster: insufficient balance");
        
        userBalances[msg.sender] -= amount;
        totalDeposits -= amount;
        
        require(usdcToken.transfer(msg.sender, amount), "Transfer failed");
    }
    
    /**
     * @notice Estimate gas cost in USDC
     * @param gasUsed Gas amount used
     * @param gasPrice Gas price in wei
     * @return Cost in USDC (6 decimals)
     */
    function estimateGasCost(uint256 gasUsed, uint256 gasPrice) public view returns (uint256) {
        // Calculate ETH cost: gasUsed * gasPrice (in wei)
        uint256 ethCostWei = gasUsed * gasPrice;
        
        // Convert to USDC: (ethCostWei * ethToUsdcRate) / 1e18
        uint256 usdcCost = (ethCostWei * ethToUsdcRate) / 1e18;
        
        // Apply fee multiplier
        uint256 costWithFee = (usdcCost * feeConfig.feeMultiplier) / 10000;
        
        // Apply minimum fee
        if (costWithFee < feeConfig.minFee) {
            costWithFee = feeConfig.minFee;
        }
        
        return costWithFee;
    }
    
    /**
     * @notice Pay for a transaction using user's deposited funds
     * @param user User address
     * @param gasUsed Gas used for the transaction
     * @param gasPrice Gas price for the transaction
     */
    function payForTransaction(address user, uint256 gasUsed, uint256 gasPrice) external {
        require(authorizedCallers[msg.sender] || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "CirclePaymaster: unauthorized");
        
        uint256 cost = estimateGasCost(gasUsed, gasPrice);
        require(userBalances[user] >= cost, "CirclePaymaster: insufficient funds for gas");
        
        userBalances[user] -= cost;
        totalDeposits -= cost;
        totalFeesCollected += cost;
    }
    
    /**
     * @notice Get user's USDC balance
     * @param user User address
     * @return User's balance in USDC (6 decimals)
     */
    function getUserBalance(address user) external view returns (uint256) {
        return userBalances[user];
    }
    
    /**
     * @notice Get total deposits across all users
     * @return Total deposits in USDC (6 decimals)
     */
    function getTotalDeposits() external view returns (uint256) {
        return totalDeposits;
    }
    
    /**
     * @notice Set gas price oracle address
     * @param newOracle New oracle address
     */
    function setGasPriceOracle(address newOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newOracle != address(0), "CirclePaymaster: invalid oracle address");
        gasPriceOracle = newOracle;
    }
    
    /**
     * @notice Update ETH to USDC conversion rate
     * @param newRate New rate (USDC per ETH, scaled by 1e6)
     */
    function updateConversionRate(uint256 newRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRate > 0, "CirclePaymaster: invalid conversion rate");
        ethToUsdcRate = newRate;
    }
    
    /**
     * @notice Add authorized caller for payForTransaction
     * @param caller Address to authorize
     */
    function addAuthorizedCaller(address caller) external onlyRole(DEFAULT_ADMIN_ROLE) {
        authorizedCallers[caller] = true;
    }
    
    /**
     * @notice Remove authorized caller for payForTransaction
     * @param caller Address to remove authorization
     */
    function removeAuthorizedCaller(address caller) external onlyRole(DEFAULT_ADMIN_ROLE) {
        authorizedCallers[caller] = false;
    }
    
    /**
     * @notice Check if address is authorized caller
     * @param caller Address to check
     * @return Whether address is authorized
     */
    function isAuthorizedCaller(address caller) external view returns (bool) {
        return authorizedCallers[caller];
    }
    
    /**
     * @notice Emergency withdraw all contract funds (admin only)
     */
    function emergencyWithdraw() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 balance = usdcToken.balanceOf(address(this));
        require(usdcToken.transfer(msg.sender, balance), "Transfer failed");
    }
    
    /**
     * @notice Update the fee configuration
     * @param _baseGasOverhead Base gas overhead
     * @param _feeMultiplier Fee multiplier
     * @param _minFee Minimum fee
     */
    function updateFeeConfig(
        uint256 _baseGasOverhead,
        uint256 _feeMultiplier,
        uint256 _minFee
    ) external onlyRole(FEE_MANAGER_ROLE) {
        feeConfig = FeeConfig({
            baseGasOverhead: _baseGasOverhead,
            feeMultiplier: _feeMultiplier,
            minFee: _minFee
        });
        
        emit FeeConfigUpdated(_baseGasOverhead, _feeMultiplier, _minFee);
    }

    /**
     * @notice Set the token to gas exchange rate
     * @param _tokenToGasExchangeRate New exchange rate
     * @dev This represents how many wei of gas 1 token unit (1e6 for USDC) can buy
     */
    function setTokenToGasExchangeRate(uint256 _tokenToGasExchangeRate) external {
        require(hasRole(FEE_MANAGER_ROLE, msg.sender), "Ownable: caller is not the owner");
        tokenToGasExchangeRate = _tokenToGasExchangeRate;
    }
    
    /**
     * @notice Check if an address has the RELAYER_ROLE
     * @param account The address to check
     * @return True if the address has the RELAYER_ROLE
     */
    function isRelayer(address account) external view returns (bool) {
        return hasRole(RELAYER_ROLE, account);
    }
    
    /**
     * @notice Get the owner (admin) of the contract
     * @return The address with DEFAULT_ADMIN_ROLE
     * @dev This function is added for compatibility with contracts that expect an owner() function
     */
    function owner() external view returns (address) {
        return _admin;
    }
    
    /**
     * @notice Add a new relayer
     * @param relayer Relayer address
     */
    function addRelayer(address relayer) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Ownable: caller is not the owner");
        _grantRole(RELAYER_ROLE, relayer);
    }
    
    /**
     * @notice Remove a relayer
     * @param relayer Relayer address
     */
    function removeRelayer(address relayer) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Ownable: caller is not the owner");
        _revokeRole(RELAYER_ROLE, relayer);
    }
    
    /**
     * @notice Estimate the gas fee for a transaction in USDC
     * @param gasLimit Gas limit for the transaction
     * @return usdcAmount The estimated amount in USDC (6 decimals)
     */
    function estimateGasFee(uint256 gasLimit) external view returns (uint256 usdcAmount) {
        uint256 estimatedGas = gasLimit + feeConfig.baseGasOverhead;
        uint256 gasPrice = _getGasPrice();
        
        // Calculate the estimated ETH cost
        uint256 ethCost = estimatedGas * gasPrice;
        
        // Convert to USDC using a simplified price (1 ETH = 3000 USDC)
        // In a real implementation, this would use an oracle
        uint256 ethToUsdcPrice = 3000 * 10**6; // 3000 USDC per ETH with 6 decimals
        uint256 usdcCost = (ethCost * ethToUsdcPrice) / 10**18;
        
        // Apply fee multiplier
        usdcAmount = (usdcCost * feeConfig.feeMultiplier) / 10000;
        
        // Apply minimum fee
        if (usdcAmount < feeConfig.minFee) {
            usdcAmount = feeConfig.minFee;
        }
        
        return usdcAmount;
    }
    
    /**
     * @notice Pre-fund a transaction with USDC
     * @param operationData The operation data for authorizing the transaction
     * @param gasLimit Maximum gas allowed
     * @param validUntil The expiry timestamp
     * @return txId The transaction ID
     */
    function preFundTransaction(
        bytes memory operationData,
        uint256 gasLimit,
        uint256 validUntil
    ) external nonReentrant returns (bytes32 txId) {
        require(validUntil > block.timestamp, "Expiry must be in the future");
        
        // Generate transaction ID
        txId = keccak256(abi.encodePacked(
            msg.sender,
            operationData,
            gasLimit,
            validUntil,
            block.timestamp
        ));
        
        // Calculate required USDC
        uint256 requiredUsdc = this.estimateGasFee(gasLimit);
        
        // Transfer USDC from user
        require(usdcToken.transferFrom(msg.sender, address(this), requiredUsdc), "USDC transfer failed");
        
        // Save transaction details
        authorizedTxs[txId] = PreFundedTx({
            user: msg.sender,
            fundingAmount: requiredUsdc,
            gasLimit: gasLimit,
            expiry: validUntil,
            used: false
        });
        
        emit TransactionPreFunded(txId, msg.sender, requiredUsdc);
        
        return txId;
    }
    
    /**
     * @notice Execute a pre-funded transaction
     * @param txId Transaction ID
     * @param target Contract to call
     * @param data Call data
     * @param refundAddress Address to refund any excess USDC
     * @return success Whether execution was successful
     * @return result The execution result
     */
    function executeTransaction(
        bytes32 txId,
        address target, 
        bytes calldata data,
        address refundAddress
    ) external onlyRole(RELAYER_ROLE) nonReentrant returns (bool success, bytes memory result) {
        PreFundedTx storage preFundedTx = authorizedTxs[txId];
        
        require(preFundedTx.user != address(0), "Transaction not found");
        require(!preFundedTx.used, "Transaction already executed");
        require(block.timestamp <= preFundedTx.expiry, "Transaction expired");
        
        // Mark as used before executing to prevent reentrancy
        preFundedTx.used = true;
        
        // Record gas before execution
        uint256 startGas = gasleft();
        
        // Execute the target call
        (success, result) = target.call{gas: preFundedTx.gasLimit}(data);
        
        // Calculate gas used
        uint256 gasUsed = startGas - gasleft() + feeConfig.baseGasOverhead;
        
        // Calculate actual fee
        uint256 gasPrice = _getGasPrice();
        uint256 ethCost = gasUsed * gasPrice;
        uint256 ethToUsdcPrice = 3000 * 10**6; // 3000 USDC per ETH
        uint256 actualUsdcCost = (ethCost * ethToUsdcPrice) / 10**18;
        uint256 feeCharged = (actualUsdcCost * feeConfig.feeMultiplier) / 10000;
        
        if (feeCharged < feeConfig.minFee) {
            feeCharged = feeConfig.minFee;
        }
        
        // Cap fee at funding amount
        if (feeCharged > preFundedTx.fundingAmount) {
            feeCharged = preFundedTx.fundingAmount;
        }
        
        // Add to total fees collected
        totalFeesCollected += feeCharged;
        
        // Refund excess if any
        if (preFundedTx.fundingAmount > feeCharged && refundAddress != address(0)) {
            uint256 refundAmount = preFundedTx.fundingAmount - feeCharged;
            require(usdcToken.transfer(refundAddress, refundAmount), "Refund failed");
        }
        
        emit TransactionExecuted(txId, preFundedTx.user, gasUsed, feeCharged);
        
        return (success, result);
    }
    
    /**
     * @notice Withdraw collected fees
     * @param receiver Address to receive fees
     * @param amount Amount to withdraw
     */
    function withdrawFees(
        address receiver,
        uint256 amount
    ) external nonReentrant {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Ownable: caller is not the owner");
        require(amount <= totalFeesCollected, "Amount exceeds collected fees");
        
        totalFeesCollected -= amount;
        require(usdcToken.transfer(receiver, amount), "Fee withdrawal failed");
        
        emit FeesWithdrawn(receiver, amount);
    }
    
    /**
     * @notice Check if a transaction is authorized
     * @param txId Transaction ID
     * @return isAuthorized Whether the transaction is authorized
     * @return user User address
     * @return fundingAmount Funding amount
     */
    function checkAuthorization(
        bytes32 txId
    ) external view returns (bool isAuthorized, address user, uint256 fundingAmount) {
        PreFundedTx memory preFundedTx = authorizedTxs[txId];
        
        isAuthorized = preFundedTx.user != address(0) && 
                      !preFundedTx.used && 
                      block.timestamp <= preFundedTx.expiry;
                      
        return (isAuthorized, preFundedTx.user, preFundedTx.fundingAmount);
    }
    
    /**
     * @notice Pay for gas using USDC
     * @param usdcAmount Amount of USDC to pay
     */
    function payForGas(uint256 usdcAmount) external {
        // Transfer USDC from user to paymaster
        require(usdcToken.transferFrom(msg.sender, address(this), usdcAmount), "USDC transfer failed");
        
        // Add to total fees collected
        totalFeesCollected += usdcAmount;
        
        // Convert USDC amount to gas credits using the exchange rate
        // Rate represents USDC per ETH, so we need to convert: gasCredits = usdcAmount * 1e18 / rate
        uint256 gasCreditsToAdd = (usdcAmount * 1e18) / tokenToGasExchangeRate;
        
        // Update user's gas credits
        gasCredits[msg.sender] += gasCreditsToAdd;
        
        // Emit event
        emit GasPaymentReceived(msg.sender, address(usdcToken), usdcAmount, gasCreditsToAdd);
    }
    
    /**
     * @notice Relay a transaction for a user who has paid for gas
     * @param user The user who authorized the transaction
     * @param target The target contract to call
     * @param data The calldata to send
     * @param value The ETH value to send
     * @param gasLimit The maximum gas to use
     * @return success Whether the transaction was successful
     */
    function relayTransaction(
        address user,
        address target,
        bytes calldata data,
        uint256 value,
        uint256 gasLimit
    ) external returns (bool success) {
        // Check if caller is authorized relayer
        require(hasRole(RELAYER_ROLE, msg.sender), "Not authorized as relayer");
        
        // Ensure user has enough gas credits
        uint256 maxGasCost = gasLimit * tx.gasprice;
        require(gasCredits[user] >= maxGasCost, "Insufficient gas credits");
        
        // Deduct gas from user's account (pre-pay model)
        gasCredits[user] -= maxGasCost;
        
        // Execute transaction
        uint256 startGas = gasleft();
        (success, ) = target.call{value: value, gas: gasLimit}(data);
        uint256 gasUsed = startGas - gasleft();
        
        // If target has no code and we're calling with data, consider it a failure
        if (success && data.length > 0) {
            uint256 size;
            assembly {
                size := extcodesize(target)
            }
            if (size == 0) {
                success = false;
            }
        }
        
        // Calculate actual cost and refund excess
        uint256 actualCost = gasUsed * tx.gasprice;
        if (actualCost < maxGasCost) {
            uint256 refund = maxGasCost - actualCost;
            gasCredits[user] += refund;
        }
        
        return success;
    }
    
    /**
     * @notice Get current gas price
     * @return price Current gas price
     */
    function _getGasPrice() internal view returns (uint256 price) {
        // In a real implementation, this would query the oracle
        // For demonstration, we'll use block.basefee if available (EIP-1559) or tx.gasprice
        if (block.basefee > 0) {
            // EIP-1559 chain
            return block.basefee + 2 gwei; // base fee + priority fee
        } else {
            // Legacy gas price
            return tx.gasprice;
        }
    }
    
    /**
     * @notice Check if the contract is active
     * @return Whether the contract is active
     */
    function isActive() public view returns (bool) {
        return _active;
    }
    
    /**
     * @notice Set the active state of the contract (admin only)
     * @param active New active state
     */
    function setActive(bool active) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _active = active;
        emit ActiveStateChanged(active);
    }
    
    /**
     * @notice Modifier to ensure contract is active
     */
    modifier whenActive() {
        require(_active, "CirclePaymaster: contract is not active");
        _;
    }
}
