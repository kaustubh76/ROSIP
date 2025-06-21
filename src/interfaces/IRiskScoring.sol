// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IRiskScoring
 * @notice Interface for the risk scoring engine that assesses asset risk across multiple dimensions
 */
interface IRiskScoring {
    /**
     * @notice Struct representing different risk dimensions for an asset
     * @param volatilityScore Score based on price volatility (0-1000)
     * @param liquidityDepthScore Score based on market depth and liquidity (0-1000)
     * @param smartContractScore Score based on audit history and security (0-1000)
     * @param counterpartyScore Score based on centralization and governance (0-1000)
     * @param regulatoryScore Score based on compliance and regulation (0-1000)
     * @param lastUpdated Timestamp of the last score update
     */
    struct RiskProfile {
        uint16 volatilityScore;
        uint16 liquidityDepthScore;
        uint16 smartContractScore;
        uint16 counterpartyScore;
        uint16 regulatoryScore;
        uint32 lastUpdated;
    }

    /**
     * @notice Returns the composite risk score for an asset
     * @param token The address of the token to evaluate
     * @return score The composite risk score (0-1000, where 1000 is highest risk)
     */
    function getRiskScore(address token) external view returns (uint256 score);
    
    /**
     * @notice Returns the detailed risk profile for an asset
     * @param token The address of the token to evaluate
     * @return profile The detailed risk profile with component scores
     */
    function getRiskProfile(address token) external view returns (RiskProfile memory profile);
    
    /**
     * @notice Updates the risk score for an asset
     * @param token The address of the token to update
     * @param profile The new risk profile data
     */
    function updateRiskProfile(address token, RiskProfile calldata profile) external;
    
    /**
     * @notice Calculates a risk-adjusted fee based on asset risk and swap parameters
     * @param token The address of the token being swapped
     * @param amount The amount being swapped
     * @param volatility Current market volatility (optional, can be 0 to use stored data)
     * @return riskFee The additional fee component based on risk (in basis points)
     */
    function calculateRiskPremium(
        address token,
        uint256 amount,
        uint256 volatility
    ) external view returns (uint256 riskFee);
    
    /**
     * @notice Returns the time decay factor for a risk score based on data freshness
     * @param lastUpdated Timestamp when the data was last updated
     * @return decayFactor The decay multiplier (where 10000 = 100%)
     */
    function getTimeDecayFactor(uint32 lastUpdated) external view returns (uint256 decayFactor);
}
