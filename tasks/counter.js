module.exports = async function ( taskArgs, hre ) {
    const contract = await ethers.getContract( "Counter" )

    const x = await contract.x()
    console.log( x )
    
    const inc1Tx = await contract.inc1()
    console.log( inc1Tx.hash )
    await inc1Tx.wait()
}