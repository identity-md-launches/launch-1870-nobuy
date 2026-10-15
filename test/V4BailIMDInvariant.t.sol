// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {InvariantTest} from "./Invariants.t.sol";

/// @notice The full IMD/supply/obligation invariants start from a live, funded game with coins.
/// Random actions can immediately bail, resolve, graduate, burn, crown, donate, and claim.
/// Conversion escrow invariants were removed with the conversion feature itself.
/// forge-config: default.invariant.runs = 40
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = false
contract V4BailIMDInvariantTest is InvariantTest {
    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 6; ++i) {
            handler.enter(i, 0);
        }
        vm.warp(pvp.signupEnd());
        vm.prank(players[0]);
        pvp.draw(32);
        arb.advance(4);
        vm.prank(players[0]);
        pvp.draw(32);
        for (uint256 r; r < 3; ++r) {
            for (uint256 i; i < 6; ++i) {
                handler.roll(i, 0);
            }
            arb.advance(4);
            handler.resolve(0, 16);
            vm.warp(vm.getBlockTimestamp() + 61);
        }
        handler.fundCarry(0, 100 ether);
        assertEq(pvp.rollCount(), 18);
        invariant_gameBalanceEqualsObligations();
        invariant_systemEthConserved();
    }
}
