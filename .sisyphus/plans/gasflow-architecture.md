# gasFlow 架构计划

## 项目定位

为无 gas token 的用户提供 EIP-7702 委托式的 gas 赞助服务。用户以稳定币支付手续费，质押者提供 ETH 流动性并获得收益。

## 核心约束

- 用户全程不需要持有 ETH（零 gas token）
- 基于 EIP-7702，保留用户原始 EOA 地址
- 手续费通过链上 gas 实际消耗反算，而非链下预估
- 质押者存入 ETH，获取稳定币收益
- v1 支持 USDC（EIP-2612 permit），USDT 通过免费设置交易支持

---

## 挑战与解决方案

### 挑战 1：Gas 预测准确性

**方案：链上实测 + 缓冲 + 上限签名**

- 合约在执行过程中用 `gasleft()` 记录实际消耗
- 固定开销（auth 处理、合约自身代码）作为确定性常数硬编码
- 费用 =（实际消耗 + 固定开销）× gasPrice × 汇率 + 溢价
- 用户用 EIP-2612 签署一个膨胀的上限金额（实际消耗 × 1.5），合约只扣实际需要的量
- 中继器用 `eth_call` + state override 预先模拟，用于构造 permit 上限参数和判定交易是否值得接

### 挑战 2：中继器 EOA 的 ETH 补偿

**方案：协议控制中继器 + 定期结算**

- `GasFlowStaking.sol` 提供 `withdrawForRelayer(amount)` → 向中继器 EOA 转账 ETH
- 中继器 EOA 是协议运营成本的一部分，由质押池统一提供 gas 资金
- 每笔交易的 USDC 手续费流入质押池
- 定期结算周期：用 USDC 部分回购 ETH 补充池子，部分分配给质押者
- 冷启动：项目方初始质押 5-10 ETH

### 挑战 3：USDT 不支持 EIP-2612

**方案：v1 仅支持 permit 代币 + USDT 免费设置**

- v1 核心支持 USDC、DAI 等有 EIP-2612 permit 的稳定币
- USDT 用户：协议赞助一次免费设置交易（type-0x04 做 approve），之后所有交易无需 ETH
- L2 上设置成本约 $0.10/用户 → 34 笔交易后回本
- L1 上设置成本约 $2-5/用户 → 7-17 笔交易后回本
- 限制：免费设置仅在 L2 上提供

### 挑战 4（额外）：委托持久化副作用

**方案：透明透传 fallback**

- `GasFlowDelegator` 包含 fallback 函数，对未识别的 calldata 透明透传
- 用户委托后仍可正常使用 EOA（转账、approve 等），无需撤销委托

### 挑战 5（额外）：网络拥堵 gas price 尖峰

**方案：宽松 maxFee + 私有 mempool**

- 中继器设置 `maxFeePerGas` = 当前 base fee × 3
- 使用 Flashbots/私有 mempool 提交避免公开 mempool 的价格竞争

---

## 模块清单

### 模块 A：GasFlowDelegator.sol（核心合约）

**职责**：EIP-7702 委托目标，接收用户的交易并执行，计算并扣取 USDC 手续费。

**关键接口**：
```
execute(
    address[] targets,     // 用户的交易目标（一个或多个）
    bytes[] data,           // 对应的 calldata
    address feeToken,       // 支付手续费的稳定币地址
    uint256 maxPermitAmount,// permit 授权的上限金额
    uint256 deadline,       // permit 过期时间
    uint8 v, bytes32 r, bytes32 s  // permit 签名
) external
```

**内部逻辑**：
1. `gasStart = gasleft()`
2. 遍历执行 targets[i].call(data[i])
3. `gasEnd = gasleft()`
4. `userGas = gasStart - gasEnd`
5. `totalGas = userGas + FIXED_OVERHEAD`
6. `fee = (totalGas × tx.gasprice × ethUsdPrice) / usdcUsdPrice + premiumBps`
7. `feeToken.permit(user, this, maxPermitAmount, deadline, v, r, s)`
8. `feeToken.transferFrom(user, feeCollector, fee)`

**依赖**：模块 D（GasFlowOracle）获取 ETH/USD 和 稳定币/USD 价格

**状态**：单个实例，无状态变量（无状态合约），不持有任何资金

---

### 模块 B：GasFlowStaking.sol（质押池）

**职责**：接收质押者的 ETH，提供给中继器作为 gas 资金，分配 USDC 收益。

**关键接口**：
```
stake() external payable              // 质押 ETH
unstake(uint256 shares) external      // 赎回 ETH（有等待期）
withdrawForRelayer(uint256 amount)    // 协议提取 ETH 给中继器
receiveUSDC(uint256 amount)           // 接收用户支付的 USDC 手续费
distributeRewards() external          // 按份额分配 USDC 给质押者
claimRewards() external               // 质押者提取 USDC 收益
```

**设计要点**：
- `withdrawForRelayer` 需要访问控制（onlyOwner 或多签）
- 赎回有等待期（如 7 天）防止闪电贷攻击
- USDC 收益按质押份额（shares 模型）分配
- 每次 `distributeRewards()` 可以同时把部分 USDC 换 ETH 补充池子

**依赖**：无（独立模块）

---

### 模块 C：GasFlowFeeCollector.sol（可选，可合并到 Staking）

**职责**：接收 `transferFrom` 的 USDC 手续费，然后转发到质押池。

**设计**：如果 Staking 和 Delegator 是同一个团队部署的，可以直接让 USDC 转入 Staking 合约，省略中间层。

---

### 模块 D：GasFlowOracle.sol（价格预言机）

**职责**：提供 ETH/USD 和 稳定币/USD 的最新价格，用于手续费计算。

**方案**：
- v1：使用 Chainlink Price Feeds
- 需要两个 feed：ETH/USD（如 `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419`）和 USDC/USD（如 `0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6`）
- 配置 `stalenessThreshold`（如 1 小时）避免使用过期价格
- 添加 `minAnswer` / `maxAnswer` 防护

**依赖**：Chainlink AggregatorV3Interface

---

### 模块 E：Relayer Service（中继器服务）

**职责**：接收用户签名后的交易包，验证、模拟、提交 type-0x04 交易。

**技术栈**：TypeScript（Node.js）+ viem

**API**：
```
POST /api/v1/submit
{
    user: "0x...",            // 用户 EOA 地址
    authorization: {          // EIP-7702 授权签名
        contractAddress, chainId, nonce, yParity, r, s
    },
    multicall: [{ to, data }], // 用户要执行的交易
    permit: {                  // EIP-2612 permit
        token, maxAmount, deadline, v, r, s
    },
    feeToken: "0x..."          // 稳定币地址
}
→ { txHash: "0x..." }
```

**内部流程**：
1. 验证 permit 有效性和代币余额 ≥ 预估最低费用
2. 用 `eth_call` + state override 模拟完整执行
3. 检查模拟结果：无 revert、预估 gas 在可接受范围
4. 构造 type-0x04 交易
5. 用中继器 EOA 的私钥签名并提交
6. 返回 txHash，监控确认

**关键要求**：
- Nonce 管理：同一个用户的多个交易需要串行处理（nonce 递增）
- 并发控制：多个用户的交易可以并行提交
- 余额监控：中继器 ETH 余额低于阈值时自动从质押池提款

---

### 模块 F：gasFlow SDK（客户端 SDK）

**职责**：简化 dApp 集成，隐藏 EIP-7702 授权、EIP-2612 permit 等复杂性。

**技术栈**：TypeScript + viem

**API 设计**：
```typescript
import { createGasFlow } from '@gasflow/sdk';

const gasFlow = createGasFlow({
    relayerUrl: 'https://relayer.gasflow.io',
    chain: arbitrum,
});

// 用户只需要关心这个调用
const txHash = await gasFlow.sendTransaction({
    // 要执行的交易
    transactions: [
        { to: '0xUniswap', data: swapCalldata },
    ],
    // 用哪种稳定币付手续费
    feeToken: 'USDC',  // 或 'USDT', 'DAI'
});
// SDK 内部处理：
//   1. 获取用户 nonce
//   2. 构造 EIP-7702 授权消息 → 让用户签名
//   3. 构造 EIP-2612 permit → 让用户签名
//   4. 把所有签名打包发送给中继器
//   5. 返回 txHash
```

**关键需求**：
- 支持 wagmi / viem 生态
- 自动检测用户是否已委托（避免重复授权）
- 清晰的钱包签名提示（用户看到的是"授权 gasFlow 用 USDC 支付本次 gas 费用"）

---

### 模块 G：前端 Widget（可选，React 组件）

**职责**：可嵌入 dApp 的"用稳定币支付 gas"按钮。

**形态**：
```tsx
<GasFlowButton
    feeToken="USDC"
    transactions={[...]}
    onSuccess={(txHash) => {...}}
/>
```

---

## 开发顺序与依赖关系

```
阶段一（核心合约）          阶段二（质押池）          阶段三（中继器）
┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
│ D: GasFlowOracle │    │ B: GasFlowStaking│    │ E: Relayer       │
│  (无依赖)         │    │  (无依赖)         │    │  (依赖 A, B, D) │
├──────────────────┤    ├──────────────────┤    ├──────────────────┤
│ A: GasFlowDelega-│    │ C: FeeCollector  │    │                  │
│    tor (依赖 D)  │    │  (可选，依赖 B)   │    │                  │
└──────────────────┘    └──────────────────┘    └──────────────────┘
         │                       │                       │
         └───────────────────────┴───────────────────────┘
                                 │
                    阶段四（SDK + 前端）
                    ┌──────────────────┐
                    │ F: SDK           │
                    │  (依赖 E 的 API) │
                    ├──────────────────┤
                    │ G: Widget        │
                    │  (依赖 F)        │
                    └──────────────────┘
```

### 阶段零：环境准备（1-2 天）

- [ ] 初始化 Hardhat/Foundry 项目
- [ ] 配置 Solidity 编译器（0.8.24+，支持 Pectra 操作码）
- [ ] 在 Sepolia/Arbitrum Sepolia 部署开发环境
- [ ] 引入 OpenZeppelin Contracts、Chainlink 接口
- [ ] 搭建 viem + TypeScript 开发环境

### 阶段一：核心合约（5-7 天）

**顺序：先 Oracle，再 Delegator**

| 顺序 | 模块 | 文件 | 说明 |
|---|---|---|---|
| 1 | D | `src/GasFlowOracle.sol` | Chainlink 价格 feed 封装。提供 `getEthUsdPrice()` 和 `getTokenUsdPrice(token)` |
| 2 | D | `test/GasFlowOracle.t.sol` | 测试价格获取、过期检测、边界情况 |
| 3 | A | `src/GasFlowDelegator.sol` | 核心委托合约。`execute()` 函数实现 multicall + gas 计费 + permit 扣款 |
| 4 | A | `test/GasFlowDelegator.t.sol` | 测试：正常执行 → 扣费正确；余额不足 → 回滚；gas 计费准确性；多笔 multicall |

**验证目标**：
- Delegator 在本地测试网上能完成 EIP-7702 委托 → 执行 → 扣费的完整流程
- Gas 计费误差在 ±5% 以内（通过测试测量 FIXED_OVERHEAD 常数）

### 阶段二：质押池（3-4 天）

| 顺序 | 模块 | 文件 | 说明 |
|---|---|---|---|
| 5 | B | `src/GasFlowStaking.sol` | 质押、赎回、中继器提款、收益分配 |
| 6 | B | `test/GasFlowStaking.t.sol` | 测试质押/赎回、份额计算、收益分配公平性 |
| 7 | — | 集成测试 | Delegator 收取的 USDC → 自动流入 Staking |

### 阶段三：中继器服务（7-10 天）

| 顺序 | 模块 | 文件 | 说明 |
|---|---|---|---|
| 8 | E | `relayer/src/server.ts` | Express/Fastify API 服务 |
| 9 | E | `relayer/src/simulate.ts` | eth_call + state override 模拟 |
| 10 | E | `relayer/src/submit.ts` | 构造和提交 type-0x04 交易 |
| 11 | E | `relayer/src/health.ts` | ETH 余额监控、自动提款、nonce 管理 |
| 12 | E | 集成测试 | 端到端：用户签名 → 中继器提交 → 合约执行 → 费用结算 |

**验证目标**：
- 在 Arbitrum Sepolia 上完成 100 笔端到端 gasless 交易
- 零失败率（排除用户余额不足导致的正常回滚）

### 阶段四：SDK + 前端（5-7 天）

| 顺序 | 模块 | 文件 | 说明 |
|---|---|---|---|
| 13 | F | `sdk/src/gasFlow.ts` | SDK 主入口 |
| 14 | F | `sdk/src/authorize.ts` | EIP-7702 授权签名逻辑 |
| 15 | F | `sdk/src/permit.ts` | EIP-2612 授权签名逻辑 |
| 16 | F | `sdk/README.md` | 使用文档 |
| 17 | G | `widget/src/GasFlowButton.tsx` | React 组件 |

### 阶段五：测试与安全（持续）

- [ ] 作恶攻击模拟：空余额、余额不足、代币未授权、超大 gas、重入
- [ ] Gas 消耗分析：测量各路径的实际 gas 消耗
- [ ] 压力测试：并发 1000 用户，中继器吞吐量
- [ ] 安全审计（推荐第三方）：Delegator + Staking 合约

---

## 技术栈

| 层 | 选型 | 原因 |
|---|---|---|
| 智能合约 | Solidity 0.8.24+ | 需要 Pectra 操作码支持 |
| 开发框架 | Foundry | 对 EIP-7702 测试支持最好 |
| 合约库 | OpenZeppelin Contracts 5.x | 标准实现 |
| 预言机 | Chainlink Price Feeds | 成熟稳定 |
| 中继器 | Node.js + TypeScript + viem | viem 对 EIP-7702 支持完善 |
| SDK | TypeScript + viem | 与前端生态兼容 |
| 测试网 | Arbitrum Sepolia | L2 成本低，适合迭代 |

---

## 风险与缓解

| 风险 | 等级 | 缓解 |
|---|---|---|
| 钱包不支持 EIP-7702 签名 | 🔴 高 | SDK 降级方案：polyfill 授权签名 |
| USDC 预言机被操纵 | 🟡 中 | 双预言机 + TWAP + CAPO 上限 |
| 中继器私钥泄露 | 🔴 高 | 中继器 ETH 余额只保留够 1 天用的量 |
| 质押者 ETH/USD 方向性损失 | 🟡 中 | 定期 USDC→ETH 回购；质押者可选择收益币种 |
| 作恶用户空余额攻击 | 🟡 中 | EIP-2612 permit 预校验 + 模拟执行 |
| Circle 竞争 | 🟡 中 | 低费率 + 多稳定币 + 开源差异化 |
