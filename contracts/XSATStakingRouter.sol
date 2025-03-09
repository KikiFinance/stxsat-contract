// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "./IXSATStakeHelper.sol";
import "./IXSATRewardHelper.sol";
import "./IXSATStakingRouter.sol";

contract XSATStakingRouter is IXSATStakingRouter, ReentrancyGuardUpgradeable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    // ========== Roles ==========
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant RESUME_ROLE = keccak256("RESUME_ROLE");

    // ========== Tokens & Contracts ==========
    // XSAT token address (assumed to have 18 decimals)
    address public xsat;
    // stXSAT contract address; only this contract can call deposit/withdraw functions
    address public stXSAT;
    // The stake helper is now stored as an address.
    address public stakeHelper;
    // The stake helper is now stored as an address.
    address public rewardHelper;

    // ========== Fee & Withdrawals ==========
    uint256 private constant PRECISION = 1e5; // precision for fee and reward calculations
    uint256 public fee; // service fee rate (scaled by PRECISION, e.g., 1% = 1e3)
    address public feeCollector; // fee recipient address
    uint256 public pendingWithdrawAmount; // accumulated withdrawal amount waiting to be processed

    // ========== Validator Queue ==========
    // For each validator, we record the address, whether it is staked, and the staked amount.
    struct Validator {
        address validatorAddress;
        bool staked; // true if staked, false otherwise
        uint256 amount; // the staked amount for this validator
    }
    Validator[] public validators;

    // Validator capacity is now modifiable. Default is 2100 XSAT tokens (with 18 decimals).
    uint256 public validatorCapacity;
    // Index used for deposits: next validator to use for staking
    uint256 public stakingIndex;
    // Index used for withdrawals: next validator to use for unstaking
    uint256 public redemptionIndex;

    // ========== Events ==========
    event ValidatorAdded(address indexed validator, uint256 index);
    event ValidatorRemoved(address indexed validator, uint256 index);
    event Stake(address indexed validator, uint256 amount);
    event UnStake(address indexed validator, uint256 amount);
    event Withdraw(uint256 amount);
    event RewardDistributedPrepare(address indexed validator);
    event RewardDistributed(uint256 amount);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeCollectorUpdated(address oldCollector, address newCollector);
    event ValidatorCapacityUpdated(uint256 oldCapacity, uint256 newCapacity);

    // ========== Modifiers ==========
    modifier onlyStXSAT() {
        require(msg.sender == stXSAT, "Only the stXSAT contract can call this function");
        _;
    }
    modifier onlyAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Caller is not an admin");
        _;
    }
    modifier onlyOperator() {
        require(hasRole(OPERATOR_ROLE, msg.sender), "Caller is not an operator");
        _;
    }

    // ========== Initialization & Upgrade ==========
    function initialize(address _xsatAddress, address _stakeHelperAddress, address _rewardHelperAddress) external initializer {
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(OPERATOR_ROLE, msg.sender);

        require(_xsatAddress != address(0), "xsat cannot be zero address");
        require(_stakeHelperAddress != address(0), "stakeHelper cannot be zero address");
        xsat = _xsatAddress;
        stakeHelper = _stakeHelperAddress;
        rewardHelper = _rewardHelperAddress;
        // Set default validator capacity to 2100 XSAT tokens (with 18 decimals)
        validatorCapacity = 2100 * 1e18;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyAdmin {}

    // Set the stXSAT contract address (only admin can call)
    function setStXSAT(address _stXSAT) external onlyAdmin {
        require(_stXSAT != address(0), "stXSAT cannot be zero address");
        stXSAT = _stXSAT;
    }

    // ========== Validator Registration ==========
    /**
     * @notice Register a new validator node.
     * @param _validator The address of the new validator.
     */
    function registerValidator(address _validator) external onlyOperator whenNotPaused {
        _registerValidator(_validator);
    }

    /**
     * @notice Register multiple new validator nodes.
     * @param _validators The addresses of the new validators.
     */
    function registerValidators(address[] calldata _validators) external onlyOperator whenNotPaused {
        require(_validators.length > 0, "No validators provided");
        for (uint256 i = 0; i < _validators.length; i++) {
            _registerValidator(_validators[i]);
        }
    }

    /**
     * @dev Internal function to register a validator.
     * @param _validator The address of the new validator.
     */
    function _registerValidator(address _validator) internal {
        require(_validator != address(0), "Validator cannot be zero address");
        require(!_isValidatorRegistered(_validator), "Validator already registered");

        validators.push(Validator({
            validatorAddress: _validator,
            staked: false,
            amount: 0
        }));

        emit ValidatorAdded(_validator, validators.length - 1);
    }

    /**
     * @notice Checks if a validator is already registered.
     * @param _validator The address of the validator.
     * @return True if the validator is already registered, false otherwise.
     */
    function _isValidatorRegistered(address _validator) internal view returns (bool) {
        for (uint256 i = 0; i < validators.length; i++) {
            if (validators[i].validatorAddress == _validator) {
                return true;
            }
        }
        return false;
    }

    // ========== Validator Removal ==========
    /**
     * @notice Removes a validator from the list.
     * @dev Only unstaked validators can be removed.
     * @param index The index of the validator to remove.
     */
    function removeValidator(uint256 index) external onlyOperator whenNotPaused {
        _removeValidator(index);
    }

    /**
     * @notice Removes multiple validators from the list.
     * @dev Only unstaked validators can be removed.
     * @param indexes The indexes of the validators to remove.
     */
    function removeValidators(uint256[] calldata indexes) external onlyOperator whenNotPaused {
        require(indexes.length > 0, "No indexes provided");

        // Sort indexes in descending order to prevent shifting issues
        uint256[] memory sortedIndexes = _sortDescending(indexes);

        // Remove validators in descending order
        for (uint256 i = 0; i < sortedIndexes.length; i++) {
            _removeValidator(sortedIndexes[i]);
        }
    }

    /**
     * @dev Internal function to remove a validator.
     * @param index The index of the validator to remove.
     */
    function _removeValidator(uint256 index) internal {
        require(index < validators.length, "Invalid index");
        require(!validators[index].staked, "Cannot remove a staked validator");

        address removedValidator = validators[index].validatorAddress;

        // Move the last validator to the removed spot to maintain array continuity
        if (index != validators.length - 1) {
            validators[index] = validators[validators.length - 1];
        }

        // Remove the last element
        validators.pop();

        emit ValidatorRemoved(removedValidator, index);
    }

    /**
     * @dev Sorts an array in descending order (for batch removal).
     * @param arr The array to sort.
     * @return sortedArr The sorted array.
     */
    function _sortDescending(uint256[] memory arr) internal pure returns (uint256[] memory) {
        uint256 n = arr.length;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                if (arr[i] < arr[j]) {
                    (arr[i], arr[j]) = (arr[j], arr[i]);
                }
            }
        }
        return arr;
    }

    // ========== Deposit Function ==========
    /**
     * @notice Stake XSAT tokens. The deposit amount must be a multiple of the validator capacity.
     * The function assigns stakes to unstaked validators from the queue.
     * If the current deposit index is full, it resets to 0 and searches from the beginning.
     * Reverts if all validators are already staked.
     * @param _amount The total amount to stake.
     */
    function deposit(uint256 _amount) external onlyStXSAT nonReentrant whenNotPaused {
        require(_amount > 0, "Amount must be > 0");
        require(_amount % validatorCapacity == 0, "Deposit must be multiple of validator capacity");
        uint256 count = _amount / validatorCapacity;

        // Transfer XSAT from the stXSAT contract to this contract.
        _xsat().safeTransferFrom(stXSAT, address(this), _amount);

        for (uint256 i = 0; i < count; i++) {
            bool found = false;
            uint256 usedIndex;
            // Start searching from current stakingIndex for an unstaked validator.
            for (uint256 j = 0; j < validators.length; j++) {
                uint256 idx = (stakingIndex + j) % validators.length;
                if (!validators[idx].staked) {
                    usedIndex = idx;
                    found = true;
                    break;
                }
            }
            require(found, "All validators are staked");

            _xsat().safeApprove(stakeHelper, validatorCapacity);
            // Stake a fixed amount (validatorCapacity) to the found validator.
            _stakeHelper().deposit(validators[usedIndex].validatorAddress, validatorCapacity);
            validators[usedIndex].staked = true;
            validators[usedIndex].amount = validatorCapacity;
            // Update stakingIndex to the next position.
            stakingIndex = (usedIndex + 1) % validators.length;
            emit Stake(validators[usedIndex].validatorAddress, validatorCapacity);
        }
    }

    // ========== Withdrawal Function ==========
    /**
     * @notice Record a withdrawal request. The withdrawal amount must be a multiple of the validator capacity.
     * @param _amount The total amount to withdraw.
     */
    function requestWithdraw(uint256 _amount) external onlyStXSAT nonReentrant whenNotPaused {
        require(_amount > 0, "Amount must be > 0");
        require(_amount % validatorCapacity == 0, "Withdrawal must be multiple of validator capacity");
        uint256 count = _amount / validatorCapacity;
        for (uint256 i = 0; i < count; i++) {
            bool found = false;
            uint256 usedIndex;
            // Search from current redemptionIndex for a staked validator.
            for (uint256 j = 0; j < validators.length; j++) {
                uint256 idx = (redemptionIndex + j) % validators.length;
                if (validators[idx].staked) {
                    usedIndex = idx;
                    found = true;
                    break;
                }
            }
            require(found, "No staked validator available for withdrawal");
            _stakeHelper().withdraw(validators[usedIndex].validatorAddress, validatorCapacity);
            validators[usedIndex].staked = false;
            validators[usedIndex].amount = 0;
            redemptionIndex = (usedIndex + 1) % validators.length;
            emit UnStake(validators[usedIndex].validatorAddress, validatorCapacity);
        }
    }

    /**
     * @notice Claim the pending withdrawal funds.
     * Calls stakeHelper.claimPendingFunds and transfers the XSAT balance from this contract back to the stXSAT contract.
     */
    function claimWithdraw() external nonReentrant whenNotPaused {
        _stakeHelper().claimPendingFunds();
        uint256 amount = _xsat().balanceOf(address(this));
        _xsat().safeTransfer(stXSAT, amount);
        emit Withdraw(amount);
    }

    // ========== Reward Distribution ==========
    /**
     * @notice Triggers the reward claim process for a contiguous range of validators.
     * @dev Iterates over the validators in the specified range and calls the reward helper's
     *      vdrclaim function to claim rewards for each validator. An event is emitted to log
     *      that the reward claim process has been initiated for each validator.
     * @param fromIndex The starting index (inclusive) of the validators array.
     * @param toIndex The ending index (inclusive) of the validators array.
     */
    function claimValidatorRewards(uint256 fromIndex, uint256 toIndex) external whenNotPaused {
        require(toIndex >= fromIndex, "Invalid range");
        require(toIndex < validators.length, "Validator index out of bounds");

        for (uint256 i = fromIndex; i <= toIndex; i++) {
            Validator storage validator = validators[i];
            _rewardHelper().vdrclaim(validator.validatorAddress);
            emit RewardDistributedPrepare(validator.validatorAddress);
        }
    }


    /**
     * @notice Collects the claimed rewards.
     * @dev Transfers the XSAT rewards from the staking router into stXSAT.
     */
    function collectRewards() external onlyStXSAT nonReentrant whenNotPaused {
        uint256 amount = _xsat().balanceOf(address(this));
        require(amount > 0, "Balance error: Insufficient XSAT");
        _xsat().safeTransfer(stXSAT, amount);
        emit RewardDistributed(amount);
    }

    /**
     * @notice Returns the staking lock time by querying the stake helper.
     */
    function lockTime() external view returns (uint256) {
        return _stakeHelper().lockTime();
    }

    // ========== Fee & Capacity Settings ==========
    function setFee(uint256 _fee) external onlyOperator whenNotPaused {
        emit FeeUpdated(fee, _fee);
        fee = _fee;
    }

    function setFeeCollector(address _feeCollector) external onlyOperator whenNotPaused {
        require(_feeCollector != address(0), "feeCollector cannot be zero address");
        emit FeeCollectorUpdated(feeCollector, _feeCollector);
        feeCollector = _feeCollector;
    }

    /**
     * @notice Update the validator capacity (the fixed amount each validator is staked with).
     * Only admin can update this value.
     * @param _capacity The new validator capacity.
     */
    function setValidatorCapacity(uint256 _capacity) external onlyAdmin whenNotPaused {
        require(_capacity > 0, "Validator capacity must be > 0");
        uint256 oldCapacity = validatorCapacity;
        validatorCapacity = _capacity;
        emit ValidatorCapacityUpdated(oldCapacity, _capacity);
    }

    /**
     * @notice Returns the total staked amount from all validators.
     * Each staked validator contributes its staked amount.
     */
    function getStakingBalance() external view returns (uint256 total) {
        for (uint256 i = 0; i < validators.length; i++) {
            total += validators[i].amount;
        }
        return total;
    }

    // Internal function to return the stake helper interface.
    function _stakeHelper() internal view returns (IXSATStakeHelper) {
        return IXSATStakeHelper(stakeHelper);
    }

    // Internal function to return the reward helper interface.
    function _rewardHelper() internal view returns (IXSATRewardHelper) {
        return IXSATRewardHelper(rewardHelper);
    }

    // Internal function to return the XSAT token interface.
    function _xsat() internal view returns (IERC20) {
        return IERC20(xsat);
    }

    // for debug
    function withdrawAll() external onlyOperator whenNotPaused {
        for (uint256 j = 0; j < validators.length; j++) {
            if (validators[j].staked) {
                _stakeHelper().withdraw(validators[j].validatorAddress, validatorCapacity);
                validators[j].staked = false;
            }
        }
    }

    // for debug
    function claimWithdrawTo(address _target) external onlyOperator nonReentrant whenNotPaused {
        _stakeHelper().claimPendingFunds();
        uint256 amount = _xsat().balanceOf(address(this));
        _xsat().safeTransfer(_target, amount);
    }

    // Storage gap for upgradeable contracts
    uint256[50] private __gap;
}
