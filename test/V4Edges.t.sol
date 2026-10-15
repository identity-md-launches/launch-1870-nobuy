// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TestIMD, NoReturnIMD, imdBalance, imdDeal, TEST_IMD} from "./mocks/IMD.sol";

import {BaseTest} from "./Base.t.sol";
import {PadGame} from "../src/PadGame.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {PadLib} from "../src/libs/PadLib.sol";
import {PoolKey, IPoolManager, IUnlockCallback, SwapParams, IERC20Min} from "../src/interfaces/Interfaces.sol";
import {V4Router} from "./RealV4.sol";
import {Rejector} from "./mocks/Mocks.sol";

import {PvPPad} from "../src/PvPPad.sol";

/// @dev Inside one PoolManager unlock: sells IMD (spot up), tries to record that spot through the public
/// observeMarket() and through the pad's own upkeep, then buys the IMD back before settling.
contract V4EdgesTest is BaseTest {
    function setUp() public override {
        super.setUp();
        openPad();
    }

    function _start(uint256 n) internal {
        mintAll(pvp, n);
        advance(10 minutes);
    }

    function _finish() internal {
        if (!pvp.ended()) vm.warp(pvp.endTime() + 1);
        arb.advance(300);
        while (pvp.pendingCount() != 0) pvp.resolvePending(16);
        pvp.finalize();
    }

    function _height(uint256 i, int16 h) internal {
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(uint256(10)))) + i * 2);
        uint256 word = uint256(vm.load(address(pvp), slot));
        word = (word & ~(uint256(type(uint16).max) << 160)) | (uint256(uint16(h)) << 160);
        vm.store(address(pvp), slot, bytes32(word));
    }

    function _gameEthAccounted() internal view {
        uint256 claims = pvp.claimable(address(this));
        for (uint256 i; i < players.length; ++i) {
            claims += pvp.claimable(players[i]);
        }
        uint256 curve = pvp.graduated() ? 0 : pvp.imdRaised();
        assertEq(imdBalance(address(pvp)), curve + pvp.pot() + claims + pvp.pendingCount() * pvp.ROLL_TIP());
    }

    // ---- bail-out boundaries -------------------------------------------------------------------------

    function test_seatedWalletWithoutCoinsBailsForZeroAndMinOutOneReverts() public {
        _start(3);
        rollAs(pvp, players[1]);
        assertEq(pvpToken.balanceOf(players[0]), 0);
        assertEq(pvp.curveSpent(players[0]), 0);
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadMinOut()"));
        pvp.bailOut(1);
        uint256 pot = pvp.pot();
        uint256 raised = pvp.imdRaised();
        uint256 before = imdBalance(players[0]);
        vm.prank(players[0]);
        pvp.bailOut(0);
        assertTrue(pvp.erased(players[0]));
        assertEq(imdBalance(players[0]), before, "nothing to pay");
        assertEq(pvp.pot(), pot);
        assertEq(pvp.imdRaised(), raised);
        assertFalse(pvp.isAlive(pvp.impOf(players[0]) - 1));
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadErased()"));
        pvp.roll();
        _gameEthAccounted();
    }

    function test_bailOutRefusedAfterBellAndAfterHardEnd() public {
        _start(2);
        rollAs(pvp, players[0]);
        rollAs(pvp, players[1]);
        // the pending roll of seat 0 will land at +-50 from 49 / -49 only if it moves the right way; force the
        // bell directly by resolving a roll from the cap-adjacent height in the direction it goes.
        uint256 seat = pvp.impOf(players[0]) - 1;
        arb.advance(4);
        PadGame.Roll memory r = pvp.getRoll(0);
        uint256 rand = uint256(
            keccak256(
                abi.encode(
                    address(pvp),
                    uint256(r.imp),
                    uint256(r.nonce),
                    arb.arbBlockHash(r.commitBlock + 1),
                    arb.arbBlockHash(r.commitBlock + 2),
                    arb.arbBlockHash(r.commitBlock + 3)
                )
            )
        );
        uint256 face = rand % 8;
        int256 d = face < 4 ? -int256(face + 1) : int256(face - 3);
        _height(seat, d > 0 ? int16(50 - int16(d)) : int16(-50 - int16(d)));
        pvp.resolvePending(1);
        assertTrue(pvp.bellRang(), "bell");
        assertTrue(pvp.ended());
        vm.prank(players[1]);
        vm.expectRevert(abi.encodeWithSignature("PadNotPlaying()"));
        pvp.bailOut(0);
        vm.prank(players[0]);
        vm.expectRevert(abi.encodeWithSignature("PadNotPlaying()"));
        pvp.bailOut(0);
    }

    function test_bailOutRefusedAtHardEndEvenWithLiveActivity() public {
        _start(2);
        for (uint256 i; i < 6; ++i) {
            rollAs(pvp, players[0]);
            rollAs(pvp, players[1]);
            if (i < 5) advance(9 minutes);
        }
        assertFalse(pvp.ended());
        assertEq(pvp.endTime(), pvp.hardEnd(), "live activity: the hard end decides");
        vm.warp(pvp.hardEnd() - 1);
        vm.prank(players[0]);
        pvp.bailOut(0);
        vm.warp(pvp.hardEnd());
        assertTrue(pvp.ended());
        vm.prank(players[1]);
        vm.expectRevert(abi.encodeWithSignature("PadNotPlaying()"));
        pvp.bailOut(0);
    }

    function test_expiredPendingRollOfErasedSeatPaysTipToPotWithNoEffect() public {
        _start(2);
        rollAs(pvp, players[0]);
        rollAs(pvp, players[1]);
        uint256 seat = pvp.impOf(players[0]) - 1;
        vm.prank(players[0]);
        pvp.bailOut(0);
        uint256 pot = pvp.pot();
        arb.advance(300); // past the 256-block hash window: both rolls expire
        pvp.resolvePending(16);
        assertEq(pvp.pendingCount(), 0);
        assertEq(pvp.pot(), pot + 2 * pvp.ROLL_TIP(), "expired tips return to the pot");
        assertEq(pvp.getImp(seat).height, 0, "no height effect for the erased seat");
        assertEq(pvp.getRoll(0).delta, 0);
        assertTrue(pvp.getRoll(0).expired);
        _gameEthAccounted();
    }

    function test_erasedSeatOneBelowCapNeverRingsTheBell() public {
        _start(2);
        rollAs(pvp, players[0]);
        rollAs(pvp, players[1]);
        uint256 seat = pvp.impOf(players[0]) - 1;
        _height(seat, 49);
        vm.prank(players[0]);
        pvp.bailOut(0);
        arb.advance(4);
        pvp.resolvePending(16);
        assertEq(pvp.getImp(seat).height, 49);
        assertEq(pvp.bellAt(), 0, "an erased seat cannot ring");
        assertFalse(pvp.ended());
    }

    function test_kingSplitIgnoresGameWithErasedSeatBelowFive() public {
        _start(6);
        for (uint256 i; i < 6; ++i) {
            rollAs(pvp, players[i]);
        }
        (bool live, uint256 weight) = pvp.isLiveForKing();
        assertTrue(live);
        uint256 earned = pvp.rollPot();
        assertEq(weight, earned);
        vm.prank(players[5]);
        pvp.bailOut(0);
        (live, weight) = pvp.isLiveForKing();
        assertTrue(live, "five non-erased seats still qualify");
        assertEq(weight, earned, "bail tax is not king weight");
        vm.prank(players[4]);
        pvp.bailOut(0);
        (live,) = pvp.isLiveForKing();
        assertFalse(live, "four non-erased seats do not qualify");
        // the king's share then goes to the carry pot instead of this game
        imdDeal(address(king), 400 ether);
        uint256 carry = pad.carryPot();
        uint256 funded = pvp.fundedPot();
        vm.prank(address(king));
        pad.fundGames(200.0 ether);
        assertEq(pad.carryPot(), carry + 200.0 ether);
        assertEq(pvp.fundedPot(), funded);
    }

    function test_everySeatBailingOutEndsTheGameAtOnceAndFailsGraduation() public {
        _start(3);
        for (uint256 i; i < 3; ++i) {
            rollAs(pvp, players[i]);
        }
        for (uint256 i; i < 3; ++i) {
            vm.prank(players[i]);
            pvp.bailOut(0);
            assertEq(pvp.ended(), i == 2);
        }
        assertEq(pvp.endTime(), vm.getBlockTimestamp());
        assertEq(pvp.imdRaised(), 0);
        assertEq(pvp.tokensSold(), 0);
        uint256 pot = pvp.pot();
        assertGt(pot, 0);
        arb.advance(4);
        pvp.resolvePending(16);
        pot = pvp.pot(); // resolved tips
        uint256 fee = pot * 50 / 10_000;
        if (fee > pvp.rollPot()) fee = pvp.rollPot();
        uint256 carry = pad.carryPot();
        uint256 finalizer = imdBalance(address(this));
        pvp.finalize();
        assertEq(pvp.livingAtEnd(), 0);
        assertEq(imdBalance(address(this)) - finalizer, fee, "finalizer fee from roll income only");
        assertEq(pad.carryPot(), carry + pot - fee, "nobody ranks: the rest of the pot is carried");
        assertEq(pvp.status(), 4, "no curve ETH: no converting phase");
        pvp.graduate();
        assertTrue(pvp.failed());
        assertEq(pvp.status(), 6);
        assertEq(pvpToken.balanceOf(DEAD), pvpToken.totalSupply());
        assertFalse(pvpToken.unlocked());
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_bailPayoutFormulaAndCurveLedger(uint8 rollsSeed, uint8 who, uint96 minOutSeed) public {
        uint256 rounds = bound(rollsSeed, 1, 5);
        _start(4);
        for (uint256 r; r < rounds; ++r) {
            for (uint256 i; i < 4; ++i) {
                if ((uint256(rollsSeed) >> i) & 1 == 1 || r == 0) rollAs(pvp, players[i]);
            }
            advance(61);
            arb.advance(300);
        }
        address p = players[who % 4];
        uint256 coins = pvpToken.balanceOf(p);
        uint256 value = pvp.quoteSell(coins);
        uint256 cost = pvp.curveSpent(p);
        uint256 expected = value >= cost ? cost + (value - cost) / 2 : value * 90 / 100;
        assertLe(expected, value, "the curve never pays above the sell value");
        assertLe(value, pvp.imdRaised(), "the sell value never exceeds the curve ETH");
        uint256 minOut = bound(minOutSeed, 0, expected + 1);
        uint256 pot = pvp.pot();
        uint256 earned = pvp.rollPot();
        uint256 raised = pvp.imdRaised();
        uint256 sold = pvp.tokensSold();
        uint256 before = imdBalance(p);
        vm.prank(p);
        if (minOut > expected) {
            vm.expectRevert(abi.encodeWithSignature("PadMinOut()"));
            pvp.bailOut(minOut);
            assertFalse(pvp.erased(p));
            return;
        }
        pvp.bailOut(minOut);
        assertEq(imdBalance(p) - before, expected);
        assertEq(pvp.pot() - pot, value - expected);
        assertEq(pvp.rollPot(), earned);
        assertEq(raised - pvp.imdRaised(), value);
        assertEq(sold - pvp.tokensSold(), coins);
        (uint256 vEth, uint256 vTok,) = pvp.curveState();
        assertGe(vEth * vTok, pvp.K(), "constant product holds after the sell");
        assertEq(pvpToken.balanceOf(address(pvp)), pvpToken.totalSupply() - pvp.tokensSold());
        _gameEthAccounted();
    }

    // ---- conversion escrow semantics -------------------------------------------------------------------
}
