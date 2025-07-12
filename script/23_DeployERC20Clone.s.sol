pragma solidity ^0.8.19;

// local imports

import {BaseScript} from "script/BaseScript.sol";
import {ERC20PresetFixedSupplyClone} from "src/core/ERC20PresetFixedSupplyClone.sol";

// library imports

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// required to import stdJson
import "forge-std/Script.sol";

contract DeployERC20Clone is BaseScript {

    mapping(uint256 chainId => address originalToken) chainIdToOriginalToken;
    address proxyAdmin;
    // determined by testing that 104+ is supported
    uint256 constant BATCH_SIZE = 105;

    function setUp() public override {
        super.setUp();
        chainIdToOriginalToken[11_155_111] = 0x83E6850591425e3C1E263c054f4466838B9Bd9e4;
        chainIdToOriginalToken[17_000] = 0x1E867667Ef16111047C2c7f6ADf4612bDf80064D;
    }

    function run() public {
        vm.selectFork(clientChain);
        vm.startBroadcast(owner.privateKey);
        uint256 chainId = block.chainid;
        address originalToken = chainIdToOriginalToken[chainId];
        if (originalToken == address(0)) {
            revert("Chain not supported");
        }
        string memory chainName = chainIdToName[chainId];
        string memory prerequisiteContracts = vm.readFile("script/deployments/deployedContracts.json");
        proxyAdmin = stdJson.readAddress(prerequisiteContracts, string.concat(".", chainName, ".proxyAdmin"));
        require(proxyAdmin != address(0), "Proxy admin not found");
        // implementation
        ERC20PresetFixedSupplyClone erc20Clone = new ERC20PresetFixedSupplyClone();
        // proxy
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(erc20Clone),
            proxyAdmin,
            abi.encodeWithSelector(ERC20PresetFixedSupplyClone.initialize.selector, "imuaEthereum", "imETH", owner.addr)
        );
        console.log("Proxy deployed at", address(proxy));
        // now we have to iterate over the holders and copy the balances
        IERC20 oldErc20 = IERC20(originalToken);
        ERC20PresetFixedSupplyClone newERC20 = ERC20PresetFixedSupplyClone(address(proxy));
        address[] memory holders;
        uint256[] memory balances;
        bool[] memory burns;
        if (chainId == 11_155_111) {
            // holders, counts, sourced from Sepolia Etherscan
            holders = new address[](104);
            // balances to be sourced from the contract directly.
            balances = new uint256[](104);
            burns = new bool[](104);
            holders[0] = 0x3583fF95f96b356d716881C871aF7Eb55ea34a93;
            holders[1] = 0x8A21AE3e1344A83Bb05D5b1c9cFF04A9614F2567;
            holders[2] = 0xBAbBDeA86C96C18131bC158C8C7C76A779a3F366;
            holders[3] = 0x9956424d9bF3557FB9b7795211174B96b7Fe3293;
            holders[4] = 0x121398A3F1e7fDAcEfA4cBbC19a052f4Ea354e06;
            holders[5] = 0xD8bbF3fb198da987E9e26C05e1CfECd6AAe7bb25;
            holders[6] = 0xB2DBf222b35D3ba8bB0Dbbc30109d797C22Ffe0A;
            holders[7] = 0x9DAefa8046CB4a7dE50215226317b5e4b9429448;
            holders[8] = 0x0F4760CCab936a8fb0C9459dba2a739B22059b5f;
            holders[9] = 0x74b5fF3A931147Dc3B14F11be7934E75Ce5E87f3;
            holders[10] = 0x8052851F0Ae084d576E3cedBAc96F81823F06fFf;
            holders[11] = 0xcCb2BAC12e1FfDB3ec6009982Fd7c4d2c3daDedD;
            holders[12] = 0x3084b038A5C3C2730C5e6Ee0F38e5025949869bE;
            holders[13] = 0x052f9E529Ae027AC1AdD57Ca974B5AE2001b60C4;
            holders[14] = 0x32016AC5Cc2D0eAC2B15C05605d1783652ed1013;
            holders[15] = 0x462A57Ca88368219A69BF3c4FAD6424A035889bE;
            holders[16] = 0x49018a4c808B0C9B01c50019E47F8A5F044c73D7;
            holders[17] = 0x93C991a51484d272d3a8a8EA791640b78a695c58;
            holders[18] = 0xA1dfab3234f49e02e04E6C56a021F1a497CD0f82;
            holders[19] = 0xC1815914f6219ca4A1E2CE44d98b6C957b49bD0f;
            // faucet, manually removed!
            // skipped by the copyBalances function
            holders[20] = 0x0000000000000000000000000000000000000000;
            holders[21] = 0x884958ffB23885a13B5D51617f05F2B8b20f0405;
            holders[22] = 0xa865561101Ba1207dC7a89032112824c3aBF7Cf8;
            holders[23] = 0xdd779732A91a801bb65c4acF867c55606fC19630;
            holders[24] = 0xFCd5Aa5583ef0947AE91C8081fce041E0807c930;
            holders[25] = 0x18bDa2a6fbd172AD0c06B6744e094Ab909dF19A0;
            holders[26] = 0x722B73F57a0219755Cd829b7809F912AF6423f95;
            holders[27] = 0x6e5eE3e436539f46455b5174411942F520c1120E;
            holders[28] = 0x968001CDCf7558611B1c07c584948E47f009c6D6;
            holders[29] = 0xc6E1c84c2Fdc8EF1747512Cda73AaC7d338906ac;
            holders[30] = 0xD644860F052D30e14Fe71c0fc5783CAc1A0652D9;
            holders[31] = 0xC315Fd5E8873C8A19ef66D31df600313Dd0A3d3B;
            holders[32] = 0x40e1E5eEDE08Fd13F8DbbED11E35bc2a75EC783D;
            holders[33] = 0xA3e8c639C87C79C6DC6DD176aA4e0b76a446D09e;
            holders[34] = 0xA87FCB7c0DEAfF893f5Edf58F4934292316163d4;
            holders[35] = 0x19Bfe7b58D3D2C63Ee082A1C1db33F970Ca1fA44;
            holders[36] = 0x9fbd2bfFad0b9145F47948b2751CC8C36C94470c;
            holders[37] = 0x41B2ddC309Af448f0B96ba1595320D7Dc5121Bc0;
            holders[38] = 0x6C9585B10126C147DCBE7c7CfA816E9C5feDaDd0;
            holders[39] = 0xc5404531DF735Bd5CDBF935Bd41904b7B8247f97;
            holders[40] = 0xD683BC8e4A24097bbeC4f7cDBC7021CF356B808C;
            holders[41] = 0xFfB260e5d3C3573EaEF01a370d5d52798dB2F401;
            holders[42] = 0x3b5e063960f61B33E8FB9F5d03F788d6147D21E4;
            holders[43] = 0x3Ba0d394643Bf1C6e20B56Fa2BC6Ff2208760DDb;
            holders[44] = 0x003b649CA0bf91FeF71d5D04A7127E7Feccb5341;
            holders[45] = 0x5262F7921E318517E23b2D26ab5aaE455213C371;
            holders[46] = 0x481E020DB4709e6EdDbf8134D41b866c6Fc8555e;
            holders[47] = 0x633A9A3ae1Bf267d96d53Bf12Bfc1855636E9867;
            holders[48] = 0x9F5F1b63A7861dE50d3bcBe3327aA2B0f49F065d;
            holders[49] = 0x2228d389Bb4FdF42cCCB0F2BC371343f810173f9;
            holders[50] = 0xB26c469c17154911AF343E506ED8eFcd77EebdA0;
            holders[51] = 0xd7F2E8129f7Bcab8fD55a2C2207d5E02c3df6dbA;
            holders[52] = 0xFb408FA20c6f6DA099a7492107bC3531911896e3;
            holders[53] = 0x412C9B7a0664456450Fe050684A615D0B02BE908;
            holders[54] = 0x917f9b7B445f95f8d26E0072cC4F9Cd8Ba28A100;
            holders[55] = 0xee1031A177D1eca56A37932eAD41Aa19E574bd6d;
            holders[56] = 0xA8E4331cA8f83b36D6efD12F02f4B44abe991a2E;
            holders[57] = 0x5541e674C96A2F4166B07e6ac28241F46688e66C;
            holders[58] = 0xD9054F484ed98a7Dd632EB9c09644616db3deA8C;
            holders[59] = 0x2EFe21F4FeF7e737C0a3491C93be7D696038b6f5;
            holders[60] = 0x101305891890e64267253a3c0c5716c76682dE0a;
            holders[61] = 0x1a6004E02B141947442FF9aC32922A56609A9Ed6;
            holders[62] = 0x21a106936F2C794731aBf690923d24D35D451bDB;
            holders[63] = 0x45821AF32F0368fEeb7686c4CC10B7215E00Ab04;
            holders[64] = 0x4Ee441E8a1b12a146bDa07dCf6213759802DC654;
            holders[65] = 0x7306dcFFeBCf21DA031383E0247eEac7b6A8b4c3;
            holders[66] = 0x2104574c1Ac94120b4B745cA8B3eE23bfb6Bf440;
            holders[67] = 0x591b0fE4054aB2Ff0A9a7E5228CcBCb55f29C5C1;
            holders[68] = 0x698F0BF08F6847b497Fe4dBdA2B014BD6a666F11;
            holders[69] = 0xBC1eF09B6A48aAEEC6059Cf7E7936F4DD1eFE8cF;
            holders[70] = 0xC35323396A02e7932274C5AE0b7cb2eE2c43A28d;
            holders[71] = 0x44492E125A5848eAB9997302F64e24e9Ae1a1C92;
            holders[72] = 0x01fDfAE79277D3B2ecc9D7e106F35fa3582104Df;
            holders[73] = 0x80627081932B768D9978F58B06F930aaD6A642Ac;
            holders[74] = 0x80E1b2aCa117a79FD733EdcC84384FB06Ce47C3D;
            holders[75] = 0x781a7674CD85759396a9e7b4025F8561A6C0F3eC;
            holders[76] = 0x4e5F3a272017cceEC73E660d10f3Db7E8732391f;
            holders[77] = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
            holders[78] = 0xe87be5166f07a61D008ABF3D80D7724Ded4B894f;
            holders[79] = 0xE9025777C4824bd1580D956fF00B53ff5C7576aB;
            holders[80] = 0x5B85394494672AE2351EE4a02C8ed67d2FDc3CF9;
            holders[81] = 0x06275683A0156Eb00b3Dd7D95509394b29ae1354;
            holders[82] = 0x0ebAD11907e72986C2923278D888550B83AFe59F;
            holders[83] = 0x3197d67B761dCE05C3ec756Ba758272480724Ed8;
            holders[84] = 0x3605f5Ac35D5B2A26017558Ea1A25C4AF56868Fe;
            holders[85] = 0x3ACF8cCa4F184FCb3D4a4Ecc3401cBB94F56439F;
            holders[86] = 0x451281A0C66d470842792fd6204Bf206EB8c0098;
            holders[87] = 0x62CEDdcEdB8Efb9FB67fe5Fb9C3AD5575cBA835e;
            holders[88] = 0x7ba557D6cB4b2A96E824A8aE1A5778D3383d45D3;
            holders[89] = 0x938Cb96c8066b0eCD93397029968B84B8b7020e1;
            holders[90] = 0x945bE1E5f432d9D2B498Bb7BFE0C28f95648236a;
            holders[91] = 0x9aDBD9f4Ae269006e77dc978A55A5B7C74A8fc73;
            holders[92] = 0xc6A56ab1d3EBc250767ef85E0053742434408664;
            holders[93] = 0xcf12895728BB87407ef8735a101476ce8A932Bc2;
            holders[94] = 0xe8680f23cE3145a51A9AA0E0aa1f9061ECE1Ed4f;
            holders[95] = 0xF43b6f53864B5DcE905B8A1CbB7e02A3ee46ecdc;
            holders[96] = 0xfab2CDa006FA1b19Ed7105297C2443d98bf7074c;
            holders[97] = 0x372722650834B42fD8d382719a1115F679DA00C1;
            holders[98] = 0x45Ce9aFd3d141142842083Ff35d6849776Cfb0d8;
            holders[99] = 0x85c6cA649b794876c8e7417c35695B74662F1a2B;
            holders[100] = 0x9615DB57642417B114516C55cF1ff503f7AE4E8D;
            holders[101] = 0xD0E153e2Ee18eE6eE9E397b17F9A7308202BC0f0;
            holders[102] = 0xed2C85787D72e78D87aBc2342cAF2b0Fa227557D;
            holders[103] = 0x1d94C508016D5836F77901cF17E4895aC593F866;
            for (uint256 i = 0; i < holders.length; ++i) {
                uint256 oldBalance = oldErc20.balanceOf(holders[i]);
                uint256 newBalance = newERC20.balanceOf(holders[i]);
                if (oldBalance > newBalance) {
                    balances[i] = oldBalance - newBalance;
                } else if (oldBalance < newBalance) {
                    balances[i] = newBalance - oldBalance;
                    burns[i] = true;
                }
                // 0 is skipped by the copyBalances function
            }
        } else if (chainId == 17_000) {
            holders = new address[](23);
            balances = new uint256[](23);
            burns = new bool[](23);
            holders[0] = 0x968001CDCf7558611B1c07c584948E47f009c6D6;
            holders[1] = 0xdD4aF30a4C167BD010eB8746d41E8Db483336014;
            holders[2] = 0x3583fF95f96b356d716881C871aF7Eb55ea34a93;
            holders[3] = 0xBAbBDeA86C96C18131bC158C8C7C76A779a3F366;
            holders[4] = 0xdd779732A91a801bb65c4acF867c55606fC19630;
            holders[5] = 0x703CB5F2c75F3a707a92FeaD98c2A61E7DF56af3;
            holders[6] = 0x6f784CBb7Da75a87BdA0650a5107910ACbdE73d8;
            holders[7] = 0xaEc2e4303E11A78dC3db2f3B7F0f7adB38F39757;
            holders[8] = 0xD1654Cf29fD3C5543bCC9AFE1D883C6a214f942f;
            holders[9] = 0x3979119d03e5e8aC28f804d818eaE05ea5d34043;
            holders[10] = 0xB70C961A6be6cB8Aae564d19D81bc944E50cb6Ef;
            holders[11] = 0xEf08C6b278CcE76bDC0C53688cee4329BD6127a5;
            holders[12] = 0x6e5eE3e436539f46455b5174411942F520c1120E;
            holders[13] = 0x0B34c4D876cd569129CF56baFAbb3F9E97A4fF42;
            holders[14] = 0x533686CF952631E2bF28E0Ee0536F077b6e25818;
            holders[15] = 0x7Fd55E3692dEbd35Beb302978Be73073e9252436;
            holders[16] = 0xc6E1c84c2Fdc8EF1747512Cda73AaC7d338906ac;
            holders[17] = 0x7e7A484a60F3Bd5e8276D01118e932f36d4AD5f8;
            holders[18] = 0xDA82c2Dba1871a21905480cEf2f2E10729Ec56Ed;
            holders[19] = 0x451281A0C66d470842792fd6204Bf206EB8c0098;
            holders[20] = 0x21c193Dc7AfD8514CA284430b0A064707dEE68a3;
            holders[21] = 0x28D841fD0C49b9cd4D54420CC5939e798C28C25b;
            holders[22] = 0x62CEDdcEdB8Efb9FB67fe5Fb9C3AD5575cBA835e;
            for (uint256 i = 0; i < holders.length; ++i) {
                uint256 oldBalance = oldErc20.balanceOf(holders[i]);
                uint256 newBalance = newERC20.balanceOf(holders[i]);
                if (oldBalance > newBalance) {
                    balances[i] = oldBalance - newBalance;
                } else if (oldBalance < newBalance) {
                    balances[i] = newBalance - oldBalance;
                    burns[i] = true;
                }
                // 0 is skipped by the copyBalances function
            }
        } else {
            revert("Chain not supported");
        }
        uint256 effectiveBatchSize = BATCH_SIZE;
        for (uint256 i = 0; i < holders.length; i += BATCH_SIZE) {
            if (i + BATCH_SIZE > holders.length) {
                effectiveBatchSize = holders.length - i;
            }
            address[] memory batchHolders = new address[](effectiveBatchSize);
            uint256[] memory batchBalances = new uint256[](effectiveBatchSize);
            bool[] memory batchBurns = new bool[](effectiveBatchSize);
            for (uint256 j = 0; j < effectiveBatchSize; ++j) {
                batchHolders[j] = holders[i + j];
                batchBalances[j] = balances[i + j];
                batchBurns[j] = burns[i + j];
            }
            newERC20.copyBalances(batchHolders, batchBalances, batchBurns);
        }
        vm.stopBroadcast();
    }

}
