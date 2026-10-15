// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PadGame} from "../src/PadGame.sol";
import {PadToken} from "../src/PadToken.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {PadLib} from "../src/libs/PadLib.sol";
import {TestIMD, TEST_IMD, imdBalance, imdDeal} from "./mocks/IMD.sol";

/// @dev A payee whose IMD receipt callback burns a chosen amount of gas (max means endless). It can
/// hold a seat, bid for the crown and claim, so every payout route can meet a hostile recipient.
contract GasEater {
    uint256 public burn;

    constructor() {
        TestIMD(TEST_IMD).setCallback(address(this), true);
    }

    function setBurn(uint256 b) external {
        burn = b;
    }

    function onIMDTransfer(uint256) external view {
        if (burn == type(uint256).max) {
            assembly ("memory-safe") { for {} 1 {} {} }
        }
        uint256 stop = gasleft() > burn ? gasleft() - burn : 0;
        while (gasleft() > stop) {}
    }

    function enter(PadGame g) external {
        g.enter();
    }

    function roll(PadGame g) external {
        g.roll();
    }

    function bid(KingOfThePad k, uint256 v) external {
        k.takeCrown(v);
    }

    function claimGame(PadGame g) external {
        g.claim();
    }
}

contract PushProbe {
    function pushGas(address token, address to, uint256 amount) external returns (bool ok, uint256 used) {
        uint256 g = gasleft();
        ok = PadLib.push(token, to, amount);
        used = g - gasleft();
    }
}

/// @notice The revision raised the payout stipend (40k to 100k) and every budget that nests it:
/// collection 400k, crown settlement floor 7M, optional upkeep distribution 950k. These tests attack
/// the new numbers from the recipient's side: a payee that eats its whole stipend on every push, in
/// every pool, in the largest game, at the smallest gas a bid may carry.
contract IMDBudgetRevisionTest is BaseTest {
    uint256 internal constant OUTER_OVERHEAD = 12_000;

    // ---- the stipend itself -------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_pushBoundsRecipientWorkAndParksInsteadOfReverting(uint32 burnSeed) public {
        uint256 burn = bound(uint256(burnSeed), 0, 4 * PadLib.PUSH_GAS);
        GasEater eater = new GasEater();
        eater.setBurn(burn);
        PushProbe probe = new PushProbe();
        imdDeal(address(probe), 10 ether);
        (bool ok, uint256 used) = probe.pushGas(TEST_IMD, address(eater), 1 ether);
        assertLe(used, PadLib.PUSH_GAS + OUTER_OVERHEAD, "a push never costs more than its stipend plus call overhead");
        if (ok) {
            assertEq(imdBalance(address(eater)), 1 ether, "a landed push moved the funds");
            assertLt(burn, PadLib.PUSH_GAS, "nothing lands past the stipend");
        } else {
            assertEq(imdBalance(address(eater)), 0, "a parked push moved nothing");
            assertEq(imdBalance(address(probe)), 10 ether);
        }
        // a recipient doing modest work on receipt is never parked; one eating the stipend always is
        if (burn <= 40_000) assertTrue(ok, "modest receipt work lands");
        if (burn >= PadLib.PUSH_GAS) assertFalse(ok, "stipend-eating receipt is parked");
    }

    function test_endlessRecipientCostsExactlyOneStipendAndZeroAmountCostsNoCall() public {
        GasEater eater = new GasEater();
        eater.setBurn(type(uint256).max);
        PushProbe probe = new PushProbe();
        imdDeal(address(probe), 10 ether);
        (bool ok, uint256 used) = probe.pushGas(TEST_IMD, address(eater), 1 ether);
        assertFalse(ok);
        assertGt(used, PadLib.PUSH_GAS);
        assertLe(used, PadLib.PUSH_GAS + OUTER_OVERHEAD);
        (ok, used) = probe.pushGas(TEST_IMD, address(eater), 0);
        assertTrue(ok, "zero amount is a no-op success");
        assertLt(used, 1_000, "and never calls the token");
    }

    // ---- game payouts ---------------------------------------------------------------------------

    function test_eatenRankPayoutIsParkedAndClaimableOnceTheRecipientBehaves() public {
        openPad();
        GasEater eater = new GasEater();
        eater.setBurn(type(uint256).max);
        imdDeal(address(eater), 100 ether);
        eater.enter(pvp);
        advance(10 minutes);
        uint256 start = pvp.playStart();
        // one roll every nine minutes keeps the seat alive through the hard end
        for (uint256 r; r < 6; ++r) {
            vm.warp(start + r * 9 minutes);
            arb.advance(8);
            eater.roll(pvp);
            arb.advance(4);
            while (pvp.pendingCount() != 0) pvp.resolvePending(16);
        }
        vm.warp(pvp.hardEnd() + 1);
        arb.advance(8);
        assertFalse(pvp.finalized());
        assertEq(pvp.pot(), 6 * 0.07 ether, "six rolls funded the pot");
        uint256 g = gasleft();
        vm.prank(players[0]);
        pvp.finalize();
        uint256 used = g - gasleft();
        assertEq(pvp.livingAtEnd(), 1);
        uint256 parked = pvp.claimable(address(eater));
        assertGt(parked, 0, "the eaten prize is parked as a claim");
        assertEq(imdBalance(address(eater)), 100 ether - 0.5 ether - 6 ether, "nothing was pushed through");
        assertLt(used, 4_500_000, "one eaten push fits the 4.5M upkeep step");
        // claim with the recipient still eating: the claim reverts, nothing is lost
        vm.expectRevert();
        eater.claimGame(pvp);
        assertEq(pvp.claimable(address(eater)), parked);
        eater.setBurn(0);
        eater.claimGame(pvp);
        assertEq(pvp.claimable(address(eater)), 0);
        assertEq(imdBalance(address(eater)), 100 ether - 6.5 ether + parked);
        assertEq(imdBalance(address(pvp)), pvp.imdRaised() + gameReserves(pvp), "game stays backed");
    }

    /// @dev MAX_IMPS seats, every rank paid to a recipient that eats its whole stipend: 100 parked
    /// pushes at 100k each. Reports the gas; the direct finalize path must still fit a block.
    function test_twoHundredSeatFinalizeWithEveryRankPushEatenFitsTheBlock() public {
        vm.pauseGasMetering();
        openPad();
        GasEater[] memory seats = new GasEater[](200);
        // seats behave while metering is paused (an endless callback would never run out of gas there)
        for (uint256 i; i < 200; ++i) {
            seats[i] = new GasEater();
            imdDeal(address(seats[i]), 400 ether);
            seats[i].enter(pvp);
        }
        advance(10 minutes);
        uint256 start = pvp.playStart();
        for (uint256 r; r < 6 && !pvp.ended(); ++r) {
            vm.warp(start + r * 9 minutes);
            arb.advance(300);
            for (uint256 i; i < 200 && !pvp.ended(); ++i) {
                seats[i].roll(pvp);
            }
            arb.advance(4);
            while (pvp.pendingCount() != 0) pvp.resolvePending(16);
        }
        if (!pvp.ended()) vm.warp(pvp.hardEnd() + 1);
        arb.advance(300);
        while (pvp.pendingCount() != 0) pvp.resolvePending(16);
        vm.resumeGasMetering();
        for (uint256 i; i < 200; ++i) {
            seats[i].setBurn(type(uint256).max);
        }
        uint256 g = gasleft();
        vm.prank(players[9]);
        pvp.finalize();
        uint256 used = g - gasleft();
        emit log_named_uint("finalize gas, 200 living seats, every rank push eaten", used);
        assertEq(pvp.livingAtEnd(), 200);
        assertEq(pvp.paidAtEnd(), 100);
        uint256 claims;
        for (uint256 i; i < 200; ++i) {
            claims += pvp.claimable(address(seats[i]));
        }
        assertGt(claims, 0, "every rank payout was parked");
        assertLt(used, 32_000_000, "fits an Arbitrum-stack block");
        // curve IMD, the harness's own resolver tips, and every parked rank prize are all still backed
        assertEq(imdBalance(address(pvp)), pvp.imdRaised() + gameReserves(pvp) + claims, "game stays backed");
        assertLt(used, 16_777_216, "and the single-transaction ceiling the launch is held to");
    }

    // ---- crown settlement floor -----------------------------------------------------------------

    function _sixteenPoolsWithEatingKing() internal returns (GasEater outgoing) {
        vm.pauseGasMetering();
        graduatePvp();
        for (uint256 i; i < 15; ++i) {
            PadGame g = PadGame(pad.gameOf(pad.launch("Gas", "G", "")));
            playOut(g, 1, 1);
            graduateGame(g);
        }
        outgoing = new GasEater();
        imdDeal(address(outgoing), 400 ether);
        outgoing.bid(king, 4.0 ether);
        for (uint256 i; i < 16; ++i) {
            donateFees(liq.poolKey(liq.getPool(i).token), 0.5 ether, 1000 ether);
        }
        vm.warp(king.challengeOpensAt());
        vm.resumeGasMetering();
        // armed only once metering is back: an endless callback never runs out of unmetered gas
        outgoing.setBurn(type(uint256).max);
    }

    function _attemptBid(uint256 gas) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        vm.prank(players[9]);
        (ok,) = address(king).call{gas: gas}(abi.encodeCall(KingOfThePad.takeCrown, (4.4 ether)));
        vm.revertToState(snap);
    }

    /// @dev Finds the least outer gas a bid can carry and checks that, at that exact amount, all sixteen
    /// pools settle both currencies to a king that eats every IMD push; one unit less reverts whole.
    function test_leastBidGasSettlesSixteenPoolsWhenTheOutgoingKingEatsEveryPush() public {
        GasEater outgoing = _sixteenPoolsWithEatingKing();
        uint256 lo = 7_000_000;
        uint256 hi = 8_000_000;
        assertFalse(_attemptBid(lo), "7M is below the settlement floor");
        assertTrue(_attemptBid(hi), "8M carries the floor");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_attemptBid(mid)) hi = mid;
            else lo = mid;
        }
        emit log_named_uint("least outer gas for a bid that settles sixteen pools", hi);
        assertLe(hi, 7_800_000, "README: a bid must carry about 7.72M");
        assertGt(hi, king.CROWN_DISTRIBUTE_GAS() + 600_000, "the floor plus the reserve is really required");

        uint256 reignBefore = liq.reign();
        uint256 cursorBefore = liq.distributeCursor(); // the first bid's own upkeep walked empty pools
        uint256 claimBefore = liq.claimable(TEST_IMD, address(outgoing));
        vm.prank(players[9]);
        (bool ok,) = address(king).call{gas: lo}(abi.encodeCall(KingOfThePad.takeCrown, (4.4 ether)));
        assertFalse(ok, "one unit less fails");
        assertEq(king.king(), address(outgoing), "and leaves the crown");
        assertEq(liq.reign(), reignBefore, "and the reign");
        assertEq(liq.distributeCursor(), cursorBefore, "and the cursor");

        vm.prank(players[9]);
        king.takeCrown{gas: hi}(4.4 ether);
        assertEq(king.king(), players[9]);
        assertEq(liq.reign(), reignBefore + 1);
        // sixteen strict steps bring the cursor full circle; the bid's own upkeep then walks two more
        assertEq(liq.distributeCursor(), (cursorBefore + 1) % 16 + 1, "full circle plus the bid's upkeep");
        assertApproxEqAbs(liq.claimable(TEST_IMD, address(outgoing)) - claimBefore, 8 ether, 20e12, "IMD parked");
        assertEq(king.claimable(address(outgoing)), 4.0 ether, "refund parked");
        for (uint256 i; i < 16; ++i) {
            assertApproxEqAbs(PadToken(liq.getPool(i).token).balanceOf(address(outgoing)), 1000 ether, 1);
            assertEq(liq.getPool(i).failures, 0, "an eaten push is not a pool failure");
        }
    }

    function test_bidBelowTheSettlementFloorRevertsWithTheGasErrorNotMidway() public {
        GasEater outgoing = _sixteenPoolsWithEatingKing();
        uint256 before = imdBalance(players[9]);
        vm.prank(players[9]);
        vm.expectRevert(abi.encodeWithSignature("PadSettlementGas()"));
        king.takeCrown{gas: 7_600_000}(4.4 ether);
        assertEq(king.king(), address(outgoing));
        assertEq(imdBalance(players[9]), before);
        assertEq(liq.claimable(TEST_IMD, address(outgoing)), 0, "nothing was collected");
    }

    // ---- optional upkeep distribution -----------------------------------------------------------

    function test_optionalUpkeepStillSettlesTwoPoolsWhenBothCollectionsEatTheirIMDPush() public {
        graduatePvp();
        for (uint256 i; i < 2; ++i) {
            PadGame g = PadGame(pad.gameOf(pad.launch("Up", "U", "")));
            playOut(g, 1, 1);
            graduateGame(g);
        }
        GasEater eater = new GasEater();
        eater.setBurn(type(uint256).max);
        imdDeal(address(eater), 100 ether);
        eater.bid(king, 4.0 ether);
        for (uint256 i; i < 3; ++i) {
            donateFees(liq.poolKey(liq.getPool(i).token), 0.5 ether, 1000 ether);
        }
        // the bid's own upkeep already walked (empty) pools, so start from wherever the cursor sits
        uint256 first = liq.distributeCursor() % 3;
        uint256 second = (first + 1) % 3;
        uint256 third = (first + 2) % 3;
        uint256 claimBefore = liq.claimable(TEST_IMD, address(eater));
        vm.prank(players[9]);
        pad.upkeep{gas: 12_000_000}();
        assertEq(liq.distributeCursor(), second + 1, "two pools per optional step, even with eaten pushes");
        assertApproxEqAbs(liq.claimable(TEST_IMD, address(eater)) - claimBefore, 1 ether, 10e12);
        assertApproxEqAbs(PadToken(liq.getPool(first).token).balanceOf(address(eater)), 1000 ether, 1);
        assertApproxEqAbs(PadToken(liq.getPool(second).token).balanceOf(address(eater)), 1000 ether, 1);
        assertEq(PadToken(liq.getPool(third).token).balanceOf(address(eater)), 0, "third pool waits");
        for (uint256 i; i < 3; ++i) {
            assertEq(liq.getPool(i).failures, 0);
        }
        // the next step reaches the third pool and wraps
        vm.prank(players[9]);
        pad.upkeep{gas: 12_000_000}();
        assertEq(liq.distributeCursor(), first + 1);
        assertApproxEqAbs(PadToken(liq.getPool(third).token).balanceOf(address(eater)), 1000 ether, 1);
        assertApproxEqAbs(liq.claimable(TEST_IMD, address(eater)) - claimBefore, 1.5 ether, 15e12);
        // parked IMD is recoverable once the king behaves
        eater.setBurn(0);
        uint256 owed = liq.claimable(TEST_IMD, address(eater));
        vm.prank(address(eater));
        liq.claim(TEST_IMD);
        assertEq(imdBalance(address(eater)), 100 ether - 4 ether + owed);
    }
}
