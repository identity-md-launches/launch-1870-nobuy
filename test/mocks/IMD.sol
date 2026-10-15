// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

address constant TEST_IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;

contract TestIMD {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;
    mapping(address => bool) public callbacks;
    address public approvedPad;
    uint256 public shortBy;
    bool public returnsFalse;

    function setPad(address p) external {
        approvedPad = p;
    }

    function setBlocked(address to, bool b) external {
        blocked[to] = b;
    }

    function setCallback(address to, bool b) external {
        callbacks[to] = b;
    }

    function setShort(uint256 n) external {
        shortBy = n;
    }

    function setFalse(bool b) external {
        returnsFalse = b;
    }

    function setAllowance(address from, address spender, uint256 amount) external {
        allowance[from][spender] = amount;
    }

    function setBalance(address to, uint256 amount) external {
        totalSupply = totalSupply - balanceOf[to] + amount;
        balanceOf[to] = amount;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external virtual returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        if (returnsFalse || blocked[to]) return false;
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        if (returnsFalse || blocked[to]) return false;
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "IMD allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        uint256 cut = shortBy > amount ? amount : shortBy;
        balanceOf[to] += amount - cut;
        totalSupply -= cut;
        if (callbacks[to]) {
            (bool ok,) = to.call(abi.encodeWithSignature("onIMDTransfer(uint256)", amount - cut));
            require(ok, "IMD callback");
        }
    }
}

/// @dev Same storage as TestIMD. Return no bytes from all ERC20 writes.
contract NoReturnIMD is TestIMD {
    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        assembly { return(0, 0) }
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(!returnsFalse && !blocked[to]);
        _move(msg.sender, to, amount);
        assembly { return(0, 0) }
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        require(!returnsFalse && !blocked[to]);
        uint256 a = allowance[from][msg.sender];
        require(a >= amount);
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        assembly { return(0, 0) }
    }
}

function imdBalance(address who) view returns (uint256) {
    return TestIMD(TEST_IMD).balanceOf(who);
}

function imdDeal(address who, uint256 amount) {
    TestIMD t = TestIMD(TEST_IMD);
    t.setBalance(who, amount);
    t.setAllowance(who, t.approvedPad(), type(uint256).max);
}
