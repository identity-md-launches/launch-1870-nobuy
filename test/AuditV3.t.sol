// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TestIMD, NoReturnIMD, imdBalance, imdDeal, TEST_IMD} from "./mocks/IMD.sol";

import {BaseTest} from "./Base.t.sol";
import {PadGame} from "../src/PadGame.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {IPoolManager, IUnlockCallback, PoolKey, ModifyLiquidityParams} from "../src/interfaces/Interfaces.sol";
import {Rejector} from "./mocks/Mocks.sol";

contract UnlockCrownProbe is IUnlockCallback {
    IPoolManager immutable manager;
    KingOfThePad immutable king;
    PadLiquidity immutable liquidity;

    constructor(IPoolManager m, KingOfThePad k, PadLiquidity l) {
        manager = m;
        king = k;
        liquidity = l;
    }

    function attempt(uint256 mode) external payable {
        manager.unlock(abi.encode(mode));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        uint256 mode = abi.decode(data, (uint256));
        if (mode == 0) king.takeCrown(imdBalance(address(this)));
        else if (mode == 1) king.distribute(16);
        else liquidity.distribute(16);
        return "";
    }

    function onIMDTransfer(uint256 receivedAmount) external {}
}

contract GasEatingKing {
    constructor() {
        TestIMD(TEST_IMD).setCallback(address(this), true);
    }

    function bid(KingOfThePad k, uint256 value) external {
        k.takeCrown(value);
    }

    function onIMDTransfer(uint256 receivedAmount) external {
        assembly ("memory-safe") { for {} 1 {} {} }
    }
}

contract AuditV3KingTest is BaseTest {
    function setUp() public override {
        super.setUp();
        graduatePvp();
    }

    function _crownAndAccrue() internal {
        vm.prank(players[8]);
        king.takeCrown(4.0 ether);
        vm.warp(king.challengeOpensAt());
        liq.burnChunk();
        liq.distribute(16);
        donateFees(liq.poolKey(address(pvpToken)), 40.0 ether, 2_000_000 ether);
    }

    function test_unlockCallbackCannotTakeCrownOrDistribute() public {
        _crownAndAccrue();
        UnlockCrownProbe probe = new UnlockCrownProbe(pm, king, liq);
        imdDeal(address(probe), 4.4 ether);
        uint256 before = imdBalance(players[8]);
        for (uint256 mode; mode < 3; ++mode) {
            vm.expectRevert(abi.encodeWithSignature("PadManagerUnlocked()"));
            probe.attempt(mode);
        }
        assertEq(king.king(), players[8]);
        assertEq(imdBalance(players[8]), before);
        assertEq(liq.getPool(0).failures, 0, "nested unlock cannot flag a healthy pool");
        vm.prank(players[9]);
        king.takeCrown(4.4 ether);
        assertApproxEqAbs(imdBalance(players[8]) - before, 44.0 ether, 1);
        assertApproxEqAbs(pvpToken.balanceOf(players[8]), 2_000_000 ether, 1);
    }

    function test_firstCrownAlsoRejectsUnlockedManager() public {
        UnlockCrownProbe probe = new UnlockCrownProbe(pm, king, liq);
        imdDeal(address(probe), 4.0 ether);
        vm.expectRevert(abi.encodeWithSignature("PadManagerUnlocked()"));
        probe.attempt(0);
        assertEq(king.crownCount(), 0);
    }

    function test_gasStarvedBidRevertsWithoutChangingCrownOrPoolHealth() public {
        _crownAndAccrue();
        vm.prank(players[9]);
        (bool ok, bytes memory reason) =
            address(king).call{gas: 500_000}(abi.encodeCall(KingOfThePad.takeCrown, (4.4 ether)));
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSignature("PadSettlementGas()"));
        assertEq(king.king(), players[8]);
        assertEq(liq.getPool(0).failures, 0);
        // Underfunding a permissionless health probe must not manufacture a failed collection.
        (ok,) = address(liq).call{gas: 200_000}(abi.encodeCall(PadLiquidity.distribute, (16)));
        assertTrue(ok, "ordinary distribution skips work below its gas floor");
        assertEq(liq.getPool(0).failures, 0);
        (ok,) = address(liq).call{gas: 200_000}(abi.encodeCall(PadLiquidity.retryPool, (0)));
        assertFalse(ok);
        assertEq(liq.getPool(0).failures, 0);
    }

    function test_failedPoolRequiresThreeDistinctL2BlocksThenAnyoneCanRecoverIt() public {
        _crownAndAccrue();
        PoolKey memory key = liq.poolKey(address(pvpToken));
        vm.mockCallRevert(
            address(pm),
            abi.encodeCall(
                IPoolManager.modifyLiquidity, (key, ModifyLiquidityParams(-887200, 887200, 0, 0), bytes(""))
            ),
            bytes("broken position")
        );
        vm.prank(players[9]);
        vm.expectRevert(abi.encodeWithSignature("PadPoolCollectionFailed()"));
        king.takeCrown(4.4 ether);
        assertEq(liq.getPool(0).failures, 0, "failed bid rolls back all settlement state");
        liq.distribute(16);
        liq.distribute(16);
        liq.retryPool(0);
        assertEq(liq.getPool(0).failures, 1, "same L2 block counts once");
        // L1 block progress is deliberately irrelevant on this chain.
        vm.roll(vm.getBlockNumber() + 100);
        liq.retryPool(0);
        assertEq(liq.getPool(0).failures, 1);
        arb.advance(1);
        liq.retryPool(0);
        assertEq(liq.getPool(0).failures, 2);
        vm.prank(players[9]);
        vm.expectRevert(abi.encodeWithSignature("PadPoolCollectionFailed()"));
        king.takeCrown(4.4 ether);
        arb.advance(1);
        liq.retryPool(0);
        assertEq(liq.getPool(0).failures, 3);
        vm.prank(players[9]);
        king.takeCrown(4.4 ether);
        assertEq(king.king(), players[9], "a diagnosed dead pool cannot freeze crown");
        vm.clearMockedCalls();
        vm.prank(players[10]);
        assertTrue(liq.retryPool(0));
        assertEq(liq.getPool(0).failures, 0);
        // The pool was skipped at the crown, so it stays owed to the king whose reign earned its fees.
        assertApproxEqAbs(pvpToken.balanceOf(players[8]), 2_000_000 ether, 1);
        assertEq(pvpToken.balanceOf(players[9]), 0);
        // A fresh failure after recovery starts a new sequence.
        vm.mockCallRevert(address(pm), abi.encodeWithSelector(IPoolManager.unlock.selector), bytes("new failure"));
        liq.retryPool(0);
        assertEq(liq.getPool(0).failures, 1);
    }

    function test_failedSettlementRollsBackEarlierHealthyPoolPayments() public {
        PadGame g = PadGame(pad.gameOf(pad.launch("Second", "S", "")));
        playOut(g, 1, 1);
        graduateGame(g);
        vm.prank(players[8]);
        king.takeCrown(4.0 ether);
        vm.warp(king.challengeOpensAt());
        liq.burnChunk();
        liq.distribute(16);
        uint256 first = liq.distributeCursor() % 2;
        uint256 second = (first + 1) % 2;
        PoolKey memory healthy = liq.poolKey(liq.getPool(first).token);
        PoolKey memory broken = liq.poolKey(liq.getPool(second).token);
        donateFees(healthy, 40.0 ether, 1000 ether);
        donateFees(broken, 40.0 ether, 1000 ether);
        vm.mockCallRevert(
            address(pm),
            abi.encodeCall(
                IPoolManager.modifyLiquidity, (broken, ModifyLiquidityParams(-887200, 887200, 0, 0), bytes(""))
            ),
            bytes("failure after healthy pool")
        );
        uint256 ethBefore = imdBalance(players[8]);
        uint256 tokensBefore =
            PadToken(healthy.currency0 == IMD ? healthy.currency1 : healthy.currency0).balanceOf(players[8]);
        uint256 cursor = liq.distributeCursor();
        uint256 collected = liq.getPool(first).imdFees;
        vm.prank(players[9]);
        vm.expectRevert(abi.encodeWithSignature("PadPoolCollectionFailed()"));
        king.takeCrown(4.4 ether);
        assertEq(king.king(), players[8]);
        assertEq(imdBalance(players[8]), ethBefore);
        assertEq(
            PadToken(healthy.currency0 == IMD ? healthy.currency1 : healthy.currency0).balanceOf(players[8]),
            tokensBefore
        );
        assertEq(liq.getPool(first).imdFees, collected);
        assertEq(liq.distributeCursor(), cursor);
        assertEq(liq.getPool(second).failures, 0);
        vm.clearMockedCalls();
        vm.prank(players[9]);
        king.takeCrown(4.4 ether);
        assertApproxEqAbs(imdBalance(players[8]) - ethBefore, 84.0 ether, 2);
    }

    function test_outgoingKingGetsLargeTokenFeesInKindAndNextKingGetsNoStash() public {
        _crownAndAccrue();
        uint256 ethBefore = imdBalance(players[8]);
        vm.prank(players[9]);
        king.takeCrown(4.4 ether);
        assertApproxEqAbs(imdBalance(players[8]) - ethBefore, 44.0 ether, 1);
        assertApproxEqAbs(pvpToken.balanceOf(players[8]), 2_000_000 ether, 1);
        assertEq(pvpToken.balanceOf(address(liq)), 0);
        uint256 newEth = imdBalance(players[9]);
        uint256 newTokens = pvpToken.balanceOf(players[9]);
        for (uint256 i; i < 10; ++i) {
            liq.distribute(16);
        }
        assertEq(imdBalance(players[9]), newEth);
        assertEq(pvpToken.balanceOf(players[9]), newTokens);
    }

    function test_sixteenPoolsBothCurrenciesAndGasEatingKingFitSettlementBudget() public {
        vm.pauseGasMetering();
        for (uint256 i; i < 15; ++i) {
            PadGame g = PadGame(pad.gameOf(pad.launch("Gas", "G", "")));
            playOut(g, 1, 1);
            graduateGame(g);
        }
        vm.resumeGasMetering();
        GasEatingKing outgoing = new GasEatingKing();
        imdDeal(address(outgoing), 400 ether);
        outgoing.bid(king, 4.0 ether);
        uint256 previousClaim = liq.claimable(TEST_IMD, address(outgoing));
        for (uint256 i; i < 16; ++i) {
            donateFees(liq.poolKey(liq.getPool(i).token), 0.5 ether, 1000 ether);
        }
        vm.warp(king.challengeOpensAt());
        vm.resumeGasMetering();
        uint256 start = gasleft();
        vm.prank(players[9]);
        king.takeCrown{gas: 6_000_000}(4.4 ether);
        uint256 used = start - gasleft();
        emit log_named_uint("16 real pools both currencies, rejecting king, bid gas used", used);
        assertLt(used, king.CROWN_DISTRIBUTE_GAS());
        assertApproxEqAbs(liq.claimable(TEST_IMD, address(outgoing)) - previousClaim, 8 ether, 20e12);
        assertEq(king.claimable(address(outgoing)), 4.0 ether);
        for (uint256 i; i < 16; ++i) {
            assertApproxEqAbs(PadToken(liq.getPool(i).token).balanceOf(address(outgoing)), 1000 ether, 1);
            assertEq(liq.getPool(i).failures, 0);
        }
    }
}

contract AuditV3GameTest is BaseTest {
    function setUp() public override {
        super.setUp();
        openPad();
    }

    function test_tenBlocksPerSecondSixtySecondRollerNeverExpiresWithResolver() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        for (uint256 i; i < 10; ++i) {
            rollAs(pvp, players[0]);
            vm.warp(vm.getBlockTimestamp() + 1);
            arb.advance(10);
            vm.prank(players[10]);
            if (i % 2 == 0) pvp.resolvePending(16);
            else pad.upkeep();
            assertTrue(pvp.getRoll(i).resolved);
            assertFalse(pvp.getRoll(i).expired);
            assertTrue(pvp.getRoll(i).delta != 0);
            vm.warp(vm.getBlockTimestamp() + 59);
            arb.advance(590);
        }
        assertEq(pvp.claimable(players[10]), 10 * pvp.ROLL_TIP());
        assertEq(pvp.claimable(address(pad)), 0, "upkeep tip belongs to its actual caller");
        assertEq(pvp.pot(), 10 * 0.07 ether);
        assertEq(pvp.imdRaised(), 10 * 0.9 ether);
        uint256 before = imdBalance(players[10]);
        vm.prank(players[10]);
        pvp.claim();
        assertEq(imdBalance(players[10]) - before, 10 * pvp.ROLL_TIP());
        vm.prank(players[10]);
        vm.expectRevert(abi.encodeWithSignature("PadNothing()"));
        pvp.claim();
        pvp.resolvePending(16);
        assertEq(pvp.claimable(players[10]), 0, "a resolved roll cannot pay twice");
        assertEq(imdBalance(address(pvp)), pvp.imdRaised() + pvp.pot());
    }

    function test_nonGenesisSplitAndExpiredTipGoesToPotWithPenalty() public {
        graduatePvp();
        PadGame g = PadGame(pad.gameOf(pad.launch("Tips", "TIP", "")));
        mintAll(g, 1);
        advance(10 minutes);
        uint256 burn = liq.burnBucket() + liq.totalBurnedIMD();
        rollAs(g, players[0]);
        assertEq(g.imdRaised(), 0.9 ether);
        assertEq(g.pot(), 0.07 ether);
        assertEq(liq.burnBucket() + liq.totalBurnedIMD() - burn, 0.02 ether);
        assertEq(imdBalance(address(g)), g.imdRaised() + g.pot() + g.ROLL_TIP());
        arb.advance(10);
        vm.prank(players[10]);
        g.resolvePending(16);
        assertEq(g.claimable(players[10]), 0.01 ether);
        int256 height = g.getImp(0).height;
        assertTrue(height != 0);
        vm.warp(vm.getBlockTimestamp() + 60);
        arb.advance(600);
        rollAs(g, players[0]);
        uint256 pot = g.pot();
        arb.advance(258);
        vm.prank(players[9]);
        g.resolvePending(16);
        assertTrue(g.getRoll(1).expired);
        assertEq(g.getImp(0).height, 0, "expiry still moves up to four toward zero");
        assertEq(g.pot(), pot + g.ROLL_TIP());
        assertEq(g.claimable(players[9]), 0);
        g.resolvePending(16);
        assertEq(g.pot(), pot + g.ROLL_TIP());
        assertEq(imdBalance(address(g)), g.imdRaised() + g.pot() + g.claimable(players[10]));
    }

    function test_resolveBatchClampsToSixteenAndLowGasStopsSafely() public {
        for (uint256 i; i < 33; ++i) {
            address who = address(uint160(0x123000 + i));
            imdDeal(who, 400 ether);
            vm.prank(who);
            pvp.enter();
        }
        advance(10 minutes);
        for (uint256 i; i < 33; ++i) {
            rollAs(pvp, pvp.getImp(i).owner);
        }
        arb.advance(4);
        vm.prank(players[10]);
        pvp.resolvePending(type(uint256).max);
        assertEq(pvp.pendingCount(), 17);
        assertEq(pvp.claimable(players[10]), 16 * pvp.ROLL_TIP());
        vm.prank(players[9]);
        (bool ok,) = address(pvp).call{gas: 300_000}(abi.encodeCall(PadGame.resolvePending, (16)));
        assertTrue(ok);
        uint256 resolved = 17 - pvp.pendingCount();
        assertGt(resolved, 0);
        assertLt(resolved, 16);
        assertEq(pvp.claimable(players[9]), resolved * pvp.ROLL_TIP());
        pvp.resolvePending(16);
        assertEq(pvp.pendingCount(), 0);
        assertEq(gameClaims(pvp), 33 * pvp.ROLL_TIP());
    }

    function test_lapsedSeedIsIndependentOfCallerAndCaptureDelayAndBountyPaidOnce() public {
        mintAll(pvp, 5);
        assertEq(pvp.drawBounty(), pvp.ENTRY_PRICE());
        assertEq(liq.burnBucket(), 4 * pvp.ENTRY_PRICE());
        vm.warp(pvp.signupEnd());
        pvp.draw(32);
        uint256 commit = pvp.drawCommitBlock();
        uint256 snapshot = vm.snapshotState();
        arb.set(commit + 258);
        uint256 before = imdBalance(players[9]);
        vm.prank(players[9]);
        pvp.draw(32);
        assertEq(imdBalance(players[9]) - before, pvp.ENTRY_PRICE());
        bytes32 expected = keccak256(abi.encode(address(pvp), commit, uint256(5)));
        assertEq(pvp.drawSeed(), expected);
        address[5] memory order;
        for (uint256 i; i < 5; ++i) {
            order[i] = pvp.getImp(i).owner;
        }
        vm.revertToState(snapshot);
        arb.set(commit + 100_000);
        Rejector rejector = new Rejector();
        vm.prank(address(rejector));
        pvp.draw(1);
        assertEq(pvp.claimable(address(rejector)), pvp.ENTRY_PRICE());
        assertEq(pvp.drawBounty(), 0);
        arb.advance(100_000);
        while (!pvp.drawComplete()) pvp.draw(1);
        for (uint256 i; i < 5; ++i) {
            assertEq(pvp.getImp(i).owner, order[i]);
        }
        assertEq(pvp.drawSeed(), expected);
        assertEq(pvp.drawCommitBlock(), commit);
        pvp.draw(32);
        assertEq(pvp.claimable(address(rejector)), pvp.ENTRY_PRICE());
        assertEq(imdBalance(address(pvp)), pvp.ENTRY_PRICE());
    }

    function test_upkeepSeedBountyGoesToCallerAndNotPad() public {
        mintAll(pvp, 5);
        vm.warp(pvp.signupEnd());
        pad.upkeep();
        arb.advance(4);
        uint256 before = imdBalance(players[9]);
        vm.prank(players[9]);
        pad.upkeep();
        assertTrue(pvp.drawSeeded());
        assertEq(imdBalance(players[9]) - before, pvp.ENTRY_PRICE());
        assertEq(pvp.drawBounty(), 0);
        vm.prank(players[10]);
        pad.upkeep();
        assertEq(imdBalance(players[10]), 4000 ether);
    }
}
