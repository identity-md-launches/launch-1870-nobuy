// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PadGame} from "../src/PadGame.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadLib} from "../src/libs/PadLib.sol";
import {PoolKey} from "../src/interfaces/Interfaces.sol";
import {TestIMD, NoReturnIMD, imdBalance, imdDeal} from "./mocks/IMD.sol";

contract IMDPadTest is BaseTest {
    event UnitChanged(uint256 previous, uint256 current);

    function test_unitBoundsOwnerEventAndSnapshot() public {
        openPad();
        vm.expectRevert();
        pad.setUnit(2 ether);
        vm.startPrank(OWNER);
        vm.expectRevert();
        pad.setUnit(0.1 ether - 1);
        vm.expectRevert();
        pad.setUnit(10 ether + 1);
        vm.expectEmit();
        emit UnitChanged(1 ether, 0.1 ether);
        pad.setUnit(0.1 ether);
        pad.setUnit(10 ether);
        vm.stopPrank();
        assertEq(pvp.unit(), 1 ether);
        assertEq(pvp.ENTRY_PRICE(), 0.5 ether);
        assertEq(pvp.ROLL_PRICE(), 1 ether);
        assertEq(pvp.VIMD(), 400 ether);
        assertEq(pvp.FINALIZER_MAX(), 2 ether);
        assertEq(king.minBid(), 40 ether);
        playOut(pvp, 2, 2);
        graduateGame(pvp);
        uint256 id = pad.launch("New", "NEW", "");
        PadGame next = PadGame(pad.gameOf(id));
        assertEq(next.unit(), 10 ether);
        assertEq(next.ENTRY_PRICE(), 5 ether);
        assertEq(next.VIMD(), 4000 ether);
        uint256 before = imd.balanceOf(players[0]);
        vm.prank(players[0]);
        next.enter();
        assertEq(before - imd.balanceOf(players[0]), 5 ether);
    }

    function testFuzz_unitPricesAndRoundingConserveIMD(uint256 u) public {
        u = bound(u, 0.1 ether, 10 ether);
        vm.prank(OWNER);
        pad.setUnit(u);
        openPad();
        mintAll(pvp, 2);
        advance(10 minutes);
        uint256 before = imd.balanceOf(players[0]);
        uint256 bucket = liq.burnBucket();
        vm.prank(players[0]);
        pvp.roll();
        assertEq(before - imd.balanceOf(players[0]), u);
        assertEq(pvp.imdRaised(), u * 90 / 100);
        assertEq(liq.burnBucket() - bucket, u * 2 / 100);
        assertEq(pvp.pot(), u - u * 90 / 100 - u * 2 / 100 - u / 100);
        assertEq(imd.balanceOf(address(pvp)), pvp.imdRaised() + pvp.pot() + pvp.pendingCount() * pvp.ROLL_TIP());
        vm.prank(OWNER);
        pad.setUnit(10 ether);
        assertEq(pvp.unit(), u);
        assertEq(pvp.VIMD(), 400 * u);
    }

    function test_currentUnitCapsAFullFillBurn() public {
        graduatePvp();
        PoolKey memory key = liq.poolKey(address(pvpToken));
        imd.mint(address(router), 10000 ether);
        vm.prank(DEAD);
        pvpToken.transfer(address(router), 800_000_000 ether);
        router.add(key, uint256(liq.getPool(0).liquidity) * 20);
        vm.prank(OWNER);
        pad.setUnit(0.1 ether);
        pad.burn(100 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        uint256 bucket = liq.burnBucket();
        liq.burnChunk();
        assertEq(bucket - liq.burnBucket(), 0.8 ether);
    }

    function test_unsolicitedIMDDoesNotAlterGraduationPriceOrCredit() public {
        openPad();
        playOut(pvp, 1, 1);
        uint256 raised = pvp.imdRaised();
        uint256 claims = gameReserves(pvp);
        imd.mint(address(pvp), 1000 ether);
        imd.mint(address(liq), 1000 ether);
        uint256 bucket = liq.burnBucket();
        uint256 before = imd.balanceOf(address(pm));
        vm.prank(address(pad));
        pvp.upkeepStep(address(this)); // graduate without the optional trailing burn
        assertEq(imd.balanceOf(address(pm)) - before, raised);
        assertEq(imd.balanceOf(address(pvp)), 1000 ether + claims);
        assertEq(liq.burnBucket(), bucket);
        assertEq(imd.balanceOf(address(liq)), 1000 ether + bucket);
    }

    function test_pullOnlyTrustedCallersAndEndpointsAlwaysChargeTheirCaller() public {
        openPad();
        address victim = players[0];
        uint256 before = imd.balanceOf(victim);
        vm.prank(players[1]);
        vm.expectRevert();
        pad.pull(victim, 1 ether);
        vm.prank(address(liq));
        vm.expectRevert();
        pad.pull(victim, 1 ether);
        vm.prank(address(gameTemplate));
        vm.expectRevert();
        pad.pull(victim, 1 ether);
        imd.setAllowance(players[1], address(pad), 0);
        vm.prank(players[1]);
        vm.expectRevert();
        pvp.enter();
        assertEq(imd.balanceOf(victim), before);
        assertEq(pvp.entryCount(), 0);
        vm.prank(victim);
        pvp.enter();
        assertEq(imd.balanceOf(victim), before - 0.5 ether);
        assertEq(imd.allowance(victim, address(pvp)), 0);
        assertEq(imd.allowance(victim, address(liq)), 0);
        assertEq(imd.allowance(victim, address(king)), 0);
    }

    function test_shortPullsRevertAtomicallyAndDonationsDoNotCreateCredits() public {
        openPad();
        imd.setShort(1);
        uint256 before = imd.balanceOf(players[0]);
        vm.prank(players[0]);
        vm.expectRevert();
        pvp.enter();
        vm.prank(players[0]);
        vm.expectRevert();
        pad.fundCarry(1 ether);
        vm.prank(players[0]);
        vm.expectRevert();
        pad.burn(1 ether);
        assertEq(imd.balanceOf(players[0]), before);
        assertEq(pvp.entryCount(), 0);
        assertEq(pad.carryPot(), 0);
        assertEq(liq.burnBucket(), 0);
        imd.setShort(0);
        imd.mint(address(pad), 50 ether);
        imd.mint(address(liq), 50 ether);
        imd.mint(address(pvp), 50 ether);
        assertEq(pad.carryPot(), 0);
        assertEq(liq.burnBucket(), 0);
        assertEq(pvp.imdRaised(), 0);
        vm.prank(players[0]);
        pvp.enter();
        assertEq(pvp.drawBounty(), 0.5 ether);
        assertEq(imd.balanceOf(address(pvp)), 50.5 ether);
    }

    function test_everyApplicationTemplateCloneAndHookRejectsETH() public {
        openPad();
        address[8] memory targets = [
            address(pad),
            address(liq),
            address(king),
            address(pvp),
            address(pvpToken),
            address(tokenTemplate),
            address(gameTemplate),
            address(pad.hook())
        ];
        vm.deal(address(this), 1 ether);
        for (uint256 i; i < targets.length; ++i) {
            (bool ok,) = targets[i].call{value: 1}("");
            assertFalse(ok);
            assertEq(targets[i].balance, 0);
        }
        (bool entered,) = address(pvp).call{value: 1}(abi.encodeCall(PadGame.enter, ()));
        assertFalse(entered);
    }

    function test_noReturnIMDFullGameGraduationBurnKingAndClaims() public {
        NoReturnIMD implementation = new NoReturnIMD();
        vm.etch(IMD, address(implementation).code);
        graduatePvp();
        PoolKey memory key = liq.poolKey(address(pvpToken));
        vm.prank(players[8]);
        king.takeCrown(4 ether);
        donateFees(key, 2 ether, 1000 ether);
        imd.setBlocked(players[8], true);
        liq.distribute(1);
        uint256 owed = liq.claimable(IMD, players[8]);
        assertGt(owed, 1.99 ether);
        imd.setBlocked(players[8], false);
        uint256 before = imd.balanceOf(players[8]);
        vm.prank(players[8]);
        liq.claim(IMD);
        assertEq(imd.balanceOf(players[8]) - before, owed);
        vm.prank(players[0]);
        pad.burn(8 ether);
        vm.warp(block.timestamp + 10 minutes);
        uint256 dead = pvpToken.balanceOf(DEAD);
        liq.burnChunk();
        assertGt(pvpToken.balanceOf(DEAD), dead);
        assertEq(imd.balanceOf(address(liq)), liq.burnBucket());
    }

    function test_failedIMDAndCoinPayoutsCannotBlockCrownOrBatch() public {
        graduatePvp();
        vm.prank(players[8]);
        king.takeCrown(4 ether);
        donateFees(liq.poolKey(address(pvpToken)), 3 ether, 1000 ether);
        imd.setBlocked(players[8], true);
        vm.mockCall(
            address(pvpToken), abi.encodeWithSelector(PadToken.transfer.selector, players[8]), abi.encode(false)
        );
        vm.warp(king.challengeOpensAt());
        vm.prank(players[9]);
        king.takeCrown(4.4 ether);
        assertEq(king.king(), players[9]);
        assertEq(liq.getPool(0).failures, 0);
        assertGt(liq.claimable(IMD, players[8]), 2.99 ether);
        assertGt(liq.claimable(address(pvpToken), players[8]), 999 ether);
        assertEq(king.claimable(players[8]), 4 ether);
        uint256 iq = liq.claimable(IMD, players[8]);
        uint256 cq = liq.claimable(address(pvpToken), players[8]);
        vm.clearMockedCalls();
        imd.setBlocked(players[8], false);
        uint256 ib = imd.balanceOf(players[8]);
        uint256 cb = pvpToken.balanceOf(players[8]);
        vm.startPrank(players[8]);
        liq.claim(IMD);
        liq.claim(address(pvpToken));
        king.claim();
        vm.expectRevert();
        liq.claim(IMD);
        vm.stopPrank();
        assertEq(imd.balanceOf(players[8]) - ib, iq + 4 ether);
        assertEq(pvpToken.balanceOf(players[8]) - cb, cq);
    }

    function test_shortPoolReceiptDoesNotCreateFeeCredits() public {
        graduatePvp();
        vm.prank(players[8]);
        king.takeCrown(4 ether);
        donateFees(liq.poolKey(address(pvpToken)), 2 ether, 0);
        uint256 fees = liq.getPool(0).imdFees;
        uint256 before = imd.balanceOf(address(liq));
        imd.setShort(1);
        assertFalse(liq.retryPool(0));
        assertEq(liq.getPool(0).imdFees, fees);
        assertEq(imd.balanceOf(address(liq)), before);
        assertEq(liq.claimable(IMD, players[8]), 0);
        imd.setShort(0);
        assertTrue(liq.retryPool(0));
        assertGt(liq.getPool(0).imdFees, fees);
    }

    function _live(uint256 n) internal {
        openPad();
        mintAll(pvp, n);
        advance(10 minutes);
        uint256 start = pvp.playStart();
        for (uint256 r; r < 8; ++r) {
            vm.warp(start + r * 6 minutes);
            arb.advance(300);
            for (uint256 i; i < n; ++i) {
                rollAs(pvp, players[i]);
            }
            arb.advance(4);
            pvp.resolvePending(16);
        }
        vm.warp(start + 48 minutes);
    }

    function test_lateAliveBailKeepsCarryReleaseWithFourRankableSeats() public {
        _late(5);
    }

    function test_lateAliveBailWithFiveOtherSurvivors() public {
        _late(6);
    }

    function _late(uint256 n) internal {
        _live(n);
        pad.fundCarry(400 ether);
        uint256 before = pad.carryPot();
        address bailer = players[n - 1];
        vm.prank(bailer);
        pvp.bailOut(0);
        uint256 payoutBalance = imd.balanceOf(bailer);
        assertEq(pvp.bailedAliveCount(), 1);
        assertFalse(pvp.isAlive(pvp.impOf(bailer) - 1));
        uint256 cap = pvp.fundedReleaseCap();
        assertGt(cap, 0);
        vm.warp(pvp.hardEnd() + 1);
        arb.advance(300);
        pvp.finalize();
        assertEq(pvp.livingAtEnd(), n - 1);
        assertEq(pvp.paidAtEnd(), n / 2);
        assertApproxEqAbs(before - pad.carryPot(), cap, 2);
        assertEq(imd.balanceOf(bailer), payoutBalance, "erased seat gets no prize");
    }

    /// @dev Revision advisory 7125678: a seat that goes idle, dies and only then bails is not an
    /// alive bail. It never counted as living before and bailing dead does not add it back, exactly as if
    /// it had never bailed. Only a bail taken while alive (the lever CHANGE 3 names) keeps qualification.
    function test_deadSeatBailDoesNotQualifyFundingAnyMoreThanIdlingDid() public {
        openPad();
        mintAll(pvp, 5);
        advance(10 minutes);
        uint256 start = pvp.playStart();
        for (uint256 r; r < 8; ++r) {
            vm.warp(start + r * 6 minutes);
            arb.advance(300);
            // seat 4 stops rolling after minute 36; it is dead from minute 46
            for (uint256 i; i < (r == 7 ? 4 : 5); ++i) {
                rollAs(pvp, players[i]);
            }
            arb.advance(4);
            pvp.resolvePending(16);
        }
        pad.fundCarry(400 ether);
        uint256 before = pad.carryPot();
        vm.warp(start + 48 minutes);
        address idler = players[4];
        assertFalse(pvp.isAlive(pvp.impOf(idler) - 1), "idle seat is dead before it bails");
        vm.prank(idler);
        pvp.bailOut(0);
        assertEq(pvp.bailedAliveCount(), 0, "a dead bail is not an alive bail");
        assertGt(pvp.fundedReleaseCap(), 0);
        vm.warp(pvp.hardEnd() + 1);
        arb.advance(300);
        pvp.finalize();
        assertEq(pvp.livingAtEnd(), 4);
        assertGe(
            pad.carryPot(), before, "four qualifying seats release nothing, as with an idle seat that never bailed"
        );
    }

    function test_lateBailCannotClawBackExistingKingFunding() public {
        _live(5);
        imdDeal(address(pad), 100 ether);
        vm.prank(address(pad));
        pvp.fundPot(10 ether);
        vm.prank(players[4]);
        pvp.bailOut(0);
        uint256 cap = pvp.fundedReleaseCap();
        vm.warp(pvp.hardEnd() + 1);
        arb.advance(300);
        pvp.finalize();
        assertApproxEqAbs(pad.carryPot(), 10 ether - cap, 2);
    }

    function test_soleBuyerSybilWithAliveBailAndFourSurvivorsStillLoses() public {
        uint256 initial;
        for (uint256 i; i < 5; ++i) {
            initial += imd.balanceOf(players[i]);
        }
        uint256 resolverBefore = imd.balanceOf(address(this));
        _live(5);
        uint256 coins = pvpToken.balanceOf(players[0]);
        assertGt(pvp.quoteSell(coins), pvp.curveSpent(players[0]));
        vm.prank(players[0]);
        pvp.bailOut(0);
        pad.fundCarry(400 ether);
        resolverBefore -= 400 ether;
        vm.warp(pvp.hardEnd() + 1);
        arb.advance(300);
        pvp.finalize();
        pvp.graduate();
        PoolKey memory key = liq.poolKey(address(pvpToken));
        for (uint256 i; i < 5; ++i) {
            uint256 bal = pvpToken.balanceOf(players[i]);
            if (bal != 0) {
                vm.prank(players[i]);
                pvpToken.transfer(address(router), bal);
                router.trade(key, false, bal);
            }
        }
        uint256 finalWealth = imd.balanceOf(address(router)) + imd.balanceOf(address(this)) - resolverBefore;
        finalWealth += pvp.claimable(address(this));
        for (uint256 i; i < 5; ++i) {
            finalWealth += imd.balanceOf(players[i]) + pvp.claimable(players[i]);
        }
        assertLt(finalWealth, initial, "even all prizes, bail tax, tips and finalizer cannot cover permanent LP loss");
        emit log_named_uint("Sybil loss in IMD wei", initial - finalWealth);
    }

    function test_bothCurrencyOrdersPriceEquivalenceAndPartialFillBurn() public {
        graduatePvp();
        bool saw0;
        bool saw1;
        for (uint256 i; i < 24 && !(saw0 && saw1); ++i) {
            uint256 id = pad.launch("Order", "ORD", "");
            PadGame g = PadGame(pad.gameOf(id));
            PadToken t = PadToken(pad.tokenOf(id));
            playOut(g, 1, 1);
            uint256 e = g.imdRaised();
            (uint256 vq, uint256 vt,) = g.curveState();
            uint256 qBefore = imd.balanceOf(address(pm));
            graduateGame(g);
            PoolKey memory key = liq.poolKey(address(t));
            bool coin0 = key.currency0 == address(t);
            if (coin0) saw0 = true;
            else saw1 = true;
            uint256 lpCoins = PadLib.mulDiv(e, vt, vq);
            uint160 expected = PadLib.sqrtRatioX96(coin0 ? e : lpCoins, coin0 ? lpCoins : e);
            assertEq(liq.sqrtPriceOf(key), expected);
            assertEq(imd.balanceOf(address(pm)) - qBefore, e);
            assertTrue(t.unlocked());
            assertEq(key.fee, 10000);
            assertEq(key.tickSpacing, 200);
            assertEq(key.hooks, pad.hook());
            assertEq(t.balanceOf(address(liq)), 0);
        }
        assertTrue(saw0 && saw1);
        vm.prank(OWNER);
        pad.setUnit(0.1 ether);
        pad.burn(100 ether);
        vm.warp(block.timestamp + 10 minutes);
        PoolKey memory pkey = liq.poolKey(address(pvpToken));
        uint256 spot = liq.sqrtPriceOf(pkey);
        uint256 bucket = liq.burnBucket();
        uint256 dead = pvpToken.balanceOf(DEAD);
        liq.burnChunk();
        uint256 spent = bucket - liq.burnBucket();
        uint256 price = liq.sqrtPriceOf(pkey);
        assertGt(spent, 0);
        assertLt(spent, 0.8 ether, "thin pool gives a partial fill");
        assertGt(pvpToken.balanceOf(DEAD), dead);
        if (pkey.currency0 == IMD) assertGe(price, spot - spot * 50 / 10000);
        else assertLe(price, spot * 1004987562112089027 / 1e18);
        uint256 afterBucket = liq.burnBucket();
        liq.burnChunk();
        assertEq(liq.burnBucket(), afterBucket);
    }
}
