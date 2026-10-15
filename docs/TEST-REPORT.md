# PvP Pad v4 IMD test report

Local offline checks on 2026-10-15: Foundry 1.8.3, Solidity 0.8.26, Cancun, via-IR,
optimizer 1, `bytecode_hash = "none"`, `cbor_metadata = false`. The supplied configuration
and vendored dependencies are unchanged.

**225 tests passed, zero failed, zero skipped, across 24 suites**, with both the assignment's
fuzz seed and the inherited configuration's seed. Foundry aggregates each invariant suite into
one result; the individual properties and action counts are listed below. `forge build` and the
compiled-artifact manifest validator also pass.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xd6321f3461e845380299a439f8370d678c37b29a7be1fd0dbac3b3e4f390e402 forge test --gas-report -vv
forge test
python3 tools/validate_manifest.py
```

The plain test run uses the original configured seed:
`0xb5c5a9b40cefda723aeaf099e10ee3bceaa5447ce85a23ffe7d1b73cc8363f6c`.
The final supplied-seed run took 18.39 seconds; the default run took 15.95 seconds on this runner.
Compiler heuristic warnings about casts, timestamps and guarded external calls remain. These
results are local evidence, not an independent audit or a claim of warning-free static analysis.

## Coverage and regression changes

| Area | Evidence |
|---|---|
| IMD intake and payer authority | Registered clones and king alone may call pull; entry charges its own caller; players approve only the pad. Short receipts revert atomically. Public carry/burn donations pull their caller. Unsolicited balances never become carry, burn, game or graduation credits. |
| Optional ERC20 returns | A no-return IMD variant runs the full game, graduation, crown, fee claim and one-hop burn on the real manager. False/reverting recipient payments are separately exercised. |
| Prices and unit | Initial 1 IMD; owner-only bounds 0.1–10 inclusive; event; existing-game snapshot; new-game prices; arbitrary-unit rounding fuzz; first-bid minimum and current-unit full-fill burn cap. |
| Native rejection | Bare ETH to all five applications, both genesis clones and the hook reverts; value-bearing entry also reverts. Compiled ABIs contain no payable method or native receiver. |
| Direct graduation | Final-curve price equivalence, both sorted currency orders, full-range tick constants, permanent position, quote dust donation, excess coin burn, atomic token unlock, donation isolation, smallest raise and sell-out after 2,400 actual rolls. |
| One-hop burn | Actual v4 swaps, both directions, price limits, partial fills, retained input, current-unit cap, interval, bucket/manager/dead balances and unrelated prior sync. No conversion venue exists in the application. |
| Bail-outs | Profit, loss, minOut rollback, zero coin balance, dead/erased seat, pending roll tips, hard end/bell rejection, sell-out/rebuy, all-bailed failure, rejected payout claims and repeated-bail exclusion. |
| Late bail and funding | Five initial living seats with one alive bail retain release to four rankable survivors; six-seat variant; already-funded king money remains releasable. Erased seats never rank, ring, win or qualify a game for new king funding. |
| Sole-buyer economics | Five-wallet profitable-bail scenario keeps funded release and dumps all remaining coins through the real coin/IMD pool; aggregate buyer still loses. AUDIT.md #13 gives the bound in IMD. |
| Crown and in-kind fees | IMD bids/refunds/dev split; IMD and coin fee claims; failed recipient does not break a pool or freeze the crown; short manager receipt cannot create fee credit; reign stamps, cursor steering, 18/40/60-pool settlement, distinct-block failure/retry, manager-unlock and reentrancy regressions. |
| Raffle, game and upkeep | All applicable inherited v3 regressions: fixed/lapsed seed and one-time bounty, 5,000 entrants, statistical selection, 200 living seats, ranks/bell/death, resolver expiry/tips, carry chains and caps, entry/roll gas isolation, bounded upkeep and malicious callback recipients. |
| Deployment policy | Raw atomic CREATE2 manifest rehearsal, no external dependency code during constructors, zero token supply/name/symbol, sealed templates, no initial pool/hook, ownership/bindings, runtime sizes, no application escape opcodes or library links. |

Tests use the unmodified vendored **Uniswap v4-core v4.0.0 PoolManager**, including its actual
liquidity, swaps, donation, fees, transient lock and settlement code. IMD and ArbSys are local
fixtures. No successful pool operation substitutes mocked AMM math. Recipient failures and
selected ranking states use explicit adversarial fixtures. Local fixtures establish neither live
IMD behavior nor production randomness.

The old v3 native-value tests are ported to IMD with the requested price changes and token failure
callbacks. Some inherited test names still contain `ETH`; their balances and assertions now use
IMD. Only conversion/anchor/escrow/native-fallback v4 scenarios were retired because that entire
feature was removed. The former bail/conversion invariant is replaced by a seeded IMD lifecycle
campaign. Historical contributor reports and audit histories are marked as superseded.

## Fuzz and invariant campaigns

| Campaign | Final configured run | Properties |
|---|---:|---|
| Whole pad | 40 × 60 = 2,400 actions per seed | Curve price/supply bounds; pots, tips, claims and carry; pad/liquidity/king/game balance obligations; IMD conservation; coin supply and graduation unlock |
| Live game seeded with rolls/carry, including bail-outs | 40 × 60 = 2,400 actions per seed | Same whole-system properties, starting from a funded active game |
| Resolver accounting | 128 × 96 = 12,288 actions per seed | Every tip pending, expired or owed to its actual resolver; IMD and coin conservation |
| King fee accounting | 128 × 64 = 8,192 actions per seed | In-kind fees remain with their reign, including rejected payments; real-pool fees and bids conserve IMD |

The seeded live-game invariant also passed an earlier 64 × 500 = 32,000-action run before its
final per-test campaign settings were made explicit. Final campaign reverts are allowed adversarial
actions; property assertions all pass. Additional fuzz cases cover curve quotes (1,000 each),
monotonicity (500), crown splits/refunds/hold (200 each), ranks/funding/roll splits, bail sequences,
carry caps, pending liabilities and arbitrary unit values. Statistical raffle regressions remain.

## Gas

Measurements below come from the final supplied-seed run. They are operation gas or estimated
call limits as labeled, not the total gas of tests that build large fixtures.

| Operation | Gas |
|---|---:|
| Atomic raw-CREATE2 manifest, calldata/intrinsic and probe accounting included | **12,016,891** |
| Later openPad, hook and genesis clones, calldata/intrinsic included | **900,486** |
| Combined deployment and later opening | **12,917,377** |
| Crown transition: 16 real pools, both fee currencies, rejecting outgoing king | 4,907,515 |
| Crown transition: 18 real pools | 2,828,401 |
| Finalize: 200 living seats, adverse rank order | 4,394,041 |
| Largest 32-seat draw chunk at 5,000 entries, cold game | 2,688,595 |
| All seven draw chunks for 200 seats | 16,272,475 across separate calls |
| Entry with pending foreign draw/finalize/graduation, estimated call limit | 268,574 |
| Roll with pending foreign draw, estimated call limit | 266,738 |
| Roll with pending foreign finalize/graduation, estimated call limit | 270,410 |

The atomic rehearsal enforces the **16,777,216** hard deployment ceiling and **13M** combined
opening target. It includes runtime code-deposit cost, intrinsic/calldata gas and a 23k allowance
for probe bookkeeping/return overhead. Factory-specific attestation/wrapper overhead is not
simulated; the authorized deployment service must still simulate its complete transaction. The
combined target has 82,623 gas of measured headroom. Compiler/source changes require remeasurement.

Upkeep retains 4.5M per game step, 750k distribution, 350k burn, a 100k outer reserve and EIP-150
margin. Each collection retains 300k and a 100k reserve. Crown settlement retains a 5M minimum
stipend, EIP-150 margin and 600k outer reserve. ERC20 payout attempts use 40k instead of the old
30k native-send cap; failed attempts become claimable. Explicit claims forward remaining gas.
Tests exercise gas exhaustion without allowing optional upkeep to revert entry/roll.

## Artifacts and manifest

| Application | Initcode bytes without arguments | Runtime bytes | Constructor words |
|---|---:|---:|---:|
| PadToken | 3,044 | 2,999 | 0 |
| PadGame | 19,969 | 19,928 | 0 |
| PvPPad | 13,302 | 12,903 | 3 |
| PadLiquidity | 14,466 | 14,086 | 3 |
| KingOfThePad | 4,109 | 3,613 | 3 |

Total runtime: **53,529 bytes**, or **10,705,800** code-deposit gas. Every runtime is below 24,576
bytes; each initcode plus arguments is below 49,152 bytes. The validator checks compiled ABI
constructor order/types, nonpayable surfaces, static string arguments, backward references,
nonzero lowercase addresses, owner/dev `$owner`, no library links and the protected linear opcode
scan. PadLiquidity has exactly `(poolManager, pad, imd)`, with no pool-id argument.
No dependency was installed or changed; offline checks need only the supplied Foundry toolchain
and repository files. The configuration's metadata flags remain unchanged.

## Imported findings and economic evidence

The untouched original was rehearsed separately before the changes: its erasure test confirms
that one alive bail cancels funding; its 24-hour anchor-stall test confirms the unwanted native
fallback; a false-return IMD fee reproduction confirms `PadPoolCollectionFailed` freezes a crown
bid. Native-payable behavior and clone/template lifecycle were confirmed by original code/tests.
All three defects are covered by the replacements above; the native inventory was migrated and
the explicitly requested clone design was retained. ADAPTATION.md records each disposition.

The new five-wallet sole-buyer case includes one profitable alive bail, four living survivors,
funded carry release, finalizer/resolver receipts and a dump through coin/IMD. It loses
**12.160243613483469790 IMD** in aggregate, excluding gas. This is one concrete test, not an
arbitrage guarantee; AUDIT.md #13 states the mathematical bound and closed-market assumptions.

No deployment, broadcast, RPC, live code attestation, explorer submission, Slither/Mythril run or
independent audit was performed. IMD is a bridged token with unverified source: if transfers stop,
the pad's IMD waits. Legal review, an independent audit, live dependency review and the deployment
service's complete transaction simulation remain requirements before public opening.
