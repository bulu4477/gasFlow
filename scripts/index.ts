import dotenv from "dotenv";
import { ethers } from "ethers";
import { contractABI } from "./contract";

dotenv.config();

// 用于可重用性的全局变量
let provider: ethers.JsonRpcProvider,
  firstSigner: ethers.Wallet,
  sponsorSigner: ethers.Wallet,
  targetAddress: string,
  usdcAddress: string,
  recipientAddress: string;

async function initializeSigners() {
  // 检查环境变量
  if (
    !process.env.FIRST_PRIVATE_KEY ||
    !process.env.SPONSOR_PRIVATE_KEY ||
    !process.env.DELEGATION_CONTRACT_ADDRESS ||
    !process.env.QUICKNODE_URL ||
    !process.env.USDC_ADDRESS
  ) {
    console.error("请在 .env 文件中设置你的环境变量。");
    process.exit(1);
  }

  const quickNodeUrl = process.env.QUICKNODE_URL;
  provider = new ethers.JsonRpcProvider(quickNodeUrl);

  firstSigner = new ethers.Wallet(process.env.FIRST_PRIVATE_KEY, provider);
  sponsorSigner = new ethers.Wallet(process.env.SPONSOR_PRIVATE_KEY, provider);

  targetAddress = process.env.DELEGATION_CONTRACT_ADDRESS;
  usdcAddress = process.env.USDC_ADDRESS;
  recipientAddress =
    (await provider.resolveName("vitalik.eth")) ||
    "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";

  console.log(firstSigner)
  console.log("第一个签名者地址：", firstSigner.address);
  console.log("赞助者签名者地址：", sponsorSigner.address);

  // 检查余额
  const firstBalance = await provider.getBalance(firstSigner.address);
  const sponsorBalance = await provider.getBalance(sponsorSigner.address);
  console.log("第一个签名者余额：", ethers.formatEther(firstBalance), "ETH");
  console.log(
    "赞助者签名者余额：",
    ethers.formatEther(sponsorBalance),
    "ETH"
  );
}

async function checkDelegationStatus(address = firstSigner.address) {
  console.log("\n=== 正在检查委托状态 ===");

  try {
    // 获取 EOA 地址的代码
    const code = await provider.getCode(address);

    if (code === "0x") {
      console.log(`❌ 未找到 ${address} 的委托`);
      return null;
    }

    // 检查它是否是 EIP-7702 委托 (以 0xef0100 开头)
    if (code.startsWith("0xef0100")) {
      // 提取委托的地址 (删除 0xef0100 前缀)
      const delegatedAddress = "0x" + code.slice(8); // 删除 0xef0100 (8 个字符)

      console.log(`✅ 找到 ${address} 的委托`);
      console.log(`📍 委托给：${delegatedAddress}`);
      console.log(`📝 完整委托代码：${code}`);

      return delegatedAddress;
    } else {
      console.log(`❓ 地址有代码但不是 EIP-7702 委托：${code}`);
      return null;
    }
  } catch (error) {
    console.error("检查委托状态时出错：", error);
    return null;
  }
}

async function createAuthorization(nonce: number) {
  const auth = await firstSigner.authorize({
    address: targetAddress,
    nonce: nonce,
    // chainId: 11155111, // Sepolia 链 ID
  });

  console.log("使用以下 nonce 创建授权：", auth.nonce);
  return auth;
}

async function sendNonSponsoredTransaction() {
  console.log("\n=== 交易 1：非赞助 (ETH 转移) ===");

  const currentNonce = await firstSigner.getNonce();
  console.log("第一个签名者的当前 nonce：", currentNonce);

  // 为同一钱包交易创建具有递增 nonce 的授权
  const auth = await createAuthorization(currentNonce + 1);

  // 准备 ETH 转移的调用
  const calls = [
    // to address, value, data\
    [ethers.ZeroAddress, ethers.parseEther("0.001"), "0x"],
    [recipientAddress, ethers.parseEther("0.002"), "0x"],
  ];

  // 创建合约实例并执行
  const delegatedContract = new ethers.Contract(
    firstSigner.address,
    contractABI,
    firstSigner
  );

  const tx = await delegatedContract["execute((address,uint256,bytes)[])"](
    calls,
    {
      type: 4,
      authorizationList: [auth],
    }
  );

  console.log("已发送非赞助交易：", tx.hash);

  const receipt = await tx.wait();
  console.log("非赞助交易的回执：", receipt);

  return receipt;
}

// 用于为赞助调用创建签名的函数，它在实现合约中是必需的
async function createSignatureForCalls(calls: any[], contractNonce: number) {
  // 对签名调用进行编码
  let encodedCalls = "0x";
  for (const call of calls) {
    const [to, value, data] = call;
    encodedCalls += ethers
      .solidityPacked(["address", "uint256", "bytes"], [to, value, data])
      .slice(2);
  }

  // 创建需要签名的摘要
  const digest = ethers.keccak256(
    ethers.solidityPacked(["uint256", "bytes"], [contractNonce, encodedCalls])
  );

  // 使用 EOA 的私钥签署摘要
  return await firstSigner.signMessage(ethers.getBytes(digest));
}

async function sendSponsoredTransaction() {
    console.log( "\n=== 交易 2：赞助 (合约函数调用) ===" );
    
    const currentNonce = await firstSigner.getNonce();
    console.log("第一个签名者的当前 nonce：", currentNonce);

    // 为同一钱包交易创建具有递增 nonce 的授权
    const auth = await createAuthorization( currentNonce);
  
    // 准备 ERC20 转移调用数据
    const erc20ABI = [
      "function transfer(address to, uint256 amount) external returns (bool)",
    ];
    const erc20Interface = new ethers.Interface(erc20ABI);
  
    const calls = [
      [
        usdcAddress,
        0n,
        erc20Interface.encodeFunctionData("transfer", [
          recipientAddress,
          ethers.parseUnits("0.1", 6), // 0.1 USDC\
        ]),
      ],
    ];
  
    // 为赞助交易创建合约实例
    const delegatedContract = new ethers.Contract(
      firstSigner.address,
      contractABI,
      sponsorSigner
    );
  
    // 获取合约 nonce 并创建签名
    const storage = await provider.getStorage(firstSigner.address, 0)
    const contractNonce = BigInt(storage)
    const signature = await createSignatureForCalls(calls, Number(contractNonce));
  
    await checkUSDCBalance(firstSigner.address, "第一个签名者 (发送者)");
  
    // 执行赞助交易
    const tx = await delegatedContract[
      "execute((address,uint256,bytes)[],bytes)"
    ](calls, signature, {
      type: 4,                   // 重用现有委托。
      authorizationList: [auth], // 不需要新授权或 EIP-7702 类型。
    });
  
    console.log("已发送赞助交易：", tx.hash);
  
    const receipt = await tx.wait();
    console.log("赞助交易的回执：", receipt);
  
    // 交易后检查 USDC 余额
    console.log("\n--- 交易后 USDC 余额 ---");
    await checkUSDCBalance(firstSigner.address, "第一个签名者 (发送者)");
  
    return receipt;
}

async function checkUSDCBalance(address: string, label = "地址") {
    const usdcContract = new ethers.Contract(
      usdcAddress,
      ["function balanceOf(address owner) view returns (uint256)"],
      provider
    );
  
    try {
      const balance = await usdcContract.balanceOf(address);
      const formattedBalance = ethers.formatUnits(balance, 6); // USDC 有 6 位小数
      console.log(`${label} USDC 余额：${formattedBalance} USDC`);
      return balance;
    } catch (error) {
      console.error(`获取 ${label} 的 USDC 余额时出错：`, error);
      return 0n;
    }
}

async function revokeDelegation() {
    console.log("\n=== 正在撤销委托 ===");
  
    const currentNonce = await firstSigner.getNonce();
    console.log("撤销的当前 nonce：", currentNonce);
  
    // 创建授权以撤销 (将地址设置为零地址)
    const revokeAuth = await firstSigner.authorize({
      address: ethers.ZeroAddress, // 零地址以撤销
      nonce: currentNonce + 1,
      // chainId: 11155111,
    });
  
    console.log("已创建撤销授权");
  
    // 发送带有撤销授权的交易
    const tx = await firstSigner.sendTransaction({
      type: 4,
      to: firstSigner.address,
      authorizationList: [revokeAuth],
    });
  
    console.log("已发送撤销交易：", tx.hash);
  
    const receipt = await tx.wait();
    console.log("委托已成功撤销！");
  
    return receipt;
}

async function sendEIP7702Transactions() {
    try {
      // 初始化签名者并获取初始余额
      await initializeSigners();
      await provider.getBalance(firstSigner.address);
      await provider.getBalance(sponsorSigner.address);
  
      // 在开始之前检查委托
      await checkDelegationStatus();
  
    //   // 执行交易
    //   const receipt1 = await sendNonSponsoredTransaction();
  
    //   // 在第一次交易后检查委托
    //   await checkDelegationStatus();
  
        const receipt2 = await sendSponsoredTransaction();
        await checkDelegationStatus();
  
    //   console.log("\n=== 成功 ===");
    //   console.log("两个 EIP-7702 交易均已成功完成！");
    //   console.log("非赞助交易区块：", receipt1.blockNumber);
    //   console.log("赞助交易区块：", receipt2.blockNumber);
  
      // 如果你想在最后撤销委托，请取消注释
    //   await revokeDelegation();
  
    //   return { receipt1, receipt2 };
    } catch (error) {
      console.error("EIP-7702 交易中出错：", error);
      throw error;
    }
}
  
  // 执行主函数
  sendEIP7702Transactions()
    .then(() => {
      console.log("流程已成功完成。");
    })
    .catch((error) => {
      console.error("无法发送 EIP-7702 交易：", error);
    });
