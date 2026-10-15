// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TestIMD, NoReturnIMD, imdBalance, imdDeal, TEST_IMD} from "./mocks/IMD.sol";

import {stdError} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {AccountingRecipient} from "./V3AccountingActors.sol";
import {PadGame} from "src/PadGame.sol";
import {PadToken} from "src/PadToken.sol";
import {PadLiquidity} from "src/PadLiquidity.sol";
import {KingOfThePad} from "src/KingOfThePad.sol";
import {IPoolManager, IUnlockCallback} from "src/interfaces/Interfaces.sol";

contract NestedRetryProbe is IUnlockCallback {
    IPoolManager internal immutable manager;
    PadLiquidity internal immutable liquidity;

    constructor(IPoolManager manager_, PadLiquidity liquidity_) {
        manager = manager_;
        liquidity = liquidity_;
    }

    function attempt() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        liquidity.retryPool(0);
        return "";
    }
}

contract BountyReentryProbe {
    PadGame internal immutable game;
    uint256 public callbackState = 1;

    constructor(PadGame game_) {
        game = game_;
        TestIMD(TEST_IMD).setCallback(address(this), true);
    }

    function capture() external {
        game.draw(1);
    }

    function onIMDTransfer(uint256) external {
        (bool ok, bytes memory reason) = address(game).call(abi.encodeCall(PadGame.draw, (32)));
        require(!ok && keccak256(reason) == keccak256(abi.encodeWithSignature("PadReentrancy()")));
        callbackState = 2;
    }
}

/// @dev Replaces only the optional upkeep target, to reproduce full-stipend OOG in each subcall.
contract LiquidityUpkeepGasEater {
    function imd() external pure returns (address) {
        return TEST_IMD;
    }

    function fundBurn(uint256 amount) external {
        TestIMD(TEST_IMD).transferFrom(msg.sender, address(this), amount);
    }

    function distribute(uint256) external pure {
        assembly ("memory-safe") { for {} 1 {} {} }
    }

    function burnChunk() external pure {
        assembly ("memory-safe") { for {} 1 {} {} }
    }
}

contract V3PoolFailureEdgesTest is BaseTest {
    function setUp() public override {
        super.setUp();
        graduatePvp();
        vm.prank(players[8]);
        king.takeCrown(4.0 ether);
        // Drain any graduation/burn fees before the failure fixture.
        liq.distribute(16);
    }

    function _rejectTokenFees() private {
        vm.mockCallRevert(
            address(pm), abi.encodeWithSelector(IPoolManager.modifyLiquidity.selector), bytes("pool failure")
        );
    }

    function test_tokenTransferFailureBecomesClaimableWithoutBlockingCollection() public {
        donateFees(liq.poolKey(address(pvpToken)), 4 ether, 1_000 ether);
        uint256 oldIMD = imdBalance(players[8]);
        uint256 oldTokens = pvpToken.balanceOf(players[8]);
        vm.mockCall(
            address(pvpToken), abi.encodeWithSelector(PadToken.transfer.selector, players[8]), abi.encode(false)
        );
        assertTrue(liq.retryPool(0));
        assertApproxEqAbs(imdBalance(players[8]) - oldIMD, 4 ether, 1);
        assertEq(pvpToken.balanceOf(players[8]), oldTokens);
        uint256 owed = liq.claimable(address(pvpToken), players[8]);
        assertApproxEqAbs(owed, 1_000 ether, 1);
        assertEq(liq.getPool(0).failures, 0);
        vm.warp(king.challengeOpensAt());
        vm.prank(players[9]);
        king.takeCrown(4.4 ether);
        assertEq(king.king(), players[9]);
        vm.clearMockedCalls();
        vm.prank(players[8]);
        liq.claim(address(pvpToken));
        assertEq(pvpToken.balanceOf(players[8]) - oldTokens, owed);
    }

    function test_successBetweenFailuresRequiresThreeNewDistinctBlocksToBreakPool() public {
        donateFees(liq.poolKey(address(pvpToken)), 4.0 ether, 40000 ether);
        _rejectTokenFees();
        assertFalse(liq.retryPool(0));
        arb.advance(1);
        assertFalse(liq.retryPool(0));
        assertEq(liq.getPool(0).failures, 2);
        vm.clearMockedCalls();
        assertTrue(liq.retryPool(0));
        assertEq(liq.getPool(0).failures, 0);
        donateFees(liq.poolKey(address(pvpToken)), 4.0 ether, 40000 ether);
        _rejectTokenFees();
        for (uint256 i = 1; i <= 3; ++i) {
            assertFalse(liq.retryPool(0));
            assertEq(liq.getPool(0).failures, i);
            assertFalse(liq.retryPool(0));
            assertEq(liq.getPool(0).failures, i, "same-block retry inflated the failure count");
            arb.advance(1);
        }
        vm.warp(king.challengeOpensAt());
        vm.prank(players[9]);
        king.takeCrown(4.4 ether);
        assertEq(king.king(), players[9]);
        assertEq(liq.getPool(0).failures, 3, "a broken pool must not veto the bid");
        assertEq(liq.reign(), 1);
        assertEq(liq.reignKing(0), players[8]);
        assertEq(liq.getPool(0).settledReign, 0, "the broken pool stays stamped with the outgoing reign");
        vm.clearMockedCalls();
        // The pool was never settled for reign 0, so its retry pays the outgoing king in kind, not the
        // bidder (AUDIT.md #29); the token transfer that failed three times now succeeds.
        uint256 oldKingTokens = pvpToken.balanceOf(players[8]);
        uint256 oldKingETH = imdBalance(players[8]);
        uint256 newKingTokens = pvpToken.balanceOf(players[9]);
        uint256 newKingETH = imdBalance(players[9]);
        vm.prank(players[11]);
        assertTrue(liq.retryPool(0));
        assertApproxEqAbs(pvpToken.balanceOf(players[8]) - oldKingTokens, 40000 ether, 1, "outgoing king's tokens");
        // The donation plus the genesis pool's real swap fees from the bid's own burn buy.
        assertGe(imdBalance(players[8]) - oldKingETH, 4.0 ether - 1, "outgoing king's ETH");
        assertLt(imdBalance(players[8]) - oldKingETH, 4.4 ether, "outgoing king's ETH");
        assertEq(pvpToken.balanceOf(players[9]), newKingTokens, "bidder must not take the old reign's tokens");
        assertEq(imdBalance(players[9]), newKingETH, "bidder must not take the old reign's ETH");
        assertEq(liq.getPool(0).failures, 0);
        assertEq(liq.getPool(0).lastFailureBlock, 0);
        assertEq(liq.getPool(0).settledReign, 1, "recovery stamps the current reign");
        // Fees earned from now on belong to the new king; the earlier king gets nothing more.
        donateFees(liq.poolKey(address(pvpToken)), 2.0 ether, 20000 ether);
        oldKingTokens = pvpToken.balanceOf(players[8]);
        oldKingETH = imdBalance(players[8]);
        assertTrue(liq.retryPool(0));
        assertApproxEqAbs(pvpToken.balanceOf(players[9]) - newKingTokens, 20000 ether, 1);
        assertApproxEqAbs(imdBalance(players[9]) - newKingETH, 2.0 ether, 1);
        assertEq(pvpToken.balanceOf(players[8]), oldKingTokens);
        assertEq(imdBalance(players[8]), oldKingETH);
    }

    function test_retryInsideRealManagerUnlockCannotDiagnoseHealthyPoolAsBroken() public {
        donateFees(liq.poolKey(address(pvpToken)), 4.0 ether, 40000 ether);
        NestedRetryProbe probe = new NestedRetryProbe(pm, liq);
        bytes32 beforePool = keccak256(abi.encode(liq.getPool(0)));
        vm.expectRevert(abi.encodeWithSignature("PadManagerUnlocked()"));
        probe.attempt();
        assertEq(keccak256(abi.encode(liq.getPool(0))), beforePool);
        assertTrue(liq.retryPool(0));
        assertEq(liq.getPool(0).failures, 0);
    }

    function test_onlyCrownMayRequestStrictSettlementAndIndexErrorsDoNotChangeHealth() public {
        vm.prank(players[10]);
        vm.expectRevert(abi.encodeWithSignature("PadNotKing()"));
        liq.settleCrown();
        bytes32 beforePool = keccak256(abi.encode(liq.getPool(0)));
        uint256 invalidIndex = liq.poolCount();
        vm.expectRevert(stdError.indexOOBError);
        liq.retryPool(invalidIndex);
        assertEq(keccak256(abi.encode(liq.getPool(0))), beforePool);
    }
}

contract V3GameFailureEdgesTest is BaseTest {
    function setUp() public override {
        super.setUp();
        openPad();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_everyResolutionWindowOffsetPreservesTheTip(uint256 offsetSeed) public {
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        uint256 offset = bound(offsetSeed, 0, 350);
        uint256 commit = pvp.getRoll(0).commitBlock;
        arb.set(commit + offset);
        uint256 beforePot = pvp.pot();
        vm.prank(players[9]);
        pvp.resolvePending(type(uint256).max);
        PadGame.Roll memory r = pvp.getRoll(0);
        if (offset <= 3) {
            assertFalse(r.resolved);
            assertEq(pvp.pendingCount(), 1);
            assertEq(pvp.claimable(players[9]), 0);
            assertEq(pvp.pot(), beforePot);
        } else if (offset <= 257) {
            assertTrue(r.resolved);
            assertFalse(r.expired);
            assertTrue(r.delta != 0);
            assertEq(pvp.claimable(players[9]), 0.01 ether);
            assertEq(pvp.pot(), beforePot);
        } else {
            assertTrue(r.resolved);
            assertTrue(r.expired);
            assertEq(pvp.claimable(players[9]), 0);
            assertEq(pvp.pot(), beforePot + 0.01 ether);
        }
        bytes32 firstResult = keccak256(abi.encode(r));
        vm.prank(players[10]);
        pvp.resolvePending(16);
        assertEq(keccak256(abi.encode(pvp.getRoll(0))), firstResult);
        assertEq(pvp.claimable(players[10]), 0, "another caller took an already assigned tip");
        assertEq(
            imdBalance(address(pvp)),
            pvp.imdRaised() + pvp.pot() + pvp.pendingCount() * 0.01 ether + pvp.claimable(players[9])
        );
    }

    function test_drawBountyCallbackCannotCaptureAgainOrAdvanceExtraSeats() public {
        mintAll(pvp, 5);
        vm.warp(pvp.signupEnd());
        pvp.draw(1);
        arb.advance(4);
        BountyReentryProbe receiver = new BountyReentryProbe(pvp);
        imdDeal(address(receiver), 1);
        receiver.capture();
        assertEq(receiver.callbackState(), 2, "callback was not reached within the ETH push stipend");
        assertEq(imdBalance(address(receiver)), 0.5 ether + 1);
        assertEq(pvp.impCount(), 1, "reentrant draw bypassed the outer chunk limit");
        assertEq(pvp.drawBounty(), 0);
        assertEq(pvp.claimable(address(receiver)), 0);
        receiver.capture();
        assertEq(imdBalance(address(receiver)), 0.5 ether + 1, "bounty paid more than once");
        pvp.draw(32);
        assertTrue(pvp.drawComplete());
        assertEq(imdBalance(address(pvp)), 0);
    }

    function test_resolverDebtSurvivesFinalizationGraduationAndRejectedClaim() public {
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, players[0]);
        arb.advance(4);
        AccountingRecipient resolver = new AccountingRecipient();
        resolver.setRejecting(true);
        vm.prank(address(resolver));
        pvp.resolvePending(16);
        uint256 owed = pvp.claimable(address(resolver));
        assertEq(owed, 0.01 ether);
        vm.warp(pvp.endTime());
        arb.advance(6_000);
        pvp.finalize();
        graduateGame(pvp);
        assertEq(imdBalance(address(pvp)), owed, "graduation spent the resolver's reserve");
        vm.prank(address(resolver));
        vm.expectRevert(abi.encodeWithSignature("PadToken()"));
        pvp.claim();
        assertEq(pvp.claimable(address(resolver)), owed);
        resolver.setRejecting(false);
        vm.prank(address(resolver));
        pvp.claim();
        assertEq(resolver.received(), owed);
        assertEq(imdBalance(address(pvp)), 0);
        vm.prank(address(resolver));
        vm.expectRevert(abi.encodeWithSignature("PadNothing()"));
        pvp.claim();
    }

    function test_finalizeBatchFailureRollsBackTipsAndPartialResolutionUntilPermissionlessProgress() public {
        address[20] memory entrants;
        for (uint256 i; i < entrants.length; ++i) {
            entrants[i] = makeAddr(string.concat("batch-player-", vm.toString(i)));
            imdDeal(entrants[i], 400 ether);
            vm.prank(entrants[i]);
            pvp.enter();
        }
        advance(10 minutes);
        // Keep all twenty alive up to the natural hard end using real paid rolls. Let old rolls
        // expire rather than selecting favorable hashes: the final pending batch starts at height 0.
        for (uint256 minute; minute <= 45; minute += 9) {
            vm.warp(pvp.playStart() + minute * 60);
            arb.advance(5_400);
            for (uint256 i; i < entrants.length; ++i) {
                rollAs(pvp, entrants[i]);
            }
        }
        vm.warp(pvp.hardEnd() - 1);
        arb.advance(2_990);
        for (uint256 i; i < entrants.length; ++i) {
            rollAs(pvp, entrants[i]);
        }
        vm.warp(pvp.hardEnd());
        arb.advance(10);
        assertEq(pvp.pendingCount(), 20);
        uint256 next = pvp.nextPending();
        uint256 first = pvp.rollCount() - 20;
        vm.prank(players[9]);
        vm.expectRevert(abi.encodeWithSignature("PadNotFinalizable()"));
        pvp.finalize();
        assertEq(pvp.nextPending(), next);
        assertEq(pvp.pendingCount(), 20);
        assertEq(pvp.claimable(players[9]), 0);
        assertFalse(pvp.getRoll(first).resolved);
        vm.prank(players[10]);
        pvp.resolvePending(4);
        assertEq(pvp.claimable(players[10]), 4 * 0.01 ether);
        assertEq(pvp.pendingCount(), 16);
        vm.prank(players[9]);
        pvp.finalize();
        assertTrue(pvp.finalized());
        assertEq(pvp.livingAtEnd(), 20);
        assertEq(pvp.pendingCount(), 0);
        assertEq(pvp.claimable(players[9]), 16 * 0.01 ether);
    }

    function test_optionalDistributeAndBurnMayBothExhaustCapsWithoutRevertingEntryOrRoll() public {
        LiquidityUpkeepGasEater eater = new LiquidityUpkeepGasEater();
        vm.etch(address(liq), address(eater).code);
        _expectLiquidityCaps();
        uint256 start = gasleft();
        vm.prank(players[0]);
        pvp.enter{gas: 1_900_000}();
        emit log_named_uint("entry with both liquidity upkeep stipends exhausted", start - gasleft());
        assertEq(pvp.entryCount(), 1);
        advance(10 minutes);
        start = gasleft();
        vm.prank(players[0]);
        pvp.roll{gas: 1_900_000}();
        emit log_named_uint("roll with both liquidity upkeep stipends exhausted", start - gasleft());
        assertEq(pvp.rollCount(), 1);
        assertEq(pvp.pendingCount(), 1);
    }

    function _expectLiquidityCaps() private {
        vm.expectCall(address(liq), 0, uint64(950_000), abi.encodeCall(PadLiquidity.distribute, (2)), 2);
        vm.expectCall(address(liq), 0, uint64(350_000), abi.encodeCall(PadLiquidity.burnChunk, ()), 2);
    }
}
