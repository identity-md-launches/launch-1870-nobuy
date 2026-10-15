// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TestIMD, NoReturnIMD, imdBalance, imdDeal, TEST_IMD} from "./mocks/IMD.sol";

import {BaseTest} from "./Base.t.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadGame} from "../src/PadGame.sol";
import {Rejector} from "./mocks/Mocks.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "../src/interfaces/Interfaces.sol";
import {PvPPad} from "../src/PvPPad.sol";

/// @notice Attacker that buys PVP, triggers the protocol's burn chunk, then sells back, all in one call.
contract Sandwicher is IUnlockCallback {
    IPoolManager immutable pm;
    PvPPad immutable pad;
    PadToken immutable token;
    PoolKey key;

    constructor(IPoolManager pm_, PvPPad pad_, PadToken token_, PoolKey memory key_) {
        pm = pm_;
        pad = pad_;
        token = token_;
        key = key_;
    }

    function attack(uint256 ethIn) external {
        pm.unlock(abi.encode(true, ethIn));
        pad.upkeep();
        pm.unlock(abi.encode(false, token.balanceOf(address(this))));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool buying, uint256 amountIn) = abi.decode(data, (bool, uint256));
        bool zeroForOne = buying == (key.currency0 == TEST_IMD);
        int256 d = pm.swap(
            key,
            SwapParams(
                zeroForOne,
                -int256(amountIn),
                zeroForOne ? 4_295_128_741 : 1461446703485210103287273052203988822378723970341
            ),
            ""
        );
        int128 a0 = int128(d >> 128);
        int128 a1 = int128(d);
        address input = zeroForOne ? key.currency0 : key.currency1;
        address output = zeroForOne ? key.currency1 : key.currency0;
        uint256 spent = uint256(uint128(-(zeroForOne ? a0 : a1)));
        uint256 got = uint256(uint128(zeroForOne ? a1 : a0));
        pm.sync(input);
        if (input == TEST_IMD) TestIMD(input).transfer(address(pm), spent);
        else token.transfer(address(pm), spent);
        pm.settle();
        pm.take(output, address(this), got);
        return "";
    }

    receive() external payable {}
}

contract KingTest is BaseTest {
    function setUp() public override {
        super.setUp();
        graduatePvp();
    }

    function test_firstBidMinimumAndFullSplit() public {
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadMinBid()"));
        king.takeCrown(3.6 ether);
        uint256 devBefore = imdBalance(OWNER);
        uint256 burnBefore = liq.burnBucket() + liq.totalBurnedIMD();
        uint256 carryBefore = pad.carryPot();
        vm.prank(players[0]);
        king.takeCrown(4.0 ether);
        assertEq(king.king(), players[0]);
        assertEq(king.bid(), 4.0 ether);
        // whole first bid is "extra": 50% games (none live -> carry pot), 25% burn, 25% dev
        assertEq(pad.carryPot() - carryBefore, 2.0 ether);
        assertEq(liq.burnBucket() + liq.totalBurnedIMD() - burnBefore, 1.0 ether);
        assertEq(imdBalance(OWNER) - devBefore, 1.0 ether);
        assertEq(imdBalance(address(king)), 0, "the whole first bid is split away");
    }

    function test_challengeNeedsHoldAnd110Percent() public {
        vm.prank(players[0]);
        king.takeCrown(4.0 ether);
        vm.prank(players[1]);
        vm.expectRevert(abi.encodeWithSignature("PadKingHolds()"));
        king.takeCrown(8.0 ether);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(players[1]);
        vm.expectRevert(abi.encodeWithSignature("PadBidTooLow()"));
        king.takeCrown(4.36 ether);
        uint256 p0 = imdBalance(players[0]);
        uint256 devBefore = imdBalance(OWNER);
        uint256 carryBefore = pad.carryPot();
        uint256 burnBefore = liq.burnBucket() + liq.totalBurnedIMD();
        vm.prank(players[1]);
        king.takeCrown(8.0 ether);
        assertEq(king.king(), players[1]);
        assertEq(imdBalance(players[0]) - p0, 4.0 ether, "old king refunded in full");
        // extra = 0.01: 0.005 games (carry), 0.0025 burn, 0.0025 dev
        assertEq(pad.carryPot() - carryBefore, 2.0 ether);
        assertEq(liq.burnBucket() + liq.totalBurnedIMD() - burnBefore, 1.0 ether);
        assertEq(imdBalance(OWNER) - devBefore, 1.0 ether);
        assertEq(imdBalance(address(king)), 0, "refund and extra leave nothing behind");
        assertEq(king.nextMinBid(), 8.8 ether);
    }

    function test_extraFundsLiveGamesByPotSize() public {
        uint256 a = pad.launch("A", "A", "");
        PadGame ga = PadGame(pad.gameOf(a));
        uint256 b = pad.launch("B", "B", "");
        PadGame gb = PadGame(pad.gameOf(b));
        uint256 c = pad.launch("C", "C", "");
        PadGame gc = PadGame(pad.gameOf(c));
        mintAll(ga, 5);
        mintAll(gb, 5);
        mintAll(gc, 4); // fewer than 5 imps: excluded
        advance(10 minutes);
        rollAs(ga, players[0]);
        rollAs(ga, players[1]);
        rollAs(gb, players[2]);
        rollAs(gc, players[3]);
        assertTrue(!ga.ended() && !gb.ended() && !gc.ended());
        uint256 potA = ga.pot();
        uint256 potB = gb.pot();
        uint256 potC = gc.pot();
        // Carry remains in the pad; king weights still use roll income only.
        assertEq(ga.fundedPot(), 0);
        uint256 rollA = ga.rollPot();
        uint256 rollB = gb.rollPot();
        assertGt(rollA, rollB);
        vm.prank(players[8]);
        king.takeCrown(400 ether);
        uint256 games = 200.0 ether;
        uint256 total = rollA + rollB;
        assertEq(ga.pot() - potA, games * rollA / total);
        assertEq(gb.pot() - potB, games - games * rollA / total);
        assertEq(gc.pot(), potC);
        assertEq(ga.rollPot(), rollA, "king share is funded, not roll-earned");
    }

    function test_refundToRejectingKingIsClaimable() public {
        Rejector rj = new Rejector();
        imdDeal(address(rj), 400 ether);
        vm.prank(address(rj));
        king.takeCrown(4.0 ether);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(players[1]);
        king.takeCrown(8.0 ether);
        assertEq(king.claimable(address(rj)), 4.0 ether);
        assertEq(imdBalance(address(king)), 4.0 ether, "claimable is backed");
        vm.prank(address(rj));
        vm.expectRevert(abi.encodeWithSignature("PadToken()"));
        king.claim();
    }

    function test_distributeSendsPoolFeesToKing() public {
        vm.prank(players[0]);
        king.takeCrown(4.0 ether);
        // simulate trading fees on the PvP pool: 0.1 ETH and 1000 PVP
        uint256 oldEthFees = liq.getPool(0).imdFees;
        uint256 oldTokenFees = liq.getPool(0).tokenFees;
        donateFees(liq.poolKey(address(pvpToken)), 40.0 ether, 1000 ether);
        uint256 before = imdBalance(players[0]);
        king.distribute(1);
        uint256 got = imdBalance(players[0]) - before;
        assertApproxEqAbs(got, 40.0 ether, 1, "ETH fees paid in kind");
        assertApproxEqAbs(liq.getPool(0).imdFees - oldEthFees, 40.0 ether, 1);
        assertApproxEqAbs(liq.getPool(0).tokenFees - oldTokenFees, 1000 ether, 1);
        assertEq(pvpToken.balanceOf(address(liq)), 0, "token fees fully transferred");
    }

    function test_distributeWithoutKingLeavesFeesInPosition() public {
        donateFees(liq.poolKey(address(pvpToken)), 40.0 ether, 1000 ether);
        uint256 ethFees = liq.getPool(0).imdFees;
        uint256 tokenFees = liq.getPool(0).tokenFees;
        uint256 bucket = liq.burnBucket();
        liq.distribute(3);
        assertEq(liq.getPool(0).imdFees, ethFees);
        assertEq(liq.getPool(0).tokenFees, tokenFees);
        assertEq(imdBalance(address(liq)), bucket);
        vm.prank(players[8]);
        king.takeCrown(4.0 ether);
        assertGe(imdBalance(players[8]), 4000 ether - 4.0 ether + 40.0 ether - 1);
        assertApproxEqAbs(pvpToken.balanceOf(players[8]), 1000 ether, 1);
    }

    /// @dev Deepen the PVP pool so a 0.02 ETH chunk moves the price by far less than 1%.
    function deepenPvpPool(uint256 r0) internal {
        PoolKey memory key = liq.poolKey(address(pvpToken));
        uint256 liquidity = uint256(liq.getPool(0).liquidity) * r0 / pvp.imdRaised();
        imdDeal(address(router), r0 * 2);
        // Deep-liquidity fixture needs more tokens than genesis circulating supply: this test-only
        // funding affects the router, never the PoolManager accounting or price calculations.
        deal(address(pvpToken), address(router), 100_000_000_000 ether);
        router.add(key, liquidity);
    }

    function test_burnChunkBuysPvpToDeadEvery10Minutes() public {
        deepenPvpPool(8000 ether);
        imdDeal(address(this), 400 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes); // upkeep already burned the graduation dust
        uint256 burnedBefore = liq.totalBurnedIMD();
        pad.burn(20.0 ether);
        uint256 initialBucket = liq.burnBucket();
        uint256 deadBefore = pvpToken.balanceOf(DEAD);
        liq.burnChunk();
        assertEq(liq.burnBucket(), initialBucket - 8.0 ether, "max 0.02 per buy");
        assertGt(pvpToken.balanceOf(DEAD), deadBefore);
        assertEq(liq.totalBurnedIMD() - burnedBefore, 8.0 ether);
        uint256 dead1 = pvpToken.balanceOf(DEAD);
        liq.burnChunk();
        assertEq(liq.burnBucket(), initialBucket - 8.0 ether, "one buy per 10 min");
        assertEq(pvpToken.balanceOf(DEAD), dead1);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        liq.burnChunk();
        assertEq(liq.burnBucket(), initialBucket - 16.0 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        liq.burnChunk();
        assertEq(liq.burnBucket(), 0);
    }

    function test_burnChunkStopsAtOnePercentPriceMoveAndKeepsTheRest() public {
        // thin pool (genesis raised about 0.02 ETH): a 0.02 ETH chunk would nearly double the price
        PoolKey memory key = liq.poolKey(address(pvpToken));
        uint160 before = liq.sqrtPriceOf(key);
        assertEq(before, managerPrice(key), "extsload reads slot0");
        imdDeal(address(this), 400 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        pad.burn(8.0 ether);
        uint256 bucket = liq.burnBucket();
        uint256 burnedBefore = liq.totalBurnedIMD();
        liq.burnChunk();
        uint256 spent = liq.totalBurnedIMD() - burnedBefore;
        assertGt(spent, 0, "a partial buy happened");
        assertLt(spent, 1 ether, "the thin pool caps the fill");
        assertEq(liq.burnBucket(), bucket - spent, "unspent ETH stays in the bucket");
        uint160 after_ = liq.sqrtPriceOf(key);
        assertLt(after_, before);
        assertGe(uint256(after_) * 10_000, uint256(before) * 9_950, "sqrt price moved at most 0.5%");
    }

    function test_sandwichOnBurnChunkDoesNotPay() public {
        PoolKey memory key = liq.poolKey(address(pvpToken));
        Sandwicher atk = new Sandwicher(pm, pad, pvpToken, key);
        imdDeal(address(atk), 400 ether);
        imdDeal(address(this), 400 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        pad.burn(8.0 ether);
        uint256 burnedBefore = liq.totalBurnedIMD();
        atk.attack(4.0 ether);
        assertGt(liq.totalBurnedIMD(), burnedBefore, "the chunk ran inside the sandwich");
        assertLt(imdBalance(address(atk)), 400 ether, "the attacker loses the pool fees on the round trip");
        assertEq(pvpToken.balanceOf(address(atk)), 0);
    }

    function test_takeCrownUpkeepPaysFinalizerFeeToBidder() public {
        uint256 id = pad.launch("Foo", "FOO", "");
        PadGame g = PadGame(pad.gameOf(id));
        mintAll(g, 3);
        advance(10 minutes);
        for (uint256 i; i < 3; ++i) {
            rollAs(g, players[i]);
        }
        advance(60 minutes);
        assertTrue(g.ended() && !g.finalized());
        uint256 fee = g.pot() * 50 / 10_000;
        assertGt(fee, 0);
        uint256 before = imdBalance(players[7]);
        vm.prank(players[7]);
        king.takeCrown(4.0 ether);
        assertTrue(g.finalized(), "upkeep finalized the due game");
        assertEq(g.claimable(address(king)), 0, "nothing stranded on the king contract");
        // the bidder also receives, as the new king, the LP fees that the same upkeep distributed
        assertGe(imdBalance(players[7]), before - 4.0 ether + fee, "the bidder gets the finalizer fee");
    }

    function test_upkeepForAcceptsKingContract() public {
        vm.prank(address(king));
        pad.upkeepFor(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadNotGame()"));
        pad.upkeepFor(players[0]);
    }

    function test_burnWaitsForPvpGraduation() public {
        // fresh deployment where PvP has not graduated
        BaseTest.setUp();
        openPad();
        imdDeal(address(this), 400 ether);
        pad.burn(20.0 ether);
        liq.burnChunk();
        assertEq(liq.burnBucket(), 20.0 ether);
        assertEq(liq.totalBurnedIMD(), 0);
    }

    function test_unlockCallbackOnlyPoolManager() public {
        vm.expectRevert(abi.encodeWithSignature("PadNotPoolManager()"));
        liq.unlockCallback("");
    }

    function test_launchAfterGenesisPlaysAndGraduatesIntoOwnPool() public {
        uint256 id = pad.launch("Foo", "FOO", "");
        PadGame g = PadGame(pad.gameOf(id));
        PadToken t = PadToken(pad.tokenOf(id));
        playOut(g, 6, 2);
        if (!g.graduated()) graduateGame(g);
        assertTrue(g.graduated());
        assertTrue(t.unlocked());
        assertEq(liq.poolCount(), 2);
        assertEq(liq.getPool(1).launchId, id);
        assertGt(liq.burnBucket(), 0, "non-genesis rolls fund the burn bucket");
    }
}
