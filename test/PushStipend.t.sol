// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PadLib} from "../src/libs/PadLib.sol";

/// @dev Revision finding eda71ad0cb97: IMD is a bridged token with unverified source. The usual
/// Arbitrum-stack shape is an OpenZeppelin-v4 ERC20Upgradeable behind a beacon proxy (beacon SLOAD,
/// STATICCALL implementation(), DELEGATECALL). This copy adds one extra cold storage read (a pause
/// flag) to the transfer path. A transfer to a holder with a zero balance then needs about 44.7k gas
/// including call overhead, which the former 40k stipend never covered.
contract BridgedOZ4Shape {
    uint8 private _initialized;
    bool private _initializing;
    uint256[50] private __gap0;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    bool private _paused;
    mapping(address => bool) private _blocked;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 a) external {
        _totalSupply += a;
        _balances[to] += a;
        emit Transfer(address(0), to, a);
    }

    function balanceOf(address a) external view returns (uint256) {
        return _balances[a];
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        require(msg.sender != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(!_paused, "paused");
        require(!_blocked[to] && !_blocked[msg.sender], "blocked");
        uint256 fromBalance = _balances[msg.sender];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[msg.sender] = fromBalance - amount;
            _balances[to] += amount;
        }
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}

contract ShapeBeacon {
    address public implementation;

    constructor(address i) {
        implementation = i;
    }
}

contract ShapeBeaconProxy {
    address internal beacon;

    constructor(address b) {
        beacon = b;
    }

    fallback() external payable {
        address impl = ShapeBeacon(beacon).implementation();
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

/// @dev A recipient whose token callback never returns: the stipend bounds its work.
contract HookedToken {
    mapping(address => uint256) public balanceOf;
    address public eater;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function setEater(address e) external {
        eater = e;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (to == eater) {
            assembly ("memory-safe") { for {} 1 {} {} }
        }
        return true;
    }
}

contract StipendPayer {
    function push(address token, address to, uint256 amount) external returns (bool) {
        return PadLib.push(token, to, amount);
    }

    function pushGas(address token, address to, uint256 amount) external returns (bool ok, uint256 used) {
        uint256 g = gasleft();
        ok = PadLib.push(token, to, amount);
        used = g - gasleft();
    }

    function needed(address token, address to, uint256 amount) external returns (uint256 used) {
        uint256 g = gasleft();
        PadLib.tokenCall(token, abi.encodeWithSelector(0xa9059cbb, to, amount), gasleft());
        used = g - gasleft();
    }
}

contract PushStipendTest is Test {
    BridgedOZ4Shape token;
    StipendPayer payer;

    function setUp() public {
        BridgedOZ4Shape impl = new BridgedOZ4Shape();
        ShapeBeacon beacon = new ShapeBeacon(address(impl));
        token = BridgedOZ4Shape(address(new ShapeBeaconProxy(address(beacon))));
        payer = new StipendPayer();
        token.mint(address(payer), 10 ether);
    }

    function test_pushLandsForBeaconProxiedTokenWithExtraChecksAndKeepsHalfTheStipendSpare() public {
        uint256 used = payer.needed(address(token), address(0xCAFE), 1 ether);
        emit log_named_uint("beacon-proxied OZ4 transfer with two extra reads, fresh holder, gas", used);
        assertGt(used, 40_000, "the shape the old 40k stipend could not pay");
        assertLt(used * 2, PadLib.PUSH_GAS, "at least 2x headroom over the measured transfer");

        (bool landed, uint256 pushUsed) = payer.pushGas(address(token), address(0xF00D), 1 ether);
        assertTrue(landed, "first-time payout must land as a plain transfer");
        assertEq(token.balanceOf(address(0xF00D)), 1 ether);
        assertLt(pushUsed, PadLib.PUSH_GAS);
    }

    function test_pushToAnExistingHolderLandsToo() public {
        token.mint(address(0xF00D), 1);
        assertTrue(payer.push(address(token), address(0xF00D), 1 ether));
        assertEq(token.balanceOf(address(0xF00D)), 1 ether + 1);
    }

    function test_pushStillBoundsAGasEatingRecipientToTheStipend() public {
        HookedToken hooked = new HookedToken();
        hooked.mint(address(payer), 10 ether);
        hooked.setEater(address(0xEA7));
        (bool landed, uint256 used) = payer.pushGas(address(hooked), address(0xEA7), 1 ether);
        assertFalse(landed, "an endless callback fails inside the stipend");
        assertGt(used, PadLib.PUSH_GAS, "the whole stipend was consumed");
        assertLt(used, PadLib.PUSH_GAS + 10_000, "and nothing beyond it plus call overhead");
        assertTrue(payer.push(address(hooked), address(0xBEEF), 1 ether), "other recipients are unaffected");
    }
}
