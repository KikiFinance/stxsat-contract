// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IXSATStakingRouter {

    /// @notice Returns the lock time (in seconds) for reward withdrawals.
    function lockTime() external view returns (uint256);

    /// @notice Returns the total staking balance managed by the router.
    function getStakingBalance() external view returns (uint256);

    /// @notice Returns the fixed capacity of each validator.
    function validatorCapacity() external view returns (uint256);

    /// @notice Returns the fee rate (scaled by PRECISION).
    function fee() external view returns (uint256);

    /// @notice Returns the fee collector address.
    function feeCollector() external view returns (address);

    /// @notice Deposits a specified amount of XSAT tokens.
    function deposit(uint256 _amount) payable external;

    /// @notice Requests a withdrawal of the specified amount of XSAT tokens.
    function requestWithdraw(uint256 _amount) external;

    /// @notice Claims a pending withdrawal.
    function claimWithdraw() external;

    /**
     * @notice Collects the claimed rewards.
     * @dev Transfers the XSAT rewards from the staking router into stXSAT.
     */
    function collectRewards() external;
}
