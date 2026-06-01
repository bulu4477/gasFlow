# gasFlow

EIP-7702 委托式的 gas 赞助基础设施。

为无 gas token 的用户提供 gas 赞助，用户以稳定币支付手续费，质押者提供 ETH 流动性并获得收益。

## 核心特性

- 基于 EIP-7702，用户保留原始 EOA 地址
- 零 ETH 交互——用户全程不需要持有原生 gas token
- 双边市场：使用者付稳定币 ↔ 质押者提供 ETH
- 链上 gas 实测计费，非预估
- 支持多种稳定币（USDC、DAI 等）

## 架构计划

详见 [.sisyphus/plans/gasflow-architecture.md](.sisyphus/plans/gasflow-architecture.md)
