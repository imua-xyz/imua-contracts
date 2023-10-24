pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IController} from "../interfaces/IController.sol";
import {ILayerZeroEndpoint} from "@layerzero-contracts/interfaces/ILayerZeroEndpoint.sol";
import {Controller} from "../core/Controller.sol";

contract GatewayStorage {
    address public ExocoreValidatorSetBLSPubkey;
    IController public controller;
    
    ILayerZeroEndpoint public lzEndpoint;
    uint256 public lzFee;
    mapping(uint16 => bytes) public trustedRemoteLookup;
    mapping(uint16 => uint256) public payloadSizeLimitLookup;
    mapping(Controller.Action => bytes4) public whiteListedFunctionSigs;
}