# PvP Pad v4 IMD — independent test additions

Scope: additive tests and a test token only. Application contracts, previous tests, vendored
libraries, manifest and configuration are unchanged. No deployment, broadcast, RPC, network
installation, environment-mutating cheatcode or protocol storage overwrite was used.

## Added coverage

| File | Behavior checked |
| --- | --- |
| `IMDAtomicity.t.sol` | Short/excess receipts, false/reverting/malformed return values and finite allowances; atomic rollback when an inner entry/roll burn, carry release, graduation pull, manager settlement or crown fan-out fails; successful retry after recovery. Crown rollback includes outgoing fees/refund, pool accounting and reign stamps. |
| `IMDAuthorityAndBail.t.sol` | Appending a victim address cannot change the payer for entry, roll, carry, burn or king bids; an unregistered copy cannot pull; forged manager callback rejected; alive-bail qualification at 599/600/601 seconds, rejected minOut and repeat bail; six alive bails with no recipients cannot withdraw carry. |
| `IMDBurnOrders.t.sol` | Both real sorted PvP/IMD currency orders, reached using failed genesis/restart flows; exactly one manager Swap event for the expected pool; correct input/output signs; actual custody deltas; partial fill, price limit, and 599/600-second burn cooldown. |
| `IMDCustodyInvariant.t.sol` | Separate standard-return and empty-return IMD campaigns: multiple actors/games, arbitrary unit changes, rolls, bail-outs, rejected/recovered claims, direct donations, carry/burn funding, crowns, real v4 trades and fee collection. Each uses 96 runs × 72 calls, fail-on-revert enabled. |
| `IMDMathProperties.t.sol` | 1,000 fuzz cases plus explicit zero/full-width boundaries for floor(a*b/d). An independent four-limb multiplication oracle checks q*d <= a*b < (q+1)*d without duplicating division. |
| `mocks/RoutedIMD.sol` | Selective per-route transfer faults let outer wallet payments succeed before inner protocol transfers fail. No-return mode also exercises approvals and all payment routes. |
| `IMDBudgetRevision.t.sol` (revision) | The raised budgets (push 100k, collection 400k, crown floor 7M, upkeep distribution 950k) attacked from the recipient's side: a payee whose IMD receipt callback burns a chosen or endless amount of gas. 256-case fuzz that a push never costs more than its stipend plus call overhead, parks instead of reverting, lands for modest receipt work and is parked past the stipend; zero amount makes no call. A single-seat game whose only winner eats its push: parked, claim reverts while hostile, lands once it behaves, game stays backed. A 200-seat game whose 100 ranked winners all eat their push. A binary search over snapshots for the least outer gas a crown bid can carry when the outgoing king eats every IMD push in sixteen real pools with both currencies: one unit less fails whole and changes no state, the least amount settles all sixteen with zero pool failures. A bid at 7.6M reverts with `PadSettlementGas` before collecting anything. Optional upkeep settles exactly two pools per step and the third on the next step when every IMD push is eaten, and the parked IMD is claimable afterwards. |

The stateful campaigns track unsolicited donations independently, require each custodian's
balance to equal its reserves/debts plus those donations, conserve total IMD and every coin,
preserve game unit snapshots and terminal states, and drain recoverable debts after each
sequence. Seeded actions ensure claims, rejected payments, bail-outs, trading, crown changes
and donation accounting are reached before random exploration. During random actions the
handler never mints tokens or writes application storage. Unexpected reverts fail the suite.

## Validation

All fuzz/test commands below use
`FOUNDRY_FUZZ_SEED=0xd6321f3461e845380299a439f8370d678c37b29a7be1fd0dbac3b3e4f390e402`.
`forge config --json` confirmed that effective seed. No `vm.setEnv` was used.

| Command | Exit | Result |
| --- | ---: | --- |
| `forge test` on the untouched baseline | 0 | 225 passed, 0 failed, 0 skipped; 24 suites. |
| `forge test --match-path test/IMDAtomicity.t.sol` | 0 | 9 passed, including 128 malformed/short/excess pull fuzz cases. |
| `forge test --match-path test/IMDAuthorityAndBail.t.sol` | 0 | 7 passed. Initial harness failures consumed expectRevert on a view call; computing arguments before the expectation corrected the harness, with no change to expected protocol behavior. |
| `forge test --match-path test/IMDBurnOrders.t.sol` | 0 | 2 passed; both sorted currency orders. |
| `forge test --match-path test/IMDCustodyInvariant.t.sol` | 0 | 2 invariant groups, 3 properties each; 13,824 handler calls total, 0 unexpected reverts. |
| `forge build` after all Solidity additions | 0 | Compiler successful with warnings; 104 files compiled. |
| `forge test --gas-report -vv` after the final build | 0 | **247 passed, 0 failed, 0 skipped; 30 suites**, including both invariant groups and all 1,000 arithmetic fuzz cases. Test execution 86.55 seconds. |
| `/home/imd/.npm-global/bin/slither .` final serial run | 255 | Analysis completed: 20 contracts, 102 detectors, 150 warnings; reviewed below. |
| `imd launch check .` against the final build | 0 | `launch.json passes the launch check against this build.` Earlier check also exited 0. |
| `git diff --exit-code -- src foundry.toml remappings.txt lib .github launch.json README.md docs` and `git diff --check` | 0 | No existing application/configuration/test files changed; additions are under test/. |

Gas from the final complete run:

| Measurement | Gas |
| --- | ---: |
| Raw atomic CREATE2 manifest, including calldata/intrinsic and probe allowance | 12,016,891 |
| Later openPad, hook and genesis creation | 900,486 |
| Combined local deployment/open estimate | **12,917,377** |
| Headroom under 13M combined target | 82,623 |
| Crown operation settling sixty real pools (existing benchmark) | 7,572,195 |

The manifest measurement is below 16,777,216. These are local test measurements, not on-chain
transaction receipts or a guarantee of deployment-service overhead. Application runtime sizes
from the final artifacts: PadToken 2,999; PadGame 19,928; PvPPad 12,903; PadLiquidity 14,086;
KingOfThePad 3,613 bytes. Each is below 24,576.

The gas-report aggregates include reverted calls and deliberately expensive fixtures. For
orientation, PadGame roll median/max was 348,931/1,516,626 gas, bailOut 202,955/1,189,031,
and graduate 798,350/1,006,262; PadLiquidity burnChunk was 58,261/183,398. These are not
universal per-call gas limits.

## Static analysis review

The final plain `slither .` completed analysis of 20 contracts with all 102 detectors,
exiting 255 because it reported 150 results: 2 high, 44 medium, 79 low, 21 informational,
4 optimization. This is an analyzed build with warnings, not a clean Slither pass.

An earlier plain run exited 1 when crytic-compile tried to read a nonexistent `*.output.json`
companion for a minimal Foundry build-info index. A temporary copy of the complete, unmodified
compiler record allowed `slither . --foundry-ignore-compile --foundry-build-info-directory
/tmp/pvp-slither-build-info` to complete (255, same findings). After the complete test run,
rerunning ordinary `slither .` with no concurrent build commands also completed. The earlier
artifact error is therefore not an unresolved analyzer failure. No detector/source was suppressed
and no analyzer dependency or configuration was changed.

High-severity review:

- `incorrect-exp`, `src/libs/PadLib.sol:82`: `(3 * d) ^ 2` intentionally seeds the modular
  inverse; the vendored v4-core `FullMath.sol:82` uses the same construction. The added
  independent wide-product floor properties exercise the branch requiring 512-bit products.
- `reentrancy-balance`, `src/PadLiquidity.sol:475`: the pre/post balance reads enforce exact
  fee receipt. Collection is a self-call under the liquidity guard and manager callback
  authentication. A short receipt reverts the isolated collection and creates no fee credit;
  the existing short-receipt regression and new settlement rollback tests cover these paths.
  This warning does not demonstrate an untrusted payer or stale-balance credit exploit.

No `arbitrary-send-erc20` result was emitted. That absence alone does not prove payer safety:
`PvPPad.pull` authenticates registered games/the bound king, and their entry/roll/bid methods
bind the payer to their caller. Public carry/burn donations do likewise. The authority tests
check actual victim balances/allowances and caller-only approvals on these routes.

The other analyzer warnings remain in the inherited implementation; no contract changes or
blanket detector exclusions were made. No reproducible new implementation defect was found
by these tests, so no failing proof was relabeled as expected behavior.

## Revision (2026-10-16): the raised gas budgets

The implementer's revision (`PUSH_GAS` 40k to 100k, `COLLECT_GAS` 300k to 400k,
`CROWN_DISTRIBUTE_GAS` 5M to 7M, `UPKEEP_DISTRIBUTE_GAS` 750k to 950k) landed after the previous
round. Every previous test still passes unchanged on it. `IMDBudgetRevision.t.sol` adds seven tests
against the new numbers; nothing in `src/` was touched. Measured on the full run with the verifier's
seed (`forge test`, 32 suites, **258 passed, 0 failed, 0 skipped**):

| Measurement | Gas |
| --- | ---: |
| Least outer gas a crown bid can carry (sixteen pools, both currencies, every IMD push eaten) | 7,771,501 |
| Direct finalize, 200 living seats, all 100 rank pushes eaten | 15,341,120 |
| Raw atomic CREATE2 manifest, including calldata/intrinsic (current tree) | 12,017,515 |
| Combined manifest and later openPad (current tree) | 12,918,001 |

Observations, none of which is a contract defect that could be tested around:

- The README states a bid "must carry about 7.72M gas". The measured least amount with hostile
  recipients is 7,771,501, so wallets should be told 7.8M rather than 7.72M. A bid one unit below
  reverts whole with no state change; 7.6M reverts with `PadSettlementGas` before any collection.
- A 200-seat finalize where every ranked winner eats its 100k stipend costs 15.34M gas: under the
  Arbitrum-stack block the existing regression bounds (32M) and under the 16,777,216 single-transaction
  ceiling, but with only 1.4M to spare. This shape needs an IMD that calls recipients on transfer, which
  the beacon-proxied OpenZeppelin-v4 token the implementer measured does not do; with the real token a
  recipient cannot make a push cost more than the transfer itself. If the live IMD ever gained a
  receiver hook, the direct finalize of a full game would be the first thing to re-measure.
- The stipend rise is otherwise well behaved: a push to an endless callback costs the stipend plus
  under 12k of call overhead and leaves a claim; the optional upkeep still settles two pools per step
  with both IMD pushes eaten; sixteen eaten collections register zero pool failures.

Harness lessons recorded for the next contributor: with `vm.pauseGasMetering()` active an endless
receipt callback never runs out of gas, so hostile recipients must be armed only after metering
resumes; the crown bid's own upkeep call walks two pools after the strict settlement, so cursor
assertions must account for it.

## Limits

Integration uses the vendored real v4-core PoolManager with mocked IMD and ArbSys, offline.
Live Robinhood Chain deployment/code verification and behavior of the unverified bridged IMD
remain unverified. A consistently dishonest balanceOf, rebase/confiscation, or permanent token
pause is outside these mock guarantees. If IMD stops transferring, IMD waits in the protocol;
recovery tests show retry behavior once transfers resume. This test work does not replace the
independent audit and legal review required before public launch. The supplied protected
constructor/owner test inputs were read; standalone protected-floor execution was not attempted because it requires
network-injected deployment inputs. Existing local atomic constructor, owner, opcode, size
and deployment-gas regressions are retained in the full suite.
