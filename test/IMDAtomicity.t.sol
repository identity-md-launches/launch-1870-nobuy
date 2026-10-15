// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {RoutedIMD} from "./mocks/RoutedIMD.sol";
import {PadGame} from "src/PadGame.sol";
import {PadToken} from "src/PadToken.sol";
import {PadErrors} from "src/interfaces/PadErrors.sol";

contract IMDAtomicityTest is BaseTest {
    RoutedIMD internal routed;

    function setUp() public override {
        super.setUp();
        RoutedIMD implementation = new RoutedIMD();
        vm.etch(IMD, address(implementation).code);
        routed = RoutedIMD(IMD);
        openPad();
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_badPullReturnOrReceiptRollsBackFiniteAllowance(uint8 modeSeed, uint8 endpointSeed) public {
        RoutedIMD.Fault mode = RoutedIMD.Fault(bound(modeSeed, 1, 7));
        uint256 endpoint = endpointSeed % 3;
        address destination = endpoint == 0 ? address(pad) : endpoint == 1 ? address(liq) : address(pvp);
        imd.setAllowance(players[0], address(pad), 2 ether);
        routed.configure(players[0], destination, mode);
        bytes32 beforeState = _state(pvp);
        vm.startPrank(players[0]);
        vm.expectRevert(
            mode == RoutedIMD.Fault.Short || mode == RoutedIMD.Fault.Excess
                ? PadErrors.PadAmount.selector
                : PadErrors.PadToken.selector
        );
        if (endpoint == 0) pad.fundCarry(1 ether);
        else if (endpoint == 1) pad.burn(1 ether);
        else pvp.enter();
        vm.stopPrank();
        assertEq(_state(pvp), beforeState, "failed pull changed custody, ledger or finite allowance");

        routed.configure(players[0], destination, RoutedIMD.Fault.None);
        vm.prank(players[0]);
        if (endpoint == 0) pad.fundCarry(1 ether);
        else if (endpoint == 1) pad.burn(1 ether);
        else pvp.enter();
        assertEq(imd.allowance(players[0], address(pad)), endpoint == 2 ? 1.5 ether : 1 ether);
    }

    function test_secondEntryInnerBurnShortReceiptRevertsEntireEntry() public {
        vm.prank(players[0]);
        pvp.enter();
        imd.setAllowance(players[1], address(pad), pvp.ENTRY_PRICE());
        routed.configure(address(pvp), address(liq), RoutedIMD.Fault.Short);
        bytes32 beforeState = _state(pvp);
        vm.prank(players[1]);
        vm.expectRevert(PadErrors.PadAmount.selector);
        pvp.enter();
        assertEq(_state(pvp), beforeState);
        assertEq(pvp.entryOf(players[1]), 0);
        routed.configure(address(pvp), address(liq), RoutedIMD.Fault.None);
        vm.prank(players[1]);
        pvp.enter();
        assertEq(imd.allowance(players[1], address(pad)), 0);
        assertEq(pvp.entryCount(), 2);
    }

    function test_rollInnerBurnShortReceiptRollsBackCoinsCurveNonceAndAllowance() public {
        mintAll(pvp, 2);
        advance(10 minutes);
        imd.setAllowance(players[0], address(pad), pvp.ROLL_PRICE());
        routed.configure(address(pvp), address(liq), RoutedIMD.Fault.Short);
        bytes32 beforeState = _state(pvp);
        vm.prank(players[0]);
        vm.expectRevert(PadErrors.PadAmount.selector);
        pvp.roll();
        assertEq(_state(pvp), beforeState);
        assertEq(pvp.rollCount(), 0);
        assertEq(pvp.getImp(pvp.impOf(players[0]) - 1).nonce, 0);
        routed.configure(address(pvp), address(liq), RoutedIMD.Fault.None);
        rollAs(pvp, players[0]);
        assertEq(imd.allowance(players[0], address(pad)), 0);
        assertEq(pvp.rollCount(), 1);
    }

    function test_shortCarryPullCannotPartiallyFinalizeOrPayWinners() public {
        mintAll(pvp, 5);
        advance(10 minutes);
        uint256 start = pvp.playStart();
        for (uint256 r; r < 6; ++r) {
            vm.warp(start + r * 9 minutes);
            arb.advance(300);
            for (uint256 i; i < 5; ++i) {
                rollAs(pvp, players[i]);
            }
            arb.advance(4);
            pvp.resolvePending(16);
        }
        pad.fundCarry(50 ether);
        vm.warp(pvp.hardEnd());
        routed.configure(address(pad), address(pvp), RoutedIMD.Fault.Short);
        bytes32 beforeState = _state(pvp);
        vm.expectRevert(PadErrors.PadAmount.selector);
        pvp.finalize();
        assertEq(_state(pvp), beforeState);
        assertFalse(pvp.finalized());
        routed.configure(address(pad), address(pvp), RoutedIMD.Fault.None);
        pvp.finalize();
        assertTrue(pvp.finalized());
        assertEq(pvp.livingAtEnd(), 5);
        assertLt(pad.carryPot(), 50 ether);
    }

    function test_shortGraduationPullPreservesLockedCoinsAndPoolAbsence() public {
        _graduationFailure(false);
    }

    function test_shortManagerSettlementRollsBackPoolInitializationAndUnlock() public {
        _graduationFailure(true);
    }

    function _graduationFailure(bool settlement) internal {
        playOut(pvp, 2, 2);
        assertTrue(pvp.finalized());
        assertFalse(pvp.graduated());
        address from = settlement ? address(liq) : address(pvp);
        address to = settlement ? address(pm) : address(liq);
        routed.configure(from, to, RoutedIMD.Fault.Short);
        bytes32 beforeState = _state(pvp);
        vm.expectRevert(PadErrors.PadAmount.selector);
        pvp.graduate();
        assertEq(_state(pvp), beforeState);
        assertEq(liq.poolCount(), 0);
        assertEq(liq.sqrtPriceOf(liq.poolKey(address(pvpToken))), 0);
        assertFalse(pvpToken.unlocked());
        routed.configure(from, to, RoutedIMD.Fault.None);
        pvp.graduate();
        assertTrue(pvpToken.unlocked());
        assertEq(liq.poolCount(), 1);
    }

    function test_shortKingGamesPullRevertsRefundAndReignSettlement() public {
        _crownFailure(false);
    }

    function test_shortKingBurnPullRevertsRefundAndReignSettlement() public {
        _crownFailure(true);
    }

    function _crownFailure(bool burnRoute) internal {
        graduatePvp();
        vm.prank(players[8]);
        king.takeCrown(4 ether);
        donateFees(liq.poolKey(address(pvpToken)), 2 ether, 1000 ether);
        vm.warp(king.challengeOpensAt());
        address destination = burnRoute ? address(liq) : address(pad);
        routed.configure(address(king), destination, RoutedIMD.Fault.Short);
        imd.setAllowance(players[9], address(pad), 4.4 ether);
        bytes32 beforeState = _state(pvp);
        bytes32 poolBefore = keccak256(abi.encode(liq.getPool(0)));
        vm.prank(players[9]);
        vm.expectRevert(PadErrors.PadAmount.selector);
        king.takeCrown(4.4 ether);
        assertEq(_state(pvp), beforeState);
        assertEq(keccak256(abi.encode(liq.getPool(0))), poolBefore);
        assertEq(liq.reign(), 0);
        assertEq(liq.reignKing(0), address(0));
        assertEq(king.king(), players[8]);
        routed.configure(address(king), destination, RoutedIMD.Fault.None);
        vm.prank(players[9]);
        king.takeCrown(4.4 ether);
        assertEq(king.king(), players[9]);
        assertEq(liq.reignKing(0), players[8]);
        assertEq(imd.allowance(players[9], address(pad)), 0);
    }

    function test_failedBurnSettlementRestoresBucketTimestampAndPoolPrice() public {
        graduatePvp();
        pad.burn(10 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        routed.configure(address(liq), address(pm), RoutedIMD.Fault.Short);
        bytes32 beforeState = _state(pvp);
        uint160 price = liq.sqrtPriceOf(liq.poolKey(address(pvpToken)));
        vm.expectRevert(PadErrors.PadAmount.selector);
        liq.burnChunk();
        assertEq(_state(pvp), beforeState);
        assertEq(liq.sqrtPriceOf(liq.poolKey(address(pvpToken))), price);
        routed.configure(address(liq), address(pm), RoutedIMD.Fault.None);
        uint256 bucket = liq.burnBucket();
        liq.burnChunk();
        assertLt(liq.burnBucket(), bucket);
    }

    function _state(PadGame g) internal view returns (bytes32 h) {
        h = keccak256(
            abi.encode(
                g.imdRaised(),
                g.tokensSold(),
                g.pot(),
                g.fundedPot(),
                g.rollCount(),
                g.pendingCount(),
                g.entryCount(),
                g.drawBounty(),
                g.finalized(),
                g.graduated(),
                g.bailedAliveCount(),
                pad.carryPot(),
                liq.burnBucket(),
                liq.lastBurnAt(),
                liq.totalBurnedIMD(),
                liq.poolCount(),
                king.king(),
                king.bid(),
                king.crownCount(),
                imd.totalSupply()
            )
        );
        for (uint256 i; i < players.length + 7; ++i) {
            address a = i < players.length
                ? players[i]
                : i == players.length
                    ? address(g)
                    : i == players.length + 1
                        ? address(liq)
                        : i == players.length + 2
                            ? address(pad)
                            : i == players.length + 3
                                ? address(king)
                                : i == players.length + 4
                                    ? address(pm)
                                    : i == players.length + 5 ? address(this) : OWNER;
            h = keccak256(
                abi.encode(
                    h,
                    imd.balanceOf(a),
                    PadToken(g.token()).balanceOf(a),
                    imd.allowance(a, address(pad)),
                    g.claimable(a),
                    king.claimable(a),
                    liq.claimable(IMD, a),
                    liq.claimable(g.token(), a)
                )
            );
        }
    }
}
