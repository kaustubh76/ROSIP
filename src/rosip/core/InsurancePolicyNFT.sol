// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title InsurancePolicyNFT
 * @notice ERC-721 NFT representing parameterized insurance policies
 * @dev Each NFT encodes specific insurance parameters and can be used for claims
 */
contract InsurancePolicyNFT is ERC721, ERC721Enumerable, AccessControl {
    
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant CLAIM_PROCESSOR_ROLE = keccak256("CLAIM_PROCESSOR_ROLE");
    
    /// @notice Types of insurance available
    enum InsuranceType {
        DEPEG_PROTECTION,      // Stablecoin depeg insurance
        IMPERMANENT_LOSS,      // LP position IL protection
        VOLATILITY_CAP,        // Price volatility insurance
        BRIDGE_PROTECTION,     // Cross-chain bridge insurance TODO
        SMART_CONTRACT_RISK,   // Protocol exploit insurance TODO
        LIQUIDATION_PROTECTION // Lending position insurance TODO
    }
    
    /// @notice Current status of an insurance policy
    enum PolicyStatus {
        ACTIVE,      // Policy is active and monitoring
        TRIGGERED,   // Event occurred, pending claim
        CLAIMED,     // Payout has been processed
        EXPIRED,     // Policy expired without trigger
        CANCELLED    // Policy was cancelled/invalidated TODO
    }
    
    /// @notice Core insurance policy parameters
    struct InsurancePolicy {
        InsuranceType insuranceType;
        PolicyStatus status;
        address beneficiary;
        address asset;           // Primary asset being insured
        uint256 coverageAmount;  // Max payout in USDC
        uint256 premium;         // Premium paid in USDC
        uint256 startTime;       // Policy activation time
        uint256 duration;        // Coverage duration in seconds
        uint256 triggerPrice;    // Price trigger (if applicable)
        uint256 thresholdPercent; // Percentage threshold (if applicable)
        bytes32 poolId;          // Associated Uniswap pool
        bytes additionalParams;  // Type-specific parameters
    }
    
    /// @notice Event data for triggered insurance
    struct TriggerEvent {
        uint256 policyId;
        uint256 triggerTime;
        uint256 eventValue;      // Actual price/value when triggered
        bytes32 eventProof;      // Hash of supporting evidence
        bool verified;           // Whether event has been verified
        uint256 payoutAmount;    // Calculated payout amount
    }
    
    /// @dev Policy counter for unique IDs
    uint256 private _policyIdCounter;
    
    /// @dev Policy ID to policy data mapping
    mapping(uint256 => InsurancePolicy) public policies;
    
    /// @dev Policy ID to trigger event mapping
    mapping(uint256 => TriggerEvent) public triggerEvents;
    
    /// @dev User to active policy IDs mapping
    mapping(address => uint256[]) public userPolicies;
    
    /// @dev Pool to active policy IDs mapping (for monitoring)
    mapping(bytes32 => uint256[]) public poolPolicies;
    
    /// @notice Events for policy lifecycle tracking
    event PolicyMinted(
        uint256 indexed policyId,
        address indexed beneficiary,
        InsuranceType insuranceType,
        uint256 coverageAmount,
        uint256 premium
    );
    
    event PolicyTriggered(
        uint256 indexed policyId,
        uint256 triggerTime,
        uint256 eventValue,
        bytes32 eventProof
    );
    
    event PolicyClaimed(
        uint256 indexed policyId,
        address indexed beneficiary,
        uint256 payoutAmount
    );
    
    event PolicyExpired(uint256 indexed policyId);
    event PolicyCancelled(uint256 indexed policyId);
    
    constructor(
        string memory name,
        string memory symbol,
        address _admin
    ) ERC721(name, symbol) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MINTER_ROLE, _admin);
    }
    
    /**
     * @notice Mint a new insurance policy NFT
     * @param to Address to receive the policy NFT
     * @param policy Insurance policy parameters
     * @return policyId The ID of the newly minted policy
     */
    function mintPolicy(
        address to,
        InsurancePolicy memory policy
    ) external onlyRole(MINTER_ROLE) returns (uint256 policyId) {
        _policyIdCounter++;
        policyId = _policyIdCounter;
        
        // Set beneficiary and status
        policy.beneficiary = to;
        policy.status = PolicyStatus.ACTIVE;
        policy.startTime = block.timestamp;
        
        // Store policy data
        policies[policyId] = policy;
        
        // Update user tracking
        userPolicies[to].push(policyId);
        
        // Update pool tracking if applicable
        if (policy.poolId != bytes32(0)) {
            poolPolicies[policy.poolId].push(policyId);
        }
        
        // Mint NFT
        _safeMint(to, policyId);
        
        emit PolicyMinted(
            policyId,
            to,
            policy.insuranceType,
            policy.coverageAmount,
            policy.premium
        );
    }
    
    /**
     * @notice Trigger an insurance policy due to qualifying event
     * @param policyId The policy to trigger
     * @param eventValue The value/price when event occurred
     * @param eventProof Hash of supporting evidence
     */
    function triggerPolicy(
        uint256 policyId,
        uint256 eventValue,
        bytes32 eventProof
    ) external onlyRole(CLAIM_PROCESSOR_ROLE) {
        require(_ownerOf(policyId) != address(0), "Policy does not exist");
        
        InsurancePolicy storage policy = policies[policyId];
        require(policy.status == PolicyStatus.ACTIVE, "Policy not active");
        require(block.timestamp <= policy.startTime + policy.duration, "Policy expired");
        
        // Calculate payout based on insurance type and event
        uint256 payoutAmount = _calculatePayout(policy, eventValue);
        
        // Update policy status
        policy.status = PolicyStatus.TRIGGERED;
        
        // Record trigger event
        triggerEvents[policyId] = TriggerEvent({
            policyId: policyId,
            triggerTime: block.timestamp,
            eventValue: eventValue,
            eventProof: eventProof,
            verified: false,
            payoutAmount: payoutAmount
        });
        
        emit PolicyTriggered(policyId, block.timestamp, eventValue, eventProof);
    }
    
    /**
     * @notice Process a claim for a triggered policy
     * @param policyId The policy to claim
     */
    function processClaim(uint256 policyId) 
        external 
        onlyRole(CLAIM_PROCESSOR_ROLE) 
        returns (uint256 payoutAmount) 
    {
        require(_ownerOf(policyId) != address(0), "Policy does not exist");
        
        InsurancePolicy storage policy = policies[policyId];
        require(policy.status == PolicyStatus.TRIGGERED, "Policy not triggered");
        
        TriggerEvent storage trigger = triggerEvents[policyId];
        require(trigger.verified, "Event not verified");
        
        // Update policy status
        policy.status = PolicyStatus.CLAIMED;
        
        payoutAmount = trigger.payoutAmount;
        
        emit PolicyClaimed(policyId, policy.beneficiary, payoutAmount);
    }
    
    /**
     * @notice Verify a trigger event (by oracle or admin)
     * @param policyId The policy with the trigger event
     * @param verified Whether the event is verified as valid
     */
    function verifyTriggerEvent(
        uint256 policyId,
        bool verified
    ) external onlyRole(CLAIM_PROCESSOR_ROLE) {
        require(_ownerOf(policyId) != address(0), "Policy does not exist");
        
        TriggerEvent storage trigger = triggerEvents[policyId];
        require(trigger.triggerTime > 0, "No trigger event");
        
        trigger.verified = verified;
        
        if (!verified) {
            // If verification fails, revert policy to active
            policies[policyId].status = PolicyStatus.ACTIVE;
        }
    }
    
    /**
     * @notice Expire policies that have passed their duration
     * @param policyIds Array of policy IDs to check for expiration
     */
    function expirePolicies(uint256[] calldata policyIds) external {
        for (uint256 i = 0; i < policyIds.length; i++) {
            uint256 policyId = policyIds[i];
            
            if (_ownerOf(policyId) == address(0)) continue;
            
            InsurancePolicy storage policy = policies[policyId];
            
            if (policy.status == PolicyStatus.ACTIVE && 
                block.timestamp > policy.startTime + policy.duration) {
                
                policy.status = PolicyStatus.EXPIRED;
                emit PolicyExpired(policyId);
            }
        }
    }
    
    /**
     * @notice Get policy details
     * @param policyId The policy ID to query
     * @return policy The insurance policy data
     */
    function getPolicy(uint256 policyId) 
        external 
        view 
        returns (InsurancePolicy memory policy) 
    {
        require(_ownerOf(policyId) != address(0), "Policy does not exist");
        return policies[policyId];
    }
    
    /**
     * @notice Get trigger event details
     * @param policyId The policy ID to query
     * @return trigger The trigger event data
     */
    function getTriggerEvent(uint256 policyId) 
        external 
        view 
        returns (TriggerEvent memory trigger) 
    {
        require(_ownerOf(policyId) != address(0), "Policy does not exist");
        return triggerEvents[policyId];
    }
    
    /**
     * @notice Get all active policies for a user
     * @param user The user address
     * @return activePolicyIds Array of active policy IDs
     */
    function getUserActivePolicies(address user) 
        external 
        view 
        returns (uint256[] memory activePolicyIds) 
    {
        uint256[] memory userPolicyIds = userPolicies[user];
        uint256 activeCount = 0;
        
        // Count active policies
        for (uint256 i = 0; i < userPolicyIds.length; i++) {
            if (policies[userPolicyIds[i]].status == PolicyStatus.ACTIVE) {
                activeCount++;
            }
        }
        
        // Build result array
        activePolicyIds = new uint256[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < userPolicyIds.length; i++) {
            if (policies[userPolicyIds[i]].status == PolicyStatus.ACTIVE) {
                activePolicyIds[index] = userPolicyIds[i];
                index++;
            }
        }
    }
    
    /**
     * @notice Get all policies for a specific pool
     * @param poolId The pool identifier
     * @return policyIds Array of policy IDs for the pool
     */
    function getPoolPolicies(bytes32 poolId) 
        external 
        view 
        returns (uint256[] memory policyIds) 
    {
        return poolPolicies[poolId];
    }
    
    /**
     * @notice Check if a policy is active and within coverage period
     * @param policyId The policy ID to check
     * @return isActive True if policy is active and valid
     */
    function isPolicyActive(uint256 policyId) external view returns (bool isActive) {
        if (_ownerOf(policyId) == address(0)) return false;
        
        InsurancePolicy memory policy = policies[policyId];
        return policy.status == PolicyStatus.ACTIVE && 
               block.timestamp <= policy.startTime + policy.duration;
    }
    
    /**
     * @dev Calculate payout amount based on insurance type and event
     */
    function _calculatePayout(
        InsurancePolicy memory policy,
        uint256 eventValue
    ) internal pure returns (uint256 payoutAmount) {
        
        if (policy.insuranceType == InsuranceType.DEPEG_PROTECTION) {
            // For depeg: payout difference to trigger price
            if (eventValue < policy.triggerPrice) {
                uint256 depegAmount = policy.triggerPrice - eventValue;
                payoutAmount = (depegAmount * policy.coverageAmount) / policy.triggerPrice;
            }
        } else if (policy.insuranceType == InsuranceType.VOLATILITY_CAP) {
            // For volatility: payout excess beyond threshold
            if (eventValue > policy.triggerPrice) {
                uint256 excessVolatility = eventValue - policy.triggerPrice;
                payoutAmount = (excessVolatility * policy.coverageAmount) / policy.triggerPrice;
            }
        } else if (policy.insuranceType == InsuranceType.IMPERMANENT_LOSS) {
            // For IL: payout percentage of coverage based on loss
            uint256 lossPercent = (eventValue * 10000) / policy.triggerPrice; // Basis points
            if (lossPercent > policy.thresholdPercent) {
                payoutAmount = (policy.coverageAmount * (lossPercent - policy.thresholdPercent)) / 10000;
            }
        } else {
            // For other types: full coverage if triggered
            payoutAmount = policy.coverageAmount;
        }
        
        // Cap payout at coverage amount
        if (payoutAmount > policy.coverageAmount) {
            payoutAmount = policy.coverageAmount;
        }
    }
    
    /**
     * @dev Override required by Solidity for multiple inheritance
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ERC721, ERC721Enumerable) returns (address) {
        return super._update(to, tokenId, auth);
    }
    
    /**
     * @dev Override required by Solidity for multiple inheritance
     */
    function _increaseBalance(
        address account,
        uint128 value
    ) internal override(ERC721, ERC721Enumerable) {
        super._increaseBalance(account, value);
    }
    
    /**
     * @dev Override required by Solidity for multiple inheritance
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
