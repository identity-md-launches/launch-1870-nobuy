// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestIMD} from "./IMD.sol";

/// @notice Faults one token route, so a successful outer pull can reach a failing inner pull.
/// Inherits the existing mock's storage layout, allowing its code to be installed before a test.
contract RoutedIMD is TestIMD {
    enum Fault {
        None,
        Short,
        FalseReturn,
        RevertCall,
        ShortReturn,
        NonBoolean,
        LongReturn,
        Excess
    }

    address public faultFrom;
    address public faultTo;
    Fault public fault;
    bool public emptyReturns;

    function configure(address from, address to, Fault f) external {
        faultFrom = from;
        faultTo = to;
        fault = f;
    }

    function setEmptyReturns(bool value) external {
        emptyReturns = value;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return _returnValue(Fault.None);
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        return _transfer(msg.sender, to, amount, false);
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        return _transfer(from, to, amount, true);
    }

    function _transfer(address from, address to, uint256 amount, bool pull) private returns (bool) {
        Fault f = from == faultFrom && to == faultTo ? fault : Fault.None;
        require(f != Fault.RevertCall, "route paused");
        if (returnsFalse || blocked[to] || f == Fault.FalseReturn) return false;
        if (pull) {
            uint256 a = allowance[from][msg.sender];
            require(a >= amount, "IMD allowance");
            if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        }
        // Malformed returns intentionally follow a move: the caller must roll that move back.
        _move(from, to, amount);
        if (f == Fault.Short && amount != 0) {
            --balanceOf[to];
            --totalSupply;
        } else if (f == Fault.Excess) {
            ++balanceOf[to];
            ++totalSupply;
        }
        return _returnValue(f);
    }

    function _returnValue(Fault f) private view returns (bool) {
        if (f == Fault.ShortReturn) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (f == Fault.NonBoolean) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        if (f == Fault.LongReturn) {
            assembly ("memory-safe") {
                mstore(0, 1)
                mstore(32, 0)
                return(0, 64)
            }
        }
        if (emptyReturns) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }
}
