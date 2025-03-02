// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";
import {IAssets} from "src/interfaces/precompiles/IAssets.sol";
import {TokenInfo} from "src/interfaces/precompiles/IAssets.sol";
import {StakerBalance} from "src/interfaces/precompiles/IAssets.sol";

contract AssetsMock is IAssets {

    address constant VIRTUAL_STAKED_ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address constant VIRTUAL_STAKED_BTC_ADDRESS = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;
    uint32 internal constant clientBtcChainId = 1;

    mapping(uint32 => mapping(bytes => mapping(bytes => uint256))) public principalBalances;
    mapping(bytes => mapping(bytes => bool)) public inValidatorSet;
    mapping(address => bool) public authorizedGateways;

    uint32[] internal chainIds;
    mapping(uint32 chainId => bool registered) public isRegisteredChain;
    mapping(uint32 chainId => mapping(bytes token => bool registered)) public isRegisteredToken;
    mapping(uint32 chainId => mapping(bytes token => TokenInfo)) public registeredTokens;

    constructor(uint32 clientChainId) {
        isRegisteredChain[clientChainId] = true;
        chainIds.push(clientChainId);
    }

    function depositLST(
        uint32 clientChainLzId,
        bytes calldata assetsAddress,
        bytes calldata stakerAddress,
        uint256 opAmount
    ) external returns (bool success, uint256 latestAssetState) {
        require(assetsAddress.length == 32, "invalid asset address");

        if (clientChainLzId != clientBtcChainId) {
            require(stakerAddress.length == 32, "invalid staker address");
        }

        // Validate the asset address
        // If the assetsAddress is not the virtual ETH/BTC address, check if the token is registered
        bool notEth = bytes32(assetsAddress) != bytes32(bytes20(VIRTUAL_STAKED_ETH_ADDRESS));
        bool notBtc = bytes32(assetsAddress) != bytes32(bytes20(VIRTUAL_STAKED_BTC_ADDRESS));
        console.log("notEth ", notEth, " notBtc", notBtc);
        if (notEth && notBtc) {
            require(isRegisteredToken[clientChainLzId][assetsAddress], "the token not registered");
        }

        principalBalances[clientChainLzId][assetsAddress][stakerAddress] += opAmount;
        console.log("principalBalances: ", opAmount);
        return (true, principalBalances[clientChainLzId][assetsAddress][stakerAddress]);
    }

    function depositNST(
        uint32 clientChainLzId,
        bytes calldata validatorID,
        bytes calldata stakerAddress,
        uint256 opAmount
    ) external returns (bool success, uint256 latestAssetState) {
        require(stakerAddress.length == 32, "invalid staker address");

        bytes memory nstAddress = abi.encodePacked(bytes32(bytes20(VIRTUAL_STAKED_ETH_ADDRESS)));
        principalBalances[clientChainLzId][nstAddress][stakerAddress] += opAmount;
        inValidatorSet[stakerAddress][validatorID] = true;
        return (true, principalBalances[clientChainLzId][nstAddress][stakerAddress]);
    }

    function withdrawLST(
        uint32 clientChainLzId,
        bytes calldata assetsAddress,
        bytes calldata withdrawer,
        uint256 opAmount
    ) external returns (bool success, uint256 latestAssetState) {
        require(assetsAddress.length == 32, "invalid asset address");
        require(withdrawer.length == 32, "invalid staker address");

        bytes32 assetAddressBytes32 = bytes32(assetsAddress);
        bool isEth = assetAddressBytes32 == bytes32(bytes20(VIRTUAL_STAKED_ETH_ADDRESS));
        bool isBtc = assetAddressBytes32 == bytes32(bytes20(VIRTUAL_STAKED_BTC_ADDRESS));

        console.log("isEth ", isEth, " isBtc", isBtc);
        // Disallow ETH withdrawals or non-registered tokens (except BTC)
        if (isEth || (!isRegisteredToken[clientChainLzId][assetsAddress] && !isBtc)) {
            return (false, 0);
        }

        if (opAmount > principalBalances[clientChainLzId][assetsAddress][withdrawer]) {
            return (false, 0);
        }

        principalBalances[clientChainLzId][assetsAddress][withdrawer] -= opAmount;
        console.log("principalBalances: ", opAmount);
        return (true, principalBalances[clientChainLzId][assetsAddress][withdrawer]);
    }

    function withdrawNST(
        uint32 clientChainLzId,
        bytes calldata validatorID,
        bytes calldata withdrawer,
        uint256 opAmount
    ) external returns (bool success, uint256 latestAssetState) {
        require(withdrawer.length == 32, "invalid staker address");

        bytes memory nstAddress = abi.encodePacked(bytes32(bytes20(VIRTUAL_STAKED_ETH_ADDRESS)));
        if (opAmount > principalBalances[clientChainLzId][nstAddress][withdrawer]) {
            return (false, 0);
        }
        principalBalances[clientChainLzId][nstAddress][withdrawer] -= opAmount;
        inValidatorSet[withdrawer][validatorID] = false;
        return (true, principalBalances[clientChainLzId][nstAddress][withdrawer]);
    }

    function getClientChains() external view returns (bool, uint32[] memory) {
        return (true, chainIds);
    }

    function registerOrUpdateClientChain(
        uint32 clientChainId,
        uint8 addressLength,
        string calldata name,
        string calldata metaInfo,
        string calldata signatureType
    ) external returns (bool, bool) {
        bool updated = isRegisteredChain[clientChainId];
        if (!isRegisteredChain[clientChainId]) {
            isRegisteredChain[clientChainId] = true;
            chainIds.push(clientChainId);
        }
        return (true, updated);
    }

    function registerToken(
        uint32 clientChainId,
        bytes calldata token,
        uint8 decimals,
        string calldata name,
        string calldata metaData,
        string calldata oracleInfo
    ) external returns (bool success) {
        if (!isRegisteredChain[clientChainId]) {
            // chain not registered
            return false;
        }

        if (isRegisteredToken[clientChainId][token]) {
            // token already registered
            return false;
        }
        isRegisteredToken[clientChainId][token] = true;
        registeredTokens[clientChainId][token] = TokenInfo({
            name: name,
            symbol: "",
            clientChainID: clientChainId,
            tokenID: token,
            decimals: decimals,
            totalStaked: 0
        });
        return true;
    }

    function updateToken(uint32 clientChainId, bytes calldata token, string calldata metaData)
        external
        view
        returns (bool success)
    {
        if (!isRegisteredChain[clientChainId]) {
            // chain not registered
            return false;
        }

        if (!isRegisteredToken[clientChainId][token]) {
            // token not registered
            return false;
        }

        return true;
    }

    function updateAuthorizedGateways(address[] calldata gateways) external returns (bool) {
        if (gateways.length == 0) {
            return false;
        }

        for (uint256 i = 0; i < gateways.length; i++) {
            authorizedGateways[gateways[i]] = true;
        }
        return true;
    }

    function getPrincipalBalance(uint32 clientChainLzId, bytes memory token, bytes memory staker)
        public
        view
        returns (uint256)
    {
        return principalBalances[clientChainLzId][token][staker];
    }

    function _addressToBytes(address addr) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(bytes20(addr)));
    }

    function isRegisteredClientChain(uint32 clientChainID) external view returns (bool, bool) {
        return (true, isRegisteredChain[clientChainID]);
    }

    function isAuthorizedGateway(address gateway) external view returns (bool, bool) {
        return (true, authorizedGateways[gateway]);
    }

    function getTokenInfo(uint32 clientChainId, bytes calldata tokenId)
        external
        view
        returns (bool, TokenInfo memory)
    {
        if (!isRegisteredToken[clientChainId][tokenId]) {
            return (false, TokenInfo("", "", 0, bytes(""), 0, 0));
        }
        return (true, registeredTokens[clientChainId][tokenId]);
    }

    function getStakerBalanceByToken(uint32 clientChainId, bytes calldata stakerAddress, bytes calldata token)
        external
        view
        returns (bool, StakerBalance memory)
    {
        return (
            true,
            StakerBalance(
                clientChainId,
                stakerAddress,
                token,
                principalBalances[clientChainId][token][stakerAddress],
                principalBalances[clientChainId][token][stakerAddress],
                0,
                0,
                principalBalances[clientChainId][token][stakerAddress]
                )
        );
    }

}
