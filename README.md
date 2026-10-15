# PvP Pad v4 — IMD

Contracts-only launchpad for Robinhood Chain (4663), adapted from
`identity-md-launches/launch-1832-donotbuy` at `a9a48cb4b458f35160da7ec0693e4b422be684ca`.
Every launch is a Spireth game paid entirely in IMD; every successful launch graduates directly
into its coin/IMD pool. The parked ETH conversion route has been removed.

**Legal review and an independent audit are required before public launch.** This project's tests
and builder review do not replace either. See [AUDIT.md](docs/AUDIT.md) and
[TEST-REPORT.md](docs/TEST-REPORT.md).

Deployment creates no token supply, name, symbol, game clone, hook, pool or distributor.
`PadToken` and `PadGame` are sealed templates. The pad creates every actual token later, including
PvP at `openPad(salt)`. The supplied name `nobuy` is not deployment token metadata: this is a
contracts-only launch. No website is included.

## Deployment

All five applications deploy in one transaction, in this order:

| Contract | Static constructor arguments |
|---|---|
| PadToken | none |
| PadGame | none |
| PvPPad | `$owner`, `$contract:PadToken`, `$contract:PadGame` |
| PadLiquidity | poolManager, `$contract:PvPPad`, imd |
| KingOfThePad | `$contract:PvPPad`, `$contract:PadLiquidity`, `$owner` |

`launch.json` supplies the inherited manager `0x8366a39cc670b4001a1121b8f6a443a643e40951`
and IMD `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` (18 decimals). Owner and dev both resolve
to `$owner`, the supplied `0x5b95a971b4583a5f011e9da082acdd679b870d06`.
The manager address is inherited configuration, not a claim of live verification.

Constructors are nonpayable, take static arguments, and call only earlier manifest contracts.
One-shot bindings must occur in that atomic transaction. No external code is needed at either
manager or IMD address during deployment, and no configuration call follows deployment.
The owner may later open the pad with a mined hook salt; anyone may open after 30 days.
`address(hook) & 0x3fff` must equal `0x2000`. The genesis creator remains the owner.
See [VERIFY.md](docs/VERIFY.md) for the later explorer handoff. This task deploys nothing and calls no RPC.

## IMD and prices

Wallets approve **only PvPPad**. `enter()` and `roll()` pull their fixed IMD prices through
`PvPPad.pull(msg.sender, amount)`; `takeCrown(amount)` does the same. Only registered games and
the king may call `pull`, and their user-facing functions expose no arbitrary payer argument.
Public donations are `PvPPad.fundCarry(amount)` and `PvPPad.burn(amount)`, charged to their caller.
Internal contracts approve their fixed counterparties to move allocated funds. Each pull checks
before/after recipient balances and reverts unless the exact requested amount arrived. Ledgers
credit that verified amount, never a whole balance. Direct token donations create no credit.

`unit` starts at **1 IMD**. Only the owner may call `setUnit(u)`, from **0.1 to 10 IMD** inclusive;
every change emits `UnitChanged`. Games copy the unit at creation, including before their first
entry, and retain it forever. The first king minimum and burn cap use the current pad unit.
There is no pause, upgrade, sweep, fee setter, or arbitrary privileged mint.

| Item | IMD amount |
|---|---|
| Entry | 0.5 game unit |
| Roll | 1 game unit: 90% curve, 7% pot, 2% PvP burn, 1% resolver tip |
| Virtual curve | 400 game units against 1 billion virtual coins |
| Curve supply / sell-out | 800 million coins / 1,600 game units net raised |
| Finalizer | 0.5% of pot, maximum 2 game units, limited by roll income |
| First king bid | at least 4 current pad units |
| Later king bid | at least 110% of previous bid, after 1 hour |
| Burn | at most 8 current pad units per 10 minutes |

All percentages round down except the pot/dev remainder, which preserves exact accounting.
The `ether` suffix in Solidity denotes 10^18 raw token units; no application accepts native ETH.
The burn share also goes to the bucket during genesis and waits for its pool.

IMD is bridged and has unverified source. Empty ERC20 returns are supported; false, revert,
malformed returns, and short pulls are rejected. Fee-on-transfer and rebasing behavior are not
supported. If IMD transfers ever stop, the pad's IMD waits: no conversion, alternate asset,
withdrawal bypass, or administrator rescue is provided. Gas-capped payouts that fail become
claimable; they do not block other recipients. Game/king claims use `claim()`; pool-fee claims use
`PadLiquidity.claim(currency)` and `claimable(currency, payee)`, preserving IMD and coins in kind.

## Game and raffle

After PvP graduates, anyone can `launch(name,ticker,imageURL)` (limits 32/10/200 bytes).
Each actual token has a fixed billion-coin supply and transfers remain locked until graduation,
except authorized game/liquidity transfers. Authenticity comes from the pad registry, not a name
or shared template. There is no mint after a token's one-shot initialization.

One nonrefundable entry per wallet starts a ten-minute signup. The first fee becomes the one-time
draw bounty; all later entries fund the burn bucket. The first post-signup draw commits once.
At commit+4 through commit+257, the next three ArbSys L2 hashes determine the seed. Later capture
uses `keccak256(abi.encode(game, commitBlock, entryCount))`, with no recommit. The seed capturer
gets the bounty. Sparse Fisher–Yates with rejection sampling seats at most 200 wallets, in
32-trial chunks; play starts only when the draw finishes.

Roll cooldown is 60 seconds. A roll commits three future L2 hashes and moves height by -4..-1 or
+1..+4, clamped at ±50. Anyone can resolve up to 16 records, earning its reserved tip as a claim.
Expired rolls move height up to four toward zero and put their tip into the roll pot. Death is ten
minutes since last activity. A bell at ±50, everyone dead, or 50 minutes of play ends the game.
Living seats rank by absolute height, earlier commit, earlier roll, then randomized seat order.
The top ceil(living/2) split triangular weights; a bell ringer gets 20%. With no living seats,
the pot carries forward. Ranking dust also carries.

During play a seated wallet can `bailOut(minOut)`, including a dead seat while others keep playing.
All its coins return to the curve. For sell value V and actual curve cost C, it receives
`C + floor((V-C)/2)` if V >= C, otherwise `floor(0.9*V)`. The remainder joins the pot but never
roll income. A low payout reverts atomically. The erased seat cannot roll, rank, ring a bell,
receive prizes or qualify a game for king funding. Its pending roll still resolves once, with
zero height change and its original tip. Erased activity does not extend the all-dead clock.
An **alive-at-bail seat still counts toward the funded-release threshold**, separately from living
rankable seats. `imdRaised` and the release cap use net curve reserves after sales.

On-chain randomness is not VRF: sequencers and keepers can influence timing, and the fallback
is predictable. Multiple wallets are allowed. Independent resolvers and seed capturers should run
well within the hash window; the bounty and tips do not guarantee service.

## Funding, graduation and king

Carry stays in the pad during play. At finalization, at least five qualifying seats (living plus
alive-at-bail) and a living recipient allow only the unused part of
`min(3 * rollPot, 15% * netCurveIMD)` to be pulled. Existing king funding consumes the same cap.
Unreleased funding returns to carry. Bail taxes and donations cannot enlarge roll income or
bypass the net-curve cap. All-bailed games end immediately, fail without liquidity, burn the
remaining token supply, and allow genesis restart. [Audit #13](docs/AUDIT.md#13-funded-release-and-sole-buyer-economics)
derives the sole-buyer loss even when an alive bail preserves release.

After finalization, `graduate()` pulls the curve's IMD directly into PadLiquidity and seeds a sorted
coin/IMD pool at the final curve price: fee 10000, tick spacing 200, PadHook, ticks ±887200.
LP belongs to PadLiquidity forever, with no removal path. A 1 ppm haircut covers rounding;
IMD dust is donated into fee growth and excess launch coins go to dEaD. The token unlocks in the
same transaction. There is no conversion state, anchor, market observer, timeout, or native pool.

The first king bid is entirely split; later bids refund the previous bid and split only the extra:
50% games, 25% burn, 25% dev. Games are the last ten entered launches, with at least five entries
before drawing or five non-erased seats afterwards, weighted by roll income (equal if all zero).
With none eligible the games share carries. Free launches cannot displace entered ones.

Before a crown changes, fees are collected for the outgoing reign while gas fits, at least
min(16, poolCount) pools. Unreached and broken pools retain their old reign stamp, so their next
collection pays that king. Fees accrued between the change and delayed collection also go to that
earlier king; the new king can collect promptly. Before the first crown, fees stay in positions.
Three collection failures in distinct L2 blocks mark a pool broken; anyone can retry it.
A failed recipient transfer becomes debt and does not count as a pool failure.

`burnChunk()` buys PvP directly with bucket IMD in one unlock and sends output to dEaD. The
sqrt-price limit is 0.995 of spot downward or 1.004987562112089027 upward, inside 1% price impact.
Partial fills retain unspent IMD in the bucket. This is an impact bound, not an absolute-price
oracle or a guarantee against MEV.

## Bounded work and offline checks

Game upkeep retains 4.5M gas per step, distribution 750k, burn 350k, and a 100k outer reserve plus
EIP-150 margin. The latest entered game and one older game are tended. Each collection has a
300k cap and 100k reserve. Crown settlement requires a 5M minimum stipend plus EIP-150 margin and
600k reserve; additional gas settles more pools. ERC20 payout attempts have a 40k cap and failed
payments remain claimable. Direct lifecycle calls remain available when optional upkeep is skipped.
Status values are 0 waiting, 1 signup, 2 play, 3 ended, 4 finalized, 5 graduated, 6 failed, 7 drawing.
Timers use timestamps; randomness and distinct failure blocks use ArbSys L2 numbers.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xd6321f3461e845380299a439f8370d678c37b29a7be1fd0dbac3b3e4f390e402 forge test
python3 tools/validate_manifest.py
```

The inherited Foundry configuration and all vendored dependencies are unchanged: Solidity 0.8.26,
Cancun, via-IR, optimizer 1, bytecode_hash none, no CBOR metadata, FFI disabled. The configuration
also retains its original fuzz seed; the report records checks with both seeds. Tests use the real
vendored v4-core PoolManager and mock IMD/ArbSys, with no network, environment, or RPC dependency.
See [ADAPTATION.md](ADAPTATION.md) for changes and regression mapping.
