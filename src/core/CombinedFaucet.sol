// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title CombinedFaucet
/// @author imua-xyz
/// @notice This contract can support both ERC20 and the EVM native token.
contract CombinedFaucet is
    IERC165,
    IERC1155Receiver,
    IERC721Receiver,
    Initializable,
    PausableUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{

    address public token;
    uint256 public tokenAmount;
    uint256 public constant ONE_DAY = 1 days;

    mapping(address => uint256) public lastRequestTime;

    event TokenAddressUpdated(address newTokenAddress);
    event TokenAmountUpdated(uint256 newTokenAmount);
    event TokensRequested(address indexed user, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    /// @dev Initialize the contract, set the owner, token address, and token amount
    /// @param owner_ The owner of the contract
    /// @param token_ The address of the token to distribute
    /// @param tokenAmount_ The amount of tokens to distribute at each request
    function initialize(address owner_, address token_, uint256 tokenAmount_) public initializer {
        // The token address can be 0 to support native token
        // slither-disable-next-line missing-zero-check
        token = token_;
        tokenAmount = tokenAmount_;

        _transferOwnership(owner_);
        __Pausable_init_unchained();
        __ReentrancyGuard_init_unchained();
    }

    /// @dev Request tokens from the faucet
    /// @notice Users can request tokens once every 24 hours
    function requestTokens() external whenNotPaused nonReentrant {
        require(token != address(0), "CombinedFaucet: not for native tokens");
        _withdraw(msg.sender);
    }

    /// @dev Give native tokens to a user (who doesn't have any to pay for gas)
    /// @param user The user to give tokens to
    function withdraw(address user) external whenNotPaused onlyOwner {
        require(token == address(0), "CombinedFaucet: only for native tokens");
        _withdraw(user);
    }

    function _withdraw(address dst) internal {
        if (lastRequestTime[dst] != 0) {
            require(
                block.timestamp >= lastRequestTime[dst] + ONE_DAY,
                "CombinedFaucet: Rate limit exceeded. Please wait 24 hours."
            );
        }
        lastRequestTime[dst] = block.timestamp;
        if (token != address(0)) {
            bool success = IERC20(token).transfer(dst, tokenAmount);
            require(success, "CombinedFaucet: token transfer failed");
        } else {
            (bool success,) = payable(dst).call{value: tokenAmount}("");
            require(success, "CombinedFaucet: wei transfer failed");
        }
        emit TokensRequested(dst, tokenAmount);
    }

    /// @dev Update the token address (Only owner can update)
    /// @param token_ The new token address
    function setTokenAddress(address token_) external onlyOwner {
        // The token address can be 0 to support native token
        // slither-disable-next-line missing-zero-check
        token = token_;
        emit TokenAddressUpdated(token_);
    }

    /// @dev Update the token amount to distribute (Only owner can update)
    /// @param tokenAmount_ The new token amount
    function setTokenAmount(uint256 tokenAmount_) external onlyOwner {
        tokenAmount = tokenAmount_;
        emit TokenAmountUpdated(tokenAmount_);
    }

    /// @dev Pause the contract (Only owner can pause)
    function pause() external onlyOwner {
        _pause();
    }

    /// @dev Unpause the contract (Only owner can unpause)
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Recover any tokens sent to the contract by mistake (Only owner)
    /// @param token_ The token address to recover
    /// @param amount_ The amount to recover
    function recoverTokens(address token_, uint256 amount_) external nonReentrant onlyOwner {
        if (token_ != address(0)) {
            bool success = IERC20(token_).transfer(owner(), amount_);
            require(success, "CombinedFaucet: token transfer failed");
        } else {
            (bool success,) = payable(owner()).call{value: amount_}("");
            require(success, "CombinedFaucet: wei transfer failed");
        }
    }

    /// @dev Always revert when ERC721 tokens are sent to this contract.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("Faucet: ERC721 tokens not accepted");
    }

    /// @dev Always revert when ERC1155 tokens are sent to this contract.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert("Faucet: ERC1155 tokens not accepted");
    }

    /// @dev Always revert when ERC1155 batch tokens are sent to this contract.
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert("Faucet: ERC1155 batch tokens not accepted");
    }

    /// @dev ERC165 interface support check.
    /// Automatically derives the interface selectors for ERC165, ERC721Receiver, and ERC1155Receiver.
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return (
            interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC721Receiver).interfaceId
                || interfaceId == type(IERC1155Receiver).interfaceId
        );
    }

    // Allow the contract to receive native token
    receive() external payable {}

}
