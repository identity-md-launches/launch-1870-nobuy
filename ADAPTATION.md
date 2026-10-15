# Adaptation: PvP Pad v4 in IMD

Base supplied project: `identity-md-launches/launch-1832-donotbuy`
`a9a48cb4b458f35160da7ec0693e4b422be684ca`, parked and never deployed.
This deliverable is a fresh contracts-only launch. No launch token named `nobuy` is created;
the explicit final no-token-at-deployment decision governs the supplied token-name field.
No website, deployment, broadcast, RPC call, or new dependency was needed.

## Changes and reasons

| Files | Change | Required by |
|---|---|---|
| `src/libs/PadLib.sol` | Internal-only ERC20 safe-call helpers; optional empty returns, bounded returndata, exact received-amount transferFrom checks; 100k payout attempts, full-gas explicit claims | Unverified bridged IMD compatibility, exact funding and nonblocking payouts. ERC20 storage work replaces the original 30k native-send allowance. |
| `src/libs/PadLib.sol` (revision) | `PUSH_GAS` 40k to 100k | Reviewer finding `eda71ad0cb97`, reproduced: a beacon-proxied OZ-v4 transfer to a fresh holder needs 39,950 gas and 44,735 with one extra storage read, so the old stipend parked every first-time payout as a claim. 100k gives more than 2x headroom; `test/PushStipend.t.sol`. |
| `src/PadLiquidity.sol`, `src/KingOfThePad.sol`, `src/PvPPad.sol` (revision) | `COLLECT_GAS` 300k to 400k, `CROWN_DISTRIBUTE_GAS` 5M to 7M, `UPKEEP_DISTRIBUTE_GAS` 750k to 950k | Follow-on of the stipend change: a pool collection pays two currencies, so a gas-eating recipient could exhaust the 300k collection cap and veto a crown bid; the crown floor of sixteen pools and the two-pools-per-upkeep rule keep their meaning with the larger cap. Tests that hard-code the minimum bid gas moved from 5.8M/6M/7M to 7.8M/8M/9M. |
| `test/IMDPad.t.sol` (revision) | `test_deadSeatBailDoesNotQualifyFundingAnyMoreThanIdlingDid` | Reviewer advisory `71256782`: behaviour kept (the brief's CHANGE 3 counts a bail taken while alive); the test and AUDIT.md #13 state that a dead seat, bailed or not, never qualified. |
| `src/PvPPad.sol` | Authenticated `pull(from, amount)` for registered games/king; caller-funded carry and `burn(amount)`; guarded funding; unit owner setter and event; game funding in IMD; remove market observations | CHANGE 1: players approve only the pad; all value in IMD; owner unit 0.1–10 IMD, initially 1. |
| `src/PadGame.sol` | Nonpayable entry/roll/lifecycle; fixed prices pulled from caller; unit copied at creation; all ledgers, fees, tips, bounty, curve, bail and payouts in IMD | CHANGE 1. Virtual reserve 400 units; 800M curve coins; sell-out at 1600 units. Roll split 90/7/2/1, including genesis burn to its waiting bucket. |
| `src/PadGame.sol` | One stored unit with derived price getters; `Initialized` includes unit | Preserve snapshots without redundant creation SSTOREs, meeting combined gas target; expose the selected price unit in creation history. Changes event ABI for this fresh deployment. |
| `src/PadGame.sol` | `bailedAliveCount` snapshots living status at bail; funding threshold uses surviving living + alive-bailed; rank, payout, bell and king eligibility exclude erased seats | CHANGE 3 and reproduced finding `62ac7910a86e`. Zero living recipients do not pull carry; all-bailed games fail/restart normally. |
| `src/PadGame.sol`, `src/PadLiquidity.sol` | Delete prepare/start/execute conversion, escrow state, anchor, observeMarket, all conversion intervals/deadlines/fallbacks and status 8; graduate immediately from finalized net IMD | CHANGE 1 and reproduced anchor-stall finding `b2e4d0cd8597`. No native pool or alternate-asset fallback remains. |
| `src/PadLiquidity.sol` | Constructor `(poolManager,pad,imd)`; direct exact IMD pull at graduation; sorted coin/IMD key; final-curve price; existing full-range permanent LP and 1 ppm haircut; donate quote dust and burn excess coins; atomic unlock | Requested direct graduation, both currency orders, three-word manifest. Native settlement deleted; every token settlement checks actual manager receipt, and fee withdrawals check actual application receipt before credit. |
| `src/PadLiquidity.sol` | One-hop IMD-to-PvP burn; at most 8 current units/10min; existing within-1% directional price limits; partial unspent input retained | CHANGE 2; no intermediate bucket or second venue. |
| `src/PadLiquidity.sol` | Currency-specific `claimable(currency,payee)` / `claim(currency)` for failed IMD **and coin** payouts; fee counters stay in kind; no pool failure for recipient rejection | Reproduced finding `69340dd7c1a2` and explicit payout requirement. Reign stamps and collection-error/broken-pool handling remain. |
| `src/KingOfThePad.sol` | `takeCrown(amount)` pulls caller's IMD; first minimum 4 current units; subsequent +10%/one-hour rules retained; IMD refunds, funding, burn/dev share and claims | CHANGE 1. Owner/dev constructor role remains `$owner`; no external constructor dependency. |
| `src/interfaces/*` | Updated IMD APIs; removed obsolete conversion/native APIs and errors | ABI changes follow removed features and nonpayable surfaces. |
| `launch.json`, `tools/validate_manifest.py` | Five unchanged application names/order; three liquidity arguments, all strings; both roles `$owner`; lowercase supplied addresses; validate ABI, sizes, opcodes, nonpayable surfaces, compiler settings and links | The task explicitly asks for LAUNCH.JSON and validation, overriding the background instruction to leave it to a later step. |
| `test/mocks/IMD.sol`, `test/Base.t.sol`, `test/RealV4.sol` | Standard and no-return IMD mocks with allowances, short/failing transfers and optional adversarial callbacks; IMD wealth/approval fixtures; real router handles both currency orders | Offline real-v4 testing of all new value paths; no substituted AMM math. |
| Existing test suites | Port native payments/wealth assertions to IMD, adjust specified prices/rounding, currency order and rejected-transfer claims; keep raffle, carry, resolver, crown, reign, gas, constructor and adversarial regressions | Every applicable v3 regression remains executable. Old native recipient tests become token-failure/callback tests; bare ETH rejection is tested separately. |
| `test/IMDPad.t.sol`, `test/V4BailIMDInvariant.t.sol`, `test/Invariants.t.sol`, retained bail suites | New unit, payer access, short receipt, donation isolation, no-return, ETH rejection, both-order price/unlock, burn cap/partial fill, late-bail, failed payout, sybil and conservation coverage | Explicit requested tests. Live seeded invariant adds bailout operations to full-system IMD/coin/accounting properties. |
| `test/V4Pad.t.sol`, `test/V4Edges.t.sol`, deleted `test/V4BailConversionInvariant.t.sol` | Retain bail, minOut, dead/erased/pending, sell-out/rebuy, all-bailed and fuzz coverage; remove only conversion/anchor/native-fallback scenarios; replace combined conversion invariant with IMD lifecycle invariant | Their conversion-specific expectations contradict the deliberate removal. V3 regressions are not removed. |
| `docs/AUDIT.md`, `docs/AUDIT-V4-ETH-HISTORY.md` | Archive arrived audit; map all imported findings and retained fixes; re-derive #13 directly in IMD, with alive-bail rule; document IMD transfer-stop dependency | Requested audit update and sole-buyer argument. |
| `README.md`, `docs/VERIFY.md`, `docs/TEST-REPORT.md` | Current APIs/economics, dependency and ownership model, offline validation/gas evidence, robin.etherscan.io handoff, legal review and independent audit before opening | Required delivery documentation. |

## Reproduction and scope

The untouched baseline was rehearsed locally with its own configuration and real v4-core.
The original 24-hour stall test passes while producing its unwanted native fallback; the original
erasure test passes while expecting a cancelled funded release. An isolated reproduction with
false-return IMD fees confirms the crown bid reverts `PadPoolCollectionFailed`. These are fixed
by deleting conversion, retaining alive-bail funding qualification, and parking failed payouts.
The native-value inventory is confirmed by original payable game/king tests and source signatures.
No imported finding was non-reproducible. The fifth finding is informational: explicit requested
immutable clones, one-shot initializers and later hook creation remain, with sealing/authenticity
and atomic-construction tests.

No existing build configuration or dependency was changed: `foundry.toml`, remappings, vendored
libraries, package/lockfiles and git submodule metadata remain untouched. No new dependency,
submodule, account, key, or runtime is required offline. Test scaffolding in `test/scratch` is not
part of the deliverable. Local checks are evidence for review, not an independent security audit.
