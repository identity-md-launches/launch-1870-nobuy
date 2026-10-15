// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {TestIMD, TEST_IMD} from "./mocks/IMD.sol";
import {RoutedIMD} from "./mocks/RoutedIMD.sol";
import {MockArbSys} from "./mocks/Mocks.sol";
import {V4Router} from "./RealV4.sol";
import {PadGame} from "src/PadGame.sol";
import {PadToken} from "src/PadToken.sol";
import {PvPPad} from "src/PvPPad.sol";
import {PadLiquidity} from "src/PadLiquidity.sol";
import {KingOfThePad} from "src/KingOfThePad.sol";
import {PadErrors} from "src/interfaces/PadErrors.sol";

/// @notice Uses real entrypoints only. No protocol storage edits, no minting during sequences,
/// no swallowed unexpected reverts. Unsolicited transfers are independently tracked as surplus.
contract IMDCustodyHandler is Test {
    PvPPad public immutable pad;
    PadLiquidity public immutable liq;
    KingOfThePad public immutable crown;
    MockArbSys public immutable arb;
    V4Router public immutable router;
    TestIMD public constant imd = TestIMD(TEST_IMD);
    address[6] public actors;
    mapping(address => uint256) public surplus;
    mapping(address => uint256) public snapshotUnit;
    mapping(address => bool) public terminal;
    uint256 public rollsSucceeded;
    uint256 public bailsSucceeded;
    uint256 public claimsSucceeded;
    uint256 public claimsRejected;
    uint256 public donations;
    uint256 public burns;
    uint256 public trades;

    constructor(PvPPad p, PadLiquidity l, KingOfThePad k, MockArbSys a, V4Router r, address[6] memory users) {
        pad = p;
        liq = l;
        crown = k;
        arb = a;
        router = r;
        actors = users;
        snapshotUnit[p.gameOf(1)] = p.unit();
    }

    function roll(uint256 actorSeed, uint256 gameSeed) public {
        PadGame g = _game(gameSeed);
        address who = actors[actorSeed % 6];
        arb.advance(4);
        vm.prank(who);
        g.resolvePending(16);
        if (g.ended() || g.erased(who)) return;
        PadGame.Imp memory imp = g.getImp(g.impOf(who) - 1);
        if (!g.isAlive(g.impOf(who) - 1)) return;
        if (imp.lastRoll != 0 && vm.getBlockTimestamp() < imp.lastRoll + g.COOLDOWN()) return;
        uint256 allowanceBefore = imd.allowance(who, address(pad));
        vm.prank(who);
        g.roll();
        assertEq(
            allowanceBefore - imd.allowance(who, address(pad)),
            snapshotUnit[address(g)],
            "owner changed running game's charge"
        );
        ++rollsSucceeded;
    }

    function bail(uint256 actorSeed, uint256 gameSeed, bool rejectPayment, bool tooHigh) public {
        PadGame g = _game(gameSeed);
        address who = actors[actorSeed % 6];
        if (g.ended() || g.erased(who)) return;
        uint256 coins = PadToken(g.token()).balanceOf(who);
        uint256 quote = g.quoteSell(coins);
        uint256 beforeBalance = imd.balanceOf(who);
        uint256 beforeDebt = g.claimable(who);
        uint256 beforeCurve = g.imdRaised();
        uint256 beforeCount = g.bailedAliveCount();
        bool alive = g.isAlive(g.impOf(who) - 1);
        imd.setBlocked(who, rejectPayment);
        vm.prank(who);
        if (tooHigh) {
            vm.expectRevert(PadErrors.PadMinOut.selector);
            g.bailOut(quote + 1);
            assertFalse(g.erased(who));
            assertEq(g.imdRaised(), beforeCurve);
            assertEq(PadToken(g.token()).balanceOf(who), coins);
        } else {
            g.bailOut(0);
            assertTrue(g.erased(who));
            assertFalse(g.isAlive(g.impOf(who) - 1));
            assertEq(PadToken(g.token()).balanceOf(who), 0);
            assertEq(g.imdRaised() + quote, beforeCurve);
            assertLe(imd.balanceOf(who) + g.claimable(who) - beforeBalance - beforeDebt, quote);
            assertEq(g.bailedAliveCount(), beforeCount + (alive ? 1 : 0));
            ++bailsSucceeded;
        }
        imd.setBlocked(who, false);
    }

    function tick(uint256 secondsSeed, uint256 blocksSeed) public {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 91));
        arb.advance(bound(blocksSeed, 0, 260));
    }

    function setUnit(uint256 valueSeed) public {
        uint256 value = bound(valueSeed, 0.1 ether, 10 ether);
        vm.prank(pad.owner());
        pad.setUnit(value);
    }

    function finish(uint256 gameSeed, uint256 actorSeed) public {
        PadGame g = _game(gameSeed);
        address who = actors[actorSeed % 6];
        if (!g.ended()) vm.warp(g.endTime());
        arb.advance(300);
        vm.startPrank(who);
        while (g.pendingCount() != 0) g.resolvePending(16);
        if (!g.finalized()) g.finalize();
        if (!g.graduated()) g.graduate();
        vm.stopPrank();
        terminal[address(g)] = true;
    }

    function createGame() public {
        if (!pad.genesisGraduated() || pad.launchCount() >= 4) return;
        uint256 u = pad.unit();
        vm.prank(actors[0]);
        uint256 id = pad.launch("Invariant", "INV", "");
        PadGame g = PadGame(pad.gameOf(id));
        snapshotUnit[address(g)] = u;
        for (uint256 i; i < 6; ++i) {
            vm.prank(actors[i]);
            g.enter();
        }
        vm.warp(g.signupEnd());
        vm.prank(actors[0]);
        g.draw(32);
        arb.advance(4);
        vm.prank(actors[0]);
        g.draw(32);
        assertTrue(g.drawComplete());
    }

    function donate(uint256 actorSeed, uint256 targetSeed, uint256 gameSeed, uint256 amountSeed) public {
        address who = actors[actorSeed % 6];
        uint256 choice = targetSeed % 4;
        address to = choice == 0
            ? address(pad)
            : choice == 1 ? address(liq) : choice == 2 ? address(crown) : address(_game(gameSeed));
        uint256 amount = bound(amountSeed, 1, 2 ether);
        _send(TEST_IMD, who, to, amount);
        surplus[to] += amount;
        ++donations;
    }

    function fund(uint256 actorSeed, uint256 amountSeed, bool toBurn) public {
        vm.prank(actors[actorSeed % 6]);
        uint256 amount = bound(amountSeed, 0, 3 ether);
        if (toBurn) pad.burn(amount);
        else pad.fundCarry(amount);
    }

    function crownBid(uint256 actorSeed, bool rejectOutgoing) public {
        if (!pad.genesisGraduated()) return;
        uint256 amount = crown.nextMinBid();
        if (amount > 300 ether) return;
        if (vm.getBlockTimestamp() < crown.challengeOpensAt()) vm.warp(crown.challengeOpensAt());
        address previous = crown.king();
        imd.setBlocked(previous, rejectOutgoing);
        vm.prank(actors[actorSeed % 6]);
        crown.takeCrown{gas: 9_000_000}(amount);
        imd.setBlocked(previous, false);
        assertEq(crown.king(), actors[actorSeed % 6]);
    }

    function claim(uint256 actorSeed, uint256 gameSeed, uint256 sourceSeed, bool reject) public {
        address who = actors[actorSeed % 6];
        uint256 source = sourceSeed % 3;
        PadGame g = _game(gameSeed);
        address target = source == 0 ? address(g) : source == 1 ? address(crown) : address(liq);
        uint256 owed =
            source == 0 ? g.claimable(who) : source == 1 ? crown.claimable(who) : liq.claimable(TEST_IMD, who);
        uint256 beforeBalance = imd.balanceOf(who);
        imd.setBlocked(who, reject);
        vm.prank(who);
        (bool ok, bytes memory reason) = target.call(
            source == 2 ? abi.encodeWithSignature("claim(address)", TEST_IMD) : abi.encodeWithSignature("claim()")
        );
        if (owed == 0 || reject) {
            assertFalse(ok, "empty or blocked claim succeeded");
            assertEq(
                reason, abi.encodeWithSelector(owed == 0 ? PadErrors.PadNothing.selector : PadErrors.PadToken.selector)
            );
            assertEq(imd.balanceOf(who), beforeBalance);
            if (owed != 0) ++claimsRejected;
        } else {
            assertTrue(ok, "recoverable debt cannot be claimed");
            assertEq(imd.balanceOf(who) - beforeBalance, owed);
            ++claimsSucceeded;
        }
        uint256 afterDebt =
            source == 0 ? g.claimable(who) : source == 1 ? crown.claimable(who) : liq.claimable(TEST_IMD, who);
        assertEq(afterDebt, ok ? 0 : owed);
        imd.setBlocked(who, false);
    }

    function burnAndCollect(uint256 actorSeed) public {
        uint256 beforeBucket = liq.burnBucket();
        uint256 beforeSpent = liq.totalBurnedIMD();
        uint256 last = liq.lastBurnAt();
        vm.prank(actors[actorSeed % 6]);
        liq.burnChunk();
        uint256 spent = liq.totalBurnedIMD() - beforeSpent;
        assertEq(beforeBucket - liq.burnBucket(), spent);
        assertLe(spent, 8 * pad.unit());
        if (vm.getBlockTimestamp() < last + 10 minutes) assertEq(spent, 0);
        if (spent > 0) ++burns;
        liq.distribute(4);
    }

    function trade(uint256 actorSeed, uint256 gameSeed, uint256 amountSeed, bool buy) public {
        PadGame g = _game(gameSeed);
        if (!g.graduated() || g.failed()) return;
        address who = actors[actorSeed % 6];
        address input = buy ? TEST_IMD : g.token();
        address output = buy ? g.token() : TEST_IMD;
        uint256 available = buy ? imd.balanceOf(who) : PadToken(input).balanceOf(who);
        if (available == 0) return;
        uint256 cap = buy ? 0.1 ether : available / 10 + 1;
        uint256 amount = bound(amountSeed, 1, cap < available ? cap : available);
        _send(input, who, address(router), amount);
        router.trade(liq.poolKey(g.token()), buy, amount);
        uint256 outputBalance = TestIMD(output).balanceOf(address(router));
        if (outputBalance != 0) _send(output, address(router), who, outputBalance);
        ++trades;
    }

    function _send(address token, address from, address to, uint256 amount) private {
        vm.prank(from);
        (bool ok, bytes memory data) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        assertTrue(ok && (data.length == 0 || abi.decode(data, (bool))), "test transfer failed");
    }

    function _game(uint256 seed) private view returns (PadGame) {
        return PadGame(pad.gameOf(1 + seed % pad.launchCount()));
    }
}

abstract contract IMDCustodyInvariantBase is BaseTest {
    IMDCustodyHandler internal handler;
    uint256 internal initialIMD;

    function emptyReturns() internal pure virtual returns (bool);

    function setUp() public override {
        super.setUp();
        RoutedIMD implementation = new RoutedIMD();
        vm.etch(IMD, address(implementation).code);
        RoutedIMD(IMD).setEmptyReturns(emptyReturns());
        vm.prank(OWNER);
        pad.setUnit(731234567890123457);
        openPad();
        mintAll(pvp, 6);
        advance(10 minutes);
        address[6] memory users;
        for (uint256 i; i < 6; ++i) {
            users[i] = players[i];
            imd.setAllowance(players[i], address(pad), 4000 ether);
        }
        handler = new IMDCustodyHandler(pad, liq, king, arb, router, users);
        initialIMD = _allIMD();
        // Exercise every custody category before random calls, including rejected and recovered debt.
        for (uint256 i; i < 6; ++i) {
            handler.roll(i, 0);
        }
        handler.bail(0, 0, true, false);
        handler.claim(0, 0, 0, true);
        handler.claim(0, 0, 0, false);
        for (uint256 i; i < 4; ++i) {
            handler.donate(2, i, 0, 11);
        }
        handler.finish(0, 1);
        handler.crownBid(0, false);
        handler.crownBid(1, true);
        handler.claim(0, 0, 1, false);
        handler.createGame();
        handler.roll(0, 1);
        handler.trade(2, 0, 1e16, true);
        handler.trade(2, 0, 100 ether, false);
        handler.fund(3, 2 ether, true);
        handler.tick(91, 260);
        handler.burnAndCollect(3);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.roll.selector;
        selectors[1] = handler.bail.selector;
        selectors[2] = handler.tick.selector;
        selectors[3] = handler.setUnit.selector;
        selectors[4] = handler.finish.selector;
        selectors[5] = handler.createGame.selector;
        selectors[6] = handler.donate.selector;
        selectors[7] = handler.fund.selector;
        selectors[8] = handler.crownBid.selector;
        selectors[9] = handler.claim.selector;
        selectors[10] = handler.burnAndCollect.selector;
        selectors[11] = handler.trade.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_eachCustodianBacksItsOwnDebtsAndSurplus() public view {
        uint256 kingDebt;
        uint256 liquidityDebt;
        for (uint256 i; i < 12; ++i) {
            kingDebt += king.claimable(players[i]);
            liquidityDebt += liq.claimable(IMD, players[i]);
        }
        kingDebt += king.claimable(OWNER);
        assertEq(imd.balanceOf(address(king)), kingDebt + handler.surplus(address(king)));
        assertEq(imd.balanceOf(address(liq)), liq.burnBucket() + liquidityDebt + handler.surplus(address(liq)));
        assertEq(imd.balanceOf(address(pad)), pad.carryPot() + handler.surplus(address(pad)));
        for (uint256 id = 1; id <= pad.launchCount(); ++id) {
            PadGame g = PadGame(pad.gameOf(id));
            uint256 debt = g.claimable(address(this));
            for (uint256 i; i < 12; ++i) {
                debt += g.claimable(players[i]);
            }
            uint256 reserve = g.graduated() ? 0 : g.imdRaised();
            assertEq(
                imd.balanceOf(address(g)),
                reserve + g.pot() + g.drawBounty() + g.pendingCount() * g.ROLL_TIP() + debt
                    + handler.surplus(address(g))
            );
        }
    }

    function invariant_IMDAndEveryCoinAreConserved() public view {
        assertEq(_allIMD(), initialIMD, "IMD was minted, lost or paid outside the actor set");
        for (uint256 id = 1; id <= pad.launchCount(); ++id) {
            PadToken t = PadToken(pad.tokenOf(id));
            uint256 sum = t.balanceOf(pad.gameOf(id)) + t.balanceOf(address(liq)) + t.balanceOf(address(pm))
                + t.balanceOf(address(router)) + t.balanceOf(DEAD);
            for (uint256 i; i < 12; ++i) {
                sum += t.balanceOf(players[i]);
            }
            assertEq(sum, t.SUPPLY(), "coin leaked or supply changed");
            assertEq(t.totalSupply(), t.SUPPLY());
        }
    }

    function invariant_unitsLocksAndTerminalStatesStayConsistent() public view {
        for (uint256 id = 1; id <= pad.launchCount(); ++id) {
            PadGame g = PadGame(pad.gameOf(id));
            assertEq(g.unit(), handler.snapshotUnit(address(g)), "running unit changed");
            assertLe(g.imdRaised(), 1600 * g.unit());
            assertLe(g.tokensSold(), 800_000_000 ether);
            (uint256 reserve, uint256 coins,) = g.curveState();
            assertGe(reserve * coins, g.K(), "curve round-trip created value");
            assertEq(PadToken(g.token()).unlocked(), g.graduated() && !g.failed());
            if (handler.terminal(address(g))) assertTrue(g.graduated() && g.finalized() && g.ended());
            if (g.graduated()) assertEq(PadToken(g.token()).balanceOf(address(g)), 0);
        }
        assertGt(handler.rollsSucceeded(), 6);
        assertGt(handler.bailsSucceeded(), 0);
        assertGt(handler.claimsRejected(), 0);
        assertGt(handler.claimsSucceeded(), 1);
        assertGe(handler.donations(), 4);
        assertGe(handler.trades(), 2);
    }

    function afterInvariant() public {
        // Healthy token recovery must let all known IMD debts drain exactly once.
        for (uint256 id; id < pad.launchCount(); ++id) {
            handler.finish(id, 1);
            for (uint256 a; a < 6; ++a) {
                handler.claim(a, id, 0, false);
            }
        }
        for (uint256 a; a < 6; ++a) {
            handler.claim(a, 0, 1, false);
            handler.claim(a, 0, 2, false);
        }
        invariant_eachCustodianBacksItsOwnDebtsAndSurplus();
        invariant_IMDAndEveryCoinAreConserved();
        invariant_unitsLocksAndTerminalStatesStayConsistent();
    }

    function _allIMD() internal view returns (uint256 total) {
        total = imd.balanceOf(address(this)) + imd.balanceOf(OWNER) + imd.balanceOf(address(pad))
            + imd.balanceOf(address(liq)) + imd.balanceOf(address(king)) + imd.balanceOf(address(pm))
            + imd.balanceOf(address(router)) + imd.balanceOf(address(handler));
        for (uint256 i; i < 12; ++i) {
            total += imd.balanceOf(players[i]);
        }
        for (uint256 id = 1; id <= pad.launchCount(); ++id) {
            total += imd.balanceOf(pad.gameOf(id));
        }
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 72
/// forge-config: default.invariant.fail-on-revert = true
contract IMDCustodyInvariantTest is IMDCustodyInvariantBase {
    function emptyReturns() internal pure override returns (bool) {
        return false;
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 72
/// forge-config: default.invariant.fail-on-revert = true
contract IMDNoReturnCustodyInvariantTest is IMDCustodyInvariantBase {
    function emptyReturns() internal pure override returns (bool) {
        return true;
    }
}
