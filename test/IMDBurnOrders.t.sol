// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PadGame} from "src/PadGame.sol";
import {PadToken} from "src/PadToken.sol";
import {PoolKey} from "src/interfaces/Interfaces.sol";
import {Vm} from "forge-std/Vm.sol";

contract IMDBurnOrdersTest is BaseTest {
    function test_coinFirstBurnIsOneHopAndPartialFillRespectsLimit() public {
        _burnOrder(true);
    }

    function test_imdFirstBurnIsOneHopAndPartialFillRespectsLimit() public {
        _burnOrder(false);
    }

    function _burnOrder(bool coinFirst) private {
        openPad();
        // Reach each sorted order through genuine no-roll genesis failures and restarts.
        // No token address, AMM implementation, pool storage or application state is substituted.
        for (uint256 i; i < 32 && (address(pvpToken) < IMD) != coinFirst; ++i) {
            playOut(pvp, 1, 0);
            pvp.graduate();
            assertTrue(pvp.failed());
            uint256 id = pad.restartGenesis();
            pvp = PadGame(pad.gameOf(id));
            pvpToken = PadToken(pad.tokenOf(id));
        }
        assertEq(address(pvpToken) < IMD, coinFirst, "fixture did not reach requested order");
        graduatePvp();
        vm.prank(OWNER);
        pad.setUnit(0.1 ether);
        pad.burn(100 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        PoolKey memory key = liq.poolKey(address(pvpToken));
        uint256 spot = liq.sqrtPriceOf(key);
        uint256 bucket = liq.burnBucket();
        uint256 dead = pvpToken.balanceOf(DEAD);
        uint256 managerIMD = imd.balanceOf(address(pm));
        uint256 managerCoins = pvpToken.balanceOf(address(pm));
        uint256 liquidityIMD = imd.balanceOf(address(liq));
        vm.recordLogs();
        liq.burnChunk();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        uint256 swaps;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pm) && logs[i].topics[0] == swapTopic) {
                ++swaps;
                assertEq(logs[i].topics[1], keccak256(abi.encode(key)), "burn used an intermediate pool");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(liq));
                (int128 a0, int128 a1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertLt(coinFirst ? a1 : a0, 0, "IMD must be the input");
                assertGt(coinFirst ? a0 : a1, 0, "PvP must be the output");
            }
        }
        assertEq(swaps, 1, "one-hop burn must make exactly one swap");
        uint256 spent = bucket - liq.burnBucket();
        uint256 bought = pvpToken.balanceOf(DEAD) - dead;
        assertGt(spent, 0);
        assertLt(spent, 0.8 ether, "the thin pool must partially fill");
        assertGt(bought, 0);
        assertEq(imd.balanceOf(address(pm)) - managerIMD, spent);
        assertEq(liquidityIMD - imd.balanceOf(address(liq)), spent);
        assertEq(managerCoins - pvpToken.balanceOf(address(pm)), bought);
        assertEq(pvpToken.balanceOf(address(liq)), 0);
        assertEq(imd.balanceOf(address(liq)), liq.burnBucket());
        uint256 price = liq.sqrtPriceOf(key);
        if (coinFirst) {
            assertGt(price, spot);
            assertLe(price, spot * 1004987562112089027 / 1e18);
        } else {
            assertLt(price, spot);
            assertGe(price, spot - spot * 50 / 10000);
        }
        uint256 afterBucket = liq.burnBucket();
        vm.warp(vm.getBlockTimestamp() + 599);
        liq.burnChunk();
        assertEq(liq.burnBucket(), afterBucket, "burn happened before cooldown elapsed");
        vm.warp(vm.getBlockTimestamp() + 1);
        liq.burnChunk();
        assertLt(liq.burnBucket(), afterBucket, "burn could not resume at exact cooldown");
    }
}
