module.exports = async function ( { deployments, getNamedAccounts } ) {
    const { deploy } = deployments
    const { deployer } = await getNamedAccounts()
    console.log( `>>> your address: ${ deployer }` )
    const weth = "0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9"
    
    await deploy("GasFlowStakeVault", {
        from: deployer,
        proxy: {
            proxyContract: "UUPS",
            execute: {
              init: {
                methodName: "initialize",
                args: [
                    deployer,
                    weth
                ]
              }
            }
          },
        log: true,
        waitConfirmations: 1,
    } )
    const impl = await ethers.getContractFactory("GasFlowStakeVault");
    const GasFlowStakeVault = await ethers.getContract( "GasFlowStakeVault_Proxy" );
    await upgrades.forceImport(GasFlowStakeVault.target, impl, {
        kind: "uups", 
    });
    console.log( "Proxy imported successfully!" );
    const gasFlowStakeVault = await ethers.getContract( "GasFlowStakeVault" )

    await deploy("GasFlowConfig", {
        from: deployer,
        args: [deployer],
        log: true,
        waitConfirmations: 1,
    } )
    const gasFlowConfig = await ethers.getContract( "GasFlowConfig" )
    const setStakePoolTx = await gasFlowConfig.setStakePool( gasFlowStakeVault.target )
    await setStakePoolTx.wait()
    console.log( `>>> setStakePoolTx: ${ setStakePoolTx.hash }` )

    const setConfigTx = await gasFlowStakeVault.setConfig( gasFlowConfig.target )
    await setConfigTx.wait()
    console.log( `>>> setConfigTx: ${ setConfigTx.hash }` )

    await deploy("GasFlowDelegator", {
        from: deployer,
        args: [gasFlowConfig.target],
        log: true,
        waitConfirmations: 1,
    } )
    const gasFlowDelegator = await ethers.getContract( "GasFlowDelegator" )
    const delegationDesignation = "0xef0100" + gasFlowDelegator.target.slice(2).toLowerCase()
    const delegatorCodeHash = ethers.keccak256(delegationDesignation)
    const setCodeHashTx = await gasFlowConfig.setDelegatorCodeHash(delegatorCodeHash)
    await setCodeHashTx.wait()
    console.log(`>>> delegatorCodeHash set: ${delegatorCodeHash}`)
}

module.exports.tags = ["SepoliaChain"]