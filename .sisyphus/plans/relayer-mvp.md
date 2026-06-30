# GasFlow Relayer MVP

## TL;DR

> **Quick Summary**: Update the existing gasFlowRelayer TypeScript project to work with the new GasFlowDelegator.sol (8-param execute + EIP-2612 permit + Chainlink oracle). MVP scope: single-tx submit, no mempool, no batch bundling. Deployed on Ethereum Sepolia (L1).
>
> **Deliverables**:
> - Updated ABI definitions matching GasFlowDelegator + GasFlowConfig
> - State Override simulation (inject Delegator bytecode at EOA for eth_call)
> - FeeEstimator reading Chainlink feeds → computing maxPermitAmount
> - 5 HTTP endpoints: /submit, /estimate, /status/:txHash, /config, /balance
> - Per-user submission serialization (in-memory mutex)
> - Startup health checks (Config, feeds, delegator bytecode, code hash)
> - TypeScript compiles with zero errors
>
> **Estimated Effort**: Medium (1-2 days)
> **Parallel Execution**: YES - 4 waves
> **Critical Path**: T1(abis) → T5(clients) → T8(simulator) → T9(submitter) → T11(validator) → T12(estimate) → T14(submit) → T17(server) → F1-F4

---

## Context

### Original Request
User asked: "现在合约看起来没什么问题了，我们现在可以着手开始写relayer了，我打算把relayer实现写在D:\TiziGithub\gasFlowRelayer中，先不要开始写，先给我列一个详细的实现路径和清单"

The existing gasFlowRelayer project was written against the OLD BatchCallAndSponsor.sol contract (2-param execute). The contracts have since been completely rewritten to GasFlowDelegator.sol (8-param execute with EIP-2612 permit + Chainlink oracle fees + stake pool compensation).

### Interview Summary
**Key Discussions**:
- Scope: MVP only — single tx submit, no alt mempool, no batch bundling. End-to-end flow must work.
- Target chain: Ethereum Sepolia (L1, l1FeeBps=0)
- Fee estimation: Relayer reads Chainlink feeds independently, computes maxPermitAmount, returns to user for signing
- HTTP API: Full set — /submit + /estimate + /status/{txHash} + /config + /balance
- Language: TypeScript + viem (existing project at D:\TiziGithub\gasFlowRelayer)

**Research Findings**:
- GasFlowDelegator.execute() now has 8 params: calls, signature, feeToken, maxPermitAmount, deadline, v, r, s
- Signature digest changed from encodePacked(nonce, encodedCalls) to abi.encode(block.chainid, nonce, calls)
- GasFlowConfig.sol provides: priceFeeds(), minFeeRateBps()=12000, l1FeeBps()=0, stakePool(), feeTokenDecimals(), relayers() whitelist, paused()
- EIP-2612 permit spender must be address(config) — user signs permit authorizing Config to spend their stablecoin
- State Override needed: inject Delegator RUNTIME bytecode (not the 0xef0100 designation) at EOA address for eth_call simulation
- Delegator nonce lives in EOA storage slot 0 — need state override to read it before first delegation
- EIP-7702 delegation is PERSISTENT — relayer does NOT send authorizationList; assumes user pre-delegated via SDK/wallet

### Metis Review
**Identified Gaps** (addressed):
- EIP-7702 delegation setup ambiguity → Resolved: assume pre-delegated, reject non-delegated EOAs with 400
- State override bytecode distinction (0xef0100 designation vs runtime bytecode) → Guardrail added
- Nonce type must be bigint not number → Guardrail added
- Per-user submission serialization needed → Added as explicit task
- Startup health checks (Config, feeds, code hash) → Added as explicit task
- Pre-submit balance check → Added to submitter task
- Config.paused() periodic check → Added to balance monitor task
- maxPermitAmount needs 5-10% buffer for price staleness → Added to fee estimator
- Fee computation must use BigInt throughout → Guardrail added
- Read priceFeeds from Config, not hardcode → Guardrail added

---

## Work Objectives

### Core Objective
Make the gasFlowRelayer project functional with the new GasFlowDelegator/GasFlowConfig contract interface, supporting the full end-to-end flow: user estimates fee → user signs ECDSA + permit → relayer simulates → relayer submits type-0x04 tx → relayer receives ETH compensation.

### Concrete Deliverables
- `src/contracts/abis.ts` — 4 ABIs: Delegator, Config, Chainlink, ERC20Permit
- `src/types/index.ts` — Extended SubmitRequest + 5 new types
- `src/config.ts` — 6+ new env vars
- `src/services/stateOverride.ts` — State Override constructor (NEW)
- `src/services/feeEstimator.ts` — Chainlink fee estimation (NEW)
- `src/services/startupCheck.ts` — Startup health checks (NEW)
- `src/services/userLock.ts` — Per-user in-memory mutex (NEW)
- `src/services/simulator.ts` — Rewritten with state override + new digest
- `src/services/submitter.ts` — 8-param execute encoding, no authorizationList
- `src/services/clients.ts` — New contract read helpers
- `src/services/validator.ts` — New field validation
- `src/services/nonceManager.ts` — bigint nonce, state override reads
- `src/services/balanceMonitor.ts` — Add Config.paused() check
- `src/routes/estimate.ts` (NEW), `src/routes/status.ts` (NEW), `src/routes/config.ts` (NEW), `src/routes/balance.ts` (NEW)
- `src/routes/submit.ts` — Updated flow
- `src/server.ts` — 5 route registrations
- `.env.example` — Updated env vars

### Definition of Done
- [ ] `npx tsc --noEmit` exits with code 0
- [ ] All 5 HTTP endpoints respond with correct status codes
- [ ] End-to-end flow: estimate → sign → submit → status works on Sepolia

### Must Have
- ABI definitions match GasFlowDelegator.sol and GasFlowConfig.sol exactly
- Signature digest: `keccak256(abi.encode(chainId, nonce, calls))` with `\x19Ethereum Signed Message:\n32` prefix
- State Override simulation injects Delegator RUNTIME bytecode (not 0xef0100 designation)
- Permit spender validated as `address(config)` in request
- All nonce types use `bigint`, never `number`
- Per-user submission serialization (in-memory mutex)
- Pre-submit balance check (reject if relayer ETH < estimated cost × 2)
- Startup health checks: Config address set, feeds non-zero and non-stale, delegator bytecode non-empty, code hash matches
- Read Chainlink feed addresses from `config.priceFeeds()` at runtime, not hardcoded
- maxPermitAmount includes 5-10% buffer above computed fee for price staleness
- Fee computation uses BigInt throughout (no floating point)
- Non-delegated EOAs rejected with HTTP 400 and clear error message
- Config.paused() checked at startup and periodically (60s) — return 503 if paused

### Must NOT Have (Guardrails)
- MUST NOT send `authorizationList` in submitter — delegation is persistent, pre-set by SDK
- MUST NOT use `encodePacked` for digest anywhere — creates signature mismatch with contract
- MUST NOT read `nonce()` via normal `readContract` without state override — reverts on non-delegated EOA
- MUST NOT hardcode Chainlink feed addresses in config — read from `config.priceFeeds()` at runtime
- MUST NOT hardcode `FIXED_GAS_OVERHEAD` in relayer — simulation includes it automatically
- MUST NOT send `value` with the submit transaction — relayer pays gas only
- MUST NOT add `/delegate` or `/undelegate` endpoints — delegation is SDK responsibility
- MUST NOT add alt mempool, batch bundling, P2P networking, Prometheus/Grafana
- MUST NOT add Redis or persistent nonce storage — in-memory only
- MUST NOT add webhook callbacks — polling-only /status endpoint
- MUST NOT add multi-chain support — hardcoded to single chain
- MUST NOT add gas price oracle / dynamic fee adjustment — static maxFeePerGasMultiplier

---

## Verification Strategy (MANDATORY)

> **ZERO HUMAN INTERVENTION** - ALL verification is agent-executed. No exceptions.

### Test Decision
- **Infrastructure exists**: NO (project has zero tests)
- **Automated tests**: None for MVP
- **Framework**: none
- **Agent-Executed QA**: ALWAYS (mandatory for all tasks)

### QA Policy
Every task MUST include agent-executed QA scenarios.
Evidence saved to `.sisyphus/evidence/task-{N}-{scenario-slug}.{ext}`.

- **API endpoints**: Use Bash (curl) - Send requests, assert status + response fields
- **TypeScript compilation**: Use Bash (npx tsc --noEmit) - Assert exit code 0
- **Contract reads**: Use Bash (tsx script) - Import, call functions, compare output
- **Startup checks**: Use Bash (tsx src/index.ts with timeout) - Assert startup logs

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start Immediately - foundation: types, ABIs, config):
├── Task 1: Replace abis.ts with 4 new ABIs [quick]
├── Task 2: Rewrite types/index.ts with new types [quick]
├── Task 3: Update config.ts with new env vars [quick]
└── Task 4: Update .env.example [quick]

Wave 2 (After Wave 1 - core services, MAX PARALLEL):
├── Task 5: Update clients.ts with contract read helpers [quick]
├── Task 6: Create stateOverride.ts (NEW) [quick]
├── Task 7: Create userLock.ts - per-user mutex (NEW) [quick]
├── Task 8: Rewrite simulator.ts with state override + new digest [unspecified-high]
├── Task 9: Rewrite submitter.ts with 8-param execute [unspecified-high]
├── Task 10: Create feeEstimator.ts (NEW) [unspecified-high]
└── Task 11: Create startupCheck.ts (NEW) [quick]

Wave 3 (After Wave 2 - routes + validation):
├── Task 12: Update validator.ts with new field validation [quick]
├── Task 13: Create routes/config.ts (NEW) [quick]
├── Task 14: Create routes/balance.ts (NEW) [quick]
├── Task 15: Create routes/status.ts (NEW) [quick]
├── Task 16: Create routes/estimate.ts (NEW) [unspecified-high]
├── Task 17: Update routes/submit.ts with new flow [unspecified-high]
├── Task 18: Update nonceManager.ts with bigint + state override [quick]
└── Task 19: Update balanceMonitor.ts with Config.paused() check [quick]

Wave 4 (After Wave 3 - integration):
├── Task 20: Update server.ts with all route registrations [quick]
└── Task 21: Verify tsc --noEmit passes [quick]

Wave FINAL (After ALL tasks — 4 parallel reviews):
├── Task F1: Plan compliance audit (oracle)
├── Task F2: Code quality review (unspecified-high)
├── Task F3: Real manual QA (unspecified-high)
└── Task F4: Scope fidelity check (deep)
-> Present results -> Get explicit user okay

Critical Path: T1 → T5 → T8 → T9 → T12 → T16 → T17 → T20 → T21 → F1-F4
Parallel Speedup: ~65% faster than sequential
Max Concurrent: 7 (Wave 2)
```

### Dependency Matrix

| Task | Depends On | Blocks | Wave |
|---|---|---|---|
| 1 (abis) | - | 5,8,9,10,12,16,17 | 1 |
| 2 (types) | - | 5,8,9,10,12,16,17 | 1 |
| 3 (config) | - | 5,6,8,9,10,11,19 | 1 |
| 4 (.env.example) | 3 | - | 1 |
| 5 (clients) | 1,2,3 | 8,9,10,11,18 | 2 |
| 6 (stateOverride) | 1,3 | 8,18 | 2 |
| 7 (userLock) | 2 | 17 | 2 |
| 8 (simulator) | 1,2,5,6 | 16,17 | 2 |
| 9 (submitter) | 1,2,5 | 17 | 2 |
| 10 (feeEstimator) | 1,2,5 | 16 | 2 |
| 11 (startupCheck) | 1,5 | 20 | 2 |
| 12 (validator) | 2,3 | 16,17 | 3 |
| 13 (routes/config) | 1,2,5 | 20 | 3 |
| 14 (routes/balance) | 2,5 | 20 | 3 |
| 15 (routes/status) | 2,5 | 20 | 3 |
| 16 (routes/estimate) | 2,10,12 | 20 | 3 |
| 17 (routes/submit) | 2,7,8,9,12 | 20 | 3 |
| 18 (nonceManager) | 2,5,6 | 17 | 3 |
| 19 (balanceMonitor) | 2,5 | 20 | 3 |
| 20 (server) | 13,14,15,16,17,19 | 21 | 4 |
| 21 (tsc verify) | ALL | F1-F4 | 4 |

### Agent Dispatch Summary

- **Wave 1**: **4** - T1-T4 → `quick`
- **Wave 2**: **7** - T5-T7,T11 → `quick`, T8-T10 → `unspecified-high`
- **Wave 3**: **8** - T12-T15,T18-T19 → `quick`, T16-T17 → `unspecified-high`
- **Wave 4**: **2** - T20-T21 → `quick`
- **FINAL**: **4** - F1 → `oracle`, F2-F3 → `unspecified-high`, F4 → `deep`

---

## TODOs

- [x] 1. Replace abis.ts with 4 new ABIs

  **What to do**:
  - Delete `batchCallAndSponsorAbi` and `erc20Abi` (old)
  - Add `gasFlowDelegatorAbi`: `execute(Call[],bytes,address,uint256,uint256,uint8,bytes32,bytes32)`, `nonce()`, `config()`, events `CallExecuted`, `BatchExecuted`, `FeeCollected`
  - Add `gasFlowConfigAbi`: `priceFeeds(address)→(address,address)`, `minFeeRateBps()`, `l1FeeBps()`, `stakePool()`, `feeTokenDecimals(address)`, `relayers(address)`, `paused()`, `delegatorCodeHash()`
  - Add `chainlinkAggregatorAbi`: `latestRoundData()→(uint80,int256,uint256,uint256,uint80)`
  - Add `erc20PermitAbi`: `permit(address,address,uint256,uint256,uint8,bytes32,bytes32)`, `balanceOf()`, `allowance()`, `decimals()`, `nonces(address)`, `DOMAIN_SEPARATOR()`
  - Use viem `parseAbi` or human-readable ABI format for type safety
  - Export `Call` tuple type for reuse: `[{ to: address, value: uint256, data: bytes }]`

  **Must NOT do**:
  - Do NOT import ABI from JSON artifacts — use human-readable format
  - Do NOT include admin/owner functions in Config ABI (only read + processCompensation)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Single-file ABI definition, mechanical work, no complex logic
  - **Skills**: []
  - **Skills Evaluated but Omitted**: none

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 2, 3, 4)
  - **Blocks**: Tasks 5, 8, 9, 10, 12, 16, 17
  - **Blocked By**: None

  **References**:

  **Pattern References** (existing code to follow):
  - `D:\TiziGithub\gasFlowRelayer\src\contracts\abis.ts` — Current file structure (human-readable format, `as const`)

  **API/Type References** (contracts to implement against):
  - `D:\TiziGithub\gasFlow\contracts\GasFlowDelegator.sol:154-211` — execute() signature with 8 params + events (CallExecuted, BatchExecuted, FeeCollected)
  - `D:\TiziGithub\gasFlow\contracts\GasFlowDelegator.sol:87-96` — config(), nonce(), FIXED_GAS_OVERHEAD
  - `D:\TiziGithub\gasFlow\contracts\GasFlowConfig.sol:93-95` — priceFeeds(address)→(address,address)
  - `D:\TiziGithub\gasFlow\contracts\GasFlowConfig.sol:50-67` — stakePool(), delegatorCodeHash(), ethUsdFeed(), tokenUsdFeeds(), feeTokenDecimals(), relayers(), minFeeRateBps(), l1FeeBps()
  - `D:\TiziGithub\gasFlow\contracts\GasFlowConfig.sol:170-199` — processCompensation() signature

  **External References**:
  - viem human-readable ABI: `https://viem.sh/docs/contracts/contract-abis#human-readable-abis`

  **WHY Each Reference Matters**:
  - GasFlowDelegator.sol execute() — exact 8-param signature must match for encoding
  - GasFlowConfig.sol — read-only functions for price feeds and fee rates
  - Chainlink AggregatorV3Interface — latestRoundData return types for price reading
  - EIP-2612 permit — 7-param signature including v/r/s

  **Acceptance Criteria**:
  - [ ] File `src/contracts/abis.ts` contains 4 exported ABI arrays: `gasFlowDelegatorAbi`, `gasFlowConfigAbi`, `chainlinkAggregatorAbi`, `erc20PermitAbi`
  - [ ] No references to `batchCallAndSponsorAbi` remain in the file
  - [ ] `gasFlowDelegatorAbi` includes `execute` with exactly 8 parameters

  **QA Scenarios**:
  ```
  Scenario: TypeScript compiles with new ABIs
    Tool: Bash (npx tsc)
    Preconditions: abis.ts written, no other files changed yet
    Steps:
      1. Run `npx tsc --noEmit` in D:\TiziGithub\gasFlowRelayer
      2. Check exit code
    Expected Result: Exit code 0 OR only errors from OTHER files (not abis.ts)
    Failure Indicators: Errors mentioning abis.ts (syntax, type, parse errors)
    Evidence: .sisyphus/evidence/task-1-tsc-check.txt

  Scenario: ABI includes execute with 8 params
    Tool: Bash (tsx)
    Preconditions: abis.ts written
    Steps:
      1. Run `tsx -e "import { gasFlowDelegatorAbi } from './src/contracts/abis'; const exec = gasFlowDelegatorAbi.find(i => i.name === 'execute'); console.log(exec?.inputs.length)"` in gasFlowRelayer
      2. Check output
    Expected Result: Output is "8"
    Failure Indicators: Output is not "8", or "undefined", or import fails
    Evidence: .sisyphus/evidence/task-1-abi-param-count.txt
  ```

  **Commit**: YES (groups with 2, 3, 4)
  - Message: `feat(relayer): update ABIs, types, and config for GasFlowDelegator interface`
  - Files: `src/contracts/abis.ts`
  - Pre-commit: `npx tsc --noEmit`

- [x] 2. Rewrite types/index.ts with new types

  **What to do**:
  - Keep `Call` interface (to, value: bigint, data: Hex)
  - Remove `Authorization` interface (EIP-7702 auth is NOT sent by relayer — delegation is pre-set)
  - Modify `SubmitRequest`: remove `authorization`, add `feeToken: Address` (required), `maxPermitAmount: bigint`, `deadline: bigint`, `permitV: number`, `permitR: Hex`, `permitS: Hex`
  - Keep `SimulationResult` (success, gasUsed: bigint, error?: string)
  - Add `EstimateRequest`: `{ user: Address, calls: Call[], feeToken: Address }`
  - Add `EstimateResponse`: `{ nonce: bigint, gasEstimate: bigint, maxPermitAmount: bigint, feeToken: Address, feeTokenDecimals: number, deadline: bigint, configAddress: Address, digest: Hex }`
  - Add `StatusResponse`: `{ status: 'pending'|'confirmed'|'failed', blockNumber?: bigint, gasUsed?: bigint, error?: string }`
  - Add `ConfigResponse`: `{ chainId: number, delegatorAddress: Address, configAddress: Address, stakePoolAddress: Address, supportedFeeTokens: Address[], minFeeRateBps: bigint, l1FeeBps: bigint }`
  - Add `BalanceResponse`: `{ relayerAddress: Address, ethBalance: bigint, minBalance: bigint }`
  - Modify `UserState`: change `lastKnownNonce` to `bigint` (was `number`), change `pendingTxHashes` to `Hash[]`
  - Remove `SubmitResponse` (submit now returns `{ txHash: Hash, gasEstimate: bigint }`)

  **Must NOT do**:
  - Do NOT use `number` for any nonce or monetary value — use `bigint`
  - Do NOT include `authorization` in SubmitRequest

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Type definitions only, no logic, mechanical work
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 1, 3, 4)
  - **Blocks**: Tasks 5, 8, 9, 10, 12, 16, 17
  - **Blocked By**: None

  **References**:

  **Pattern References**:
  - `D:\TiziGithub\gasFlowRelayer\src\types\index.ts` — Current file, keep Call/SimulationResult/UserState structure

  **API/Type References**:
  - `D:\TiziGithub\gasFlow\contracts\GasFlowDelegator.sol:154-163` — execute() params map to SubmitRequest fields
  - `D:\TiziGithub\gasFlow\contracts\GasFlowConfig.sol:93-95` — priceFeeds return type

  **WHY Each Reference Matters**:
  - Delegator execute() signature directly determines SubmitRequest fields
  - bigint is required because Solidity uint256 exceeds JS number safe range (2^53)

  **Acceptance Criteria**:
  - [ ] `SubmitRequest` has fields: user, calls, signature, feeToken, maxPermitAmount, deadline, permitV, permitR, permitS (NO authorization)
  - [ ] All nonce/monetary fields use `bigint`
  - [ ] 5 new types exported: EstimateRequest, EstimateResponse, StatusResponse, ConfigResponse, BalanceResponse

  **QA Scenarios**:
  ```
  Scenario: Types compile without errors
    Tool: Bash (npx tsc)
    Preconditions: types/index.ts written
    Steps:
      1. Run `npx tsc --noEmit` in gasFlowRelayer
      2. Check for errors in types/index.ts specifically
    Expected Result: No errors originating from types/index.ts
    Failure Indicators: "Type ... is not defined" or "Cannot find name" in types/index.ts
    Evidence: .sisyphus/evidence/task-2-tsc-check.txt

  Scenario: SubmitRequest has no authorization field
    Tool: Bash (grep)
    Preconditions: types/index.ts written
    Steps:
      1. Run `Select-String -Path "src/types/index.ts" -Pattern "authorization"` in gasFlowRelayer
      2. Check output
    Expected Result: No matches found
    Failure Indicators: Any line matching "authorization" in types/index.ts
    Evidence: .sisyphus/evidence/task-2-no-auth.txt
  ```

  **Commit**: YES (groups with 1, 3, 4)
  - Message: `feat(relayer): update ABIs, types, and config for GasFlowDelegator interface`
  - Files: `src/types/index.ts`

- [x] 3. Update config.ts with new env vars

  **What to do**:
  - Remove `delegationContractAddress` (old name)
  - Add `DELEGATOR_CONTRACT_ADDRESS` — GasFlowDelegator deployed address (for state override bytecode source)
  - Add `CONFIG_CONTRACT_ADDRESS` — GasFlowConfig deployed address (for reading config + permit spender)
  - Add `STAKE_POOL_ADDRESS` — GasFlowStakeVault deployed address (for /config endpoint)
  - Add `SUPPORTED_FEE_TOKENS` — comma-separated list of supported stablecoin addresses
  - Add `PERMIT_DEADLINE_SECONDS` — default 1800 (30 min)
  - Add `GAS_ESTIMATE_MARGIN_BPS` — default 12000 (120% safety margin on gas estimate)
  - Add `FEE_AMOUNT_MARGIN_BPS` — default 11000 (110% — 10% buffer on maxPermitAmount for price staleness)
  - Keep: `RELAYER_PRIVATE_KEY`, `RPC_URL`, `CHAIN_ID`, `PORT`, `MIN_RELAYER_BALANCE`, `MAX_FEE_PER_GAS_MULTIPLIER`, `PRIORITY_FEE`, `MAX_BATCH_SIZE`, `SIMULATION_TIMEOUT_MS`
  - Parse `SUPPORTED_FEE_TOKENS` into `Address[]` array
  - All monetary values as `bigint`

  **Must NOT do**:
  - Do NOT hardcode Chainlink feed addresses — read from Config at runtime
  - Do NOT remove existing env vars that are still used

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Config file, mechanical env var parsing
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 1, 2, 4)
  - **Blocks**: Tasks 5, 6, 8, 9, 10, 11, 19
  - **Blocked By**: None

  **References**:

  **Pattern References**:
  - `D:\TiziGithub\gasFlowRelayer\src\config.ts` — Current file, keep requireEnv pattern

  **WHY Each Reference Matters**:
  - Current config.ts shows the requireEnv helper pattern to follow

  **Acceptance Criteria**:
  - [ ] `config` object has: delegatorAddress, configAddress, stakePoolAddress, supportedFeeTokens (Address[]), permitDeadlineSeconds, gasEstimateMarginBps, feeAmountMarginBps
  - [ ] No reference to `delegationContractAddress` remains
  - [ ] `SUPPORTED_FEE_TOKENS` parsed into Address[] array

  **QA Scenarios**:
  ```
  Scenario: Config loads with all new env vars
    Tool: Bash (tsx)
    Preconditions: config.ts written, .env file exists with all vars set
    Steps:
      1. Run `tsx -e "import { config } from './src/config'; console.log(typeof config.configAddress, typeof config.delegatorAddress, config.supportedFeeTokens.length)"` in gasFlowRelayer
      2. Check output
    Expected Result: Output "string string" and a number > 0
    Failure Indicators: "undefined" for any field, or "0" for supportedFeeTokens.length
    Evidence: .sisyphus/evidence/task-3-config-load.txt

  Scenario: Missing env var causes clear error
    Tool: Bash (tsx)
    Preconditions: config.ts written, .env with CONFIG_CONTRACT_ADDRESS unset
    Steps:
      1. Run `$env:CONFIG_CONTRACT_ADDRESS=''; npx tsx -e "import { config } from './src/config'"` in gasFlowRelayer
      2. Check error output
    Expected Result: Error message containing "Missing required env variable: CONFIG_CONTRACT_ADDRESS"
    Failure Indicators: No error, or error message doesn't mention the env var name
    Evidence: .sisyphus/evidence/task-3-missing-env.txt
  ```

  **Commit**: YES (groups with 1, 2, 4)
  - Message: `feat(relayer): update ABIs, types, and config for GasFlowDelegator interface`
  - Files: `src/config.ts`

- [x] 4. Update .env.example

  **What to do**:
  - Remove `DELEGATION_CONTRACT_ADDRESS` (old)
  - Add all new env vars from Task 3 with example values:
    - `DELEGATOR_CONTRACT_ADDRESS=0x...` (GasFlowDelegator)
    - `CONFIG_CONTRACT_ADDRESS=0x...` (GasFlowConfig)
    - `STAKE_POOL_ADDRESS=0x...` (GasFlowStakeVault)
    - `SUPPORTED_FEE_TOKENS=0xUSDC_SEPOLIA,0xUSDT_SEPOLIA` (comma-separated)
    - `PERMIT_DEADLINE_SECONDS=1800`
    - `GAS_ESTIMATE_MARGIN_BPS=12000`
    - `FEE_AMOUNT_MARGIN_BPS=11000`
  - Update comments to reflect new contract names
  - Update RPC_URL example to Sepolia: `https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY`
  - Update CHAIN_ID to `11155111` (Sepolia)

  **Must NOT do**:
  - Do NOT include real private keys or API keys

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Documentation file, no logic
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 1, 2, 3)
  - **Blocks**: None
  - **Blocked By**: Task 3 (for env var names consistency)

  **References**:
  - `D:\TiziGithub\gasFlowRelayer\.env.example` — Current file structure
  - Task 3 output — env var names must match exactly

  **Acceptance Criteria**:
  - [ ] All 7 new env vars present with example values
  - [ ] No `DELEGATION_CONTRACT_ADDRESS` (old name)
  - [ ] CHAIN_ID = 11155111

  **QA Scenarios**:
  ```
  Scenario: .env.example has all new vars
    Tool: Bash (grep)
    Preconditions: .env.example written
    Steps:
      1. Run `Select-String -Path ".env.example" -Pattern "CONFIG_CONTRACT_ADDRESS|DELEGATOR_CONTRACT_ADDRESS|STAKE_POOL_ADDRESS|SUPPORTED_FEE_TOKENS|PERMIT_DEADLINE_SECONDS|GAS_ESTIMATE_MARGIN_BPS|FEE_AMOUNT_MARGIN_BPS"` in gasFlowRelayer
      2. Count matches
    Expected Result: 7 matches
    Failure Indicators: Fewer than 7 matches
    Evidence: .sisyphus/evidence/task-4-env-vars.txt
  ```

  **Commit**: YES (groups with 1, 2, 3)
  - Message: `feat(relayer): update ABIs, types, and config for GasFlowDelegator interface`
  - Files: `.env.example`

- [x] 5. Update clients.ts with contract read helpers

  **What to do**:
  - Keep `getPublicClient()`, `getWalletClient()`, `getRelayerAddress()`
  - Replace `getContractNonce(user)` with `getDelegatorNonce(user, stateOverride?)` — reads nonce via `eth_call` with state override if EOA not yet delegated
  - Add `getDelegatorRuntimeBytecode()` — `eth_getCode(config.delegatorAddress)`, cache result in module-level variable
  - Add `readConfig(field)` — generic helper to read GasFlowConfig view functions: `priceFeeds(token)`, `minFeeRateBps()`, `l1FeeBps()`, `stakePool()`, `feeTokenDecimals(token)`, `relayers(addr)`, `paused()`, `delegatorCodeHash()`
  - Add `readChainlinkPrice(feedAddress)` — calls `latestRoundData()`, returns `{ price: bigint, updatedAt: bigint }`
  - Add `checkDelegationStatus(user)` — `eth_getCode(user)`, returns `true` if code starts with `0xef0100` (EIP-7702 delegation prefix)
  - Add `getEoaTxNonce(user)` — `eth_getTransactionCount(user, 'pending')` for EIP-7702 auth nonce (not needed for submit but for /estimate)
  - Use `gasFlowConfigAbi` and `chainlinkAggregatorAbi` from Task 1

  **Must NOT do**:
  - Do NOT call `readContract({ address: user, functionName: 'nonce' })` without state override — reverts on non-delegated EOA
  - Do NOT hardcode Chainlink feed addresses — read from Config

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Client helper functions, no complex logic, follows existing pattern
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 6, 7, 8, 9, 10, 11)
  - **Blocks**: Tasks 8, 9, 10, 11, 18
  - **Blocked By**: Tasks 1, 2, 3

  **References**:

  **Pattern References**:
  - `D:\TiziGithub\gasFlowRelayer\src\services\clients.ts` — Current singleton pattern for publicClient/walletClient
  - `D:\TiziGithub\gasFlowRelayer\src\services\clients.ts:38-47` — getContractNonce pattern (replace with state override version)

  **API/Type References**:
  - `D:\TiziGithub\gasFlow\contracts\GasFlowConfig.sol:50-67` — All read functions to expose
  - `D:\TiziGithub\gasFlow\contracts\GasFlowDelegator.sol:87-96` — nonce(), config()

  **External References**:
  - viem state override: `https://viem.sh/docs/actions/public/call#state-override`

  **WHY Each Reference Matters**:
  - Current clients.ts shows singleton + readContract pattern to extend
  - GasFlowConfig read functions determine what helpers to create
  - State override docs show the viem API for injecting bytecode

  **Acceptance Criteria**:
  - [ ] `getDelegatorRuntimeBytecode()` returns cached non-empty Hex
  - [ ] `readConfig` helper reads all Config view functions
  - `readChainlinkPrice()` returns `{ price: bigint, updatedAt: bigint }`
  - [ ] `checkDelegationStatus(user)` returns boolean
  - [ ] No `getContractNonce` without state override support

  **QA Scenarios**:
  ```
  Scenario: Delegator bytecode fetched and cached
    Tool: Bash (tsx)
    Preconditions: clients.ts written, .env has valid DELEGATOR_CONTRACT_ADDRESS on Sepolia
    Steps:
      1. Run `npx tsx -e "import { getDelegatorRuntimeBytecode } from './src/services/clients'; const code = await getDelegatorRuntimeBytecode(); console.log(code.length > 4)"` in gasFlowRelayer
      2. Check output
    Expected Result: "true" (bytecode is longer than just 0x prefix)
    Failure Indicators: "false", "undefined", or error
    Evidence: .sisyphus/evidence/task-5-bytecode.txt

  Scenario: checkDelegationStatus returns false for non-delegated EOA
    Tool: Bash (tsx)
    Preconditions: clients.ts written, use a known non-delegated address (e.g. 0x0000000000000000000000000000000000000001)
    Steps:
      1. Run `npx tsx -e "import { checkDelegationStatus } from './src/services/clients'; const r = await checkDelegationStatus('0x0000000000000000000000000000000000000001'); console.log(r)"` in gasFlowRelayer
      2. Check output
    Expected Result: "false"
    Failure Indicators: "true" or error
    Evidence: .sisyphus/evidence/task-5-delegation-check.txt
  ```

  **Commit**: YES (groups with 6, 7, 8, 9, 10, 11)
  - Message: `feat(relayer): implement state override, fee estimator, and core services`
  - Files: `src/services/clients.ts`

- [x] 6. Create stateOverride.ts (NEW)

  **What to do**:
  - Create `src/services/stateOverride.ts`
  - `buildStateOverride(user, delegatorBytecode, nonce?)` → returns viem `StateOverride` object:
    ```typescript
    { [user]: { code: delegatorBytecode, stateDiff: nonce !== undefined ? { '0x0000000000000000000000000000000000000000000000000000000000000000': toHex(nonce) } : undefined } }
    ```
  - `getDelegatorBytecode()` — calls `clients.getDelegatorRuntimeBytecode()`, caches in module variable
  - IMPORTANT: The `code` field must be the Delegator's RUNTIME bytecode (full contract code from `eth_getCode`), NOT the `0xef0100 || delegatorAddress` designation (23 bytes). These are DIFFERENT.
  - For reading nonce via state override: use `publicClient.call({ to: user, data: encodeFunctionData({ abi: gasFlowDelegatorAbi, functionName: 'nonce' }), stateOverride: buildStateOverride(user, bytecode) })`

  **Must NOT do**:
  - Do NOT use `0xef0100 || address` as the code — this is the delegation designation, not runtime bytecode
  - Do NOT cache bytecode forever without invalidation — cache once at startup is fine for MVP

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Utility module, straightforward object construction
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 5, 7, 8, 9, 10, 11)
  - **Blocks**: Tasks 8, 18
  - **Blocked By**: Tasks 1, 3

  **References**:

  **Pattern References**:
  - `D:\TiziGithub\gasFlowRelayer\src\services\clients.ts` — Module-level caching pattern (publicClient singleton)

  **External References**:
  - viem state override: `https://viem.sh/docs/actions/public/call#state-override` — StateOverride type definition
  - EIP-7702 delegation designation: `0xef0100 || address` (23 bytes) vs runtime bytecode (full)

  **WHY Each Reference Matters**:
  - viem StateOverride type shows exact structure needed
  - The 0xef0100 vs runtime bytecode distinction is CRITICAL — using the wrong one silently produces incorrect simulation results

  **Acceptance Criteria**:
  - [ ] `buildStateOverride` returns object with `code` field set to runtime bytecode (length > 100 chars)
  - [ ] `stateDiff` only set when nonce parameter is provided
  - [ ] Bytecode cached after first fetch

  **QA Scenarios**:
  ```
  Scenario: State override has runtime bytecode not designation
    Tool: Bash (tsx)
    Preconditions: stateOverride.ts written, .env valid
    Steps:
      1. Run `npx tsx -e "import { buildStateOverride, getDelegatorBytecode } from './src/services/stateOverride'; const bc = await getDelegatorBytecode(); const so = buildStateOverride('0x0000000000000000000000000000000000000001', bc); console.log(so['0x0000000000000000000000000000000000000001'].code.length > 100)"` in gasFlowRelayer
      2. Check output
    Expected Result: "true" (runtime bytecode is hundreds of bytes, not 23)
    Failure Indicators: "false" (would indicate using 0xef0100 designation instead)
    Evidence: .sisyphus/evidence/task-6-state-override.txt
  ```

  **Commit**: YES (groups with 5, 7, 8, 9, 10, 11)
  - Message: `feat(relayer): implement state override, fee estimator, and core services`
  - Files: `src/services/stateOverride.ts`

- [x] 7. Create userLock.ts - per-user mutex (NEW)

  **What to do**:
  - Create `src/services/userLock.ts`
  - Implement in-memory per-user async mutex using `Map<Address, Promise<void>>`
  - `acquireUserLock(user: Address): Promise<() => void>` — returns a release function
  - Pattern: if user has pending lock, await it; create new lock; return release function
  - Used by routes/submit.ts to serialize concurrent submissions for the same user (prevents nonce collision)

  **Must NOT do**:
  - Do NOT use external libraries (no `async-mutex` package) — std lib only
  - Do NOT add timeout — the lock is released by the submit handler

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Small utility, well-known mutex pattern, ~20 lines
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 5, 6, 8, 9, 10, 11)
  - **Blocks**: Task 17
  - **Blocked By**: Task 2

  **References**:

  **Pattern References**:
  - JavaScript Promise-based mutex pattern (standard)

  **WHY Each Reference Matters**:
  - Standard async mutex pattern: `const next = prev.then(() => new Promise(release => resolver = release))`

  **Acceptance Criteria**:
  - [ ] `acquireUserLock` returns a release function
  - [ ] Concurrent calls for same user are serialized (second waits for first to release)
  - [ ] Different users are NOT blocked by each other

  **QA Scenarios**:
  ```
  Scenario: Concurrent locks for same user are serialized
    Tool: Bash (tsx)
    Preconditions: userLock.ts written
    Steps:
      1. Run a tsx script that: acquires lock for 0xAAA, sets a timer, acquires lock for 0xAAA again, measures time between
      2. The second acquire should wait until the first releases
    Expected Result: Second lock acquired AFTER first released (time difference > timer duration)
    Failure Indicators: Both locks acquired simultaneously (time difference < timer duration)
    Evidence: .sisyphus/evidence/task-7-lock-serialization.txt

  Scenario: Different users not blocked
    Tool: Bash (tsx)
    Preconditions: userLock.ts written
    Steps:
      1. Run a tsx script that: acquires lock for 0xAAA, immediately acquires lock for 0xBBB, measures time
    Expected Result: Second lock acquired immediately (no waiting)
    Failure Indicators: Second lock waits for first
    Evidence: .sisyphus/evidence/task-7-different-users.txt
  ```

  **Commit**: YES (groups with 5, 6, 8, 9, 10, 11)
  - Message: `feat(relayer): implement state override, fee estimator, and core services`
  - Files: `src/services/userLock.ts`

- [x] 8. Rewrite simulator.ts with state override + new digest

  **What to do**:
  - **Rewrite `simulateTransaction(user, calls, feeToken, maxPermitAmount, deadline, permitV, permitR, permitS)`**:
    - Build state override: inject Delegator runtime bytecode at `user` address (via `stateOverride.buildStateOverride`)
    - Encode `execute(calls, signature, feeToken, maxPermitAmount, deadline, v, r, s)` using `gasFlowDelegatorAbi`
    - For simulation, use placeholder signature (65 bytes of zeros) and valid permit params — we only care if batch calls revert
    - Use `publicClient.call({ to: user, data, stateOverride })` instead of `estimateContractGas`
    - Estimate gas via `publicClient.estimateGas({ to: user, data, stateOverride, account: relayer })`
    - Return `{ success: boolean, gasEstimate: bigint, error?: string }`
  - **Rewrite `verifySignature(user, calls, nonce, signature)`**:
    - Compute digest: `keccak256(encodeAbiParameters([{name:'uint256',type:'uint256'},{name:'uint256',type:'uint256'},{name:'Call[]',type:'tuple[]',components:[...]}], [BigInt(chainId), nonce, calls]))`
    - Wrap with `toEthSignedMessageHash` equivalent: use viem `hashMessage({ raw: digest })` or manually prefix `\x19Ethereum Signed Message:\n32`
    - Recover address via `recoverAddress({ hash: ethSignedHash, signature })`
    - Compare recovered === user
    - Nonce must be passed in (from caller, who got it via state override read)
  - **Remove** `encodeCallsForDigest` and `computeDigest` (old encodePacked versions)
  - **Add** `encodeCallsForAbiEncode(calls)` — helper to format calls as ABI tuple for digest
  - Add `estimateGas(user, calls, feeToken)` — standalone gas estimation for /estimate endpoint (uses placeholder permit params)

  **Must NOT do**:
  - Do NOT use `encodePacked` anywhere in digest — contract uses `abi.encode`
  - Do NOT use `estimateContractGas` with old 2-param execute
  - Do NOT read nonce via `readContract` without state override

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Complex logic — state override construction, ABI encoding for digest, gas estimation with override. Core correctness-critical module.
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 5, 6, 7, 9, 10, 11)
  - **Blocks**: Tasks 16, 17
  - **Blocked By**: Tasks 1, 2, 5, 6

  **References**:

  **Pattern References**:
  - `D:\TiziGithub\gasFlowRelayer\src\services\simulator.ts` — Current file structure (keep function names where possible)

  **API/Type References**:
  - `D:\TiziGithub\gasFlow\contracts\GasFlowDelegator.sol:245-253` — _verifySignature: `keccak256(abi.encode(block.chainid, nonce, calls))` + `toEthSignedMessageHash`
  - `D:\TiziGithub\gasFlow\contracts\GasFlowDelegator.sol:102-106` — Call struct: `{ address to, uint256 value, bytes data }`
  - `D:\TiziGithub\gasFlow\contracts\GasFlowDelegator.sol:154-163` — execute() 8-param signature for encoding

  **External References**:
  - viem `encodeAbiParameters`: `https://viem.sh/docs/contract/encodeAbiParameters`
  - viem `hashMessage`: `https://viem.sh/docs/utilities/hashMessage`
  - viem `recoverAddress`: `https://viem.sh/docs/utilities/recoverAddress`
  - viem `call` with stateOverride: `https://viem.sh/docs/actions/public/call`

  **WHY Each Reference Matters**:
  - Delegator _verifySignature shows exact digest formula — must match exactly or signatures won't verify
  - Call struct definition needed for ABI encoding of calls array in digest
  - viem encodeAbiParameters is the equivalent of Solidity's abi.encode

  **Acceptance Criteria**:
  - [ ] `simulateTransaction` uses `publicClient.call` with `stateOverride`, NOT `estimateContractGas`
  - [ ] Digest computed as `keccak256(abi.encode(chainId, nonce, calls))` with Ethereum signed message prefix
  - [ ] No `encodePacked` anywhere in the file
  - [ ] `verifySignature` takes `nonce: bigint` parameter (not reading it internally)

  **QA Scenarios**:
  ```
  Scenario: Digest matches contract formula
    Tool: Bash (tsx)
    Preconditions: simulator.ts written
    Steps:
      1. Run a tsx script that computes digest for chainId=11155111, nonce=0n, calls=[{to:'0x'+'1'.repeat(40), value:0n, data:'0x'}]
      2. Compare against known expected hash (precomputed from Solidity)
    Expected Result: Digest matches the Solidity abi.encode(chainId, nonce, calls) + toEthSignedMessageHash output
    Failure Indicators: Digest differs — indicates wrong encoding (e.g., encodePacked used)
    Evidence: .sisyphus/evidence/task-8-digest-match.txt

  Scenario: Simulation with state override works on non-delegated EOA
    Tool: Bash (tsx)
    Preconditions: simulator.ts written, .env valid, use a non-delegated test address
    Steps:
      1. Call simulateTransaction with a simple call (transfer 0 ETH to self) and state override
      2. Check it doesn't revert with "no code at address"
    Expected Result: Returns { success: true, gasEstimate: <non-zero bigint> } or a meaningful revert from the Delegator logic
    Failure Indicators: Revert with "no code" or similar — indicates state override not applied correctly
    Evidence: .sisyphus/evidence/task-8-simulation-override.txt
  ```

  **Commit**: YES (groups with 5, 6, 7, 9, 10, 11)
  - Message: `feat(relayer): implement state override, fee estimator, and core services`
  - Files: `src/services/simulator.ts`

- [x] 9. Rewrite submitter.ts with 8-param execute

  **What to do**:
  - **Rewrite `submitTransaction(request, gasEstimate)`**:
    - Encode `execute(calls, signature, feeToken, maxPermitAmount, deadline, v, r, s)` using `gasFlowDelegatorAbi` and `encodeFunctionData`
    - Build transaction with `to: request.user` (the EOA, NOT a contract address)
    - Do NOT include `authorizationList` — delegation is persistent, pre-set by SDK
    - Set `gas: gasEstimate * config.gasEstimateMarginBps / 10000n` (120% safety margin)
    - Set `maxFeePerGas` and `maxPriorityFeePerGas` from config
    - Use `walletClient.sendTransaction({ to, data, gas, maxFeePerGas, maxPriorityFeePerGas, chain, account })`
  - **Add pre-submit balance check**: before sending, check `relayerBalance >= gasEstimate * maxFeePerGas * 2`. If insufficient, throw `{ statusCode: 503, message: "Insufficient relayer balance" }`
  - **Keep** `waitForConfirmation(txHash)` — unchanged
  - Return `{ txHash: Hash, gasEstimate: bigint }`

  **Must NOT do**:
  - Do NOT include `authorizationList` in the transaction
  - Do NOT send `value` with the transaction (no ETH to user EOA)
  - Do NOT hardcode `FIXED_GAS_OVERHEAD` — gas estimate from simulation already includes it

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Core transaction construction, gas calculation, balance checks. Correctness-critical.
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 5, 6, 7, 8, 10, 11)
  - **Blocks**: Task 17
  - **Blocked By**: Tasks 1, 2, 5

  **References**:

  **Pattern References**:
  - `D:\TiziGithub\gasFlowRelayer\src\services\submitter.ts` — Current file, keep sendTransaction pattern but change params

  **API/Type References**:
  - `D:\TiziGithub\gasFlow\contracts\GasFlowDelegator.sol:154-163` — execute() 8-param signature
  - `D:\TiziGithub\gasFlow\contracts\GasFlowDelegator.sol:217-218` — fallback/receive (explains why tx to EOA works)

  **External References**:
  - viem `sendTransaction`: `https://viem.sh/docs/actions/wallet/sendTransaction`
  - viem `encodeFunctionData`: `https://viem.sh/docs/contract/encodeFunctionData`

  **WHY Each Reference Matters**:
  - Delegator execute() signature determines encodeFunctionData args
  - Current submitter shows the sendTransaction pattern to adapt (remove authorizationList)

  **Acceptance Criteria**:
  - [ ] `submitTransaction` encodes 8 params via `encodeFunctionData`
  - [ ] No `authorizationList` in the transaction object
  - [ ] Pre-submit balance check throws 503 if insufficient
  - [ ] `gas` field set with safety margin applied

  **QA Scenarios**:
  ```
  Scenario: Transaction data encodes 8-param execute
    Tool: Bash (tsx)
    Preconditions: submitter.ts written
    Steps:
      1. Run a tsx script that calls the internal encodeFunctionData with test params
      2. Decode the first 4 bytes (function selector) of the output
      3. Compare against the known execute() selector
    Expected Result: First 4 bytes match keccak256("execute((address,uint256,bytes)[],bytes,address,uint256,uint256,uint8,bytes32,bytes32)")[:4]
    Failure Indicators: Selector doesn't match — wrong encoding
    Evidence: .sisyphus/evidence/task-9-encode-selector.txt

  Scenario: No authorizationList in transaction
    Tool: Bash (grep)
    Preconditions: submitter.ts written
    Steps:
      1. Run `Select-String -Path "src/services/submitter.ts" -Pattern "authorizationList"`
      2. Check output
    Expected Result: No matches found
    Failure Indicators: Any line containing "authorizationList"
    Evidence: .sisyphus/evidence/task-9-no-auth-list.txt
  ```

  **Commit**: YES (groups with 5, 6, 7, 8, 10, 11)
  - Message: `feat(relayer): implement state override, fee estimator, and core services`
  - Files: `src/services/submitter.ts`

- [x] 10. Create feeEstimator.ts (NEW)

  **What to do**:
  - Create `src/services/feeEstimator.ts`
  - `estimateFee(user, calls, feeToken)` → `{ nonce: bigint, gasEstimate: bigint, maxPermitAmount: bigint, feeTokenDecimals: number, deadline: bigint, configAddress: Address, digest: Hex }`
  - Steps inside:
    1. Check delegation status via `clients.checkDelegationStatus(user)` — if false, throw `{ statusCode: 400, message: "EOA not delegated to GasFlowDelegator" }`
    2. Read current nonce via state override: `getDelegatorNonce(user)` using stateOverride module
    3. Estimate gas via `simulator.estimateGas(user, calls, feeToken)` (with state override)
    4. Read Config: `config.minFeeRateBps()`, `config.l1FeeBps()` (Sepolia = 0)
    5. Read price feeds: `config.priceFeeds(feeToken)` → `(ethUsdFeed, tokenUsdFeed)`. If tokenUsdFeed == 0x0, throw `{ statusCode: 400, message: "Fee token not supported" }`
    6. Read Chainlink: `ethUsdPrice = readChainlinkPrice(ethUsdFeed)`, `tokenUsdPrice = readChainlinkPrice(tokenUsdFeed)`
    7. Read `feeTokenDecimals = config.feeTokenDecimals(feeToken)`
    8. Compute `ethCompensation = gasEstimate * gasPrice * (10000n + l1FeeBps) / 10000n`
    9. Compute `baseFee = ethCompensation * ethUsdPrice * 10n^BigInt(feeTokenDecimals) / (10n^18n * tokenUsdPrice)` — MUST use BigInt throughout
    10. Compute `feeWithMarkup = baseFee * minFeeRateBps / 10000n`
    11. Compute `maxPermitAmount = feeWithMarkup * config.feeAmountMarginBps / 10000n` (extra 10% buffer)
    12. Set `deadline = BigInt(Math.floor(Date.now() / 1000)) + config.permitDeadlineSeconds`
    13. Compute `digest` = the ECDSA digest the user needs to sign (same as simulator.verifySignature formula)
    14. Return all fields
  - `gasPrice` for estimation: use `publicClient.getGasPrice()` or EIP-1559 `maxFeePerGas` from config

  **Must NOT do**:
  - Do NOT use floating point anywhere — all arithmetic must be BigInt
  - Do NOT hardcode Chainlink feed addresses — read from Config
  - Do NOT skip the delegation status check
  - Do NOT skip the tokenUsdFeed == 0 check

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Complex fee calculation with BigInt, Chainlink integration, multiple Config reads. Financial correctness critical.
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 5, 6, 7, 8, 9, 11)
  - **Blocks**: Task 16
  - **Blocked By**: Tasks 1, 2, 5

  **References**:

  **API/Type References**:
  - `D:\TiziGithub\gasFlow\contracts\GasFlowDelegator.sol:179-186` — ethCompensation = gasUsed * tx.gasprice + l1Fee; baseFee = _ethToStable(...); feeAmount = baseFee * minFeeRateBps / 10000
  - `D:\TiziGithub\gasFlow\contracts\GasFlowDelegator.sol:265-307` — _ethToStable formula: `(ethAmount * ethUsd * 10^tokenDec) / (1e18 * tokenUsd)`
  - `D:\TiziGithub\gasFlow\contracts\GasFlowConfig.sol:104-143` — _validateFeeAgainstOracle (Config independently validates, so buffer is needed)

  **WHY Each Reference Matters**:
  - Delegator fee formula MUST match exactly for the permit amount to be accepted
  - Config independently validates fee — if relayer's estimate is too low, tx reverts with FeeBelowOracleRate
  - The 10% buffer (feeAmountMarginBps) protects against price movement between estimate and mine

  **Acceptance Criteria**:
  - [ ] All arithmetic uses BigInt (no Number division or multiplication)
  - [ ] Delegation status checked before estimation
  - [ ] Unsupported fee token returns 400 error
  - [ ] maxPermitAmount includes feeAmountMarginBps buffer (10% above minFeeRateBps)
  - [ ] deadline = current_time + permitDeadlineSeconds

  **QA Scenarios**:
  ```
  Scenario: Fee estimation returns valid maxPermitAmount
    Tool: Bash (tsx)
    Preconditions: feeEstimator.ts written, .env valid, contracts deployed on Sepolia, user is delegated
    Steps:
      1. Call estimateFee with a delegated user address, simple call, and USDC address
      2. Check maxPermitAmount > 0n, deadline > current time, nonce is a valid bigint
    Expected Result: { nonce: bigint, gasEstimate: bigint > 0n, maxPermitAmount: bigint > 0n, deadline: bigint > now, configAddress: Address }
    Failure Indicators: maxPermitAmount = 0n, or any field undefined, or error thrown
    Evidence: .sisyphus/evidence/task-10-fee-estimate.txt

  Scenario: Non-delegated EOA returns 400
    Tool: Bash (tsx)
    Preconditions: feeEstimator.ts written, use a non-delegated address
    Steps:
      1. Call estimateFee with non-delegated address
      2. Catch the error
    Expected Result: Error with statusCode=400 and message containing "not delegated"
    Failure Indicators: No error, or error with different statusCode/message
    Evidence: .sisyphus/evidence/task-10-non-delegated.txt
  ```

  **Commit**: YES (groups with 5, 6, 7, 8, 9, 11)
  - Message: `feat(relayer): implement state override, fee estimator, and core services`
  - Files: `src/services/feeEstimator.ts`

- [x] 11. Create startupCheck.ts (NEW)

  **What to do**:
  - Create `src/services/startupCheck.ts`
  - `runStartupChecks()` — async function that runs all health checks at startup:
    1. Verify `config.configAddress` is non-zero — fail if not
    2. Verify `config.stakePool = await readConfig.stakePool()` is non-zero — warn if not
    3. Read `config.priceFeeds(feeToken)` for each supported fee token — verify both ethUsdFeed and tokenUsdFeed are non-zero — warn if missing
    4. Read Chainlink prices for each feed — verify non-stale (updatedAt within STALENESS_THRESHOLD) — warn if stale
    5. Fetch Delegator runtime bytecode via `clients.getDelegatorRuntimeBytecode()` — verify non-empty — fail if empty
    6. Read `config.delegatorCodeHash()` — compute `keccak256(delegatorRuntimeBytecode)` — verify they match — warn if mismatch
    7. Read `config.paused()` — warn if paused (relayer starts but returns 503 on submit)
    8. Read `config.relayers(relayerAddress)` — warn if relayer not whitelisted (doesn't affect execution but good to know)
  - Log results: `✅ Check passed` or `⚠️ Warning: ...` or `❌ FATAL: ...`
  - Throw on FATAL errors (config address missing, bytecode empty)
  - Continue on WARN (feeds not set, paused, not whitelisted)

  **Must NOT do**:
  - Do NOT block startup on warnings — only fail on FATAL
  - Do NOT make this a periodic check — it's startup only (periodic checks go in balanceMonitor)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Sequential validation checks, straightforward logic
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 5, 6, 7, 8, 9, 10)
  - **Blocks**: Task 20
  - **Blocked By**: Tasks 1, 5

  **References**:

  **API/Type References**:
  - `D:\TiziGithub\gasFlow\contracts\GasFlowConfig.sol:50-67` — All fields to validate
  - `D:\TiziGithub\gasFlow\contracts\GasFlowConfig.sol:149-155` — pause()/unpause()
  - `D:\TiziGithub\gasFlow\contracts\GasFlowConfig.sol:261-272` — relayers mapping

  **WHY Each Reference Matters**:
  - Config fields determine what to check at startup
  - delegatorCodeHash verification ensures the deployed bytecode matches what Config expects

  **Acceptance Criteria**:
  - [ ] All 8 checks implemented
  - [ ] FATAL errors throw and prevent startup
  - [ ] WARN errors log warning but allow startup
  - [ ] Results logged with clear ✅/⚠️/❌ indicators

  **QA Scenarios**:
  ```
  Scenario: Startup checks run and log results
    Tool: Bash (tsx with timeout)
    Preconditions: startupCheck.ts written, .env valid
    Steps:
      1. Run `npx tsx -e "import { runStartupChecks } from './src/services/startupCheck'; runStartupChecks().then(() => process.exit(0)).catch(() => process.exit(1))"` in gasFlowRelayer with 10s timeout
      2. Capture stdout/stderr
    Expected Result: Output contains "✅" for passed checks, no "❌ FATAL" if config is valid
    Failure Indicators: "❌ FATAL" in output or exit code 1 (when config should be valid)
    Evidence: .sisyphus/evidence/task-11-startup-checks.txt

  Scenario: Missing config address causes FATAL
    Tool: Bash (tsx)
    Preconditions: startupCheck.ts written, .env with CONFIG_CONTRACT_ADDRESS=0x0000...0000
    Steps:
      1. Run startup checks with invalid config address
      2. Check if it throws
    Expected Result: Throws error containing "FATAL" or "config" or "zero address"
    Failure Indicators: No error thrown when config address is zero
    Evidence: .sisyphus/evidence/task-11-fatal-config.txt
  ```

  **Commit**: YES (groups with 5, 6, 7, 8, 9, 10)
  - Message: `feat(relayer): implement state override, fee estimator, and core services`
  - Files: `src/services/startupCheck.ts`

- [x] 12. Update validator.ts with new field validation

  **What to do**:
  - **Modify `validateSubmitRequest(body)`**:
    - Remove `authorization` validation (field no longer in SubmitRequest)
    - Make `feeToken` required (was optional) — validate it's in `config.supportedFeeTokens`
    - Add validation for `maxPermitAmount`: must be `bigint`, must be > 0
    - Add validation for `deadline`: must be `bigint`, must be > `BigInt(Math.floor(Date.now()/1000))` (not expired)
    - Add validation for `permitV`: must be 0 or 1
    - Add validation for `permitR`, `permitS`: must be 32-byte Hex (66 chars including 0x)
    - Keep: user address validation, calls array validation, signature validation, batch size check
  - **Add `validateEstimateRequest(body)`**:
    - Validate `user` is valid address
    - Validate `calls` is non-empty array, each call has `to` (address) and `data` (Hex)
    - Validate `feeToken` is in supported list
    - Validate batch size

  **Must NOT do**:
  - Do NOT accept `authorization` field — it's removed from the request type
  - Do NOT validate permit signature correctness here — that's the contract's job

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Validation logic, straightforward field checks
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Tasks 13, 14, 15, 16, 17, 18, 19)
  - **Blocks**: Tasks 16, 17
  - **Blocked By**: Tasks 2, 3

  **References**:

  **Pattern References**:
  - `D:\TiziGithub\gasFlowRelayer\src\services\validator.ts` — Current file, keep ValidationError class and validation pattern

  **API/Type References**:
  - `D:\TiziGithub\gasFlowRelayer\src\types\index.ts` (Task 2 output) — SubmitRequest and EstimateRequest field definitions

  **WHY Each Reference Matters**:
  - Current validator shows the validation pattern to extend
  - New types define what fields to validate

  **Acceptance Criteria**:
  - [ ] `validateSubmitRequest` rejects missing `feeToken` with 400
  - [ ] `validateSubmitRequest` rejects expired `deadline` with 400
  - [ ] `validateSubmitRequest` rejects `permitV` not 0 or 1 with 400
  - [ ] `validateEstimateRequest` validates all EstimateRequest fields
  - [ ] No `authorization` validation remains

  **QA Scenarios**:
  ```
  Scenario: Missing feeToken returns 400
    Tool: Bash (tsx)
    Preconditions: validator.ts written
    Steps:
      1. Call validateSubmitRequest with a body missing feeToken
      2. Catch error
    Expected Result: ValidationError with statusCode=400, message containing "feeToken"
    Failure Indicators: No error, or error without "feeToken" in message
    Evidence: .sisyphus/evidence/task-12-missing-feetoken.txt

  Scenario: Expired deadline returns 400
    Tool: Bash (tsx)
    Preconditions: validator.ts written
    Steps:
      1. Call validateSubmitRequest with deadline = 1 (expired)
      2. Catch error
    Expected Result: ValidationError with statusCode=400, message containing "deadline" or "expired"
    Failure Indicators: No error thrown
    Evidence: .sisyphus/evidence/task-12-expired-deadline.txt

  Scenario: Invalid permitV returns 400
    Tool: Bash (tsx)
    Preconditions: validator.ts written
    Steps:
      1. Call validateSubmitRequest with permitV = 2
      2. Catch error
    Expected Result: ValidationError with statusCode=400
    Failure Indicators: No error, or permitV=2 accepted
    Evidence: .sisyphus/evidence/task-12-invalid-v.txt
  ```

  **Commit**: YES (groups with 13-19)
  - Message: `feat(relayer): add estimate, status, config, balance endpoints and update submit`
  - Files: `src/services/validator.ts`

- [x] 13. Create routes/config.ts (NEW)

  **What to do**:
  - Create `src/routes/config.ts`
  - `handleConfig()` → `ConfigResponse`:
    - Read from `config` object: `chainId`, `delegatorAddress`, `configAddress`, `stakePoolAddress`, `supportedFeeTokens`, `minFeeRateBps` (from Config contract), `l1FeeBps` (from Config contract)
    - Read `minFeeRateBps` and `l1FeeBps` from Config contract at runtime (not from env)
    - Return JSON

  **Must NOT do**:
  - Do NOT read minFeeRateBps from env — read from Config contract

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Simple read + return, no complex logic
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Tasks 12, 14, 15, 16, 17, 18, 19)
  - **Blocks**: Task 20
  - **Blocked By**: Tasks 1, 2, 5

  **References**:

  **Pattern References**:
  - `D:\TiziGithub\gasFlowRelayer\src\routes\submit.ts` — Current route handler pattern

  **API/Type References**:
  - `D:\TiziGithub\gasFlowRelayer\src\types\index.ts` (Task 2) — ConfigResponse type

  **Acceptance Criteria**:
  - [ ] Returns JSON with all ConfigResponse fields
  - [ ] `minFeeRateBps` and `l1FeeBps` read from Config contract, not env
  - [ ] `supportedFeeTokens` is an array

  **QA Scenarios**:
  ```
  Scenario: GET /api/v1/config returns valid response
    Tool: Bash (curl)
    Preconditions: Server running on localhost:3000, contracts deployed
    Steps:
      1. Run `curl -s http://localhost:3000/api/v1/config`
      2. Parse JSON response
    Expected Result: JSON with fields: chainId (number), delegatorAddress (0x...), configAddress (0x...), stakePoolAddress (0x...), supportedFeeTokens (array), minFeeRateBps (string), l1FeeBps (string)
    Failure Indicators: Missing fields, 500 error, or empty response
    Evidence: .sisyphus/evidence/task-13-config-endpoint.txt
  ```

  **Commit**: YES (groups with 12, 14-19)
  - Message: `feat(relayer): add estimate, status, config, balance endpoints and update submit`
  - Files: `src/routes/config.ts`

- [x] 14. Create routes/balance.ts (NEW)

  **What to do**:
  - Create `src/routes/balance.ts`
  - `handleBalance()` → `BalanceResponse`:
    - Get relayer address from `clients.getRelayerAddress()`
    - Get ETH balance from `publicClient.getBalance({ address: relayerAddress })`
    - Get `config.minRelayerBalance` from config
    - Return `{ relayerAddress, ethBalance: balance.toString(), minBalance: config.minRelayerBalance.toString() }`

  **Must NOT do**:
  - Do NOT return private key or sensitive info

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Simple balance read, no complex logic
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Tasks 12, 13, 15, 16, 17, 18, 19)
  - **Blocks**: Task 20
  - **Blocked By**: Tasks 2, 5

  **References**:

  **Pattern References**:
  - `D:\TiziGithub\gasFlowRelayer\src\services\balanceMonitor.ts` — Balance reading pattern

  **Acceptance Criteria**:
  - [ ] Returns JSON with relayerAddress, ethBalance, minBalance
  - [ ] ethBalance is a string (not number — bigint serialization)

  **QA Scenarios**:
  ```
  Scenario: GET /api/v1/balance returns valid response
    Tool: Bash (curl)
    Preconditions: Server running, .env valid
    Steps:
      1. Run `curl -s http://localhost:3000/api/v1/balance`
      2. Parse JSON response
    Expected Result: JSON with relayerAddress (0x...), ethBalance (string number), minBalance (string number)
    Failure Indicators: Missing fields, 500 error
    Evidence: .sisyphus/evidence/task-14-balance-endpoint.txt
  ```

  **Commit**: YES (groups with 12, 13, 15-19)
  - Message: `feat(relayer): add estimate, status, config, balance endpoints and update submit`
  - Files: `src/routes/balance.ts`

- [x] 15. Create routes/status.ts (NEW)

  **What to do**:
  - Create `src/routes/status.ts`
  - `handleStatus(txHash)` → `StatusResponse`:
    - Call `publicClient.getTransactionReceipt({ hash: txHash })`
    - If receipt exists: return `{ status: receipt.status === 'success' ? 'confirmed' : 'failed', blockNumber: receipt.blockNumber.toString(), gasUsed: receipt.gasUsed.toString() }`
    - If no receipt (tx pending): return `{ status: 'pending' }`
    - If tx not found: throw `{ statusCode: 404, message: "Transaction not found" }`
  - Parse txHash from URL path: `/api/v1/status/:txHash`

  **Must NOT do**:
  - Do NOT parse event logs — just return basic receipt info
  - Do NOT maintain in-memory tx tracking — query on demand

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Simple receipt lookup, no complex logic
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Tasks 12, 13, 14, 16, 17, 18, 19)
  - **Blocks**: Task 20
  - **Blocked By**: Tasks 2, 5

  **References**:

  **External References**:
  - viem `getTransactionReceipt`: `https://viem.sh/docs/actions/public/getTransactionReceipt`

  **Acceptance Criteria**:
  - [ ] Returns `{ status: 'confirmed', blockNumber, gasUsed }` for mined successful tx
  - [ ] Returns `{ status: 'pending' }` for unmined tx
  - [ ] Returns 404 for non-existent tx hash
  - [ ] All bigint fields serialized as strings

  **QA Scenarios**:
  ```
  Scenario: GET /api/v1/status/:txHash for pending tx
    Tool: Bash (curl)
    Preconditions: Server running, use a recently submitted tx hash
    Steps:
      1. Run `curl -s http://localhost:3000/api/v1/status/0xRECENT_TX_HASH`
      2. Parse JSON
    Expected Result: JSON with status field = "pending" or "confirmed"
    Failure Indicators: 500 error, or missing status field
    Evidence: .sisyphus/evidence/task-15-status-endpoint.txt

  Scenario: GET /api/v1/status/:txHash for non-existent tx returns 404
    Tool: Bash (curl)
    Preconditions: Server running
    Steps:
      1. Run `curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/v1/status/0x0000000000000000000000000000000000000000000000000000000000000000`
      2. Check HTTP status code
    Expected Result: "404"
    Failure Indicators: "200" or "500"
    Evidence: .sisyphus/evidence/task-15-status-404.txt
  ```

  **Commit**: YES (groups with 12, 13, 14, 16-19)
  - Message: `feat(relayer): add estimate, status, config, balance endpoints and update submit`
  - Files: `src/routes/status.ts`

- [x] 16. Create routes/estimate.ts (NEW)

  **What to do**:
  - Create `src/routes/estimate.ts`
  - `handleEstimate(body)` → `EstimateResponse`:
    1. Validate body via `validator.validateEstimateRequest(body)`
    2. Call `feeEstimator.estimateFee(body.user, body.calls, body.feeToken)`
    3. Return the EstimateResponse
  - Handle errors: 400 for validation, 400 for non-delegated EOA, 400 for unsupported token, 500 for internal

  **Must NOT do**:
  - Do NOT reserve nonce — estimate is non-binding
  - Do NOT submit anything

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Integrates validator + feeEstimator, error handling for multiple failure modes
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Tasks 12, 13, 14, 15, 17, 18, 19)
  - **Blocks**: Task 20
  - **Blocked By**: Tasks 2, 10, 12

  **References**:

  **Pattern References**:
  - `D:\TiziGithub\gasFlowRelayer\src\routes\submit.ts` — Current route handler pattern (try/catch, error mapping)

  **API/Type References**:
  - `D:\TiziGithub\gasFlowRelayer\src\types\index.ts` (Task 2) — EstimateRequest, EstimateResponse types

  **Acceptance Criteria**:
  - [ ] Returns 200 with valid EstimateResponse for delegated user
  - [ ] Returns 400 for non-delegated EOA
  - [ ] Returns 400 for unsupported fee token
  - [ ] Returns 400 for invalid request body

  **QA Scenarios**:
  ```
  Scenario: POST /api/v1/estimate returns valid response
    Tool: Bash (curl)
    Preconditions: Server running, contracts deployed, user is delegated, USDC supported
    Steps:
      1. Run `curl -s -X POST http://localhost:3000/api/v1/estimate -H "Content-Type: application/json" -d '{"user":"0xDELEGATED_EOA","calls":[{"to":"0xRECIPIENT","value":"0","data":"0x"}],"feeToken":"0xUSDC"}'`
      2. Parse JSON response
    Expected Result: JSON with nonce (string), gasEstimate (string > 0), maxPermitAmount (string > 0), deadline (string > current time), configAddress (0x...), feeTokenDecimals (number), digest (0x...)
    Failure Indicators: Missing fields, 500 error, maxPermitAmount = "0"
    Evidence: .sisyphus/evidence/task-16-estimate-endpoint.txt

  Scenario: POST /api/v1/estimate for non-delegated EOA returns 400
    Tool: Bash (curl)
    Preconditions: Server running
    Steps:
      1. Run `curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:3000/api/v1/estimate -H "Content-Type: application/json" -d '{"user":"0xNON_DELEGATED","calls":[{"to":"0x1","value":"0","data":"0x"}],"feeToken":"0xUSDC"}'`
      2. Check HTTP status code
    Expected Result: "400"
    Failure Indicators: "200" or "500"
    Evidence: .sisyphus/evidence/task-16-estimate-400.txt
  ```

  **Commit**: YES (groups with 12-15, 17-19)
  - Message: `feat(relayer): add estimate, status, config, balance endpoints and update submit`
  - Files: `src/routes/estimate.ts`

- [x] 17. Update routes/submit.ts with new flow

  **What to do**:
  - **Rewrite `handleSubmit(body)`**:
    1. Validate body via `validator.validateSubmitRequest(body)`
    2. Acquire per-user lock via `userLock.acquireUserLock(request.user)` — release at end (finally block)
    3. Check delegation status via `clients.checkDelegationStatus(request.user)` — if false, throw `{ statusCode: 400, message: "EOA not delegated to GasFlowDelegator" }`
    4. Check `config.paused()` via `clients.readConfig.paused()` — if paused, throw `{ statusCode: 503, message: "GasFlowConfig is paused" }`
    5. Read current nonce via state override: `getDelegatorNonce(request.user)`
    6. Verify ECDSA signature: `simulator.verifySignature(request.user, request.calls, nonce, request.signature)` — if invalid, throw 401
    7. Simulate: `simulator.simulateTransaction(request.user, request.calls, request.feeToken, request.maxPermitAmount, request.deadline, request.permitV, request.permitR, request.permitS)` — if fails, throw 422
    8. Submit: `submitter.submitTransaction(request, simulation.gasEstimate)` — returns `{ txHash, gasEstimate }`
    9. Track pending: `nonceManager.addPending(request.user, txHash)`
    10. Return `{ txHash, gasEstimate }`
  - **Release lock** in finally block regardless of success/failure

  **Must NOT do**:
  - Do NOT skip the user lock — concurrent submissions for same user cause nonce collision
  - Do NOT read nonce without state override
  - Do NOT verify signature without the correct nonce

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Core orchestrator — integrates validator, userLock, clients, simulator, submitter, nonceManager. Error handling for 5+ failure modes.
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Tasks 12, 13, 14, 15, 16, 18, 19)
  - **Blocks**: Task 20
  - **Blocked By**: Tasks 2, 7, 8, 9, 12

  **References**:

  **Pattern References**:
  - `D:\TiziGithub\gasFlowRelayer\src\routes\submit.ts` — Current file, keep try/catch error mapping pattern

  **API/Type References**:
  - `D:\TiziGithub\gasFlowRelayer\src\types\index.ts` (Task 2) — SubmitRequest type (new fields)

  **WHY Each Reference Matters**:
  - Current submit.ts shows the handler pattern to extend
  - New SubmitRequest type defines what fields are available

  **Acceptance Criteria**:
  - [ ] User lock acquired and released in finally block
  - [ ] Delegation status checked before signature verification
  - [ ] Config.paused() checked before submission
  - [ ] Nonce read via state override (not direct readContract)
  - [ ] Signature verified with correct nonce from state override
  - [ ] Returns 400 for non-delegated, 401 for invalid sig, 422 for sim failure, 503 for paused

  **QA Scenarios**:
  ```
  Scenario: POST /api/v1/submit with valid payload returns 200
    Tool: Bash (curl)
    Preconditions: Server running, user delegated, valid signatures obtained from SDK
    Steps:
      1. Run `curl -s -X POST http://localhost:3000/api/v1/submit -H "Content-Type: application/json" -d '{"user":"0x...","calls":[...],"signature":"0x...","feeToken":"0x...","maxPermitAmount":"...","deadline":"...","permitV":0,"permitR":"0x...","permitS":"0x..."}'`
      2. Parse JSON
    Expected Result: JSON with txHash (0x...) and gasEstimate (string)
    Failure Indicators: 500 error, missing txHash
    Evidence: .sisyphus/evidence/task-17-submit-success.txt

  Scenario: POST /api/v1/submit for non-delegated EOA returns 400
    Tool: Bash (curl)
    Preconditions: Server running
    Steps:
      1. Submit with non-delegated user address
      2. Check HTTP status
    Expected Result: HTTP 400, error message containing "not delegated"
    Failure Indicators: 200 or 500
    Evidence: .sisyphus/evidence/task-17-submit-400.txt

  Scenario: POST /api/v1/submit with invalid signature returns 401
    Tool: Bash (curl)
    Preconditions: Server running, user delegated
    Steps:
      1. Submit with invalid signature (wrong bytes)
      2. Check HTTP status
    Expected Result: HTTP 401, error containing "signature"
    Failure Indicators: 200 or 500
    Evidence: .sisyphus/evidence/task-17-submit-401.txt

  Scenario: POST /api/v1/submit when Config paused returns 503
    Tool: Bash (curl)
    Preconditions: Server running, Config.pause() called by owner
    Steps:
      1. Submit with valid payload
      2. Check HTTP status
    Expected Result: HTTP 503, error containing "paused"
    Failure Indicators: 200 or 500
    Evidence: .sisyphus/evidence/task-17-submit-503.txt
  ```

  **Commit**: YES (groups with 12-16, 18, 19)
  - Message: `feat(relayer): add estimate, status, config, balance endpoints and update submit`
  - Files: `src/routes/submit.ts`

- [x] 18. Update nonceManager.ts with bigint + state override

  **What to do**:
  - Change `lastKnownNonce` type from `number` to `bigint`
  - Change `reserveNonce` return type from `number | null` to `bigint | null`
  - Change `getNextNonce` to use `clients.getDelegatorNonce(user)` (which uses state override)
  - Change `releaseNonce` to decrement bigint
  - Update `UserState` type to match (lastKnownNonce: bigint)
  - Keep `addPending` and `getPending` (change pendingTxHashes to Hash[])

  **Must NOT do**:
  - Do NOT use `number` for nonce — uint256 requires bigint
  - Do NOT call readContract for nonce without state override

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Type changes + one function update, mechanical
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Tasks 12, 13, 14, 15, 16, 17, 19)
  - **Blocks**: Task 17
  - **Blocked By**: Tasks 2, 5, 6

  **References**:

  **Pattern References**:
  - `D:\TiziGithub\gasFlowRelayer\src\services\nonceManager.ts` — Current file, keep class structure

  **Acceptance Criteria**:
  - [ ] All nonce values use `bigint`
  - [ ] `getNextNonce` calls `clients.getDelegatorNonce` (state override version)
  - [ ] No `number` type for nonce anywhere

  **QA Scenarios**:
  ```
  Scenario: NonceManager uses bigint
    Tool: Bash (grep)
    Preconditions: nonceManager.ts written
    Steps:
      1. Run `Select-String -Path "src/services/nonceManager.ts" -Pattern "number"`
      2. Check output (should only match in comments, not in nonce type declarations)
    Expected Result: No "number" type used for lastKnownNonce or return types
    Failure Indicators: "lastKnownNonce: number" or "reserveNonce(...): number"
    Evidence: .sisyphus/evidence/task-18-bigint-nonce.txt
  ```

  **Commit**: YES (groups with 12-17, 19)
  - Message: `feat(relayer): add estimate, status, config, balance endpoints and update submit`
  - Files: `src/services/nonceManager.ts`

- [x] 19. Update balanceMonitor.ts with Config.paused() check

  **What to do**:
  - Keep existing `checkRelayerBalance()` and `startBalanceMonitor()`
  - Add `checkConfigPaused()` — reads `config.paused()` via clients, logs warning if paused
  - In `startBalanceMonitor` interval callback: call both `checkRelayerBalance()` and `checkConfigPaused()`
  - Log: `⚠️ GasFlowConfig is PAUSED — submissions will fail with 503` if paused

  **Must NOT do**:
  - Do NOT stop the server if paused — just warn

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Adding one check function to existing file
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Tasks 12, 13, 14, 15, 16, 17, 18)
  - **Blocks**: Task 20
  - **Blocked By**: Tasks 2, 5

  **References**:

  **Pattern References**:
  - `D:\TiziGithub\gasFlowRelayer\src\services\balanceMonitor.ts` — Current file, keep structure

  **API/Type References**:
  - `D:\TiziGithub\gasFlow\contracts\GasFlowConfig.sol:149-155` — pause()/unpause()
  - `D:\TiziGithub\gasFlow\contracts\GasFlowConfig.sol:47` — Pausable contract (paused() view)

  **Acceptance Criteria**:
  - [ ] `checkConfigPaused()` reads `config.paused()` and logs warning if true
  - [ ] Periodic monitor calls both balance check and pause check

  **QA Scenarios**:
  ```
  Scenario: Balance monitor logs paused status
    Tool: Bash (tsx with timeout)
    Preconditions: balanceMonitor.ts written, Config is paused
    Steps:
      1. Run `npx tsx -e "import { checkConfigPaused } from './src/services/balanceMonitor'; checkConfigPaused()"` with 5s timeout
      2. Check stderr/stdout for warning
    Expected Result: Output contains "PAUSED" or "paused"
    Failure Indicators: No warning when Config is paused
    Evidence: .sisyphus/evidence/task-19-paused-check.txt
  ```

  **Commit**: YES (groups with 12-18)
  - Message: `feat(relayer): add estimate, status, config, balance endpoints and update submit`
  - Files: `src/services/balanceMonitor.ts`

- [x] 20. Update server.ts with all route registrations

  **What to do**:
  - Import and register 5 routes:
    - `POST /api/v1/submit` → `handleSubmit` (existing)
    - `POST /api/v1/estimate` → `handleEstimate` (new)
    - `GET /api/v1/status/:txHash` → `handleStatus` (new — parse txHash from URL)
    - `GET /api/v1/config` → `handleConfig` (new)
    - `GET /api/v1/balance` → `handleBalance` (new)
  - Keep `GET /health` and CORS OPTIONS handling
  - Call `runStartupChecks()` before `server.listen()` — if FATAL, process exits with code 1
  - Call `startBalanceMonitor()` after server starts (existing)
  - Parse `:txHash` from URL: `if (req.url?.startsWith('/api/v1/status/')) { const txHash = req.url.split('/').pop(); ... }`

  **Must NOT do**:
  - Do NOT use Express or other frameworks — keep std lib http
  - Do NOT skip startup checks

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Route registration, pattern matching, straightforward
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 4 (with Task 21)
  - **Blocks**: Task 21
  - **Blocked By**: Tasks 11, 13, 14, 15, 16, 17, 19

  **References**:

  **Pattern References**:
  - `D:\TiziGithub\gasFlowRelayer\src\server.ts` — Current file, keep http.createServer pattern

  **Acceptance Criteria**:
  - [ ] All 5 routes registered and respond
  - [ ] Startup checks run before listen
  - [ ] `/api/v1/status/:txHash` correctly parses txHash from URL

  **QA Scenarios**:
  ```
  Scenario: All endpoints accessible
    Tool: Bash (curl)
    Preconditions: Server running
    Steps:
      1. Run `curl -s http://localhost:3000/health` → expect {"status":"ok"}
      2. Run `curl -s http://localhost:3000/api/v1/config` → expect JSON
      3. Run `curl -s http://localhost:3000/api/v1/balance` → expect JSON
      4. Run `curl -s -X POST http://localhost:3000/api/v1/estimate -H "Content-Type: application/json" -d '{}'` → expect 400 (validation error)
      5. Run `curl -s http://localhost:3000/api/v1/status/0x0000000000000000000000000000000000000000000000000000000000000000` → expect 404
    Expected Result: All 5 endpoints respond with expected status codes
    Failure Indicators: Any endpoint returns 404 for its registered path, or 500
    Evidence: .sisyphus/evidence/task-20-all-endpoints.txt
  ```

  **Commit**: YES (groups with 21)
  - Message: `feat(relayer): register all routes and verify compilation`
  - Files: `src/server.ts`
  - Pre-commit: `npx tsc --noEmit`

- [x] 21. Verify tsc --noEmit passes

  **What to do**:
  - Run `npx tsc --noEmit` in gasFlowRelayer
  - If errors: fix them (likely type mismatches, missing imports, bigint vs number issues)
  - Common fixes: ensure all bigint fields serialized as strings in JSON responses, ensure all imports correct
  - Fix any `as any` or `@ts-ignore` — replace with proper types
  - Run again until clean

  **Must NOT do**:
  - Do NOT use `@ts-ignore` to suppress errors — fix the root cause
  - Do NOT use `as any` — use proper type assertions

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Compilation fix, iterative
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 4 (after Task 20)
  - **Blocks**: F1, F2, F3, F4
  - **Blocked By**: Task 20 (and all prior tasks)

  **References**:

  **Pattern References**:
  - `D:\TiziGithub\gasFlowRelayer\tsconfig.json` — TypeScript config

  **Acceptance Criteria**:
  - [ ] `npx tsc --noEmit` exits with code 0
  - [ ] No `@ts-ignore` in any file
  - [ ] No `as any` in any file

  **QA Scenarios**:
  ```
  Scenario: TypeScript compilation passes
    Tool: Bash (npx tsc)
    Preconditions: All tasks 1-20 complete
    Steps:
      1. Run `npx tsc --noEmit` in D:\TiziGithub\gasFlowRelayer
      2. Check exit code and output
    Expected Result: Exit code 0, no output (no errors)
    Failure Indicators: Exit code 1, error messages mentioning specific files
    Evidence: .sisyphus/evidence/task-21-tsc-pass.txt

  Scenario: No ts-ignore or as-any in codebase
    Tool: Bash (grep)
    Preconditions: All tasks complete
    Steps:
      1. Run `Select-String -Path "src/**/*.ts" -Pattern "@ts-ignore|as any"` in gasFlowRelayer
      2. Check output
    Expected Result: No matches found
    Failure Indicators: Any matches
    Evidence: .sisyphus/evidence/task-21-no-ignore.txt
  ```

  **Commit**: YES (groups with 20)
  - Message: `feat(relayer): register all routes and verify compilation`
  - Files: (any files fixed during compilation)

---

## Final Verification Wave (MANDATORY — after ALL implementation tasks)

> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit "okay" before completing.

- [x] F1. **Plan Compliance Audit** — `oracle`
  Read the plan end-to-end. For each "Must Have": verify implementation exists (read file, curl endpoint, run command). For each "Must NOT Have": search codebase for forbidden patterns — reject with file:line if found. Check evidence files exist in .sisyphus/evidence/. Compare deliverables against plan.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [x] F2. **Code Quality Review** — `unspecified-high`
  Run `npx tsc --noEmit` + linter. Review all changed files for: `as any`/`@ts-ignore`, empty catches, console.log in prod (except startup), commented-out code, unused imports. Check AI slop: excessive comments, over-abstraction, generic names. Verify no `encodePacked` in digest, no `number` type for nonces, no hardcoded feed addresses.
  Output: `Build [PASS/FAIL] | Lint [PASS/FAIL] | Files [N clean/N issues] | VERDICT`

- [x] F3. **Real Manual QA** — `unspecified-high`
  Start relayer with valid .env. Execute EVERY QA scenario from EVERY task — follow exact steps, capture evidence. Test all 5 endpoints with curl. Test error scenarios (non-delegated EOA, expired deadline, invalid signature, insufficient balance). Save to `.sisyphus/evidence/final-qa/`.
  Output: `Scenarios [N/N pass] | Integration [N/N] | Edge Cases [N tested] | VERDICT`

- [x] F4. **Scope Fidelity Check** — `deep`
  For each task: read "What to do", read actual diff (git log/diff). Verify 1:1 — everything in spec was built (no missing), nothing beyond spec was built (no creep). Check "Must NOT do" compliance: no authorizationList, no /delegate endpoint, no alt mempool, no Redis, no multi-chain. Detect cross-task contamination.
  Output: `Tasks [N/N compliant] | Contamination [CLEAN/N issues] | Unaccounted [CLEAN/N files] | VERDICT`

---

## Commit Strategy

- **Wave 1**: `feat(relayer): update ABIs, types, and config for GasFlowDelegator interface` - abis.ts, types/index.ts, config.ts, .env.example
- **Wave 2**: `feat(relayer): implement state override, fee estimator, and core services` - clients.ts, stateOverride.ts, userLock.ts, simulator.ts, submitter.ts, feeEstimator.ts, startupCheck.ts
- **Wave 3**: `feat(relayer): add estimate, status, config, balance endpoints and update submit` - validator.ts, routes/*.ts, nonceManager.ts, balanceMonitor.ts
- **Wave 4**: `feat(relayer): register all routes and verify compilation` - server.ts
- **Pre-commit**: `npx tsc --noEmit`

---

## Success Criteria

### Verification Commands
```bash
npx tsc --noEmit          # Expected: exit code 0, no errors
curl http://localhost:3000/health                          # Expected: {"status":"ok"}
curl http://localhost:3000/api/v1/config                   # Expected: JSON with chainId, addresses, fee rates
curl http://localhost:3000/api/v1/balance                  # Expected: JSON with ethBalance, address
curl -X POST http://localhost:3000/api/v1/estimate -H "Content-Type: application/json" -d '{"user":"0x...","calls":[...],"feeToken":"0x..."}'  # Expected: JSON with nonce, maxPermitAmount, deadline
curl http://localhost:3000/api/v1/status/0xTX_HASH         # Expected: JSON with status field
```

### Final Checklist
- [ ] All "Must Have" present
- [ ] All "Must NOT Have" absent
- [ ] `npx tsc --noEmit` passes with 0 errors
- [ ] All 5 endpoints respond correctly
- [ ] Error scenarios return correct HTTP status codes (400, 401, 422, 503)
