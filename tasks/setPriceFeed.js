module.exports = async function ( taskArgs, hre ) {
    const usdc = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
    const usdcFeed = "0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E"
    const ethFeed = "0x694AA1769357215DE4FAC081bf1f309aDC325306"

    const gasFlowConfig = await ethers.getContract( "GasFlowConfig" )

    const setUSDCFeedTx = await gasFlowConfig.setPriceFeed( usdc, usdcFeed, 6 )
    await setUSDCFeedTx.wait()
    console.log( `>>> setUSDCFeedTx: ${ setUSDCFeedTx.hash }` )

    const setEthUsdFeedTx = await gasFlowConfig.setEthUsdFeed( ethFeed )
    await setEthUsdFeedTx.wait()
    console.log( `>>> setEthUsdFeedTx: ${ setEthUsdFeedTx.hash }` )
}