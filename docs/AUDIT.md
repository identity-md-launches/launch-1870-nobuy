# PvP Pad v4 IMD: builder review and audit history

This is a builder review, not an independent audit. Legal review and an independent audit are
required before public launch. Base: `identity-md-launches/launch-1832-donotbuy` at
`a9a48cb4b458f35160da7ec0693e4b422be684ca`. The original parked v4 review is preserved in
[AUDIT-V4-ETH-HISTORY.md](AUDIT-V4-ETH-HISTORY.md); v2/v3 histories also remain. Those histories
describe superseded ETH economics. This document describes the delivered IMD version.

The five manifest constructors create no token, pool, hook or distributor. They use static arguments
and call only earlier manifest contracts. Owner and dev are both `$owner`. Opening and creating
all tokens later, the sealed clone templates, raffle, tips, bail-outs, carry caps, king settlement,
reign stamps, and upkeep bounds remain. No network, RPC, deployment or broadcast was used.

## Imported findings: reproduction and disposition

| Finding | Evidence against the arrived code | Resolution / new evidence |
|---|---|---|
| `62ac7910a86e`, medium: late living bail cancels release | Original `_finalize` skips erased seats; original `test_erasureExcludesRankingBellLivingAndFundedReleaseButPaysPendingTip` passes while explicitly expecting no funding for four survivors. Replayed in the untouched baseline. | Separate `bailedAliveCount`, recorded at bail time; only funding qualification includes it. `IMDPadTest` covers four survivors, five other survivors, and existing king funding. |
| `b2e4d0cd8597`, medium: public anchor stalls conversion into native fallback | Replayed original `test_heldStallForTwentyFourHoursGraduatesNativeWhenNoIMDWasEverConverted` successfully on real v4-core. | Conversion, anchor, observer, escrow, deadlines and native pool route deleted. Direct graduation tests require both sorted coin/IMD orders and all net curve IMD. |
| `69340dd7c1a2`, low: failed IMD fee transfer freezes crown | An isolated baseline reproduction graduates PvP, donates IMD fees, makes transfer to the outgoing king return false, and observes `PadPoolCollectionFailed` on the next bid. | Failed IMD and coin transfers become currency-specific claims without failing collection. `test_failedIMDAndCoinPayoutsCannotBlockCrownOrBatch` and `V3PoolFailureEdgesTest` cover recovery. |
| `bf74e51f6da9`, inventory: all native value paths | Original game/king entry tests and original source accept payable ETH; manifest has four liquidity words including the native/IMD pool id. | All application entrypoints nonpayable; all value paths use IMD, exact pulls, internal ledgers and unit pricing. ETH rejection, access, balance and no-return tests added. |
| `fff85b548028`, information: clones and later hook | Original and retained template-sealing/opening tests reproduce the architecture. | Deliberately retained by the explicit brief. Manifest runtimes have no escape opcodes; later EIP-1167 clones delegate to sealed immutable templates. Clones initialize atomically in `_create`. |

No imported finding was dismissed as non-reproducible. The informational architecture finding is
an accepted design constraint, not an authorization defect.

## Preserved fixes and current trust model

1. **Randomness and resolvers.** Three future ArbSys L2 hashes remain sequencer-influenceable,
   not VRF. Timely resolution earns 1% of the game's unit; expired tips go to the pot, with the
   original height penalty. At most 16 records and a 200k gas floor. Upkeep forwards the real
   beneficiary. The ten-blocks-per-second, boundary and idempotence regressions remain.
2. **Finalization bounds.** Packed-key heap sort remains O(n log n), at most 200 seats and 100
   rank payments. Capped ERC20 attempts replace native sends; failure creates a debt. The
   200-living-seat gas regressions remain. Direct finalization is available if optional upkeep
   cannot fit an unusually expensive finalization.
3. **Upkeep isolation.** Game steps retain 4.5M, distribution 750k, burn 350k, with cap/63 plus
   100k reserve checks; return immediately below 150k. Latest entered game plus round-robin older
   game, two pools, one burn. Full-stipend OOG cannot consume the user's reserved gas. No market
   observation remains. Local estimate/replay and deliberately exhausted stipend tests remain.
4. **Genesis recovery.** Zero net curve IMD means failed graduation; no roll or all coins returned
   by bail-outs both qualify. Remaining supply burns and anyone may restart genesis. Entry and
   non-curve roll costs remain, although a sole seed capturer may recover the first entry fee.
5. **Liquidity rounding.** The permanent full-range position uses a 1 ppm liquidity haircut to
   avoid upstream upward settlement rounding. Every remaining IMD wei is donated in the same
   unlock. Excess coins go to dEaD. Quotes derive solely from net game accounting.
6. **Real v4 offline.** Tests use the unmodified vendored PoolManager and actual pool math,
   swaps, donations, liquidity, deltas and storage reads, including 2,400 actual paid rolls to
   sell-out. Mock IMD and ArbSys are explicit substitutes, not claims of live verification.
7. **Hook flags and initialization.** `openPad` requires exactly permission bit 13. The manager
   independently checks permissions. Only PadLiquidity can initialize a pool with PadHook.
8. **Burn impact.** One IMD-to-PvP swap per ten minutes, at most eight current pad units.
   Downward sqrt factor 0.995 / upward 1.004987562112089027 stay inside 1% price impact. Unspent
   IMD remains bucket-owned. Spot manipulation and MEV are not eliminated by relative limits.
9. **King accounting.** A first bid splits entirely; later bids refund the old bid and split the
   extra 50/25/25 to games/burn/dev. The king contract retains only failed payout liabilities.
10. **Token locks.** Before graduation only game/liquidity may move coins. Approvals cannot
    bypass the lock. Reclaim is game-only while locked; only liquidity can unlock.
11. **Reentrancy and debt.** Games, king bids and claims retain guards. Pad pulls/donations/funding
    have a separate funds guard from upkeep. Effects precede payments. `PadLib` caps ERC20 push
    attempts at 40k, handles false/revert/malformed/empty returns, and bounds returndata copying.
    Game balances back curve IMD, pot, bounty, pending tips and claims. Liquidity balances back
    burn IMD and currency-specific claims; king balances back refunds/dev claims. Unsolicited
    donations are outside ledgers. Exact before/after receipt is required on every transferFrom and every manager fee withdrawal.
12. **Time.** Timestamp rules for signup, cooldown, death, opening and crown remain separate from
    ArbSys L2-block rules for hashes and pool failure counters.

## 13. Funded release and sole-buyer economics

At least five qualifying seats are required: non-erased seats alive at the game's end plus seats
that were alive when they bailed. `livingAtEnd` still counts only rankable, non-erased living seats.
A dead-at-bail seat adds nothing to the qualification count. An erased seat never ranks, rings a
bell, receives a prize or contributes to king eligibility. An all-bailed game has zero net curve
reserve, no winners and fails cleanly; carry is not pulled when no living recipient remains.

The funded release remains `min(3 * rollPot, 0.15 * e)`, with **e = net curve IMD**, after all
bail-out sell values. Bail taxes are excluded from roll income, king weights, and the roll-income
ceiling on the finalizer fee. Existing king funding consumes the cap before carry. Excess funding
returns to carry. Keeping an alive bail in the count removes a cancellation attack without
increasing the economic ceiling.

Let R = 400u IMD (u is the game's snapshotted unit), N = 1 billion virtual coins, S = all curve
purchases, V = all bail sell values and H = all withheld bail amounts. Net reserve e = S − V.
Credit the sybil with every pot prize, every resolver tip, the finalizer payment and all H: its
remaining curve outlay is still e. Entry fees, burn spending, gas and pool fees are omitted to
give the attacker a more favorable bound. The outstanding coins and graduation reserves are,
ignoring negligible rounding:

```
0 <= e <= 4R
T = N e / (R + e)                     outstanding buyer coins
P = (R + e)^2 / (N R)                 final IMD per coin
L = e / P = N R e / (R + e)^2        coins paired with e IMD
```

Dumping all T into that permanent pool, ignoring its 1% fee even if the sybil is king, recovers
at most `e*T/(L+T) = e*(R+e)/(2R+e)` IMD. Therefore at least
`e*R/(2R+e) >= e/6` remains permanently in LP. The largest funded rebate is `0.15e`, leaving a
strict loss margin of at least **e/60**. At sell-out with u = 1 IMD, e = 1,600 IMD: the retained
curve amount is at least 266.666… IMD versus at most 240 IMD released, a margin of 26.666… IMD,
before entry, burn, gas or pool fees. Bail-outs move the calculation to smaller net e, even when
an alive bail preserves qualification. At e = 0 there is no funded rebate.

Finite full-range ticks, integer rounding against traders and the 1 ppm haircut cause small
rounding differences, far below this margin over the configured units. No IMD/ETH venue depth,
conversion rate or anchor assumption remains. This is a sole-buyer, closed-pool argument without
outside buying or favorable external price movement, not a guarantee about speculative coin value.
`IMDPadTest.test_soleBuyerSybilWithAliveBailAndFourSurvivorsStillLoses` plays five wallets, bails
one in profit while alive, releases funding to four survivors, and sells every remaining coin
on real v4-core. It credits all tips, bounty and finalizer proceeds and still loses.

## Remaining inherited safeguards and v4 changes

14. **Upkeep fee beneficiary.** `KingOfThePad.takeCrown` forwards its own caller to `upkeepFor`;
    only games and king may use that entrypoint. Finalizer fees do not strand in the king contract.
15. **Roll after bell.** Resolving one's previous roll can end the game; a second over-check
    prevents committing a new paid roll after that bell.
16. **Dead Imp bell.** A late-resolved roll can move height but cannot ring or earn the bell share
    if its seat is dead. Erased rolls always have zero height delta.
17. **Tie-breaks.** HeightReachedAt is the committing L2 block, then roll index, then seat index;
    resolution order cannot steal an equal-height rank.
18. **No native intake.** Every application, clone and hook has no payable method, receive or
    fallback. Value-bearing calls revert. As with any EVM address, forced native balance changes
    outside its code cannot be prevented; no path credits or spends such ETH.
19. **Atomic one-shot bindings.** `bindLiquidity`, `bindKing`, `startGenesis` retain first-caller
    semantics inside the one-transaction manifest. Separate transactions would expose an unsafe
    binding window. No owner is inferred from factory msg.sender or tx.origin.
20. **Game upkeep guard.** `upkeepStep` holds the game lock during finalization and graduation;
    it does not rely solely on a payout stipend for reentrancy protection.
21. **Crown liveness.** Bids and collection reject an already-unlocked manager using the pinned
    Lock transient slot. Crown settlement receives surplus gas above a 600k reserve with a 5M
    minimum plus EIP-150 margin. Unflagged *pool collection* errors still veto bids; recipient
    payment errors now become claims. Ordinary distribute records three distinct-block failures
    before marking a pool broken; funded gas checks prevent fake failures through starvation.
    Pool retry and the separate liquidity claim lock remain, including the claim-callback crown
    regression. Receiving an ERC20 normally has no callback; mock callbacks stress this boundary.
22. **Paid raffle and sybils.** The unlimited entry list and 200-seat randomized sample remain.
    With exactly 200 honest entries, 240 bot entries give approximately a 95% chance of a strict
    101-seat majority under ideal unbiased sampling. Their gross fees are 120u IMD; with no honest
    entrants 101 wallets cost 50.5u. One first-entry bounty can be recovered. This is not identity
    verification or Sybil resistance.
23. **Fixed draw seed and bounty.** One commit, one capture, one payment. Fallback has no
    recommit, and sparse Fisher–Yates chunks resume the same seed. Draw completion starts fresh
    clocks. A sole keeper can choose prompt capture versus the known fallback; sequencer influence
    remains. All entry count/chunk/order/bounty/reentry regressions remain.
24. **Explicit v4 settlement currency.** Each ERC20 payment calls sync(token), transfers, then
    requires settle() to report the exact amount. An unrelated prior sync cannot poison the
    settlement. The native settle branch is removed because no native pool exists.
25. **No deployment token.** Constructors seal templates and bind applications only. Opening
    later atomically deploys PadHook and genesis clones. The requested `nobuy` metadata does not
    create a deployment token.
26. **Carry/entered-list rules.** Free launches do not enter upkeep or the king window. Draws
    never pull carry. Only finalization requests the unused cap, now with the alive-bail rule.
    Multi-game carry-chain and no-roll chain regressions remain. Anyone may donate to carry.
27. **Clone authenticity.** Look-alikes outside the registry confer no pad authority. The
    templates are sealed; registered clones initialize in the same creation call. Use tokenOf,
    gameOf and isGame to identify official launches. No proxy implementation can be changed.
28. **Indexes and tick constants.** Entered/Seated use 1-based indexes consistent with views.
    Full-range sqrt constants match vendored TickMath at ±887200. Tests retain both checks.
29. **Reign stamps.** Every pool carries settledReign. A crown closes the old reign and walks
    as many pools as gas allows, at least min(16, count). Unreached/broken pools later pay the
    earliest unsettled reign, including fees earned in the delay before collection. Cursor
    steering cannot redirect old fees. Eighteen-, forty- and sixty-pool tests remain.
30. **Predictable fallback disclosure.** The first committer can choose among observable commit
    blocks and later withhold capture. The prescribed fallback formula remains unchanged; no
    VRF or identity assumptions are added. Independent timely capture remains desirable.
31. **Bail and pending liabilities.** Reclaim returns all coins, C counts only actual curve spend,
    minOut is atomic, activity of erased seats cannot delay the end, and pending tips persist.
    Selling after full sell-out reopens capacity. Alive-at-bail is snapshotted once, separately
    from ranking and king eligibility; no erased seat can bail twice or reuse the count.
32. **Conversion removed.** No conversion escrow, anchor, observeMarket, progress timestamp,
    timeout, intermediate asset or converting status remains. Earlier conversion-specific fixes
    and tests are retired with their entire attack surface, not replaced with a new oracle.
33. **Direct graduation.** Registered game and matching token only; exact IMD pull; sorted
    currencies; final curve price; permanent full-range LP; donation of IMD dust; excess coin
    burn and unlock in one atomic transaction. Failure leaves the game and its funds unchanged.
34. **One-hop burn and fees.** Bucket-owned IMD alone funds the swap. Positive input with zero
    output reverts. Pool fees pay the captured reign in IMD and coins, never a fee sale. Failed
    transfers become claims denominated in that same currency and do not mark the pool broken.
35. **Size/gas constraints.** No linked libraries. Snapshotted prices are derived from one stored
    unit, reducing creation storage/gas. Initialized emits the snapshot unit. Runtime/initcode,
    forbidden-opcode scan, empty-chain atomic construction and later open gas are independently
    exercised locally. Exact figures are in TEST-REPORT.md; actual factory overhead is a later
    deployment-service responsibility.
36. **Manifest.** PadLiquidity takes exactly `(poolManager, pad, imd)`. No venue/pool-id arg,
    launch token, zero party address or post-deployment call. Arguments are strings and addresses
    lowercase. `tools/validate_manifest.py` checks the actual compiled ABIs and bytecode offline.
37. **Unit authority.** Owner may select 0.1–10 IMD inclusive and every selection emits an event.
    Existing games never change price. New games, first-crown minimum, and burn budget follow
    the documented rules. Unit does not change percentages, past bids, token supply or LP.
38. **IMD dependency.** IMD is a bridged token with unverified source. We cannot prove its future
    transfer availability or administrative behavior. If it stops transferring, the pad's IMD
    waits; no native fallback exists. Exact pulls reject short receipts, but balanceOf cannot
    prove solvency against a malicious token that lies consistently. Rebasing, confiscation,
    and dishonest success returns are outside the supported standard ERC20 assumptions. Payout
    failures park recipient claims; failure of the token or manager itself can leave pool fees
    in LP until recovery. This dependency requires independent review before opening.
