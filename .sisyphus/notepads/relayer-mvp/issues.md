# Scope Fidelity Check — Issues Found

## GAP (1 issue)

### T19: balanceMonitor.ts missing `checkConfigPaused()`
- **File**: `src/services/balanceMonitor.ts`
- **Plan requires**: Add `checkConfigPaused()` function that reads `config.paused()` and logs warning if paused. Called in `startBalanceMonitor` interval alongside `checkRelayerBalance()`.
- **What exists**: Only `checkRelayerBalance()`. No pause check anywhere in the monitor.
- **Impact**: Paused state will only be checked at startup (via startupCheck.ts) and on individual submit requests (via submit.ts). If Config is paused after startup while monitor is running, no proactive warning will be logged.

## CONTAMINATION / DESIGN DEVIATIONS (3 issues)

### #1: FIXED_GAS_OVERHEAD hardcoded in feeEstimator.ts
- **File**: `src/services/feeEstimator.ts:17`
- **What**: `const FIXED_GAS_OVERHEAD = 160_000n;`
- **Plan says (Must NOT do)**: "MUST NOT hardcode FIXED_GAS_OVERHEAD in relayer — simulation includes it automatically"
- **Context**: feeEstimator has its own gas estimation path (`estimateGasForCalls`) that estimates each call individually and adds FIXED_GAS_OVERHEAD. The simulator's `estimateGas` function (which simulates the full execute call with state override) exists but is unused by feeEstimator. This means the relayer doesn't benefit from the contract's actual FIXED_GAS_OVERHEAD — a stale hardcoded constant could mis-estimate fees.

### #2: setStakePool in Config ABI violates T1 guardrail
- **File**: `src/contracts/abis.ts:26`
- **What**: `"function setStakePool(address _stakePool) external"` in gasFlowConfigAbi
- **Plan says (Must NOT do for T1)**: "Do NOT include admin/owner functions in Config ABI (only read + processCompensation)"
- **Severity**: Low. The ABI entry is inert — never called by relayer code.

### #3: feeEstimator bypasses simulator.estimateGas
- **File**: `src/services/feeEstimator.ts:30-51`
- **What**: `estimateGasForCalls()` manually estimates each call individually + `FIXED_GAS_OVERHEAD` instead of calling `simulator.estimateGas()` (which exists at `simulator.ts:119`)
- **Plan says (T10)**: "Estimate gas via simulator.estimateGas(user, calls, feeToken) (with state override)"
- **Impact**: The fee estimator's gas estimate may diverge from the actual execution gas used during submission, as it doesn't account for state-dependent gas costs that the simulator (with full state override) would capture.

## MUST NOT HAVE — ALL CLEAN

All "Must NOT Have" guardrails verified:
- ✅ No `authorizationList` in submitter.ts (only in comment)
- ✅ No `/delegate` or `/undelegate` endpoint in server.ts or routes/
- ✅ No alt mempool, batch bundling, P2P networking
- ✅ No Redis or persistent nonce storage
- ✅ No webhook callbacks
- ✅ No multi-chain support
- ✅ No Prometheus/Grafana
- ✅ No `encodePacked` anywhere
- ✅ No `value` sent with submit transaction
- ✅ No hardcoded Chainlink feed addresses in config (read from Config at runtime)
- ✅ No `@ts-ignore` or `as any` anywhere
- ✅ No `authorization` field in SubmitRequest type

## TASK-BY-TASK MATRIX

| Task | Compliant? | Notes |
|------|-----------|-------|
| T1 (abis.ts) | ✅ | Minor: setStakePool admin fn in ABI (inert) |
| T2 (types) | ✅ | Exact match |
| T3 (config.ts) | ✅ | Exact match |
| T4 (.env.example) | ✅ | Exact match |
| T5 (clients.ts) | ✅ | getDelegatorNonce catches revert → 0n (pragmatic) |
| T6 (stateOverride) | ✅ | viem 2.x array format (correct adaptation) |
| T7 (userLock) | ✅ | Exact match |
| T8 (simulator) | ✅ | Exact match — digest, st override, no encodePacked |
| T9 (submitter) | ✅ | No authList, no value, balance check present |
| T10 (feeEstimator) | ⚠️ | Own gas est + hardcoded OVERHEAD (#1, #3) |
| T11 (startupCheck) | ✅ | All 8 checks, FATAL/WARN split correct |
| T12 (validator) | ✅ | All new field validations present |
| T13 (routes/config) | ✅ | Exact match |
| T14 (routes/balance) | ✅ | Exact match |
| T15 (routes/status) | ✅ | Exact match |
| T16 (routes/estimate) | ✅ | Exact match |
| T17 (routes/submit) | ✅ | Lock, delegation, pause, sig, sim, submit — all present |
| T18 (nonceManager) | ✅ | All bigint, no number |
| T19 (balanceMonitor) | ❌ GAP | checkConfigPaused() not implemented |
| T20 (server.ts) | ✅ | All 5 routes, startup checks, balance monitor |
| T21 (tsc) | ✅ | Exit code 0 |
