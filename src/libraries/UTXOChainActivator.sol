// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ASSETS_CONTRACT} from "../interfaces/precompiles/IAssets.sol";
import {UTXOGatewayStorage} from "../storage/UTXOGatewayStorage.sol";
import {Errors} from "./Errors.sol";

/**
 * @title UTXOChainActivator
 * @dev Library for activating UTXO client chain staking. Holds all chain/token metadata
 *      constants and registration logic to keep UTXOGateway under the 24KiB contract size limit.
 */
library UTXOChainActivator {

    /* -------------------- Bitcoin Chain and Token Constants ------------------- */
    uint8 private constant BITCOIN_STAKER_ACCOUNT_LENGTH = 20;
    string private constant BITCOIN_NAME = "Bitcoin";
    string private constant BITCOIN_METADATA = "Bitcoin";
    string private constant BITCOIN_SIGNATURE_SCHEME = "ECDSA";

    uint8 private constant BTC_DECIMALS = 8;
    string private constant BTC_NAME = "BTC";
    string private constant BTC_METADATA = "BTC";
    string private constant BTC_ORACLE_INFO = "BTC,BITCOIN,8";

    /* ---------------------- XRPL Chain and Token Constants --------------------- */
    uint8 private constant XRPL_ACCOUNT_LENGTH = 20;
    string private constant XRPL_NAME = "XRPL";
    string private constant XRPL_METADATA = "XRP LEDGER";
    string private constant XRPL_SIGNATURE_SCHEME = "ECDSA";

    uint8 private constant XRP_DECIMALS = 6;
    string private constant XRP_NAME = "XRP";
    string private constant XRP_METADATA = "XRP TOKEN";
    string private constant XRP_ORACLE_INFO = "XRP,XRPL,8";

    /* ---------------------- DOGE Chain and Token Constants --------------------- */
    uint8 private constant DOGE_ACCOUNT_LENGTH = 20;
    string private constant DOGE_CHAIN_NAME = "DOGE";
    string private constant DOGE_CHAIN_METADATA = "DOGE";
    string private constant DOGE_SIGNATURE_SCHEME = "ECDSA";

    uint8 private constant DOGE_DECIMALS = 8;
    string private constant DOGE_NAME = "DOGE";
    string private constant DOGE_METADATA = "DOGE";
    string private constant DOGE_ORACLE_INFO = "DOGE,DOGE,8";

    /**
     * @notice Activates staking for a UTXO client chain: registers/updates chain and token with Imua.
     * @param clientChainId The client chain to activate.
     * @param virtualToken The virtual token bytes (same as UTXOGatewayStorage.VIRTUAL_TOKEN).
     * @return chainUpdated True if the client chain was updated (false = newly registered).
     * @return tokenAdded True if the token was newly added (false = updated).
     */
    function activateStakingForClientChain(UTXOGatewayStorage.ClientChainID clientChainId, bytes memory virtualToken)
        external
        returns (bool chainUpdated, bool tokenAdded)
    {
        chainUpdated = _registerOrUpdateClientChain(clientChainId);
        tokenAdded = _registerOrUpdateToken(clientChainId, virtualToken);
    }

    function _registerOrUpdateClientChain(UTXOGatewayStorage.ClientChainID clientChainId)
        internal
        returns (bool updated)
    {
        (
            uint8 stakerAccountLength,
            string memory chainName,
            string memory chainMetadata,
            string memory signatureScheme,,,,
        ) = _getChainAndTokenConfig(clientChainId);

        (bool success, bool updated_) = ASSETS_CONTRACT.registerOrUpdateClientChain(
            uint32(uint8(clientChainId)), stakerAccountLength, chainName, chainMetadata, signatureScheme
        );
        if (!success) {
            revert Errors.RegisterClientChainToImuachainFailed(uint32(uint8(clientChainId)));
        }
        return updated_;
    }

    function _registerOrUpdateToken(UTXOGatewayStorage.ClientChainID clientChainId, bytes memory virtualToken)
        internal
        returns (bool tokenAdded)
    {
        (,,,, uint8 decimals, string memory tokenName, string memory tokenMetadata, string memory oracleInfo) =
            _getChainAndTokenConfig(clientChainId);

        uint32 clientChainIdUint32 = uint32(uint8(clientChainId));
        bool registered = ASSETS_CONTRACT.registerToken(
            clientChainIdUint32, virtualToken, decimals, tokenName, tokenMetadata, oracleInfo
        );
        if (registered) {
            return true;
        }
        bool tokenUpdated = ASSETS_CONTRACT.updateToken(clientChainIdUint32, virtualToken, tokenMetadata);
        if (!tokenUpdated) {
            bytes32 tokenId;
            assembly {
                tokenId := mload(add(virtualToken, 32))
            }
            revert Errors.AddWhitelistTokenFailed(clientChainIdUint32, tokenId);
        }
        return false;
    }

    function _getChainAndTokenConfig(UTXOGatewayStorage.ClientChainID clientChainId)
        internal
        pure
        returns (
            uint8 stakerAccountLength,
            string memory chainName,
            string memory chainMetadata,
            string memory signatureScheme,
            uint8 decimals,
            string memory tokenName,
            string memory tokenMetadata,
            string memory oracleInfo
        )
    {
        if (clientChainId == UTXOGatewayStorage.ClientChainID.BITCOIN) {
            return (
                BITCOIN_STAKER_ACCOUNT_LENGTH,
                BITCOIN_NAME,
                BITCOIN_METADATA,
                BITCOIN_SIGNATURE_SCHEME,
                BTC_DECIMALS,
                BTC_NAME,
                BTC_METADATA,
                BTC_ORACLE_INFO
            );
        }
        if (clientChainId == UTXOGatewayStorage.ClientChainID.XRPL) {
            return (
                XRPL_ACCOUNT_LENGTH,
                XRPL_NAME,
                XRPL_METADATA,
                XRPL_SIGNATURE_SCHEME,
                XRP_DECIMALS,
                XRP_NAME,
                XRP_METADATA,
                XRP_ORACLE_INFO
            );
        }
        if (clientChainId == UTXOGatewayStorage.ClientChainID.DOGE) {
            return (
                DOGE_ACCOUNT_LENGTH,
                DOGE_CHAIN_NAME,
                DOGE_CHAIN_METADATA,
                DOGE_SIGNATURE_SCHEME,
                DOGE_DECIMALS,
                DOGE_NAME,
                DOGE_METADATA,
                DOGE_ORACLE_INFO
            );
        }
        revert Errors.InvalidClientChain();
    }

}
