// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
// Do not use IERC20 because it does not expose the decimals() function.
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {OAppCoreUpgradeable} from "../lzApp/OAppCoreUpgradeable.sol";

// This import is used for @inheritdoc but slither does not recognize it.
// slither-disable-next-line unused-import
import {IBaseRestakingController} from "../interfaces/IBaseRestakingController.sol";
import {ICustomProxyAdmin} from "../interfaces/ICustomProxyAdmin.sol";
import {ILSTRestakingController} from "../interfaces/ILSTRestakingController.sol";
import {INativeRestakingController} from "../interfaces/INativeRestakingController.sol";
import {IValidatorRegistry} from "../interfaces/IValidatorRegistry.sol";

import {IImuaCapsule} from "../interfaces/IImuaCapsule.sol";
import {ITokenWhitelister} from "../interfaces/ITokenWhitelister.sol";
import {IVault} from "../interfaces/IVault.sol";

import {BeaconChainProofs} from "../libraries/BeaconChainProofs.sol";
import {Errors} from "../libraries/Errors.sol";
import {ValidatorContainer} from "../libraries/ValidatorContainer.sol";

import {BootstrapStorage} from "../storage/BootstrapStorage.sol";
import {Action} from "../storage/GatewayStorage.sol";

import {BootstrapLzReceiver} from "./BootstrapLzReceiver.sol";

/// @title Bootstrap
/// @author imua-xyz
/// @notice This contract is used to Bootstrap Imuachain. It accepts validator registration, deposits and delegations.
contract Bootstrap is
    Initializable,
    PausableUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    ITokenWhitelister,
    ILSTRestakingController,
    IValidatorRegistry,
    INativeRestakingController,
    BootstrapLzReceiver
{

    using ValidatorContainer for bytes32[];

    /// @notice Constructor for the Bootstrap contract.
    /// @param endpoint_ is the address of the layerzero endpoint on Imuachain
    /// @param config is the struct containing the values for immutable state variables
    constructor(address endpoint_, ImmutableConfig memory config)
        OAppCoreUpgradeable(endpoint_)
        BootstrapStorage(config)
    {
        _disableInitializers();
    }

    /// @notice Initializes the Bootstrap contract.
    /// @param owner The address of the contract owner.
    /// @param spawnTime_ The spawn time of Imuachain.
    /// @param offsetDuration_ The offset duration before the spawn time.
    /// @param whitelistTokens_ The list of whitelisted tokens.
    /// @param tvlLimits_ The list of TVL limits for the tokens, in the same order as the whitelist.
    /// @param customProxyAdmin_ The address of the custom proxy admin.
    function initialize(
        address owner,
        uint256 spawnTime_,
        uint256 offsetDuration_,
        address[] calldata whitelistTokens_,
        uint256[] calldata tvlLimits_,
        address customProxyAdmin_,
        address clientChainGatewayLogic_,
        bytes calldata clientChainInitializationData_
    ) external initializer {
        if (owner == address(0)) {
            revert Errors.ZeroAddress();
        }

        _validateSpawnTimeAndOffsetDuration(spawnTime_, offsetDuration_);
        spawnTime = spawnTime_;
        offsetDuration = offsetDuration_;

        if (customProxyAdmin_ == address(0)) {
            revert Errors.ZeroAddress();
        }

        _addWhitelistTokens(whitelistTokens_, tvlLimits_);

        _whiteListFunctionSelectors[Action.REQUEST_MARK_BOOTSTRAP] = this.markBootstrapped.selector;

        customProxyAdmin = customProxyAdmin_;
        bootstrapped = false;
        _setClientChainGatewayLogic(clientChainGatewayLogic_, clientChainInitializationData_);

        // msg.sender is not the proxy admin but the transparent proxy itself, and hence,
        // cannot be used here. we must require a separate owner. since Imuachain validator
        // set can not sign without the chain, the owner is likely to be an EOA or a
        // contract controlled by one.
        _transferOwnership(owner);
        __OAppCore_init_unchained(owner);
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();
    }

    /// @notice Checks if the contract is locked, meaning it has passed the offset duration
    /// before Imuachain's spawn time.
    /// @dev Returns true if the contract is locked, false otherwise.
    /// @return bool Returns `true` if the contract is locked, `false` otherwise.
    function isLocked() public view returns (bool) {
        return block.timestamp >= spawnTime - offsetDuration;
    }

    /// @dev Modifier to restrict operations based on the contract's defined timeline, that is,
    /// during the offset duration before Imuachain's spawn time.
    modifier beforeLocked() {
        if (isLocked()) {
            revert Errors.BootstrapBeforeLocked();
        }
        _;
    }

    /// @notice Pauses the contract.
    /// @dev Pausing is not gated by the beforeLocked modifier.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract.
    /// @dev Unpausing is not gated by the beforeLocked modifier.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Allows the contract owner to modify the spawn time of Imuachain.
    /// @dev This function can only be called by the contract owner and must
    /// be called before the currently set lock time has started.
    /// @param spawnTime_ The new spawn time in seconds.
    function setSpawnTime(uint256 spawnTime_) external onlyOwner beforeLocked {
        _validateSpawnTimeAndOffsetDuration(spawnTime_, offsetDuration);
        // technically the spawn time can be moved backwards in time as well.
        spawnTime = spawnTime_;
        emit SpawnTimeUpdated(spawnTime);
    }

    /// @notice Allows the contract owner to modify the offset duration that determines
    /// the lock period before Imuachain's spawn time.
    /// @dev This function can only be called by the contract owner and must be called
    /// before the currently set lock time has started.
    /// @param offsetDuration_ The new offset duration in seconds.
    function setOffsetDuration(uint256 offsetDuration_) external onlyOwner beforeLocked {
        _validateSpawnTimeAndOffsetDuration(spawnTime, offsetDuration_);
        offsetDuration = offsetDuration_;
        emit OffsetDurationUpdated(offsetDuration);
    }

    /// @dev Validates the spawn time and offset duration.
    ///      The spawn time must be in the future and greater than the offset duration.
    ///      The difference of the two must be greater than the current time.
    /// @param spawnTime_ The spawn time of Imuachain to validate.
    /// @param offsetDuration_ The offset duration before the spawn time to validate.
    function _validateSpawnTimeAndOffsetDuration(uint256 spawnTime_, uint256 offsetDuration_) internal view {
        if (offsetDuration_ == 0) {
            revert Errors.ZeroValue();
        }
        // spawnTime_ == 0 is included in the below check, since the timestamp
        // is always greater than 0. the spawn time must not be equal to the
        // present time either, although, when marking as bootstrapped, we do
        // allow that case intentionally.
        if (block.timestamp > spawnTime_) {
            revert Errors.BootstrapSpawnTimeAlreadyPast();
        }
        // guard against underflow of lockTime calculation
        if (offsetDuration_ > spawnTime_) {
            revert Errors.BootstrapSpawnTimeLessThanDuration();
        }
        uint256 lockTime = spawnTime_ - offsetDuration_;
        if (block.timestamp >= lockTime) {
            revert Errors.BootstrapLockTimeAlreadyPast();
        }
    }

    /// @inheritdoc ITokenWhitelister
    function addWhitelistTokens(address[] calldata tokens, uint256[] calldata tvlLimits)
        external
        beforeLocked
        onlyOwner
        whenNotPaused
    {
        _addWhitelistTokens(tokens, tvlLimits);
    }

    /// @dev The internal function to add tokens to the whitelist.
    /// @param tokens The list of token addresses to be added to the whitelist.
    /// @param tvlLimits The list of TVL limits for the corresponding tokens.
    // Though `_deployVault` would make external call to newly created `Vault` contract and initialize it,
    // `Vault` contract belongs to Imuachain and we could make sure its implementation does not have dangerous behavior
    // like reentrancy.
    // slither-disable-next-line reentrancy-no-eth
    function _addWhitelistTokens(address[] calldata tokens, uint256[] calldata tvlLimits) internal {
        if (tokens.length != tvlLimits.length) {
            revert Errors.ArrayLengthMismatch();
        }
        for (uint256 i = 0; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 tvlLimit = tvlLimits[i];
            if (token == address(0)) {
                revert Errors.ZeroAddress();
            }
            if (isWhitelistedToken[token]) {
                revert Errors.BootstrapAlreadyWhitelisted(token);
            }
            whitelistTokens.push(token);
            isWhitelistedToken[token] = true;

            // tokens cannot be removed from the whitelist. hence, if the token is not in the
            // whitelist, it means that it is missing a vault. we do not need to check for a
            // pre-existing vault. however, we still do ensure that the vault is not deployed
            // for restaking natively staked ETH.
            if (token != VIRTUAL_NST_ADDRESS) {
                // setting a tvlLimit higher than the supply is permitted.
                // it allows for some margin for minting of the token, and lets us use
                // a value of type(uint256).max to indicate no limit.
                _deployVault(token, tvlLimit);
            }

            emit WhitelistTokenAdded(token);
        }
    }

    /// @inheritdoc ITokenWhitelister
    function getWhitelistedTokensCount() external view returns (uint256) {
        return _getWhitelistedTokensCount();
    }

    /// @inheritdoc ITokenWhitelister
    function updateTvlLimit(address token, uint256 tvlLimit) external beforeLocked onlyOwner whenNotPaused {
        if (!isWhitelistedToken[token]) {
            revert Errors.TokenNotWhitelisted(token);
        }
        if (token == VIRTUAL_NST_ADDRESS) {
            revert Errors.NoTvlLimitForNativeRestaking();
        }
        IVault vault = _getVault(token);
        vault.setTvlLimit(tvlLimit);
    }

    /// @inheritdoc IValidatorRegistry
    function registerValidator(
        string calldata validatorAddress,
        string calldata name,
        Commission memory commission,
        bytes32 consensusPublicKey
    ) external beforeLocked whenNotPaused isValidBech32Address(validatorAddress) {
        // ensure that there is only one validator per ethereum address
        if (bytes(ethToImAddress[msg.sender]).length > 0) {
            revert Errors.BootstrapValidatorAlreadyHasAddress(msg.sender);
        }
        // check if validator with the same Imuachain address already exists
        if (bytes(validators[validatorAddress].name).length > 0) {
            revert Errors.BootstrapValidatorAlreadyRegistered();
        }
        _validateConsensusKey(consensusPublicKey);
        // and that the name (meta info) is non-empty and unique.
        if (bytes(name).length == 0) {
            revert Errors.BootstrapValidatorNameLengthZero();
        }
        if (validatorNameInUse[name]) {
            revert Errors.BootstrapValidatorNameAlreadyUsed();
        }
        // check that the commission is valid.
        if (!isCommissionValid(commission)) {
            revert Errors.BootstrapInvalidCommission();
        }
        ethToImAddress[msg.sender] = validatorAddress;
        validators[validatorAddress] =
            IValidatorRegistry.Validator({name: name, commission: commission, consensusPublicKey: consensusPublicKey});
        registeredValidators.push(msg.sender);
        consensusPublicKeyInUse[consensusPublicKey] = true;
        validatorNameInUse[name] = true;
        emit ValidatorRegistered(msg.sender, validatorAddress, name, commission, consensusPublicKey);
    }

    /// @notice Checks if the provided commission is valid.
    /// @dev The commission's rates must be <= 1e18 (100%) and the rate must be <= maxRate and maxChangeRate.
    /// @param commission The commission to check.
    /// @return bool Returns `true` if the commission is valid, `false` otherwise.
    // forgefmt: disable-next-item
    function isCommissionValid(Commission memory commission) public pure returns (bool) {
        return commission.rate <= 1e18 &&
               commission.maxRate <= 1e18 &&
               commission.maxChangeRate <= 1e18 &&
               commission.rate <= commission.maxRate &&
               commission.maxChangeRate <= commission.maxRate;
    }

    /// @inheritdoc IValidatorRegistry
    function replaceKey(bytes32 newKey) external beforeLocked whenNotPaused {
        if (bytes(ethToImAddress[msg.sender]).length == 0) {
            revert Errors.BootstrapValidatorNotExist();
        }
        _validateConsensusKey(newKey);
        bytes32 oldKey = validators[ethToImAddress[msg.sender]].consensusPublicKey;
        consensusPublicKeyInUse[oldKey] = false;
        consensusPublicKeyInUse[newKey] = true;
        validators[ethToImAddress[msg.sender]].consensusPublicKey = newKey;
        emit ValidatorKeyReplaced(ethToImAddress[msg.sender], newKey);
    }

    /// @inheritdoc IValidatorRegistry
    function updateRate(uint256 newRate) external beforeLocked whenNotPaused {
        string memory validatorAddress = ethToImAddress[msg.sender];
        if (bytes(validatorAddress).length == 0) {
            revert Errors.BootstrapValidatorNotExist();
        }
        // across the lifetime of this contract before network bootstrap,
        // allow the editing of commission only once.
        if (commissionEdited[validatorAddress]) {
            revert Errors.BootstrapComissionAlreadyEdited();
        }
        Commission memory commission = validators[validatorAddress].commission;
        uint256 rate = commission.rate;
        uint256 maxRate = commission.maxRate;
        uint256 maxChangeRate = commission.maxChangeRate;
        // newRate <= maxRate <= 1e18
        if (newRate > maxRate) {
            revert Errors.BootstrapRateExceedsMaxRate();
        }
        // to prevent validators from blindsiding users by first registering at low rate and
        // subsequently increasing it, we should also check that the change is within the
        // allowed rate change.
        if (newRate > rate + maxChangeRate) {
            revert Errors.BootstrapRateChangeExceedsMaxChangeRate();
        }
        validators[validatorAddress].commission.rate = newRate;
        commissionEdited[validatorAddress] = true;
        emit ValidatorCommissionUpdated(newRate);
    }

    /// @notice Validates a consensus key.
    /// @dev The validation checks include non-empty key and uniqueness.
    /// @param key The consensus key to validate.
    function _validateConsensusKey(bytes32 key) internal view {
        // check that the consensus key is not empty.
        if (key == bytes32(0)) {
            revert Errors.ZeroValue();
        }
        // check that the consensus key is unique.
        if (consensusPublicKeyInUse[key]) {
            revert Errors.BootstrapConsensusPubkeyAlreadyUsed(key);
        }
    }

    /// @inheritdoc ILSTRestakingController
    function deposit(address token, uint256 amount)
        external
        payable
        override
        beforeLocked
        whenNotPaused
        isTokenWhitelisted(token)
        isValidAmount(amount)
        nonReentrant // interacts with Vault
    {
        if (msg.value > 0) {
            revert Errors.NonZeroValue();
        }
        _deposit(msg.sender, token, amount);
    }

    /// @dev Internal version of deposit.
    /// @param depositor The address of the depositor.
    /// @param token The address of the token.
    /// @param amount The amount of the @param token to deposit.
    function _deposit(address depositor, address token, uint256 amount) internal {
        IVault vault = _getVault(token);
        vault.deposit(depositor, amount);

        if (!isDepositor[depositor]) {
            isDepositor[depositor] = true;
            depositors.push(depositor);
        }

        // staker_asset.go duplicate here. the duplication is required (and not simply inferred
        // from vault) because the vault is not altered by the gateway in response to
        // delegations or undelegations. hence, this is not something we can do either.
        totalDepositAmounts[depositor][token] += amount;
        withdrawableAmounts[depositor][token] += amount;
        depositsByToken[token] += amount;

        emit DepositResult(true, token, depositor, amount);
    }

    /// @inheritdoc ILSTRestakingController
    function claimPrincipalFromImuachain(address token, uint256 amount)
        external
        payable
        override
        beforeLocked
        whenNotPaused
        isTokenWhitelisted(token)
        isValidAmount(amount)
        nonReentrant // interacts with Vault
    {
        if (msg.value > 0) {
            revert Errors.NonZeroValue();
        }
        _claim(msg.sender, token, amount);
    }

    /// @dev Internal version of claim.
    /// @param user The address of the withdrawer.
    /// @param token The address of the token.
    /// @param amount The amount of the @param token to withdraw.
    function _claim(address user, address token, uint256 amount) internal {
        IVault vault = _getVault(token);

        uint256 deposited = totalDepositAmounts[user][token];
        if (deposited < amount) {
            revert Errors.BootstrapInsufficientDepositedBalance();
        }
        uint256 withdrawable = withdrawableAmounts[user][token];
        if (withdrawable < amount) {
            revert Errors.BootstrapInsufficientWithdrawableBalance();
        }

        // when the withdraw precompile is called, it does these things.
        totalDepositAmounts[user][token] -= amount;
        withdrawableAmounts[user][token] -= amount;
        depositsByToken[token] -= amount;

        // afterReceiveWithdrawPrincipalResponse
        vault.unlockPrincipal(user, amount);

        emit ClaimPrincipalResult(true, token, user, amount);
    }

    /// @inheritdoc IBaseRestakingController
    /// @dev This is not yet supported.
    function submitReward(address, address, uint256) external payable beforeLocked whenNotPaused {
        revert Errors.NotYetSupported();
    }

    /// @inheritdoc IBaseRestakingController
    /// @dev This is not yet supported.
    function claimRewardFromImuachain(address, uint256) external payable beforeLocked whenNotPaused {
        revert Errors.NotYetSupported();
    }

    /// @inheritdoc IBaseRestakingController
    /// @dev This is not yet supported.
    function withdrawReward(address, address, uint256) external view beforeLocked whenNotPaused {
        revert Errors.NotYetSupported();
    }

    /// @inheritdoc IBaseRestakingController
    function withdrawPrincipal(address token, uint256 amount, address recipient)
        external
        override
        beforeLocked
        whenNotPaused
        isTokenWhitelisted(token)
        isValidAmount(amount)
        nonReentrant // because it interacts with vault
    {
        if (recipient == address(0)) {
            revert Errors.ZeroAddress();
        }
        // getting a vault for native restaked token will fail so no need to check that.
        // if native restaking is supported in Bootstrap someday, that will change.
        IVault vault = _getVault(token);
        vault.withdraw(msg.sender, recipient, amount);
    }

    /// @inheritdoc IBaseRestakingController
    function delegateTo(string calldata validator, address token, uint256 amount)
        external
        payable
        beforeLocked
        whenNotPaused
        isTokenWhitelisted(token)
        isValidAmount(amount)
        isValidBech32Address(validator)
    // does not need a reentrancy guard
    {
        if (msg.value > 0) {
            revert Errors.NonZeroValue();
        }
        _delegateTo(msg.sender, validator, token, amount);
    }

    /// @dev The internal version of `delegateTo`.
    /// @param user The address of the delegator.
    /// @param validator The address of the validator.
    /// @param token The address of the token.
    /// @param amount The amount of the @param token to delegate.
    function _delegateTo(address user, string calldata validator, address token, uint256 amount) internal {
        if (msg.value > 0) {
            revert Errors.BootstrapNoEtherForDelegation();
        }
        // check that validator is registered
        if (bytes(validators[validator].name).length == 0) {
            revert Errors.BootstrapValidatorNotExist();
        }
        // validator can't be frozen and amount can't be negative
        // asset validity has been checked.
        // now check amounts.
        uint256 withdrawable = withdrawableAmounts[user][token];
        if (withdrawable < amount) {
            revert Errors.BootstrapInsufficientWithdrawableBalance();
        }

        if (delegations[user][validator][token] == 0) {
            // if this amount later becomes 0, it is ok. we don't worry about removing it.
            stakerToTokenToValidators[user][token].push(validator);
        }
        delegations[user][validator][token] += amount;
        delegationsByValidator[validator][token] += amount;
        withdrawableAmounts[user][token] -= amount;

        emit DelegateResult(true, user, validator, token, amount);
    }

    /// @inheritdoc IBaseRestakingController
    function undelegateFrom(string calldata validator, address token, uint256 amount)
        external
        payable
        beforeLocked
        whenNotPaused
        isTokenWhitelisted(token)
        isValidAmount(amount)
        isValidBech32Address(validator)
    // does not need a reentrancy guard
    {
        if (msg.value > 0) {
            revert Errors.NonZeroValue();
        }
        _undelegateFrom(msg.sender, validator, token, amount);
    }

    /// @dev The internal version of `undelegateFrom`.
    /// @param user The address of the delegator.
    /// @param validator The address of the validator.
    /// @param token The address of the token.
    /// @param amount The amount of the @param token to undelegate.
    function _undelegateFrom(address user, string calldata validator, address token, uint256 amount) internal {
        if (msg.value > 0) {
            revert Errors.BootstrapNoEtherForDelegation();
        }
        // check that validator is registered
        if (bytes(validators[validator].name).length == 0) {
            revert Errors.BootstrapValidatorNotExist();
        }
        // validator can't be frozen and amount can't be negative
        // asset validity has been checked.
        // now check amounts.
        uint256 delegated = delegations[user][validator][token];
        if (delegated < amount) {
            revert Errors.BootstrapInsufficientDelegatedBalance();
        }
        // the undelegation is released immediately since it is not at stake yet.
        delegations[user][validator][token] -= amount;
        delegationsByValidator[validator][token] -= amount;
        withdrawableAmounts[user][token] += amount;

        emit UndelegateResult(true, user, validator, token, amount);
    }

    /// @inheritdoc ILSTRestakingController
    // Though `_deposit` would make external call to `Vault` and some state variables would be written in the following
    // `_delegateTo`,
    // `Vault` contract belongs to Imuachain and we could make sure it's implementation does not have dangerous behavior
    // like reentrancy.
    // slither-disable-next-line reentrancy-no-eth
    function depositThenDelegateTo(address token, uint256 amount, string calldata validator)
        external
        payable
        override
        beforeLocked
        whenNotPaused
        isTokenWhitelisted(token)
        isValidAmount(amount)
        isValidBech32Address(validator)
        nonReentrant // because it interacts with vault in deposit
    {
        if (msg.value > 0) {
            revert Errors.NonZeroValue();
        }
        _deposit(msg.sender, token, amount);
        _delegateTo(msg.sender, validator, token, amount);
    }

    /// @notice Marks the contract as bootstrapped.
    /// @dev A contract can be marked as bootstrapped only when the current time is more than
    /// Imuachain's spawn time, since such a call must originate from Imuachain. To mark
    /// a contract as bootstrapped, the address of the client chain gateway logic contract and its
    /// initialization data must be set. The contract must not have been bootstrapped before.
    /// Once it is marked bootstrapped, the implementation of the contract is upgraded to the
    /// client chain gateway logic contract.
    /// @dev This call can never fail, since such failures are not handled by ImuachainGateway.
    function markBootstrapped() public onlyCalledFromThis whenNotPaused {
        // whenNotPaused is applied so that the upgrade does not proceed without unpausing it.
        // LZ checks made so far include:
        // lzReceive called by endpoint
        // correct address on remote (peer match)
        // chainId match
        // nonce match, which requires that inbound nonce is uint64(1).
        if (block.timestamp < spawnTime) {
            // technically never possible unless the block producer does some time-based shenanigans.
            emit BootstrapNotTimeYet();
            return;
        }
        // bootstrapped = true is only actioned by the clientchaingateway after upgrade
        // so no need to check for that here but better to be safe.
        if (bootstrapped) {
            emit BootstrappedAlready();
            return;
        }
        try ICustomProxyAdmin(customProxyAdmin).changeImplementation(
            // address(this) is storage address and not logic address. so it is a proxy.
            ITransparentUpgradeableProxy(address(this)),
            clientChainGatewayLogic,
            clientChainInitializationData
        ) {
            emit Bootstrapped();
        } catch {
            // to allow retries, never fail
            emit BootstrapUpgradeFailed();
        }
    }

    /// @notice Sets a new client chain gateway logic and its initialization data.
    /// @dev Allows the contract owner to update the address and initialization data for the
    /// client chain gateway logic. The change can only occur prior to bootstrapping.
    /// @param _clientChainGatewayLogic The address of the new client chain gateway logic
    /// contract.
    /// @param _clientChainInitializationData The initialization data to be used when setting up
    /// the new logic contract.
    function setClientChainGatewayLogic(address _clientChainGatewayLogic, bytes calldata _clientChainInitializationData)
        public
        onlyOwner
    {
        _setClientChainGatewayLogic(_clientChainGatewayLogic, _clientChainInitializationData);
    }

    /// @dev Internal version of `setClientChainGatewayLogic`.
    /// @param _clientChainGatewayLogic The address of the new client chain gateway logic
    /// contract.
    /// @param _clientChainInitializationData The initialization data to be used when setting up
    /// the new logic contract.
    function _setClientChainGatewayLogic(
        address _clientChainGatewayLogic,
        bytes calldata _clientChainInitializationData
    ) internal {
        if (_clientChainGatewayLogic == address(0)) {
            revert Errors.ZeroAddress();
        }
        // selector is 4 bytes long
        if (_clientChainInitializationData.length < 4) {
            revert Errors.BootstrapClientChainDataMalformed();
        }
        clientChainGatewayLogic = _clientChainGatewayLogic;
        clientChainInitializationData = _clientChainInitializationData;
        emit ClientChainGatewayLogicUpdated(_clientChainGatewayLogic, _clientChainInitializationData);
    }

    /// @dev Gets the count of registered validators.
    /// @return The number of registered validators.
    /// @notice This function returns the total number of registered validators in the contract.
    function getValidatorsCount() external view returns (uint256) {
        return registeredValidators.length;
    }

    /// @dev Gets the count of depositors.
    /// @return The number of depositors.
    /// @notice This function returns the total number of depositors in the contract.
    function getDepositorsCount() external view returns (uint256) {
        return depositors.length;
    }

    /// @notice Retrieves information for a supported token by its index in the storage array.
    /// @dev Returns comprehensive details about a token, including its ERC20 attributes and deposit amount.
    /// This function only exists in the Bootstrap contract and not in the ClientChainGateway, which
    /// does not track the deposits of whitelisted tokens.
    /// @param index The index of the token in the `supportedTokens` array.
    /// @return A `TokenInfo` struct containing the token's name, symbol, address, decimals, total supply, and deposit
    /// amount.
    function getWhitelistedTokenAtIndex(uint256 index) public view returns (TokenInfo memory) {
        if (index >= whitelistTokens.length) {
            revert Errors.IndexOutOfBounds();
        }
        address tokenAddress = whitelistTokens[index];
        if (tokenAddress == VIRTUAL_NST_ADDRESS) {
            return TokenInfo({
                name: "Native Staked ETH",
                symbol: "ETH",
                tokenAddress: tokenAddress,
                decimals: 18,
                depositAmount: depositsByToken[tokenAddress]
            });
        }
        ERC20 token = ERC20(tokenAddress);
        return TokenInfo({
            name: token.name(),
            symbol: token.symbol(),
            tokenAddress: tokenAddress,
            decimals: token.decimals(),
            depositAmount: depositsByToken[tokenAddress]
        });
    }

    /* -------------------------------------------------------------------------- */
    /*                     Ethereum Native Restaking Functions                    */
    /* -------------------------------------------------------------------------- */

    /// @notice Stakes 32 ETH on behalf of the validators in the Ethereum beacon chain, and
    /// points the withdrawal credentials to the capsule contract, creating it if necessary.
    /// @param pubkey The validator's BLS12-381 public key.
    /// @param signature Value signed by the @param pubkey.
    /// @param depositDataRoot The SHA-256 hash of the SSZ-encoded DepositData object.
    function stake(bytes calldata pubkey, bytes calldata signature, bytes32 depositDataRoot)
        external
        payable
        whenNotPaused
        nonReentrant
        nativeRestakingEnabled
    {
        if (msg.value != 32 ether) {
            revert Errors.NativeRestakingControllerInvalidStakeValue();
        }

        IImuaCapsule capsule = ownerToCapsule[msg.sender];
        if (address(capsule) == address(0)) {
            capsule = IImuaCapsule(createImuaCapsule());
        }

        ETH_POS.deposit{value: 32 ether}(pubkey, capsule.capsuleWithdrawalCredentials(), signature, depositDataRoot);
        emit StakedWithCapsule(msg.sender, address(capsule));
    }

    /// @notice Creates a new ImuaCapsule contract for the message sender.
    /// @notice The message sender must be payable
    /// @return The address of the newly created ImuaCapsule contract.
    // The bytecode returned by `BEACON_PROXY_BYTECODE` and `IMUA_CAPSULE_BEACON` address are actually fixed size of
    // byte
    // array, so it would not cause collision for encodePacked
    // slither-disable-next-line encode-packed-collision
    function createImuaCapsule() public whenNotPaused nativeRestakingEnabled returns (address) {
        if (address(ownerToCapsule[msg.sender]) != address(0)) {
            revert Errors.NativeRestakingControllerCapsuleAlreadyCreated();
        }
        IImuaCapsule capsule = IImuaCapsule(
            Create2.deploy(
                0,
                bytes32(uint256(uint160(msg.sender))),
                // set the beacon address for beacon proxy
                abi.encodePacked(BEACON_PROXY_BYTECODE.getBytecode(), abi.encode(address(IMUA_CAPSULE_BEACON), ""))
            )
        );

        // we follow check-effects-interactions pattern to write state before external call
        ownerToCapsule[msg.sender] = capsule;
        capsule.initialize(address(this), payable(msg.sender), BEACON_ORACLE_ADDRESS);

        emit CapsuleCreated(msg.sender, address(capsule));

        return address(capsule);
    }

    /**
     * @notice Verifies a deposit proof from the beacon chain and account for native stake for msg.sender.
     * @param validatorContainer The validator container which made the deposit.
     * @param proof The proof of the validator container.
     */
    function verifyAndDepositNativeStake(
        bytes32[] calldata validatorContainer,
        BeaconChainProofs.ValidatorContainerProof calldata proof
    ) external payable whenNotPaused nonReentrant nativeRestakingEnabled {
        if (msg.value > 0) {
            revert Errors.NonZeroValue();
        }

        IImuaCapsule capsule = _getCapsule(msg.sender);
        uint256 depositValue = capsule.verifyDepositProof(validatorContainer, proof);

        if (!isDepositor[msg.sender]) {
            isDepositor[msg.sender] = true;
            depositors.push(msg.sender);
        }

        // staker_asset.go duplicate here. the duplication is required (and not simply inferred
        // from vault) because the vault is not altered by the gateway in response to
        // delegations or undelegations. hence, this is not something we can do either.
        totalDepositAmounts[msg.sender][VIRTUAL_NST_ADDRESS] += depositValue;
        withdrawableAmounts[msg.sender][VIRTUAL_NST_ADDRESS] += depositValue;
        depositsByToken[VIRTUAL_NST_ADDRESS] += depositValue;
        stakerToPubkeyIDs[msg.sender].push(bytes32(proof.validatorIndex));

        emit DepositResult(true, VIRTUAL_NST_ADDRESS, msg.sender, depositValue);
    }

    /// @notice Verifies a withdrawal proof from the beacon chain and forwards the information to Imuachain.
    /// @notice This function is not yet supported, but staker could call this function after bootstrapping to withdraw
    /// their stake.
    function processBeaconChainWithdrawal(
        bytes32[] calldata,
        BeaconChainProofs.ValidatorContainerProof calldata,
        bytes32[] calldata,
        BeaconChainProofs.WithdrawalProof calldata
    ) external payable whenNotPaused nativeRestakingEnabled {
        revert Errors.NotYetSupported();
    }

    /// @notice Withdraws the nonBeaconChainETHBalance from the ImuaCapsule contract.
    /// @dev @param amountToWithdraw can not be greater than the available nonBeaconChainETHBalance.
    /// @param recipient The payable destination address to which the ETH are sent.
    /// @param amountToWithdraw The amount to withdraw.
    function withdrawNonBeaconChainETHFromCapsule(address payable recipient, uint256 amountToWithdraw)
        external
        whenNotPaused
        nonReentrant
        nativeRestakingEnabled
    {
        IImuaCapsule capsule = _getCapsule(msg.sender);
        capsule.withdrawNonBeaconChainETHBalance(recipient, amountToWithdraw);
    }

    /// @notice Returns the number of pubkeys (across all validators) deposited
    /// by a staker. The deposit must include deposit + verification for inclusion
    /// into the beacon chain.
    /// @param stakerAddress the address of the staker.
    /// @return uint256 The number of pubkeys deposited by the staker.
    function getPubkeysCount(address stakerAddress) external view returns (uint256) {
        return stakerToPubkeyIDs[stakerAddress].length;
    }

    /// @notice Returns the number of validators to whom a staker has delegated a token.
    /// @param stakerAddress The address of the staker.
    /// @param token The address of the token.
    /// @return uint256 The number of validators to whom the staker has delegated the token.
    function getValidatorsCountForStakerToken(address stakerAddress, address token) external view returns (uint256) {
        return stakerToTokenToValidators[stakerAddress][token].length;
    }

}
