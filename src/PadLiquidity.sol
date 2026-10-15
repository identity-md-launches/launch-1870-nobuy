// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PadErrors} from "./interfaces/PadErrors.sol";

import {PadLib} from "./libs/PadLib.sol";
import {Lock} from "../lib/v4-core/src/libraries/Lock.sol";
import {PadHook} from "./PadHook.sol";
import {
    IArbSys,
    IPoolManager,
    IPoolStateReader,
    IUnlockCallback,
    IPadToken,
    IERC20Min,
    IPvPPad,
    PoolKey,
    ModifyLiquidityParams,
    SwapParams
} from "./interfaces/Interfaces.sol";

interface IKingView {
    function king() external view returns (address);
}

/// @title PadLiquidity
/// @notice Seeds coin/IMD pools at the final curve price, owns full-range LP forever,
/// pays king fees in kind, and buys/burns PvP with IMD in one hop.
contract PadLiquidity is IUnlockCallback {
    uint24 internal constant FEE = 10_000;
    int24 internal constant TICK_SPACING = 200;
    int24 internal constant MIN_TICK = -887_200;
    int24 internal constant MAX_TICK = 887_200;
    // TickMath.getSqrtPriceAtTick(-887200) and (887200) of v4-core v4.0.0; asserted in LiquidityV4.t.sol.
    uint160 public constant SQRT_MIN_FULL = 4_310_618_292;
    uint160 public constant SQRT_MAX_FULL = 1_456_195_216_270_955_103_206_513_029_158_776_779_468_408_838_535;
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint160 internal constant MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    uint256 internal constant Q96 = 1 << 96;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant BURN_INTERVAL = 10 minutes;
    uint256 internal constant COLLECT_GAS = 400_000;
    /// @notice Public `distribute` examines at most this many pools per call.
    uint256 internal constant MAX_DISTRIBUTE_POOLS = 16;
    /// @dev A pre-crown settlement walks every pool while gas fits and must reach at least this many.
    uint256 internal constant MIN_CROWN_POOLS = 16;
    uint256 internal constant COLLECTION_RESERVE_GAS = 100_000;
    uint256 internal constant BROKEN_FAILURES = 3;
    uint256 internal constant LIQUIDITY_MARGIN_PPM = 1_000_000;
    /// @notice Each burn buy is limited to this sqrt-price move from the
    /// pre-swap spot: 0.5% in sqrt price, about 1% in price. Unfilled input stays for a later chunk.
    /// This bounds per-call impact; it is not a general guarantee against MEV or spot manipulation.
    uint256 internal constant IMPACT_BPS = 50;
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));

    uint8 internal constant ACT_ADD = 1;
    uint8 internal constant ACT_COLLECT = 2;
    uint8 internal constant ACT_BURN = 3;

    struct Pool {
        uint256 launchId;
        address token;
        uint128 liquidity;
        /// @dev Reign the pool's fees are settled for (see `reign`). Below the current reign, the pool
        /// still holds fees of an earlier reign and its next collection pays that reign's king.
        /// Packed with `liquidity` so its first update rewrites a non-zero slot.
        uint64 settledReign;
        uint256 tokenFees;
        uint64 lastFailureBlock;
        uint8 failures;
        uint256 imdFees;
    }

    // Written only by the constructor; no setters. Storage avoids repeated PUSH32
    // addresses in runtime and keeps the complete deployment below its gas target.
    IPoolManager public poolManager;
    address public imd;
    address public pad;
    address public king;
    address public hook;
    uint256 public burnBucket;
    uint64 public lastBurnAt;
    uint256 public distributeCursor;
    uint256 public totalBurnedIMD;
    /// @notice Number of crown changes settled so far. Reign r is the time between settlement r and
    /// settlement r + 1; reign 0 runs from deployment (no king, then the first king) to the first change.
    uint256 public reign;
    /// @notice The king whose reign each settlement closed; set when `settleCrown` runs.
    mapping(uint256 => address) public reignKing;
    bool private locked;
    bool private claimLocked;
    Pool[] internal pools;
    mapping(uint256 => uint256) public poolIndexOf; // launchId => index + 1
    mapping(address => mapping(address => uint256)) public claimable; // currency => payee => amount

    event ImdFeesCollected(uint256 indexed launchId, address indexed king, uint256 imd, uint256 coins);
    event KingBound(address indexed king);
    event HookDeployed(address indexed hook, bytes32 salt);
    event Graduated(
        uint256 indexed launchId,
        address indexed token,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 imdAmount,
        uint256 tokens,
        uint256 burnedTokens
    );
    event BurnFunded(address indexed from, uint256 amount);
    event Burned(uint256 imdSpent, uint256 tokensBurned);
    event PoolCollectionFailed(uint256 indexed launchId);
    event PoolHealth(uint256 indexed launchId, uint256 failures, bool broken);
    event KingPaid(address indexed currency, address indexed king, uint256 amount, bool pushed);
    event Claimed(address indexed currency, address indexed to, uint256 amount);

    modifier guard() {
        if (!(!locked)) revert PadErrors.PadReentrancy();
        locked = true;
        _;
        locked = false;
    }

    constructor(address poolManager_, address pad_, address imd_) {
        if (poolManager_ == address(0) || pad_ == address(0) || imd_ == address(0)) revert PadErrors.PadZero();
        poolManager = IPoolManager(poolManager_);
        pad = pad_;
        imd = imd_;
        IPvPPad(pad_).bindLiquidity();
    }

    function bindKing() external {
        if (!(king == address(0))) revert PadErrors.PadBound();
        king = msg.sender;
        emit KingBound(msg.sender);
    }

    // ---- hook ------------------------------------------------------------------------------------
    function deployHook(bytes32 salt) external returns (address h) {
        if (!(msg.sender == pad)) revert PadErrors.PadNotPad();
        if (!(hook == address(0))) revert PadErrors.PadDeployed();
        h = address(new PadHook{salt: salt}(address(poolManager), address(this)));
        hook = h;
        emit HookDeployed(h, salt);
    }

    /// @notice Init code hash to mine the open salt against (CREATE2 from this contract).
    function hookInitCodeHash() public view returns (bytes32) {
        return keccak256(abi.encodePacked(type(PadHook).creationCode, abi.encode(address(poolManager), address(this))));
    }

    function hookAddressFor(bytes32 salt) public view returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hookInitCodeHash()))))
            );
    }

    // ---- graduation ------------------------------------------------------------------------------
    function poolKey(address token) public view returns (PoolKey memory) {
        return token < imd ? PoolKey(token, imd, FEE, TICK_SPACING, hook) : PoolKey(imd, token, FEE, TICK_SPACING, hook);
    }

    function _king() internal view returns (address) {
        return IKingView(king).king();
    }

    function _onlySelf() internal view {
        if (!(msg.sender == address(this) && locked)) revert PadErrors.PadNotSelf();
    }

    function _onlyManager() internal view {
        if (!(msg.sender == address(poolManager))) revert PadErrors.PadNotPoolManager();
    }

    function _onlyGame(uint256 launchId) internal view {
        if (!(msg.sender == IPvPPad(pad).gameOf(launchId))) revert PadErrors.PadNotGame();
    }

    /// @notice Only the registered game supplies its net curve IMD. Donations do not affect price.
    function graduate(
        uint256 launchId,
        address token,
        uint256 tokenAmount,
        uint256 quoteAmount,
        uint256 vIMD,
        uint256 vTok
    ) external guard {
        _onlyGame(launchId);
        if (token != IPvPPad(pad).tokenOf(launchId)) revert PadErrors.PadToken();
        if (hook == address(0)) revert PadErrors.PadPadNotOpen();
        if (poolIndexOf[launchId] != 0) revert PadErrors.PadGraduated();
        PadLib.pullExact(imd, msg.sender, address(this), quoteAmount);
        uint256 coins = PadLib.mulDiv(quoteAmount, vTok, vIMD);
        if (!(quoteAmount != 0 && coins != 0 && coins <= tokenAmount)) revert PadErrors.PadEmpty();
        PoolKey memory key = poolKey(token);
        bool coin0 = key.currency0 == token;
        uint256 max0 = coin0 ? coins : quoteAmount;
        uint256 max1 = coin0 ? quoteAmount : coins;
        uint160 sqrtP = PadLib.sqrtRatioX96(max1, max0);
        if (!(sqrtP > SQRT_MIN_FULL && sqrtP < SQRT_MAX_FULL)) revert PadErrors.PadPriceRange();
        uint256 l0 = PadLib.mulDiv(max0, PadLib.mulDiv(sqrtP, SQRT_MAX_FULL, Q96), SQRT_MAX_FULL - sqrtP);
        uint256 l1 = PadLib.mulDiv(max1, Q96, sqrtP - SQRT_MIN_FULL);
        uint256 l = l0 < l1 ? l0 : l1;
        l -= l / LIQUIDITY_MARGIN_PPM;
        if (!(l != 0 && l <= type(uint128).max)) revert PadErrors.PadLiquidity();
        poolManager.initialize(key, sqrtP);
        (uint256 used0, uint256 used1) =
            abi.decode(poolManager.unlock(abi.encode(ACT_ADD, key, l, max0, max1)), (uint256, uint256));
        uint256 usedQuote = coin0 ? used1 : used0;
        uint256 usedCoins = coin0 ? used0 : used1;
        pools.push(Pool(launchId, token, uint128(l), uint64(reign), 0, 0, 0, 0));
        poolIndexOf[launchId] = pools.length;
        IPadToken(token).unlock();
        uint256 excess = tokenAmount - usedCoins;
        if (excess != 0) if (!(IPadToken(token).transfer(DEAD, excess))) revert PadErrors.PadBurn();
        emit Graduated(launchId, token, sqrtP, uint128(l), usedQuote, usedCoins, excess);
    }

    // ---- fees to the king -----------------------------------------------------------------------
    /// @notice Reject nested v4 unlocks even when this contract itself is idle.
    /// The slot comes directly from the pinned v4-core Lock library.
    function requireManagerLocked() public view {
        if (_managerUnlocked()) revert PadErrors.PadManagerUnlocked();
    }

    function _managerUnlocked() internal view returns (bool) {
        return IPoolStateReader(address(poolManager)).exttload(Lock.IS_UNLOCKED_SLOT) != bytes32(0);
    }

    /// @notice Permissionless round-robin collection. Fees stay in positions before the first crown.
    /// Three failed, fully gas-funded attempts in distinct L2 blocks flag a pool as broken.
    function distribute(uint256 n) external guard {
        _distribute(n, false);
    }

    /// @notice Atomic pre-crown batch: walks every pool from the cursor while the forwarded gas fits
    /// another collection, at least MIN_CROWN_POOLS of them, and an unflagged collection failure
    /// vetoes the bid. Pools it does not reach keep their entitlement: their next collection, by
    /// anyone, pays the outgoing king. Failed bids revert their failure counters too; use
    /// distribute/retryPool to diagnose a pool.
    function settleCrown() external guard {
        if (!(msg.sender == king)) revert PadErrors.PadNotKing();
        _distribute(type(uint256).max, true);
    }

    function _distribute(uint256 n, bool strict) internal {
        requireManagerLocked();
        address k = _king();
        uint256 count = pools.length;
        if (k == address(0) || count == 0 || n == 0) return;
        uint256 floor;
        if (strict) {
            // Close the outgoing king's reign: pools this walk does not reach stay owed to it.
            reignKing[reign] = k;
            reign += 1;
            n = count;
            floor = count < MIN_CROWN_POOLS ? count : MIN_CROWN_POOLS;
        } else {
            if (n > MAX_DISTRIBUTE_POOLS) n = MAX_DISTRIBUTE_POOLS;
            if (n > count) n = count;
        }
        for (uint256 i; i < n; ++i) {
            uint256 idx = distributeCursor % count;
            if (pools[idx].failures < BROKEN_FAILURES) {
                if (gasleft() < COLLECT_GAS + COLLECTION_RESERVE_GAS) {
                    if (!(i >= floor)) revert PadErrors.PadCollectionGas();
                    break;
                }
                bool ok = _collect(idx, k);
                if (!(ok || !strict)) revert PadErrors.PadPoolCollectionFailed();
            }
            distributeCursor = idx + 1;
        }
    }

    /// @notice Anyone can retry any pool, including a broken one. Success clears the flag.
    function retryPool(uint256 idx) external guard returns (bool) {
        requireManagerLocked();
        address k = _king();
        if (!(k != address(0))) revert PadErrors.PadNoKing();
        if (!(gasleft() >= COLLECT_GAS + COLLECTION_RESERVE_GAS)) revert PadErrors.PadCollectionGas();
        return _collect(idx, k);
    }

    /// @dev Pays the current king, unless the pool still holds fees of an earlier reign it was never
    /// settled for (not reached by that crown's walk, or broken then), in which case that reign's king.
    function _collect(uint256 idx, address k) internal returns (bool) {
        Pool storage p = pools[idx];
        uint256 settled = p.settledReign;
        address payee = settled < reign ? reignKing[settled] : k;
        try this.collectPool{gas: COLLECT_GAS}(idx, payee) {
            if (settled < reign) p.settledReign = uint64(reign);
            if (p.failures != 0) {
                p.failures = 0;
                p.lastFailureBlock = 0;
                _emitHealth(p);
            }
            return true;
        } catch {
            uint256 current = IArbSys(address(0x64)).arbBlockNumber();
            if (p.failures < BROKEN_FAILURES && (p.failures == 0 || current > p.lastFailureBlock)) {
                p.lastFailureBlock = uint64(current);
                ++p.failures;
                _emitHealth(p);
            }
            emit PoolCollectionFailed(p.launchId);
            return false;
        }
    }

    function _emitHealth(Pool storage p) private {
        emit PoolHealth(p.launchId, p.failures, p.failures == BROKEN_FAILURES);
    }

    /// @dev The self-call isolates a pool's revert. Both currencies are paid to the captured king;
    /// tokens are never swapped or stashed, and rejected IMD stays owed to that same king.
    function collectPool(uint256 idx, address k) external {
        _onlySelf();
        Pool storage p = pools[idx];
        PoolKey memory key = poolKey(p.token);
        bytes memory res = poolManager.unlock(abi.encode(ACT_COLLECT, key));
        (uint256 a0, uint256 a1) = abi.decode(res, (uint256, uint256));
        bool coin0 = key.currency0 == p.token;
        uint256 t = coin0 ? a0 : a1;
        uint256 q = coin0 ? a1 : a0;
        p.tokenFees += t;
        p.imdFees += q;
        _pay(p.token, k, t);
        _pay(imd, k, q);
        emit ImdFeesCollected(p.launchId, k, q, t);
    }

    function _pay(address currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        bool ok = PadLib.push(currency, to, amount);
        if (!ok) claimable[currency][to] += amount;
        emit KingPaid(currency, to, amount, ok);
    }

    // ---- burn ------------------------------------------------------------------------------------
    /// @notice Internal funding; wallets donate through PvPPad.burn and approve only PvPPad.
    function fundBurn(uint256 amount) external {
        if (msg.sender != king && !IPvPPad(pad).isGame(msg.sender)) revert PadErrors.PadNotGame();
        PadLib.pullExact(imd, msg.sender, address(this), amount);
        burnBucket += amount;
        emit BurnFunded(msg.sender, amount);
    }

    /// @dev The pad verified the receipt during its guarded donation pull.
    function creditBurn(address from, uint256 amount) external {
        if (msg.sender != pad) revert PadErrors.PadNotPad();
        burnBucket += amount;
        emit BurnFunded(from, amount);
    }

    /// @notice Buys PvP with at most eight current units / ten minutes. Partial fills retain IMD.
    function burnChunk() external guard {
        uint256 gid = IPvPPad(pad).genesisId();
        uint256 idx = gid == 0 ? 0 : poolIndexOf[gid];
        if (burnBucket == 0 || idx == 0) return;
        if (block.timestamp < lastBurnAt + BURN_INTERVAL) return;
        uint256 cap = 8 * IPvPPad(pad).unit();
        uint256 amount = burnBucket > cap ? cap : burnBucket;
        burnBucket -= amount;
        lastBurnAt = uint64(block.timestamp);
        bytes memory res = poolManager.unlock(abi.encode(ACT_BURN, poolKey(pools[idx - 1].token), amount));
        (uint256 spent, uint256 tokens) = abi.decode(res, (uint256, uint256));
        if (spent < amount) burnBucket += amount - spent;
        totalBurnedIMD += spent;
        emit Burned(spent, tokens);
    }

    /// @notice Current sqrt price of a pool, read from the PoolManager's storage (v4 StateLibrary layout).
    function sqrtPriceOf(PoolKey memory key) public view returns (uint160) {
        bytes32 slot = keccak256(abi.encodePacked(keccak256(abi.encode(key)), POOLS_SLOT));
        return uint160(uint256(IPoolStateReader(address(poolManager)).extsload(slot)));
    }

    /// @dev Both directions stay strictly inside a 1% price change: 0.995 for decreasing price,
    /// sqrt(1.01) rounded down to 18 decimals. Bounds are also clamped to v4's valid range.
    function _priceLimit(PoolKey memory key, bool zeroForOne) internal view returns (uint160) {
        uint256 spot = sqrtPriceOf(key);
        if (!(spot != 0)) revert PadErrors.PadPoolUninitialized();
        uint256 limit;
        // spot is uint160, so either product fits in 221 bits.
        unchecked {
            limit = zeroForOne ? spot - spot * IMPACT_BPS / 10_000 : spot * 1004987562112089027 / 1e18;
        }
        if (limit <= MIN_SQRT_PRICE_LIMIT) limit = MIN_SQRT_PRICE_LIMIT + 1;
        if (limit >= MAX_SQRT_PRICE_LIMIT) limit = MAX_SQRT_PRICE_LIMIT - 1;
        return uint160(limit);
    }

    /// @notice Pays a parked king payment to its owner. Uses its own lock, not the pool `guard`: the
    /// claimer receives all remaining gas, and holding the pool lock while untrusted code runs would
    /// let a claimer bid for the crown while `distribute` is unreachable (revision finding e2ea0e40).
    function claim(address currency) external {
        if (claimLocked) revert PadErrors.PadReentrancy();
        claimLocked = true;
        uint256 amount = claimable[currency][msg.sender];
        if (amount == 0) revert PadErrors.PadNothing();
        claimable[currency][msg.sender] = 0;
        PadLib.transfer(currency, msg.sender, amount);
        emit Claimed(currency, msg.sender, amount);
        claimLocked = false;
    }

    // ---- v4 callback -----------------------------------------------------------------------------
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        _onlyManager();
        uint8 action = abi.decode(data, (uint8));
        if (action == ACT_ADD) {
            (, PoolKey memory key, uint256 l, uint256 max0, uint256 max1) =
                abi.decode(data, (uint8, PoolKey, uint256, uint256, uint256));
            (int256 delta,) =
                poolManager.modifyLiquidity(key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, int256(l), 0), "");
            (int128 a0, int128 a1) = _split(delta);
            if (!(a0 <= 0 && a1 <= 0)) revert PadErrors.PadDeltaSign();
            uint256 owe0 = uint256(uint128(-a0));
            uint256 owe1 = uint256(uint128(-a1));
            if (!(owe0 <= max0 && owe1 <= max1)) revert PadErrors.PadOwesTooMuch();
            // Put IMD rounding remainder into this position's fee growth. It is collected
            // in kind for its reign, so no IMD dust
            // is stranded in an unusable burn route. Coin excess still goes to dEaD.
            if (key.currency0 == imd && max0 > owe0) {
                poolManager.donate(key, max0 - owe0, 0, "");
                owe0 = max0;
            } else if (key.currency1 == imd && max1 > owe1) {
                poolManager.donate(key, 0, max1 - owe1, "");
                owe1 = max1;
            }
            _settleToken(key.currency0, owe0);
            _settleToken(key.currency1, owe1);
            return abi.encode(owe0, owe1);
        }
        if (action == ACT_COLLECT) {
            (, PoolKey memory key) = abi.decode(data, (uint8, PoolKey));
            (, int256 fees) = poolManager.modifyLiquidity(key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, 0, 0), "");
            (int128 f0, int128 f1) = _split(fees);
            uint256 e = f0 > 0 ? uint256(uint128(f0)) : 0;
            uint256 t = f1 > 0 ? uint256(uint128(f1)) : 0;
            _takeFees(key.currency0, e);
            _takeFees(key.currency1, t);
            return abi.encode(e, t);
        }
        if (action == ACT_BURN) {
            (, PoolKey memory key, uint256 amount) = abi.decode(data, (uint8, PoolKey, uint256));
            bool zeroForOne = key.currency0 == imd;
            (uint256 spent, uint256 out) = _swap(key, zeroForOne, amount, _priceLimit(key, zeroForOne));
            if (spent != 0 && out == 0) revert PadErrors.PadZeroOutput();
            _settleToken(imd, spent);
            if (out != 0) poolManager.take(zeroForOne ? key.currency1 : key.currency0, DEAD, out);
            return abi.encode(spent, out);
        }
        revert PadErrors.PadBadAction();
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amount, uint160 limit)
        internal
        returns (uint256 spent, uint256 out)
    {
        if (!(amount <= uint256(type(int256).max))) revert PadErrors.PadAmount();
        int256 d = poolManager.swap(key, SwapParams(zeroForOne, -int256(amount), limit), "");
        (int128 a0, int128 a1) = _split(d);
        int128 input = zeroForOne ? a0 : a1;
        int128 output = zeroForOne ? a1 : a0;
        if (!(input <= 0 && output >= 0)) revert PadErrors.PadSwapSign();
        spent = uint256(uint128(-input));
        out = uint256(uint128(output));
        if (!(spent <= amount)) revert PadErrors.PadOverspent();
    }

    /// @dev A pool delta is a claim on the manager, not proof of token receipt.
    function _takeFees(address currency, uint256 amount) internal {
        if (amount == 0) return;
        uint256 beforeBalance = IERC20Min(currency).balanceOf(address(this));
        poolManager.take(currency, address(this), amount);
        uint256 afterBalance = IERC20Min(currency).balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert PadErrors.PadAmount();
    }

    function _settleToken(address token, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.sync(token);
        PadLib.transfer(token, address(poolManager), amount);
        if (poolManager.settle() != amount) revert PadErrors.PadAmount();
    }

    function _split(int256 delta) internal pure returns (int128 a0, int128 a1) {
        assembly ("memory-safe") {
            a0 := sar(128, delta)
            a1 := signextend(15, delta)
        }
    }

    // ---- views -----------------------------------------------------------------------------------
    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function getPool(uint256 idx) external view returns (Pool memory) {
        return pools[idx];
    }

    function currentKing() external view returns (address) {
        return king == address(0) ? address(0) : _king();
    }
}
