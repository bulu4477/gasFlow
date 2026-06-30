require("@nomicfoundation/hardhat-toolbox");
require( "@nomicfoundation/hardhat-verify" )
require("dotenv").config()
require("hardhat-deploy")
require("hardhat-deploy-ethers")
require( "./tasks" )
require( "@nomicfoundation/hardhat-foundry" );
const { upgrades } = require('@openzeppelin/hardhat-upgrades');

/** @type import('hardhat/config').HardhatUserConfig */
const { projectId, PRIVATE_KEY } = process.env
module.exports = {
    networks: {
        eth_testnet: {
            url: `https://sepolia.infura.io/v3/${projectId}`,
            accounts: [PRIVATE_KEY]
        },
    },
    solidity: {
        compilers:[
            {
                version: "0.8.28",
                settings: {
                    evmVersion: "prague",
                    optimizer: {
                        enabled: true,
                        runs: 200,
                    },
                    viaIR: true,
                },
            },
        ]
    },
    namedAccounts: {
        deployer: {
            default: 0, // wallet address 0, of the mnemonic in .env
        },
        proxyOwner: {
            default: 1,
        },
    },
};
