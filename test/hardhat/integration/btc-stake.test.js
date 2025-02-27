const { expect } = require("chai");
require("dotenv").config();

describe("BTC Stake", () => {
    let proxyAdmin;
    let utxoGateway;
    let utxoGatewayLogic;
    let assetsPrecompile;
    let faucet;
    let deployer;
    let owner;
    let relayer;
    let staker;
    let witness1;
    let witness2;
    let witness3;

    const ASSETS_PRECOMPILE_ADDRESS = "0x0000000000000000000000000000000000000804";
    const STAKER_BTC_ADDR = "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh";

    // enum representing client chain
    const CLIENT_CHAIN = {
        NONE: 0,
        BTC: 1,
    };

    // enum representing tokens
    const TOKEN = {
        NONE: 0,
        BTC: 1,
    };

    const TX_STATUS = {
        NotStartedOrProcessed: 0, // 0: Default state - transaction hasn't started collecting proofs
        Pending: 1, // 1: Currently collecting witness proofs
        Expired: 2, // 2: Failed due to timeout, but can be retried
    };

    const VIRTUAL_BTC_ADDR = "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB";
    const BTC_ID = ethers.getBytes(VIRTUAL_BTC_ADDR);
    const OPERATOR = "im18cggcpvwspnd5c6ny8wrqxpffj5zmhkl3agtrj";

    // Run once before all tests
    before(async () => {
        const initialAccounts = await ethers.getSigners();
        [deployer, owner, relayer, staker, witness1, witness2, witness3] = initialAccounts;

        // deployer is also the faucet
        faucet = deployer;

        // transfer 1 ether gas tokens to all accounts
        for (const account of initialAccounts) {
            const tx = await faucet.sendTransaction({
                to: account.address,
                value: ethers.parseEther("1"),
            });
            // wait until the transaction is mined but should not exceed 10 seconds
            await tx.wait();
            expect(await ethers.provider.getBalance(account.address)).to.be.greaterThanOrEqual(ethers.parseEther("1"));
        }

        // Deploy and initialize UTXOGateway only if contract hasn't been deployed yet
        if (!utxoGateway) {
            // deploy the logic contract
            const utxoGatewayFactory = await ethers.getContractFactory("UTXOGateway");
            utxoGatewayLogic = await utxoGatewayFactory.connect(deployer).deploy();
            await utxoGatewayLogic.waitForDeployment();

            // deploy the proxy admin contract
            const proxyAdminFactory = await ethers.getContractFactory("ProxyAdmin");
            proxyAdmin = await proxyAdminFactory.connect(deployer).deploy();
            await proxyAdmin.waitForDeployment();

            // deploy the proxy contract
            const proxyFactory = await ethers.getContractFactory("TransparentUpgradeableProxy");
            const utxoGatewayProxy = await proxyFactory.deploy(
                utxoGatewayLogic.target,
                proxyAdmin.target,
                utxoGatewayLogic.interface.encodeFunctionData("initialize", [owner.address, [witness1.address, witness2.address, witness3.address], 2])
            );
            await utxoGatewayProxy.waitForDeployment();

            // set the proxy address to the UTXOGateway interface
            utxoGateway = utxoGatewayFactory.attach(utxoGatewayProxy.target);
        }

        // set the utxo gateway as authorized
        assetsPrecompile = await ethers.getContractAt("IAssets", ASSETS_PRECOMPILE_ADDRESS);
        const tx = await assetsPrecompile.connect(deployer).updateAuthorizedGateways([utxoGateway.target]);
        const receipt = await tx.wait();
        expect(receipt.status).to.be.equal(1);
    });

    it("should deploy the contract and successfully set the utxo gateway as authorized", async () => {
        expect(utxoGateway.target).to.be.properAddress;
        console.log("UTXOGateway deployed to:", utxoGateway.target);

        // assert owner is set
        expect(await utxoGateway.owner()).to.equal(owner.address);

        // assert witnesses are set
        expect(await utxoGateway.authorizedWitnesses(witness1.address)).to.be.true;
        expect(await utxoGateway.authorizedWitnesses(witness2.address)).to.be.true;
        expect(await utxoGateway.authorizedWitnesses(witness3.address)).to.be.true;

        // assert threshold is set
        expect(await utxoGateway.requiredProofs()).to.equal(2);
        expect(await utxoGateway.isConsensusRequired()).to.be.true;

        // assert the utxo gateway is authorized
        const [success, authorized] = await assetsPrecompile.isAuthorizedGateway(utxoGateway.target);
        expect(success).to.be.true;
        expect(authorized).to.be.true;
    });

    it("should successfully activate staking for BTC", async () => {
        const tx = await utxoGateway.connect(owner).activateStakingForClientChain(CLIENT_CHAIN.BTC);
        const receipt = await tx.wait();
        expect(receipt.status).to.be.equal(1);

        // assert the client chain is registered
        const [success1, registered] = await assetsPrecompile.isRegisteredClientChain(CLIENT_CHAIN.BTC);
        expect(success1).to.be.true;
        expect(registered).to.be.true;

        // assert the BTC asset is registered
        const [success2, tokenInfo] = await assetsPrecompile.getTokenInfo(CLIENT_CHAIN.BTC, BTC_ID);
        expect(success2).to.be.true;
        // Access array elements directly since tokenInfo is returned as an array
        expect(tokenInfo[0]).to.equal("BTC");          // name
        expect(tokenInfo[1]).to.equal("");             // symbol
        expect(Number(tokenInfo[2])).to.equal(CLIENT_CHAIN.BTC);  // clientChainId
        
        // Convert the returned tokenId bytes to hex string for comparison
        const returnedTokenId = ethers.hexlify(tokenInfo[3]);  // tokenId
        expect(returnedTokenId).to.equal(ethers.hexlify(BTC_ID));
        expect(Number(tokenInfo[4])).to.equal(8);      // decimals
        expect(Number(tokenInfo[5])).to.equal(0);      // totalStaked
    });

    it("should successfully stake BTC", async () => {
        // construct the stake message for staker
        const stakeMsg = {
            clientChainId: CLIENT_CHAIN.BTC,  // enum value, probably 1
            clientAddress: ethers.toUtf8Bytes(STAKER_BTC_ADDR),  // convert address to bytes
            imuachainAddress: staker.address,   // use signer's address
            operator: OPERATOR,
            amount: ethers.parseUnits("1.0", 8),
            nonce: BigInt(1),
            txTag: ethers.toUtf8Bytes("test-1")
        };

        // Create the message hash using the same format as the contract
        const messageHash = ethers.keccak256(
            ethers.AbiCoder.defaultAbiCoder().encode(
                [
                    'uint8',          // clientChainId (enum is uint8)
                    'bytes',          // clientAddress
                    'address',        // imuachainAddress
                    'string',         // operator
                    'uint256',        // amount
                    'uint64',         // nonce
                    'bytes'           // txTag
                ],
                [
                    stakeMsg.clientChainId,
                    stakeMsg.clientAddress,
                    stakeMsg.imuachainAddress,
                    stakeMsg.operator,
                    stakeMsg.amount,
                    stakeMsg.nonce,
                    stakeMsg.txTag
                ]
            )
        );

        // construct proofs for the stake message, with each witness signing the message
        const proofs = [];
        for (const witness of [witness1, witness2, witness3]) {
            const proof = await witness.signMessage(ethers.getBytes(messageHash));
            proofs.push(proof);
        }

        // consensus is required, so we need to submit the proofs
        expect(await utxoGateway.isConsensusRequired()).to.be.true;
        expect(await utxoGateway.requiredProofs()).to.equal(2);

        // check initial balance, since we have not deposited any BTC yet, the call should fail
        const [success, _] = await assetsPrecompile.getStakerBalanceByToken(
            CLIENT_CHAIN.BTC,
            ethers.getBytes(staker.address),
            BTC_ID
        );
        expect(success).to.be.false;

        // submit the first proof
        const tx = await utxoGateway.connect(relayer).submitProofForStakeMsg(
            witness1.address,
            stakeMsg,
            proofs[0]
        );

        // Wait for transaction with more details
        const receipt1 = await tx.wait();
        expect(receipt1.status).to.be.equal(1);

        // assert the transaction is created and pending to be processed
        expect(await utxoGateway.getTransactionStatus(messageHash)).to.equal(TX_STATUS.Pending);
        expect(await utxoGateway.getTransactionProofCount(messageHash)).to.equal(1);

        // Check balance after first proof - should fail since we have not reached consensus to process the transaction
        const [midSuccess, midBalance] = await assetsPrecompile.getStakerBalanceByToken(
            CLIENT_CHAIN.BTC,
            ethers.getBytes(staker.address),
            BTC_ID
        );
        expect(midSuccess).to.be.false;

        // submit the second proof
        const tx2 = await utxoGateway.connect(relayer).submitProofForStakeMsg(witness2.address, stakeMsg, proofs[1]);
        const receipt2 = await tx2.wait();
        expect(receipt2.status).to.be.equal(1);
        // assert we should have met with required proofs to process the transaction
        expect(await utxoGateway.getTransactionStatus(messageHash)).to.equal(TX_STATUS.NotStartedOrProcessed);
        expect(await utxoGateway.getTransactionProofCount(messageHash)).to.equal(0);

        // Check final balance - should reflect the staked amount
        const [finalSuccess, finalBalance] = await assetsPrecompile.getStakerBalanceByToken(
            CLIENT_CHAIN.BTC,
            ethers.getBytes(staker.address),
            BTC_ID
        );
        expect(finalSuccess).to.be.true;
        expect(finalBalance[0]).to.equal(CLIENT_CHAIN.BTC);  // clientChainID
        expect(ethers.hexlify(finalBalance[1])).to.equal(ethers.hexlify(staker.address));  // stakerAddress
        expect(ethers.hexlify(finalBalance[2])).to.equal(ethers.hexlify(BTC_ID));  // tokenId
        expect(finalBalance[3]).to.equal(stakeMsg.amount);    // balance
        expect(finalBalance[4]).to.equal(0n);    // withdrawable should be zero since tokens would be delegated to operator
        expect(finalBalance[5]).to.equal(stakeMsg.amount);    // delegated
        expect(finalBalance[6]).to.equal(0n);    // pendingUndelegated
        expect(finalBalance[7]).to.equal(stakeMsg.amount);    // totalDeposited

        // Verify final transaction status
        expect(await utxoGateway.getTransactionStatus(messageHash)).to.equal(TX_STATUS.NotStartedOrProcessed);
        expect(await utxoGateway.getTransactionProofCount(messageHash)).to.equal(0);

    });
});
