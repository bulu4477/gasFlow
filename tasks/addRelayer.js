module.exports = async function ( taskArgs, hre ) {
    const relayer = "0xB1C9f2643f55A564bAF02945c37aF1A1e307506A"
    const gasFlowConfig = await ethers.getContract( "GasFlowConfig" )

    const addRelayerTx = await gasFlowConfig.addRelayer( relayer )
    await addRelayerTx.wait()
    console.log( `>>> addRelayerTx: ${ addRelayerTx.hash }` )
}