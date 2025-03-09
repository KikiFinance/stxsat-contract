// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @dev Interface for stXSAT token.
 * In addition to the standard ERC20 functions, stXSAT should implement
 * the following conversion functions.
 */
interface IStXSAT is IERC20 {
    /**
     * @notice Converts a given amount of stXSAT to the corresponding wrapped shares.
     * @param _pooledXSAT The amount of stXSAT to convert.
     * @return The equivalent amount of wrapped shares (wstXSAT).
     */
    function getSharesByPooledXSAT(uint256 _pooledXSAT) external view returns (uint256);

    /**
     * @notice Converts a given amount of wrapped shares to the corresponding stXSAT amount.
     * @param _shares The amount of wrapped shares (wstXSAT) to convert.
     * @return The equivalent amount of stXSAT.
     */
    function getPooledXSATByShares(uint256 _shares) external view returns (uint256);
}

/**
 * @title WstXSAT
 * @notice This contract wraps stXSAT tokens into wstXSAT tokens at a 1:1 conversion rate.
 * Users can call wrap() to deposit stXSAT and mint an equivalent amount of wstXSAT.
 * Conversely, calling unwrap() will burn the wstXSAT tokens and return the corresponding stXSAT.
 */
contract WstXSAT is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IStXSAT public stXSAT;

    event Wrapped(address indexed user, uint256 stXSATAmount, uint256 wstXSATAmount);
    event Unwrapped(address indexed user, uint256 wstXSATAmount, uint256 stXSATAmount);

    /**
     * @notice Constructor.
     * @param _stXSAT The address of the stXSAT token (must implement the IStXSAT interface).
     */
    constructor(IStXSAT _stXSAT)
    ERC20("Wrapped stXSAT", "wstXSAT")
    {
        require(address(_stXSAT) != address(0), "WstXSAT: invalid stXSAT address");
        stXSAT = _stXSAT;
    }

    /**
     * @notice Wrap stXSAT into wstXSAT (1:1 conversion).
     * @param _stXSATAmount The amount of stXSAT to wrap.
     * @return wstXSATAmount The amount of wstXSAT minted.
     *
     * Note: The user must approve this contract to spend at least _stXSATAmount of stXSAT.
     */
    function wrap(uint256 _stXSATAmount) external nonReentrant returns (uint256 wstXSATAmount) {
        require(_stXSATAmount > 0, "WstXSAT: cannot wrap zero stXSAT");
        // Calculate the wrapped token amount using the conversion function
        wstXSATAmount = stXSAT.getSharesByPooledXSAT(_stXSATAmount);
        require(wstXSATAmount > 0, "WstXSAT: conversion resulted in zero amount");

        // Transfer the stXSAT tokens from the user to this contract
        IERC20(address(stXSAT)).safeTransferFrom(msg.sender, address(this), _stXSATAmount);
        // Mint wstXSAT tokens to the user
        _mint(msg.sender, wstXSATAmount);

        emit Wrapped(msg.sender, _stXSATAmount, wstXSATAmount);
    }

    /**
     * @notice Unwrap wstXSAT back into stXSAT (1:1 conversion).
     * @param _wstXSATAmount The amount of wstXSAT to unwrap.
     * @return stXSATAmount The amount of stXSAT returned.
     */
    function unwrap(uint256 _wstXSATAmount) external nonReentrant returns (uint256 stXSATAmount) {
        require(_wstXSATAmount > 0, "WstXSAT: cannot unwrap zero amount");
        // Calculate the stXSAT amount using the conversion function
        stXSATAmount = stXSAT.getPooledXSATByShares(_wstXSATAmount);
        require(stXSATAmount > 0, "WstXSAT: conversion resulted in zero amount");

        // Burn the wstXSAT tokens from the user
        _burn(msg.sender, _wstXSATAmount);
        // Transfer the corresponding stXSAT tokens back to the user
        IERC20(address(stXSAT)).safeTransfer(msg.sender, stXSATAmount);

        emit Unwrapped(msg.sender, _wstXSATAmount, stXSATAmount);
    }

    /**
     * @notice Returns the wrapped token amount for a given stXSAT amount.
     * @param _stXSATAmount The amount of stXSAT.
     * @return The corresponding amount of wstXSAT.
     */
    function getWstXSATByStXSAT(uint256 _stXSATAmount) external view returns (uint256) {
        return stXSAT.getSharesByPooledXSAT(_stXSATAmount);
    }

    /**
     * @notice Returns the stXSAT amount for a given wrapped token amount.
     * @param _wstXSATAmount The amount of wstXSAT.
     * @return The corresponding amount of stXSAT.
     */
    function getStXSATByWstXSAT(uint256 _wstXSATAmount) external view returns (uint256) {
        return stXSAT.getPooledXSATByShares(_wstXSATAmount);
    }

    /**
     * @notice Returns the amount of stXSAT per one wstXSAT token.
     * @return The stXSAT amount equivalent to 1 wstXSAT (using 1 ether as the unit).
     */
    function stXSATPerToken() external view returns (uint256) {
        return stXSAT.getPooledXSATByShares(1 ether);
    }

    /**
     * @notice Returns the amount of wstXSAT per one stXSAT token.
     * @return The wstXSAT amount equivalent to 1 stXSAT (using 1 ether as the unit).
     */
    function tokensPerStXSAT() external view returns (uint256) {
        return stXSAT.getSharesByPooledXSAT(1 ether);
    }
}
