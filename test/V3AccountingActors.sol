// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TestIMD, NoReturnIMD, imdBalance, imdDeal, TEST_IMD} from "./mocks/IMD.sol";

/// @dev A test recipient whose ETH receipts can be independently reconciled with protocol debts.
/// Only one storage write in receive: an accepting recipient fits the protocol's 30k push budget.
contract AccountingRecipient {
    constructor() {
        TestIMD(TEST_IMD).setCallback(address(this), true);
    }
    bool public rejecting;
    uint256 public received;

    function setRejecting(bool value) external {
        rejecting = value;
    }

    function onIMDTransfer(uint256 receivedAmount) external {
        require(!rejecting, "recipient rejects ETH");
        received += receivedAmount;
    }
}
