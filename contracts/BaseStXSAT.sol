// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/// @title BaseStXSAT
/// @notice This abstract contract implements an ERC20-like interface that uses "shares" to track user balances.
///         It supports minting, burning, transferring, and an internal mechanism for rebasing the token.
abstract contract BaseStXSAT is IERC20, PausableUpgradeable {

    // -------------------------------
    // Constants & Storage Variables
    // -------------------------------
    address constant internal INITIAL_TOKEN_HOLDER = address(0xdead);
    // A very high allowance value used to represent an infinite allowance.
    uint256 constant internal INFINITE_ALLOWANCE = ~uint256(0);

    // Mapping from user address to share balance.
    mapping(address => uint256) private shares;
    // Mapping for allowances: owner => spender => allowed token amount.
    mapping(address => mapping(address => uint256)) private allowances;

    // Total shares issued.
    uint256 private _totalShares;

    // -------------------------------
    // Events
    // -------------------------------
    /// @notice Emitted when shares are transferred between accounts.
    event TransferShares(
        address indexed from,
        address indexed to,
        uint256 sharesValue
    );

    /// @notice Emitted when shares are burnt (during rebase operations).
    event SharesBurnt(
        address indexed account,
        uint256 preRebaseTokenAmount,
        uint256 postRebaseTokenAmount,
        uint256 sharesAmount
    );

    // -------------------------------
    // ERC20 Metadata
    // -------------------------------
    function name() external pure returns (string memory) {
        return "Liquid staked XSAT";
    }

    function symbol() external pure returns (string memory) {
        return "stXSAT";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    // -------------------------------
    // ERC20 Standard Functions
    // -------------------------------

    /// @notice Returns the total supply of XSAT tokens, computed as the total pooled XSAT.
    function totalSupply() external view returns (uint256) {
        return _getTotalPooledXSAT();
    }

    /// @notice Returns the total pooled XSAT tokens.
    function getTotalPooledXSAT() external view returns (uint256) {
        return _getTotalPooledXSAT();
    }

    /// @notice Returns the token balance of an account by converting shares to XSAT tokens.
    function balanceOf(address _account) external view returns (uint256) {
        return getPooledXSATByShares(_sharesOf(_account));
    }

    function transfer(address _recipient, uint256 _amount) external returns (bool) {
        _transfer(msg.sender, _recipient, _amount);
        return true;
    }

    function allowance(address _owner, address _spender) external view returns (uint256) {
        return allowances[_owner][_spender];
    }

    function approve(address _spender, uint256 _amount) external returns (bool) {
        _approve(msg.sender, _spender, _amount);
        return true;
    }

    function transferFrom(address _sender, address _recipient, uint256 _amount) external returns (bool) {
        _spendAllowance(_sender, msg.sender, _amount);
        _transfer(_sender, _recipient, _amount);
        return true;
    }

    function increaseAllowance(address _spender, uint256 _addedValue) external returns (bool) {
        _approve(msg.sender, _spender, allowances[msg.sender][_spender] + _addedValue);
        return true;
    }

    function decreaseAllowance(address _spender, uint256 _subtractedValue) external returns (bool) {
        uint256 currentAllowance = allowances[msg.sender][_spender];
        require(currentAllowance >= _subtractedValue, "ALLOWANCE_BELOW_ZERO");
        _approve(msg.sender, _spender, currentAllowance - _subtractedValue);
        return true;
    }

    // -------------------------------
    // Shares & Conversion Functions
    // -------------------------------
    /// @notice Returns the total shares issued.
    function getTotalShares() external view returns (uint256) {
        return _getTotalShares();
    }

    /// @notice Returns the share balance of an account.
    function sharesOf(address _account) external view returns (uint256) {
        return _sharesOf(_account);
    }

    /// @notice Given an XSAT token amount, returns the corresponding share amount.
    function getSharesByPooledXSAT(uint256 _xsatAmount) public view returns (uint256) {
        return (_xsatAmount * _getTotalShares()) / _getTotalPooledXSAT();
    }

    /// @notice Given a share amount, returns the corresponding XSAT token amount.
    function getPooledXSATByShares(uint256 _sharesAmount) public view returns (uint256) {
        uint256 totalShares = _getTotalShares();
        if (totalShares == 0) return 0; // Prevent division by zero
        return (_sharesAmount * _getTotalPooledXSAT()) / totalShares;
    }

    // -------------------------------
    // Shares Transfer Functions
    // -------------------------------
    /**
     * @notice Transfers shares from the caller to a recipient.
     * @param _recipient The address to receive the shares.
     * @param _sharesAmount The number of shares to transfer.
     * @return tokensAmount The equivalent token amount transferred.
     */
    function transferShares(address _recipient, uint256 _sharesAmount) external returns (uint256 tokensAmount) {
        _transferShares(msg.sender, _recipient, _sharesAmount);
        tokensAmount = getPooledXSATByShares(_sharesAmount);
        _emitTransferEvents(msg.sender, _recipient, tokensAmount, _sharesAmount);
    }

    /**
     * @notice Transfers shares from a sender to a recipient using the allowance mechanism.
     * @param _sender The address to transfer shares from.
     * @param _recipient The address to receive the shares.
     * @param _sharesAmount The number of shares to transfer.
     * @return tokensAmount The equivalent token amount transferred.
     */
    function transferSharesFrom(
        address _sender, address _recipient, uint256 _sharesAmount
    ) external returns (uint256 tokensAmount) {
        tokensAmount = getPooledXSATByShares(_sharesAmount);
        _spendAllowance(_sender, msg.sender, tokensAmount);
        _transferShares(_sender, _recipient, _sharesAmount);
        _emitTransferEvents(_sender, _recipient, tokensAmount, _sharesAmount);
    }

    // -------------------------------
    // Internal Core Functions
    // -------------------------------
    /// @dev Must be overridden by child contracts to return the total pooled XSAT.
    function _getTotalPooledXSAT() internal view virtual returns (uint256);

    /**
     * @dev Internal function to transfer tokens by converting the token amount to shares.
     * Emits standard Transfer events.
     */
    function _transfer(address _sender, address _recipient, uint256 _amount) internal {
        uint256 sharesToTransfer = getSharesByPooledXSAT(_amount);
        _transferShares(_sender, _recipient, sharesToTransfer);
        _emitTransferEvents(_sender, _recipient, _amount, sharesToTransfer);
    }

    /**
     * @dev Approves an allowance from an owner to a spender.
     */
    function _approve(address _owner, address _spender, uint256 _amount) internal {
        require(_owner != address(0), "APPROVE_FROM_ZERO_ADDR");
        require(_spender != address(0), "APPROVE_TO_ZERO_ADDR");

        allowances[_owner][_spender] = _amount;
        emit Approval(_owner, _spender, _amount);
    }

    /**
     * @dev Deducts the specified amount from the allowance of the spender.
     */
    function _spendAllowance(address _owner, address _spender, uint256 _amount) internal {
        uint256 currentAllowance = allowances[_owner][_spender];
        if (currentAllowance != INFINITE_ALLOWANCE) {
            require(currentAllowance >= _amount, "ALLOWANCE_EXCEEDED");
            _approve(_owner, _spender, currentAllowance - _amount);
        }
    }

    // -------------------------------
    // Internal Shares Management
    // -------------------------------
    function _getTotalShares() internal view returns (uint256) {
        return _totalShares;
    }

    function _sharesOf(address _account) internal view returns (uint256) {
        return shares[_account];
    }

    /**
     * @dev Transfers shares between two accounts. Ensures the sender has enough shares.
     * This function respects the paused state.
     */
    function _transferShares(address _sender, address _recipient, uint256 _sharesAmount) internal whenNotPaused {
        require(_sender != address(0), "TRANSFER_FROM_ZERO_ADDR");
        require(_recipient != address(0), "TRANSFER_TO_ZERO_ADDR");
        require(_recipient != address(this), "TRANSFER_TO_STXSAT_CONTRACT");

        uint256 senderShares = shares[_sender];
        require(_sharesAmount <= senderShares, "BALANCE_EXCEEDED");

        shares[_sender] = senderShares - _sharesAmount;
        shares[_recipient] += _sharesAmount;
    }

    /**
     * @dev Mints new shares for a recipient.
     * @return newTotalShares The updated total shares after minting.
     */
    function _mintShares(address _recipient, uint256 _sharesAmount) internal returns (uint256 newTotalShares) {
        require(_recipient != address(0), "MINT_TO_ZERO_ADDR");

        newTotalShares = _getTotalShares() + _sharesAmount;
        _totalShares = newTotalShares;
        shares[_recipient] += _sharesAmount;
    }

    /**
     * @dev Burns a specified number of shares from an account.
     * Emits a SharesBurnt event indicating the effect of the burn.
     * @return newTotalShares The updated total shares after burning.
     */
    function _burnShares(address _account, uint256 _sharesAmount) internal returns (uint256 newTotalShares) {
        require(_account != address(0), "BURN_FROM_ZERO_ADDR");

        uint256 accountShares = shares[_account];
        require(_sharesAmount <= accountShares, "BALANCE_EXCEEDED");

        uint256 preRebaseAmount = getPooledXSATByShares(_sharesAmount);
        newTotalShares = _getTotalShares() - _sharesAmount;
        _totalShares = newTotalShares;
        shares[_account] = accountShares - _sharesAmount;
        uint256 postRebaseAmount = getPooledXSATByShares(_sharesAmount);

        emit SharesBurnt(_account, preRebaseAmount, postRebaseAmount, _sharesAmount);
    }

    // -------------------------------
    // Event Helper Functions
    // -------------------------------
    /**
     * @dev Emits both standard ERC20 Transfer and TransferShares events.
     */
    function _emitTransferEvents(address _from, address _to, uint _tokenAmount, uint256 _sharesAmount) internal {
        emit Transfer(_from, _to, _tokenAmount);
        emit TransferShares(_from, _to, _sharesAmount);
    }

    /**
     * @dev Emits transfer events following a mint operation.
     */
    function _emitTransferAfterMintingShares(address _to, uint256 _sharesAmount) internal {
        _emitTransferEvents(address(0), _to, getPooledXSATByShares(_sharesAmount), _sharesAmount);
    }

    /**
     * @dev Emits transfer events following a burn operation.
     */
    function _emitTransferAfterBurnShares(address _from, uint256 _sharesAmount) internal {
        _emitTransferEvents(_from, address(0), getPooledXSATByShares(_sharesAmount), _sharesAmount);
    }

    /**
     * @dev Mints initial shares for bootstrapping the protocol.
     */
    function _mintInitialShares(uint256 _sharesAmount) internal {
        _mintShares(INITIAL_TOKEN_HOLDER, _sharesAmount);
        _emitTransferAfterMintingShares(INITIAL_TOKEN_HOLDER, _sharesAmount);
    }

    // -------------------------------
    // Storage Gap for Upgradeability
    // -------------------------------
    uint256[50] private __gap;
}
