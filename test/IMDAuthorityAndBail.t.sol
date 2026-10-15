// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PadGame} from "src/PadGame.sol";
import {PvPPad} from "src/PvPPad.sol";
import {KingOfThePad} from "src/KingOfThePad.sol";
import {PadErrors} from "src/interfaces/PadErrors.sol";
import {Vm} from "forge-std/Vm.sol";

contract IMDAuthorityAndBailTest is BaseTest {
    function setUp() public override {
        super.setUp();
        openPad();
    }

    function test_extraCalldataCannotSelectVictimForEntryRollOrDonations() public {
        address victim = players[11];
        address attacker = players[0];
        uint256 victimBalance = imd.balanceOf(victim);
        uint256 victimApproval = imd.allowance(victim, address(pad));
        imd.setAllowance(attacker, address(pad), 0);
        _attemptWithVictim(address(pvp), abi.encodeCall(PadGame.enter, ()), attacker, victim, false);
        imd.setAllowance(attacker, address(pad), pvp.ENTRY_PRICE());
        _attemptWithVictim(address(pvp), abi.encodeCall(PadGame.enter, ()), attacker, victim, true);
        assertEq(pvp.entryOf(attacker), 1);
        assertEq(pvp.entryOf(victim), 0);
        advance(10 minutes);
        _attemptWithVictim(address(pvp), abi.encodeCall(PadGame.roll, ()), attacker, victim, false);
        imd.setAllowance(attacker, address(pad), pvp.ROLL_PRICE());
        _attemptWithVictim(address(pvp), abi.encodeCall(PadGame.roll, ()), attacker, victim, true);
        assertGt(pvpToken.balanceOf(attacker), 0);
        assertEq(pvpToken.balanceOf(victim), 0);

        _attemptWithVictim(address(pad), abi.encodeCall(PvPPad.fundCarry, (1 ether)), attacker, victim, false);
        _attemptWithVictim(address(pad), abi.encodeCall(PvPPad.burn, (1 ether)), attacker, victim, false);
        imd.setAllowance(attacker, address(pad), 2 ether);
        _attemptWithVictim(address(pad), abi.encodeCall(PvPPad.fundCarry, (1 ether)), attacker, victim, true);
        _attemptWithVictim(address(pad), abi.encodeCall(PvPPad.burn, (1 ether)), attacker, victim, true);
        assertEq(imd.balanceOf(victim), victimBalance);
        assertEq(imd.allowance(victim, address(pad)), victimApproval);
        assertEq(imd.allowance(attacker, address(pad)), 0);
        assertEq(imd.allowance(attacker, address(pvp)), 0);
        assertEq(imd.allowance(attacker, address(liq)), 0);
    }

    function test_extraCalldataCannotSelectVictimForKingBid() public {
        graduatePvp();
        address victim = players[11];
        address attacker = players[10];
        uint256 victimBalance = imd.balanceOf(victim);
        imd.setAllowance(attacker, address(pad), 0);
        bytes memory bid = abi.encodeCall(KingOfThePad.takeCrown, (4 ether));
        _attemptWithVictim(address(king), bid, attacker, victim, false);
        assertEq(king.king(), address(0));
        imd.setAllowance(attacker, address(pad), 4 ether);
        _attemptWithVictim(address(king), bid, attacker, victim, true);
        assertEq(king.king(), attacker);
        assertEq(imd.balanceOf(victim), victimBalance);
        assertEq(imd.allowance(attacker, address(pad)), 0);
        assertEq(imd.allowance(attacker, address(king)), 0);
    }

    function test_unregisteredCopyOfGameCannotPullEvenWithVictimApproval() public {
        // Identical deployed clone runtime does not confer registry membership.
        address copy = makeAddr("unregistered game copy");
        vm.etch(copy, address(pvp).code);
        uint256 victimBalance = imd.balanceOf(players[0]);
        vm.prank(copy);
        vm.expectRevert(PadErrors.PadNotGame.selector);
        pad.pull(players[0], 1 ether);
        assertFalse(pad.isGame(copy));
        assertEq(imd.balanceOf(players[0]), victimBalance);
        bytes memory callback = abi.encode(uint8(3), liq.poolKey(address(pvpToken)), 1 ether);
        vm.prank(players[0]);
        vm.expectRevert(PadErrors.PadNotPoolManager.selector);
        liq.unlockCallback(callback);
    }

    function test_aliveBailAtOneSecondBeforeDeathQualifiesExactlyOnce() public {
        _bailBoundary(599, 1);
    }

    function test_bailAtExactDeathDoesNotQualify() public {
        _bailBoundary(600, 0);
    }

    function test_bailAfterDeathDoesNotQualify() public {
        _bailBoundary(601, 0);
    }

    function _bailBoundary(uint256 offset, uint256 expectedCount) internal {
        mintAll(pvp, 2);
        advance(10 minutes);
        uint256 start = pvp.playStart();
        rollAs(pvp, players[0]);
        vm.warp(start + 60);
        arb.advance(4);
        rollAs(pvp, players[1]);
        vm.warp(start + offset);
        uint256 raised = pvp.imdRaised();
        uint256 coins = pvpToken.balanceOf(players[0]);
        uint256 impossibleMinOut = pvp.quoteSell(coins) + 1;
        vm.prank(players[0]);
        vm.expectRevert(PadErrors.PadMinOut.selector);
        pvp.bailOut(impossibleMinOut);
        assertEq(pvp.bailedAliveCount(), 0, "failed minOut counted a seat");
        assertEq(pvp.imdRaised(), raised);
        vm.prank(players[0]);
        pvp.bailOut(0);
        assertEq(pvp.bailedAliveCount(), expectedCount);
        assertFalse(pvp.ended(), "the other seat is still alive");
        assertFalse(pvp.isAlive(pvp.impOf(players[0]) - 1));
        assertEq(pvp.endTime(), start + 60 + 10 minutes);
        vm.prank(players[0]);
        vm.expectRevert(PadErrors.PadNoImp.selector);
        pvp.bailOut(0);
        assertEq(pvp.bailedAliveCount(), expectedCount, "repeat bail counted twice");
    }

    function test_sixAliveBailsCannotPullCarryWhenNoRankableRecipientRemains() public {
        mintAll(pvp, 6);
        advance(10 minutes);
        for (uint256 i; i < 6; ++i) {
            rollAs(pvp, players[i]);
        }
        pad.fundCarry(100 ether);
        for (uint256 i; i < 6; ++i) {
            vm.prank(players[i]);
            pvp.bailOut(0);
        }
        assertEq(pvp.bailedAliveCount(), 6);
        assertTrue(pvp.ended());
        assertEq(pvp.imdRaised(), 0);
        assertEq(pvp.tokensSold(), 0);
        arb.advance(4);
        pvp.resolvePending(16);
        uint256 resolverDebt = pvp.claimable(address(this));
        assertGt(resolverDebt, 0);
        vm.recordLogs();
        pvp.finalize();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pad)) {
                assertTrue(logs[i].topics[0] != keccak256("CarryPaid(uint256,uint256)"), "empty ranks pulled carry");
            }
        }
        assertGe(pad.carryPot(), 100 ether);
        assertEq(pvp.livingAtEnd(), 0);
        assertEq(pvp.paidAtEnd(), 0);
        pvp.graduate();
        assertTrue(pvp.failed());
        assertEq(liq.poolCount(), 0);
        assertEq(pvpToken.balanceOf(DEAD), pvpToken.totalSupply());
        assertEq(imd.balanceOf(address(pvp)), resolverDebt);
        pvp.claim();
        assertEq(imd.balanceOf(address(pvp)), 0);
    }

    function _attemptWithVictim(address target, bytes memory data, address actor, address victim, bool expected)
        private
    {
        vm.prank(actor);
        (bool ok, bytes memory reason) = target.call(bytes.concat(data, abi.encode(victim)));
        assertEq(ok, expected);
        if (!expected) assertEq(reason, abi.encodeWithSelector(PadErrors.PadToken.selector));
    }
}
