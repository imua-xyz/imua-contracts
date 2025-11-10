// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IClientChainGateway} from "../interfaces/IClientChainGateway.sol";

import {IRewardVault} from "../interfaces/IRewardVault.sol";
import {ITokenWhitelister} from "../interfaces/ITokenWhitelister.sol";
import {IVault} from "../interfaces/IVault.sol";
import {OAppCoreUpgradeable} from "../lzApp/OAppCoreUpgradeable.sol";
import {OAppReceiverUpgradeable} from "../lzApp/OAppReceiverUpgradeable.sol";
import {MessagingFee, OAppSenderUpgradeable} from "../lzApp/OAppSenderUpgradeable.sol";

import {ClientChainGatewayStorage} from "../storage/ClientChainGatewayStorage.sol";
import {ClientGatewayLzReceiver} from "./ClientGatewayLzReceiver.sol";
import {LSTRestakingController} from "./LSTRestakingController.sol";
import {NativeRestakingController} from "./NativeRestakingController.sol";

import {Errors} from "../libraries/Errors.sol";
import {Action} from "../storage/GatewayStorage.sol";
import {IOAppCore} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppCore.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @title ClientChainGateway
/// @author imua-xyz
/// @notice The gateway contract deployed on client chains for Imuachain operations.
contract ClientChainGateway is
    Initializable,
    PausableUpgradeable,
    OwnableUpgradeable,
    IClientChainGateway,
    ITokenWhitelister,
    LSTRestakingController,
    NativeRestakingController,
    ClientGatewayLzReceiver
{

    using OptionsBuilder for bytes;

    /// @notice This constructor initializes only immutable state variables
    /// @param endpoint_ is the layerzero endpoint address deployed on this chain
    /// @param config is the struct containing the immutable state variables
    /// @param rewardVaultBeacon_ is the UpgradeableBeacon contract address for RewardVault beacon proxy
    constructor(address endpoint_, ImmutableConfig memory config, address rewardVaultBeacon_)
        OAppCoreUpgradeable(endpoint_)
        ClientChainGatewayStorage(config, rewardVaultBeacon_)
    {
        _disableInitializers();
    }

    /// @notice Initializes the ClientChainGateway contract.
    /// @dev reinitializer(2) is used so that the base contract (like OAppCore) functions can be called again.
    /// @param owner_ The address of the contract owner.
    function initialize(address owner_) external reinitializer(2) {
        _clearBootstrapData();

        if (owner_ == address(0)) {
            revert Errors.ZeroAddress();
        }

        _whiteListFunctionSelectors[Action.REQUEST_ADD_WHITELIST_TOKEN] =
            this.afterReceiveAddWhitelistTokenRequest.selector;
        // overwrite the bootstrap function selector
        _whiteListFunctionSelectors[Action.REQUEST_MARK_BOOTSTRAP] = this.afterReceiveMarkBootstrapRequest.selector;

        bootstrapped = true;

        _transferOwnership(owner_);
        __OAppCore_init_unchained(owner_);
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();
    }

    /// @dev Clears the bootstrap data.
    function _clearBootstrapData() internal {
        // the set below is recommended to clear, so that any possibilities of upgrades
        // can then be removed.
        delete customProxyAdmin;
        delete clientChainGatewayLogic;
        delete clientChainInitializationData;
        // no risk keeping these but they are cheap to clear.
        delete spawnTime;
        delete offsetDuration;
        // previously, we tried clearing the contents of these in loops but it is too expensive.
        delete depositors;
        delete registeredValidators;
        // mappings cannot be deleted
    }

    /// @notice Pauses the contract.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @inheritdoc ITokenWhitelister
    function getWhitelistedTokensCount() external view returns (uint256) {
        return _getWhitelistedTokensCount();
    }

    /// @inheritdoc ITokenWhitelister
    function addWhitelistTokens(address[] calldata, uint256[] calldata) external view onlyOwner whenNotPaused {
        revert Errors.ClientChainGatewayTokenAdditionViaImuachain();
    }

    /// @inheritdoc ITokenWhitelister
    function updateTvlLimit(address token, uint256 tvlLimit) external onlyOwner whenNotPaused {
        if (!isWhitelistedToken[token]) {
            // grave error, should never happen
            revert Errors.TokenNotWhitelisted(token);
        }
        if (token == VIRTUAL_NST_ADDRESS) {
            // not possible to set a TVL limit for native restaking
            revert Errors.NoTvlLimitForNativeRestaking();
        }
        IVault vault = _getVault(token);
        vault.setTvlLimit(tvlLimit);
    }

    /// @inheritdoc IClientChainGateway
    function quote(bytes calldata _message) public view returns (uint256 nativeFee) {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(
            DESTINATION_GAS_LIMIT, DESTINATION_MSG_VALUE
        ).addExecutorOrderedExecutionOption();
        MessagingFee memory fee = _quote(IMUACHAIN_CHAIN_ID, _message, options, false);
        return fee.nativeFee;
    }

    /// @inheritdoc IOAppCore
    function oAppVersion()
        public
        pure
        virtual
        override(IOAppCore, OAppSenderUpgradeable, OAppReceiverUpgradeable)
        returns (uint64 senderVersion, uint64 receiverVersion)
    {
        return (SENDER_VERSION, RECEIVER_VERSION);
    }

    /// @notice Deploy the reward vault contract.
    /// @dev The reward vault would be deployed with beacon proxy pattern like other vaults
    // The bytecode returned by the BEACON_PROXY_BYTECODE contract is static, so there is no risk of collision.
    // slither-disable-next-line encode-packed-collision
    function deployRewardVault() external onlyOwner whenNotPaused {
        rewardVault = IRewardVault(
            Create2.deploy(
                0,
                bytes32(bytes("REWARD_VAULT")),
                // for clarity, this BEACON_PROXY is not related to beacon chain
                // but rather it is the bytecode for the beacon proxy upgrade pattern.
                abi.encodePacked(BEACON_PROXY_BYTECODE.getBytecode(), abi.encode(address(REWARD_VAULT_BEACON), ""))
            )
        );
        rewardVault.initialize(address(this));
        emit RewardVaultCreated(address(rewardVault));
    }

}
