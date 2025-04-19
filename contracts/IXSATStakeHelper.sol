// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IXSATStakeHelper {

    function lockTime() external view returns (uint256);
    function deposit(address _target, uint256 _amount) external payable;
    function restake(address _from, address _to, uint256 _amount) external;
    function claim(address _target) external;
    function withdraw(address _target, uint256 _amount) external;
    function claimPendingFunds(address _target) external;
    function claimPendingFunds() external;
    function authorizeTransfer(address _operator, address _fromValidator, uint256 _amount) external;
    function performTransfer(address _user, address _fromValidator, address _toValidator, uint256 _amount) external;
    function stakeInfo(address _validator, address _user) external view returns (uint256 amount);
    function depositFee() external view returns (uint256);

}