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
