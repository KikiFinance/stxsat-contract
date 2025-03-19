// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IStXSAT is IERC20 {
    function getSharesByPooledXSAT(uint256 _pooledXSAT) external view returns (uint256);

    function getPooledXSATByShares(uint256 _shares) external view returns (uint256);
}

/**
 * @title Wrapped stXSAT (wstXSAT)
 * @notice This contract wraps the dynamic stXSAT token into a static-balance token (wstXSAT),
 * similar to wstETH. wstXSAT only changes balance on transfers, making it suitable for DeFi protocols
 * that do not support rebasable tokens.
 *
 * @dev Users can deposit stXSAT tokens to mint an equivalent amount of wstXSAT tokens based on the current conversion rate.
 * Conversely, calling unwrap() burns the user's wstXSAT tokens and returns the corresponding stXSAT tokens.
 * The conversion rate is determined by the stXSAT contract's getSharesByPooledXSAT and getPooledXSATByShares functions.
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
     * @notice Wrap stXSAT tokens into wstXSAT tokens.
     * @dev Calculates the amount of wstXSAT tokens to mint using stXSAT.getSharesByPooledXSAT.
     * The user must approve this contract to spend at least the specified amount of stXSAT.
     * @param _stXSATAmount The amount of stXSAT to wrap.
     * @return wstXSATAmount The amount of wstXSAT tokens minted and assigned to the user.
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
     * @notice Unwrap wstXSAT tokens back into stXSAT tokens.
     * @dev Calculates the corresponding stXSAT amount using stXSAT.getPooledXSATByShares,
     * burns the user's wstXSAT tokens, and transfers the stXSAT tokens back to the user.
     * @param _wstXSATAmount The amount of wstXSAT tokens to unwrap.
     * @return stXSATAmount The amount of stXSAT tokens returned to the user.
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
     * @notice Returns the equivalent wstXSAT amount for a given stXSAT amount.
     * @param _stXSATAmount The stXSAT amount.
     * @return The corresponding wstXSAT amount.
     */
    function getWstXSATByStXSAT(uint256 _stXSATAmount) external view returns (uint256) {
        return stXSAT.getSharesByPooledXSAT(_stXSATAmount);
    }

    /**
     * @notice Returns the equivalent stXSAT amount for a given wstXSAT amount.
     * @param _wstXSATAmount The wstXSAT amount.
     * @return The corresponding stXSAT amount.
     */
    function getStXSATByWstXSAT(uint256 _wstXSATAmount) external view returns (uint256) {
        return stXSAT.getPooledXSATByShares(_wstXSATAmount);
    }

    /**
     * @notice Returns the amount of stXSAT equivalent to 1 wstXSAT token (using 1 ether as the unit).
     * @return The stXSAT amount corresponding to 1 wstXSAT.
     */
    function stXSATPerToken() external view returns (uint256) {
        return stXSAT.getPooledXSATByShares(1 ether);
    }

    /**
     * @notice Returns the amount of wstXSAT equivalent to 1 stXSAT token (using 1 ether as the unit).
     * @return The wstXSAT amount corresponding to 1 stXSAT.
     */
    function tokensPerStXSAT() external view returns (uint256) {
        return stXSAT.getSharesByPooledXSAT(1 ether);
    }
}
