// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IBSCValidatorCredit} from "../interfaces/IBSCValidatorCredit.sol";
import {IImuaCapsule} from "../interfaces/IImuaCapsule.sol";
import {INativeRestakingController} from "../interfaces/INativeRestakingController.sol";
import {IStakeHub} from "../interfaces/IStakeHub.sol";
import {BeaconChainProofs} from "../libraries/BeaconChainProofs.sol";
import {Errors} from "../libraries/Errors.sol";
import {ValidatorContainer} from "../libraries/ValidatorContainer.sol";
import {ImuaCapsuleStorageBSC} from "../storage/ImuaCapsuleStorageBSC.sol";

import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/// @title ImuaCapsuleBSC
/// @notice Capsule that holds delegators' BNB and delegates on their behalf, enabling BNB-native restaking.
/// @dev Implements IImuaCapsule for compatibility with the existing gateway flow:
/// - `withdrawPrincipal(VIRTUAL_NST_ADDRESS, ...)` calls `withdraw`
/// - `claimNSTFromImuachain` uses `startClaimNST/endClaimNST`
/// - Imuachain response unlocks via `unlockETHPrincipal` (name kept for compatibility; it unlocks BNB here)
contract ImuaCapsuleBSC is ReentrancyGuardUpgradeable, ImuaCapsuleStorageBSC, IImuaCapsule {

    /// @notice Emitted when stake hub is set.
    event StakeHubSet(address stakeHub);

    /// @notice Emitted when BNB is delegated.
    event Delegated(address indexed owner, address indexed validator, uint256 amount);

    /// @notice Emitted when BNB is undelegated.
    event Undelegated(address indexed owner, address indexed validator, uint256 amount);

    /// @notice Emitted when native principal is unlocked.
    event NativePrincipalUnlocked(address indexed owner, uint256 amount);

    /// @notice Emitted when a withdrawal is completed.
    event WithdrawalSuccess(address indexed owner, address indexed recipient, uint256 amount);

    /// @dev Match `ImuaCapsule.InvalidCaller(address,address)` signature for consistency across capsules.
    error InvalidCaller(address gateway, address caller);

    modifier onlyGateway() {
        _onlyGateway();
        _;
    }

    function _onlyGateway() internal view {
        if (msg.sender != address(gateway)) {
            revert InvalidCaller(address(gateway), msg.sender);
        }
    }

    /// @dev Accept native token transfers (BNB).
    receive() external payable {}

    /// @inheritdoc IImuaCapsule
    function initialize(
        address gateway_,
        address payable capsuleOwner_,
        address /*beaconOracle*/
    )
        external
        initializer
    {
        require(gateway_ != address(0), "ImuaCapsuleBSC: gateway is zero");
        require(capsuleOwner_ != address(0), "ImuaCapsuleBSC: owner is zero");
        gateway = INativeRestakingController(gateway_);
        capsuleOwner = capsuleOwner_;
        __ReentrancyGuard_init_unchained();
    }

    /// @notice Sets the stake hub contract address.
    /// @dev Called by the capsule owner (delegator). This is expected to be a one-time setup per network.
    function setStakeHub(address stakeHub_) external {
        require(msg.sender == capsuleOwner, "ImuaCapsuleBSC: only owner");
        require(stakeHub_ != address(0), "ImuaCapsuleBSC: stakeHub is zero");
        stakeHub = stakeHub_;
        emit StakeHubSet(stakeHub_);
    }

    /// @notice Sets validator + credit contract for this capsule (one-time).
    /// @dev Called by the gateway during the first BNBNST deposit. Enforces one capsule -> one validator model.
    function _setValidatorOnce(address validator_, address credit_) internal {
        if (validator != address(0)) {
            // already set; must match
            if (validator != validator_ || validatorCreditContract != credit_) {
                revert Errors.NativeRestakingControllerUnsupportedNativeDeposit();
            }
            return;
        }
        if (validator_ == address(0) || credit_ == address(0)) {
            revert Errors.ImuaCapsuleBSCInvalidValidatorId();
        }
        validator = validator_;
        validatorCreditContract = credit_;
    }

    /// @notice Deposit and delegate native BNB to a validator in one call.
    /// @dev Intended to be called by the gateway as part of BNBNST deposit.
    /// The delegator address on BSC will be THIS capsule (so oracle queries use capsule address).
    function depositAndDelegate(address validator_) external payable onlyGateway nonReentrant {
        if (stakeHub == address(0)) {
            revert Errors.ImuaCapsuleBSCStakeHubNotSet();
        }
        if (msg.value == 0) {
            revert Errors.ZeroValue();
        }
        if (validator_ == address(0)) {
            revert Errors.ImuaCapsuleBSCInvalidValidatorId();
        }

        // credit contract is derived from the BSC system contract StakeHub
        address credit = IStakeHub(stakeHub).getValidatorCreditContract(validator_);
        _setValidatorOnce(validator_, credit);

        // default: do not delegate vote power
        IStakeHub(stakeHub).delegate{value: msg.value}(validator_, false);
        emit Delegated(capsuleOwner, validator_, msg.value);
    }

    /// @notice Undelegate BNB from a validator (best-effort; depends on stakeHub semantics).
    function undelegate(address validator_, uint256 amount) external onlyGateway nonReentrant {
        if (stakeHub == address(0)) {
            revert Errors.ImuaCapsuleBSCStakeHubNotSet();
        }
        IStakeHub(stakeHub).undelegate(validator_, amount);
        emit Undelegated(capsuleOwner, validator_, amount);
    }

    /// @notice Returns (pooledBNB, lockedBNB) for this capsule.
    /// @dev Convenience view for price-feeder/oracle queries:
    /// the feeder only needs to query the capsule once.
    /// Returns (0,0) if the capsule is not yet bound to a credit contract.
    function getPooledAndLockedBNBs() public view returns (uint256 pooledBNB, uint256 lockedBNB) {
        address creditContract = validatorCreditContract;
        if (creditContract == address(0) && stakeHub != address(0) && validator != address(0)) {
            // best-effort derivation for read-only queries
            creditContract = IStakeHub(stakeHub).getValidatorCreditContract(validator);
        }

        if (creditContract == address(0)) {
            return (0, 0);
        }

        pooledBNB = IBSCValidatorCredit(creditContract).getPooledBNB(address(this));
        lockedBNB = IBSCValidatorCredit(creditContract).lockedBNBs(address(this), 0);
    }

    /// @inheritdoc IImuaCapsule
    function verifyDepositProof(bytes32[] calldata, BeaconChainProofs.ValidatorContainerProof calldata)
        external
        pure
        returns (uint256)
    {
        revert Errors.NotYetSupported();
    }

    /// @inheritdoc IImuaCapsule
    // forge-lint: disable-next-line(mixed-case-function)
    function startClaimNST(uint256 amount) external onlyGateway {
        if (inClaimProgress) {
            revert Errors.ClaimAlreadyInProgress();
        }
        if (amount == 0) {
            revert Errors.ZeroValue();
        }
        address credit = validatorCreditContract;
        if (credit == address(0)) {
            revert Errors.ImuaCapsuleBSCInvalidValidatorId();
        }

        // Step 1) local pre-check: claim must be satisfied by currently claimable locked BNBs on BSC.
        // The credit contract exposes claimable request COUNT, not direct claimable amount,
        // so we must combine: lockedBNBs(capsule, N) where N is #claimable requests.
        uint256 maxClaimableRequests = IBSCValidatorCredit(credit).claimableUnbondRequest(address(this));
        if (maxClaimableRequests == 0) {
            revert Errors.ImuaCapsuleBSCInsufficientClaimable();
        }

        // Find smallest N such that lockedBNBs(this, N) >= amount.
        uint256 lo = 1;
        uint256 hi = maxClaimableRequests;
        uint256 ans = 0;
        while (lo <= hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 sumMid = IBSCValidatorCredit(credit).lockedBNBs(address(this), mid);
            if (sumMid >= amount) {
                ans = mid;
                if (mid == 0) {
                    break;
                }
                hi = mid - 1;
            } else {
                lo = mid + 1;
            }
        }
        if (ans == 0) {
            revert Errors.ImuaCapsuleBSCInsufficientClaimable();
        }

        uint256 exact = IBSCValidatorCredit(credit).lockedBNBs(address(this), ans);
        if (exact != amount) {
            revert Errors.ImuaCapsuleBSCClaimAmountNotAligned();
        }

        if (block.timestamp < lastClaimTimestamp + MIN_CLAIM_INTERVAL) {
            revert Errors.TooEarlySinceLastClaim();
        }

        // Step 2) mark flag + freeze oracle updates for this capsule.
        inClaimProgress = true;
        pendingClaimAmount = amount;
        pendingClaimRequestCount = ans;
    }

    /// @inheritdoc IImuaCapsule
    function endClaimNST() external onlyGateway {
        inClaimProgress = false;
    }

    /// @notice Finalizes a claim after receiving Imuachain response.
    /// @dev Success flow:
    /// - call StakeHub.claim(validator, pendingClaimRequestCount) to move BNB into capsule
    /// - increase withdrawableBalance
    /// - clear claim-in-progress flags so oracle sync resumes safely
    /// Failure flow:
    /// - clear claim-in-progress flags only
    function finalizeClaimNST(uint256 amount, bool success) external onlyGateway nonReentrant {
        if (!inClaimProgress) {
            revert Errors.ImuaCapsuleBSCNoClaimInProgress();
        }
        // Imuachain may slash between request and response, resulting in a smaller approved amount.
        // In that case, BSC claim will still transfer the full `pendingClaimAmount` into this capsule,
        // but we only credit `withdrawableBalance` by the approved `amount`.
        if (amount == 0 || amount > pendingClaimAmount) {
            revert Errors.ImuaCapsuleBSCClaimAmountNotAligned();
        }

        // Snapshot + clear claim flags BEFORE the external call (CEI) to satisfy Slither.
        uint256 requestCount = pendingClaimRequestCount;
        inClaimProgress = false;
        pendingClaimAmount = 0;
        pendingClaimRequestCount = 0;

        if (success) {
            if (stakeHub == address(0)) {
                revert Errors.ImuaCapsuleBSCStakeHubNotSet();
            }
            if (validator == address(0)) {
                revert Errors.ImuaCapsuleBSCInvalidValidatorId();
            }
            // Step 4) execute BSC claim, BNB will be transferred to THIS capsule.
            IStakeHub(stakeHub).claim(validator, requestCount);
            // Now those BNBs are withdrawable.
            withdrawableBalance += amount;
            lastClaimTimestamp = block.timestamp;
        }
    }

    /// @inheritdoc IImuaCapsule
    function withdraw(uint256 amount, address payable recipient) external onlyGateway nonReentrant {
        require(recipient != address(0), "ImuaCapsuleBSC: recipient is zero");
        require(amount > 0 && amount <= withdrawableBalance, "ImuaCapsuleBSC: invalid amount");
        // funds must be present on the capsule
        require(address(this).balance >= amount, "ImuaCapsuleBSC: insufficient balance");
        withdrawableBalance -= amount;
        (bool sent,) = recipient.call{value: amount}("");
        require(sent, "ImuaCapsuleBSC: send failed");
        emit WithdrawalSuccess(capsuleOwner, recipient, amount);
    }

    /// @inheritdoc IImuaCapsule
    function unlockETHPrincipal(uint256 amount) external onlyGateway {
        withdrawableBalance += amount;
        lastClaimTimestamp = block.timestamp;
        emit NativePrincipalUnlocked(capsuleOwner, amount);
    }

    /// @inheritdoc IImuaCapsule
    function capsuleWithdrawalCredentials() external pure returns (bytes memory) {
        // Not applicable for BNB NST.
        return bytes("");
    }

    /// @inheritdoc IImuaCapsule
    function isInClaimProgress() external view returns (bool) {
        return inClaimProgress;
    }

    /// @inheritdoc IImuaCapsule
    function isPectraMode() external pure returns (bool) {
        return false;
    }

    /// @inheritdoc IImuaCapsule
    function requestPartialWithdrawal(bytes calldata, uint64) external payable onlyGateway {
        revert Errors.NotYetSupported();
    }

    /// @inheritdoc IImuaCapsule
    function requestFullWithdrawal(bytes calldata) external payable onlyGateway {
        revert Errors.NotYetSupported();
    }

    /// @inheritdoc IImuaCapsule
    function getCurrentWithdrawalFee() external pure returns (uint256) {
        // Not applicable for BNB NST.
        return 0;
    }

    /// @inheritdoc IImuaCapsule
    function getPubkeyHash(bytes calldata pubkey) external pure returns (bytes32) {
        return ValidatorContainer.computePubkeyHash(pubkey);
    }

}
