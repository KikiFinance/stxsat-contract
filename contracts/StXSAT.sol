// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./IXSATStakingRouter.sol";
import "./BaseStXSAT.sol";

contract StXSAT is BaseStXSAT, ReentrancyGuardUpgradeable, UUPSUpgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20;

    // -------------------------------
    // Constants and Roles
    // -------------------------------
    uint256 private constant PRECISION_POINTS = 1e5;

    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant RESUME_ROLE = keccak256("RESUME_ROLE");
    bytes32 public constant STAKING_PAUSE_ROLE = keccak256("STAKING_PAUSE_ROLE");
    bytes32 public constant STAKING_CONTROL_ROLE = keccak256("STAKING_CONTROL_ROLE");

    // -------------------------------
    // State Variables
    // -------------------------------
    uint256 public maxStakeLimit;       // Maximum stake limit for pool operations
    bool private _pausedStaking;        // Internal flag to pause staking (xsat deposits)

    // Addresses for external contracts
    address public stakingRouter;       // Address of the staking router contract
    address public xsatToken;           // Address of the XSAT ERC20 token

    // Internal accounting variables
    uint256 private _depositBuffer;      // XSAT tokens temporarily held on the contract from user deposits
    uint256 private _withdrawalReserve;  // XSAT tokens reserved for user withdrawals

    // Mapping to track withdrawal requests per user
    mapping(address => WithdrawalRequest[]) public userWithdrawals;

    // -------------------------------
    // Events
    // -------------------------------
    event StakingPaused();
    event StakingResumed();
    event StakingLimitSet(uint256 maxStakeLimit);
    event DepositedValidatorsChanged(uint256 depositedValidators);

    event TokenRebased(
        uint256 preTotalShares,
        uint256 preTotalXSAT,
        uint256 postTotalShares,
        uint256 postTotalXSAT,
        uint256 sharesMintedAsFees
    );

    event TokenDepositSynced(address router, uint256 amount);
    event TokenWithdrawSynced(address router, uint256 amount);
    event RewardsReceived(uint256 amount);
    event WithdrawalsReceived(uint256 amount);
    event Submitted(address indexed sender, uint256 amount);
    event Unbuffered(uint256 amount);
    event WithdrawRequested(address indexed user, uint256 amount, uint256 timestamp);
    event Withdraw(address indexed user, uint256 amount);
    event RewardDistributed(uint256 amount);

    // -------------------------------
    // Structs
    // -------------------------------
    /// @notice Structure representing a user's withdrawal request.
    struct WithdrawalRequest {
        uint256 amount;         // Amount of XSAT requested for withdrawal
        uint256 unlockTimestamp; // Timestamp after which the withdrawal can be claimed
    }

    // -------------------------------
    // Modifiers
    // -------------------------------
    modifier onlyAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Only Admin can perform this action");
        _;
    }

    modifier onlyStakingPauser() {
        require(hasRole(STAKING_PAUSE_ROLE, msg.sender), "Only staking pauser can perform this action");
        _;
    }

    modifier onlyPauser() {
        require(hasRole(PAUSE_ROLE, msg.sender), "Only pauser can perform this action");
        _;
    }

    modifier onlyResumer() {
        require(hasRole(RESUME_ROLE, msg.sender), "Only resumer can perform this action");
        _;
    }

    modifier onlyStakingController() {
        require(hasRole(STAKING_CONTROL_ROLE, msg.sender), "Only staking controller can perform this action");
        _;
    }

    // -------------------------------
    // Initialization & Upgrade Authorization
    // -------------------------------
    /**
     * @notice Initializes the StXSAT contract.
     * @param _xsatAddress Address of the XSAT ERC20 token.
     * @param _stakeRouterAddress Address of the staking router contract.
     */
    function initialize(address _xsatAddress, address _stakeRouterAddress) public initializer {
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(STAKING_CONTROL_ROLE, msg.sender);
        xsatToken = _xsatAddress;
        stakingRouter = _stakeRouterAddress;
    }

    /**
     * @notice Authorizes upgrades. Only the admin can upgrade.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyAdmin {}

    /**
     * @notice Bootstraps the initial holder.
     * @dev If the protocol is empty (i.e. no shares exist), this function uses the contract's current XSAT balance
     *      to mint initial shares for the designated initial token holder.
     *      This function should only be called once during the initial setup.
     */
    function bootstrapInitial() public onlyAdmin {
        _bootstrapInitialHolder();
    }

    // -------------------------------
    // Staking Pause/Resume and Pool Operations
    // -------------------------------
    /// @notice Pauses staking (stops accepting XSAT deposits) for the pool.
    function pauseStaking() public onlyStakingPauser {
        _pauseStaking();
    }

    /// @notice Resumes staking operations for the pool.
    function resumeStaking() public onlyStakingController {
        _resumeStaking();
    }

    /**
     * @notice Stops pool routine operations by pausing both the protocol and staking.
     */
    function stop() external onlyPauser {
        _pause();
        _pauseStaking();
    }

    /**
     * @notice Resumes pool routine operations.
     */
    function resume() external onlyResumer {
        _unpause();
        _resumeStaking();
    }

    /**
     * @notice Sets the maximum staking limit for the pool.
     * @param _maxStakeLimit The new maximum staking limit.
     */
    function setStakingLimit(uint256 _maxStakeLimit) public onlyStakingController {
        maxStakeLimit = _maxStakeLimit;
        emit StakingLimitSet(_maxStakeLimit);
    }

    /**
     * @notice Returns whether staking is paused.
     */
    function isStakingPaused() public view returns (bool) {
        return _pausedStaking;
    }

    // -------------------------------
    // User Actions: Deposit and Withdrawal
    // -------------------------------
    /**
     * @notice Allows a user to deposit XSAT tokens into the pool.
     * @param _amount The amount of XSAT tokens to deposit.
     * @return The number of stXSAT shares minted.
     */
    function submit(uint256 _amount) external whenNotPaused nonReentrant returns (uint256) {
        return _submit(_amount);
    }

    /**
     * @notice Allows a user to request a withdrawal of XSAT tokens.
     * The corresponding stXSAT tokens are burned and a withdrawal request is created.
     * @param _amount The amount of XSAT tokens to withdraw.
     */
    function requestWithdraw(uint256 _amount) external nonReentrant whenNotPaused {
        uint256 userBalance = this.balanceOf(msg.sender);
        require(_amount > 0, "Amount must be greater than zero");
        require(userBalance >= _amount, "Insufficient stXSAT balance");

        // Burn the stXSAT tokens corresponding to the requested withdrawal
        uint256 sharesAmount = getSharesByPooledXSAT(_amount);
        _burnShares(msg.sender, sharesAmount);

        // Create withdrawal request with an unlock timestamp based on the staking router's lock time
        uint256 unlockTimestamp = block.timestamp + _stakingRouter().lockTime();
        userWithdrawals[msg.sender].push(WithdrawalRequest({
            amount: _amount,
            unlockTimestamp: unlockTimestamp
        }));

        _decreasePool(_amount);
        _emitTransferAfterBurnShares(msg.sender, sharesAmount);

        emit WithdrawRequested(msg.sender, _amount, unlockTimestamp);
    }

    /**
     * @notice Processes unlocked withdrawal requests for the caller.
     * @return totalAmount The total amount of XSAT available for withdrawal.
     */
    function _processWithdrawals() internal returns (uint256 totalAmount) {
        totalAmount = 0;
        uint256 index = 0;

        // Process each withdrawal request if its unlock time has passed
        while (index < userWithdrawals[msg.sender].length) {
            WithdrawalRequest storage request = userWithdrawals[msg.sender][index];
            if (request.unlockTimestamp <= block.timestamp) {
                totalAmount += request.amount;
                // Remove the processed request using swap-and-pop
                userWithdrawals[msg.sender][index] = userWithdrawals[msg.sender][userWithdrawals[msg.sender].length - 1];
                userWithdrawals[msg.sender].pop();
            } else {
                index++;
            }
        }

        require(totalAmount > 0, "No unlocked withdrawal requests available");
    }

    /**
     * @notice Allows a user to claim their withdrawn XSAT tokens.
     */
    function claimWithdraw() external nonReentrant whenNotPaused {
        uint256 totalAmount = _processWithdrawals();
        // Transfer the claimed XSAT tokens to the user
        _xsatToken().safeTransfer(msg.sender, totalAmount);
        emit Withdraw(msg.sender, totalAmount);
    }

    /**
     * @notice Returns all withdrawal requests for a specific user.
     * @param user The address of the user.
     */
    function getUserWithdrawals(address user) external view returns (WithdrawalRequest[] memory) {
        return userWithdrawals[user];
    }

    /**
     * @notice Returns the amount of XSAT currently buffered on this contract.
     */
    function getDepositBuffer() external view returns (uint256) {
        return _depositBuffer;
    }

    function getWithdrawalReserve() external view returns (uint256) {
        return _withdrawalReserve;
    }

    /**
     * @notice Returns the current fee from the staking router.
     */
    function getFee() public view returns (uint256 totalFee) {
        totalFee = _stakingRouter().fee();
    }

    // -------------------------------
    // Reward Distribution Functions
    // -------------------------------

    /**
     * @notice Collects the rewards after a claim has been initiated.
     * @dev Transfers XSAT rewards from the staking router to this contract,
     *      calculates the reward amount, and emits a RewardDistributed event.
     */
    function collectRewards() external nonReentrant whenNotPaused {
        uint256 stakedSupply = this.totalSupply();
        require(stakedSupply > 0, "No staked XSAT available for rewards");

        IERC20 token = _xsatToken();
        uint256 balanceBefore = token.balanceOf(address(this));

        IXSATStakingRouter router = _stakingRouter();
        router.collectRewards();

        uint256 balanceAfter = token.balanceOf(address(this));
        require(balanceAfter >= balanceBefore, "Reward collection failed: insufficient XSAT received");

        uint256 rewardAmount = balanceAfter - balanceBefore;
        uint256 feeShare = _completeTokenRebase(rewardAmount);
        _increasePool(rewardAmount);
        _emitTransferAfterMintingShares(_stakingRouter().feeCollector(), feeShare);

        emit RewardDistributed(rewardAmount);
    }

    /**
     * @notice Synchronizes the contract's XSAT funds with its internal buffers.
     * @dev - For deposits, it converts the deposit buffer into whole deposit units (each equal to validatorCapacity).
     *      If there are sufficient intentionally deposited funds, the corresponding token amount is transferred
     *      to the staking router and a deposit is triggered.
     *      - For withdrawals, if the contract's XSAT balance is less than the reserved withdrawal amount,
     *      it calculates the deficit in whole withdrawal units and triggers a withdrawal.
     *      Both actions emit events for logging.
     */
    function syncBuffers() external nonReentrant whenNotPaused {
        IERC20 xsat = _xsatToken();
        IXSATStakingRouter router = _stakingRouter();
        uint256 validatorCapacity = router.validatorCapacity();

        // Process the deposit buffer: use only intentionally deposited funds.
        if (_depositBuffer > 0) {
            // Calculate whole deposit units available.
            uint256 depositUnits = _depositBuffer / validatorCapacity;
            require(depositUnits > 0, "Deposit buffer insufficient for one unit deposit");
            // Determine the actual token amount to deposit.
            uint256 amountToDeposit = depositUnits * validatorCapacity;
            _decreasePool(amountToDeposit);
            // Transfer the deposit funds to the staking router.
            xsat.safeApprove(stakingRouter, amountToDeposit);
            // Trigger a deposit on the staking router.
            router.deposit(amountToDeposit);
            emit TokenDepositSynced(stakingRouter, amountToDeposit);
        }

        // Ensure that the contract holds enough XSAT to cover the reserved withdrawals.
        uint256 currentBalance = xsat.balanceOf(address(this));
        if (currentBalance < _withdrawalReserve) {
            uint256 deficit = _withdrawalReserve - currentBalance;
            // Calculate the number of whole withdrawal units required.
            uint256 withdrawalUnits = deficit / validatorCapacity;
            if (deficit % validatorCapacity > 0){
                withdrawalUnits += 1;
            }
            require(withdrawalUnits > 0, "Deficit too small for one unit withdrawal");
            uint256 amountToWithdraw = withdrawalUnits * validatorCapacity;
            // Request withdrawal from the staking router.
            router.requestWithdraw(amountToWithdraw);
            _increasePool(amountToWithdraw);
            emit TokenWithdrawSynced(stakingRouter, amountToWithdraw);
        }
    }

    // -------------------------------
    // Internal Deposit and Fee Distribution Functions
    // -------------------------------
    /**
     * @notice Internal function to process a user's deposit.
     * @param _amount The amount of XSAT to deposit.
     * @return The number of stXSAT shares minted.
     */
    function _submit(uint256 _amount) internal returns (uint256) {
        require(!isStakingPaused(), "STAKING_PAUSED");

        // Transfer XSAT from user to this contract
        uint256 beforeBalance = _xsatToken().balanceOf(address(this));
        _xsatToken().safeTransferFrom(msg.sender, address(this), _amount);
        uint256 afterBalance = _xsatToken().balanceOf(address(this));
        uint256 received = afterBalance - beforeBalance;
        require(received == _amount, "DEFEE_TRANSFER_NOT_SUPPORTED");

        uint256 currentStakeLimit = _getCurrentStakeLimit();
        require(_amount <= currentStakeLimit, "STAKE_LIMIT");

        uint256 sharesAmount = getSharesByPooledXSAT(_amount);
        _mintShares(msg.sender, sharesAmount);

        _increasePool(_amount);
        emit Submitted(msg.sender, _amount);
        _emitTransferAfterMintingShares(msg.sender, sharesAmount);

        return sharesAmount;
    }

    /**
     * @notice Internal function to calculate and distribute fees based on rewards.
     * @param _preTotalPooledXSAT The total pooled XSAT before rewards.
     * @param _preTotalShares The total shares before rewards.
     * @param _totalRewards The amount of new rewards.
     * @return sharesMintedAsFees The number of fee shares minted.
     */
    function _distributeFee(
        uint256 _preTotalPooledXSAT,
        uint256 _preTotalShares,
        uint256 _totalRewards
    ) internal returns (uint256 sharesMintedAsFees) {
        IXSATStakingRouter router = _stakingRouter();
        uint256 totalFee = getFee();

        if (totalFee > 0) {
            uint256 totalPooledXSATWithRewards = _preTotalPooledXSAT + _totalRewards;
            sharesMintedAsFees = (_totalRewards * totalFee * _preTotalShares) /
                ((totalPooledXSATWithRewards * PRECISION_POINTS) - (_totalRewards * totalFee));

            _mintShares(router.feeCollector(), sharesMintedAsFees);
        }
        return sharesMintedAsFees;
    }

    /**
     * @notice Updates the XSAT deposit buffer amount.
     */
    function _setDepositBuffered(uint256 _newBuffered) internal {
        _depositBuffer = _newBuffered;
    }

    /**
    * @notice Updates the XSAT withdraw reserve amount.
     */
    function _setWithdrawReserve(uint256 _newReserve) internal {
        _withdrawalReserve = _newReserve;
    }

    /**
     * @notice Increases the pool's effective deposit by adding XSAT funds.
     * @dev This function adjusts the internal accounting as follows:
     *      - If the withdrawal reserve is greater than the increase amount, it reduces the withdrawal reserve by that amount.
     *      - Otherwise, it consumes the entire withdrawal reserve and adds the remaining amount (i.e. _amount minus the current withdrawal reserve)
     *        to the deposit buffer.
     *      This mechanism ensures that any redeemed funds (tracked in the withdrawal reserve) are used first
     *      before new funds are added to the deposit buffer.
     * @param _amount The amount of XSAT tokens to increase the pool by.
     */
    function _increasePool(uint256 _amount) internal {
        if (_withdrawalReserve > _amount) {
            _setWithdrawReserve(_withdrawalReserve - _amount);
        } else {
            _setDepositBuffered(_depositBuffer + _amount - _withdrawalReserve);
            _setWithdrawReserve(0);
        }
    }

    /**
     * @notice Decreases the pool by removing XSAT funds.
     * @dev If the deposit buffer is sufficient, the given amount is deducted from it.
     *      Otherwise, the deposit buffer is cleared and the remaining amount is added to the withdrawal reserve.
     *      This mechanism ensures that the internal accounting (depositBuffer and withdrawalReserve)
     *      remains balanced with respect to funds intended for staking versus funds reserved for withdrawals.
     * @param _amount The amount of XSAT tokens to remove from the pool.
     */
    function _decreasePool(uint256 _amount) internal {
        if (_depositBuffer >= _amount) {
            _setDepositBuffered(_depositBuffer - _amount);
        } else {
            uint256 remaining = _amount - _depositBuffer;
            _setDepositBuffered(0);
            _setWithdrawReserve(_withdrawalReserve + remaining);
        }
    }

    /**
     * @notice Returns the total pooled XSAT by summing the buffered XSAT and the staking balance.
     */
    function _getTotalPooledXSAT() internal view override returns (uint256) {
        return _depositBuffer + _stakingRouter().getStakingBalance() - _withdrawalReserve;
    }

    // -------------------------------
    // Internal Staking Pause/Resume Helpers
    // -------------------------------
    /**
     * @notice Pauses staking operations.
     */
    function _pauseStaking() internal {
        _pausedStaking = true;
        emit StakingPaused();
    }

    /**
     * @notice Resumes staking operations.
     */
    function _resumeStaking() internal {
        _pausedStaking = false;
        emit StakingResumed();
    }

    /**
     * @notice Returns the current available stake limit.
     */
    function _getCurrentStakeLimit() internal view returns (uint256) {
        if (_pausedStaking) {
            return 0;
        }
        if (maxStakeLimit == type(uint256).max) {
            return type(uint256).max;
        }
        return maxStakeLimit - _stakingRouter().getStakingBalance() - _depositBuffer;
    }

    // -------------------------------
    // Token Rebase Function
    // -------------------------------
    /**
     * @notice Completes the token rebase process by distributing rewards to stXSAT holders
     * and deducting fees for the fee collector. Adjusts total shares to maintain a 1:1 exchange.
     * @param _reward The XSAT reward amount (the difference between post- and pre-reward balances).
     * @return feeShares Fee share.
     */
    function _completeTokenRebase(uint256 _reward) internal returns (uint256 feeShares)
    {
        require(_reward > 0, "No reward to distribute");

        // Capture pre-rebase totals.
        uint256 preTotalShares = _getTotalShares();
        uint256 preTotalPooledXSAT = _getTotalPooledXSAT();
        require(preTotalPooledXSAT > 0, "Total pooled XSAT must be > 0");

        // Distribute fee and retrieve the fee shares minted.
        feeShares = _distributeFee(preTotalPooledXSAT, preTotalShares, _reward);

        // Calculate new pooled XSAT.
        uint256 postTotalPooledXSAT = preTotalPooledXSAT + _reward;

        // Calculate shares corresponding to the reward.
        uint256 rewardShares = getSharesByPooledXSAT(_reward);

        // Update total shares: add reward shares and subtract fee shares.
        uint256 postTotalShares = preTotalShares + feeShares;

        emit TokenRebased(
            preTotalShares,
            preTotalPooledXSAT,
            postTotalShares,
            postTotalPooledXSAT,
            feeShares
        );
    }

    // -------------------------------
    // Helper Functions for External Contracts
    // -------------------------------
    /**
     * @notice Returns the staking router interface.
     */
    function _stakingRouter() internal view returns (IXSATStakingRouter) {
        return IXSATStakingRouter(stakingRouter);
    }

    /**
     * @notice Returns the XSAT token interface.
     */
    function _xsatToken() internal view returns (IERC20) {
        return IERC20(xsatToken);
    }

    /**
     * @notice Bootstraps the initial holder if no shares exist.
     * Uses the contract's XSAT balance to mint initial shares.
     */
    function _bootstrapInitialHolder() internal {
        uint256 balance = _xsatToken().balanceOf(address(this));
        assert(balance != 0);

        if (_getTotalShares() == 0) {
            _setDepositBuffered(balance);
            emit Submitted(INITIAL_TOKEN_HOLDER, balance);
            _mintInitialShares(balance);
        }
    }

    // -------------------------------
    // Storage Gap for Upgradeability
    // -------------------------------
    uint256[50] private __gap;
}
