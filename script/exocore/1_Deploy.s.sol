pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import "../../src/core/ClientChainGateway.sol";
import "../../src/core/Vault.sol";
import "../../src/core/ExocoreGateway.sol";
import "../../src/interfaces/precompiles/IDelegation.sol";
import "../../src/interfaces/precompiles/IDeposit.sol";
import "../../src/interfaces/precompiles/IWithdrawPrinciple.sol";
import "../../src/mock/NonShortCircuitLzEndpointMock.sol";
import "@layerzero-contracts/interfaces/ILayerZeroEndpoint.sol";

contract DeployScript is Script {
    Player[] players;
    Player exocoreValidatorSet;
    Player deployer;

    address[] whitelistTokens;
    address[] vaults;
    ERC20PresetFixedSupply restakeToken;

    ClientChainGateway clientGateway;
    Vault vault;
    ExocoreGateway exocoreGateway;
    ILayerZeroEndpoint clientChainLzEndpoint;
    ILayerZeroEndpoint exocoreLzEndpoint;

    uint16 exocoreChainId = 0;
    uint16 clientChainId = 1;

    struct Player {
        uint256 privateKey;
        address addr;
    }
    
    function setUp() public {
        players.push(Player({privateKey: uint256(0x1), addr: vm.addr(uint256(0x1))}));
        players.push(Player({privateKey: uint256(0x2), addr: vm.addr(uint256(0x2))}));
        players.push(Player({privateKey: uint256(0x3), addr: vm.addr(uint256(0x3))}));

        deployer.privateKey = vm.envUint("EXOCORE_DEPLOYER_PRIVATE_KEY");
        deployer.addr = vm.addr(deployer.privateKey);
        
        exocoreValidatorSet.privateKey = vm.envUint("EXOCORE_VALIDATOR_SET_PRIVATE_KEY");
        exocoreValidatorSet.addr = vm.addr(exocoreValidatorSet.privateKey);
    }

    function run() public {
        vm.startBroadcast(deployer.privateKey);
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        ExocoreGateway exocoreGatewayLogic = new ExocoreGateway();
        exocoreGateway = ExocoreGateway(address(new TransparentUpgradeableProxy(address(exocoreGatewayLogic), address(proxyAdmin), "")));
        exocoreLzEndpoint = new NonShortCircuitLzEndpointMock(exocoreChainId);
        vm.stopBroadcast();

        exocoreGateway.initialize(payable(exocoreValidatorSet.addr), address(exocoreLzEndpoint));
    }
}
