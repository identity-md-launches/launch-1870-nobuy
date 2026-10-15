// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TestIMD, NoReturnIMD, imdBalance, imdDeal, TEST_IMD} from "./mocks/IMD.sol";

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "./Base.t.sol";
import {PadGame} from "../src/PadGame.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {PadLib} from "../src/libs/PadLib.sol";
import {PoolKey, IPoolManager, IUnlockCallback} from "../src/interfaces/Interfaces.sol";
import {V4Router} from "./RealV4.sol";
import {Rejector} from "./mocks/Mocks.sol";

contract V4PadTest is BaseTest {
    function setUp() public override {
        super.setUp();
        openPad();
    }

    function _start(uint256 n) internal {
        mintAll(pvp, n);
        advance(10 minutes);
    }

    function _finish() internal {
        vm.warp(pvp.endTime() + 1);
        arb.advance(300);
        while (pvp.pendingCount() != 0) pvp.resolvePending(16);
        pvp.finalize();
    }

    function _largeRaise() internal {
        _start(12);
        for (uint256 r; r < 20; ++r) {
            for (uint256 i; i < 12; ++i) {
                rollAs(pvp, players[i]);
            }
            advance(61);
        }
        _finish();
        assertGt(pvp.imdRaised(), 160.0 ether);
    }

    function _height(uint256 i, int16 h) internal {
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(uint256(10)))) + i * 2);
        uint256 word = uint256(vm.load(address(pvp), slot));
        word = (word & ~(uint256(type(uint16).max) << 160)) | (uint256(uint16(h)) << 160);
        vm.store(address(pvp), slot, bytes32(word));
    }

    function _bell(address who) internal {
        uint256 word = uint256(vm.load(address(pvp), bytes32(uint256(8))));
        word = (word & ~(uint256(type(uint64).max) << 64)) | (vm.getBlockTimestamp() << 64);
        vm.store(address(pvp), bytes32(uint256(8)), bytes32(word));
        vm.store(address(pvp), bytes32(uint256(9)), bytes32(uint256(uint160(who))));
    }

    function test_bailOutProfitLossMinOutAndConservation() public {
        _start(3);
        rollAs(pvp, players[0]);
        rollAs(pvp, players[1]);
        uint256 coins = pvpToken.balanceOf(players[0]);
        uint256 value = pvp.quoteSell(coins);
        uint256 cost = pvp.curveSpent(players[0]);
        assertGt(value, cost);
        uint256 payout = cost + (value - cost) / 2;
        uint256 pot = pvp.pot();
        uint256 earned = pvp.rollPot();
        uint256 raised = pvp.imdRaised();
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadMinOut()"));
        pvp.bailOut(payout + 1);
        assertFalse(pvp.erased(players[0]));
        assertEq(pvp.imdRaised(), raised);
        uint256 before = imdBalance(players[0]);
        vm.prank(players[0]);
        pvp.bailOut(payout);
        assertEq(imdBalance(players[0]) - before, payout);
        assertEq(pvpToken.balanceOf(players[0]), 0);
        assertEq(pvp.imdRaised(), raised - value);
        assertEq(pvp.pot(), pot + value - payout);
        assertEq(pvp.rollPot(), earned, "bail tax cannot lift the funded allowance");
        assertEq(pvp.fundedReleaseCap(), (raised - value) * 15 / 100);
        value = pvp.quoteSell(pvpToken.balanceOf(players[1]));
        assertLt(value, pvp.curveSpent(players[1]));
        before = imdBalance(players[1]);
        vm.prank(players[1]);
        pvp.bailOut(value * 90 / 100);
        assertEq(imdBalance(players[1]) - before, value * 90 / 100);
        assertEq(pvp.imdRaised(), 0);
        assertEq(pvp.tokensSold(), 0);
        assertEq(pvp.fundedReleaseCap(), 0);
        assertEq(pvpToken.balanceOf(address(pvp)), pvpToken.totalSupply());
        assertEq(imdBalance(address(pvp)), pvp.pot() + pvp.pendingCount() * pvp.ROLL_TIP());
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadNoImp()"));
        pvp.bailOut(0);
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadErased()"));
        pvp.roll();
    }

    function test_erasureExcludesRankingBellLivingAndFundedReleaseButPaysPendingTip() public {
        _start(5);
        for (uint256 i; i < 5; ++i) {
            rollAs(pvp, players[i]);
        }
        uint256 seat = pvp.impOf(players[0]) - 1;
        _height(seat, 50);
        vm.prank(players[0]);
        pvp.bailOut(0);
        assertFalse(pvp.isAlive(seat));
        (bool live,) = pvp.isLiveForKing();
        assertFalse(live, "erased seat cannot meet king's five-seat eligibility");
        arb.advance(4);
        uint256 tip = pvp.claimable(address(this));
        pvp.resolvePending(16);
        assertEq(pvp.getRoll(0).delta, 0);
        assertEq(pvp.getImp(seat).height, 50, "pending roll has no height effect");
        assertEq(pvp.claimable(address(this)) - tip, 5 * pvp.ROLL_TIP());
        assertEq(pvp.bellAt(), 0);
        imdDeal(address(this), 400 ether);
        pad.fundCarry(400 ether);
        _bell(players[1]); // controlled end/rank fixture, no PoolManager substitution
        uint256 erasedBalance = imdBalance(players[0]);
        pvp.finalize();
        assertEq(pvp.livingAtEnd(), 4);
        assertEq(pvp.paidAtEnd(), 2);
        assertEq(imdBalance(players[0]), erasedBalance, "erased high rank earns no pot");
        assertLt(pad.carryPot(), 400 ether, "alive bail preserves funding for the four survivors");
    }

    function test_deadWalletMayBailWhileAnotherLivesAndErasedActivityDoesNotDelayEnd() public {
        _start(2);
        rollAs(pvp, players[0]);
        advance(9 minutes);
        rollAs(pvp, players[1]);
        advance(61);
        assertFalse(pvp.isAlive(pvp.impOf(players[0]) - 1));
        vm.prank(players[0]);
        pvp.bailOut(0);
        assertEq(pvp.bailedAliveCount(), 0);
        assertFalse(pvp.ended());
        vm.prank(players[1]);
        pvp.bailOut(0);
        assertEq(pvp.bailedAliveCount(), 1);
        assertTrue(pvp.ended());
        assertEq(pvp.endTime(), vm.getBlockTimestamp());
        arb.advance(4);
        pvp.resolvePending(16);
        pvp.finalize();
        pvp.graduate();
        assertTrue(pvp.failed());
        assertEq(pvp.livingAtEnd(), 0);
    }

    function test_bailOnlyDuringPlayAndOnlySeatedWallets() public {
        vm.expectRevert(abi.encodeWithSignature("PadNotPlaying()"));
        pvp.bailOut(0);
        _start(2);
        vm.expectRevert(abi.encodeWithSignature("PadNoImp()"));
        pvp.bailOut(0);
        rollAs(pvp, players[0]);
        _finish();
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadNotPlaying()"));
        pvp.bailOut(0);
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadNotGameOrUnlocked()"));
        pvpToken.reclaim(players[0], 1);
        pvp.graduate();
        vm.prank(address(pvp));
        vm.expectRevert(abi.encodeWithSignature("PadNotGameOrUnlocked()"));
        pvpToken.reclaim(players[0], 1);
    }

    function test_rejectedBailPaymentRemainsClaimableAndCannotBePaidTwice() public {
        Rejector recipient = new Rejector();
        imdDeal(address(recipient), 400 ether);
        vm.prank(address(recipient));
        pvp.enter();
        mintAll(pvp, 1);
        advance(10 minutes);
        rollAs(pvp, address(recipient));
        uint256 value = pvp.quoteSell(pvpToken.balanceOf(address(recipient)));
        vm.prank(address(recipient));
        pvp.bailOut(value);
        assertEq(pvp.claimable(address(recipient)), value);
        vm.prank(address(recipient));
        vm.expectRevert(abi.encodeWithSignature("PadToken()"));
        pvp.claim();
        assertEq(pvp.claimable(address(recipient)), value);
        assertEq(imdBalance(address(pvp)), value + pvp.pot() + pvp.pendingCount() * pvp.ROLL_TIP());
    }

    /// forge-config: default.fuzz.runs = 64

    function test_bailAfterActualSellOutReopensCurveAndCostCountsOnlySpentETH() public {
        vm.pauseGasMetering();
        address[] memory entrants = new address[](200);
        for (uint256 i; i < 200; ++i) {
            entrants[i] = address(uint160(0x910000 + i));
            imdDeal(entrants[i], 400 ether);
            vm.prank(entrants[i]);
            pvp.enter();
        }
        advance(10 minutes);
        for (uint256 round; round < 12; ++round) {
            for (uint256 i; i < 200; ++i) {
                rollAs(pvp, entrants[i]);
            }
            advance(61);
            arb.advance(300);
        }
        vm.resumeGasMetering();
        assertEq(pvp.imdRaised(), 1600 ether);
        assertEq(pvp.tokensSold(), 800_000_000 ether);
        assertLt(pvp.curveSpent(entrants[199]), 12 * 0.9 ether, "sold-out rolls spend no curve ETH");
        uint256 coins = pvpToken.balanceOf(entrants[0]);
        uint256 value = pvp.quoteSell(coins);
        uint256 earned = pvp.rollPot();
        vm.prank(entrants[0]);
        pvp.bailOut(0);
        assertEq(pvp.imdRaised(), 1600 ether - value);
        assertEq(pvp.tokensSold(), 800_000_000 ether - coins);
        assertEq(pvp.rollPot(), earned);
        assertEq(pvp.fundedReleaseCap(), (1600 ether - value) * 15 / 100);
        uint256 cost = pvp.curveSpent(entrants[199]);
        uint256 priorCoins = pvpToken.balanceOf(entrants[199]);
        rollAs(pvp, entrants[199]);
        assertEq(pvp.curveSpent(entrants[199]) - cost, 0.9 ether);
        assertGt(pvpToken.balanceOf(entrants[199]), priorCoins);
        uint256 total = pvpToken.balanceOf(address(pvp));
        for (uint256 i; i < 200; ++i) {
            total += pvpToken.balanceOf(entrants[i]);
        }
        assertEq(total, pvpToken.totalSupply());
        uint256 claims = pvp.claimable(address(this));
        for (uint256 i; i < 200; ++i) {
            claims += pvp.claimable(entrants[i]);
        }
        assertEq(imdBalance(address(pvp)), pvp.imdRaised() + pvp.pot() + claims + pvp.pendingCount() * pvp.ROLL_TIP());
    }

    function test_largeRawTokenRatioDoesNotOverflowPriceEncoding() public pure {
        uint160 sqrtPrice = PadLib.sqrtRatioX96(1e27, 1);
        assertGt(sqrtPrice, uint160(1 << 128));
        uint256 ratio = PadLib.mulDiv(sqrtPrice, sqrtPrice, 1 << 192);
        assertApproxEqRel(ratio, 1e27, 1e6); // < 1e-12 relative error
        uint160 reciprocal = PadLib.sqrtRatioX96(1, 1e27);
        assertGt(reciprocal, 4_310_618_292);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_bailSequencesConserveETHAndSupply(uint8 count, uint8 mask) public {
        uint256 rounds = bound(count, 1, 8);
        _start(6);
        uint256 initial;
        for (uint256 i; i < 6; ++i) {
            initial += imdBalance(players[i]);
        }
        for (uint256 r; r < rounds; ++r) {
            for (uint256 i; i < 6; ++i) {
                rollAs(pvp, players[i]);
            }
            advance(61);
            arb.advance(300);
        }
        for (uint256 i; i < 6; ++i) {
            if (uint256(mask) & (1 << i) == 0) continue;
            uint256 value = pvp.quoteSell(pvpToken.balanceOf(players[i]));
            uint256 cost = pvp.curveSpent(players[i]);
            uint256 payout = value >= cost ? cost + (value - cost) / 2 : value * 90 / 100;
            uint256 earned = pvp.rollPot();
            vm.prank(players[i]);
            pvp.bailOut(payout);
            assertEq(pvp.rollPot(), earned);
            assertFalse(pvp.isAlive(pvp.impOf(players[i]) - 1));
            assertLe(pvp.fundedReleaseCap(), pvp.imdRaised() * 15 / 100);
        }
        uint256 holdings;
        uint256 wealth = imdBalance(address(pvp));
        uint256 claims = pvp.claimable(address(this));
        for (uint256 i; i < 6; ++i) {
            wealth += imdBalance(players[i]);
            holdings += pvpToken.balanceOf(players[i]);
            claims += pvp.claimable(players[i]);
        }
        assertEq(wealth + rounds * 6 * 0.02 ether, initial);
        assertEq(holdings, pvp.tokensSold());
        assertEq(holdings + pvpToken.balanceOf(address(pvp)), pvpToken.totalSupply());
        assertEq(imdBalance(address(pvp)), pvp.imdRaised() + pvp.pot() + claims + pvp.pendingCount() * pvp.ROLL_TIP());
    }

    // ---- revision: anchored band, nested unlock, progress floor, stall clock, no-return IMD -------
}

