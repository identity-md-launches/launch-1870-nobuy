// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PadErrors} from "./interfaces/PadErrors.sol";

import {PadLib} from "./libs/PadLib.sol";
import {IArbSys, IPadToken, IPvPPad, IPadLiquidity} from "./interfaces/Interfaces.sol";

/// @title PadGame
/// @notice Template (EIP-1167 cloned per launch) holding one launch's bonding curve and its Spireth game.
/// Wall-clock rules (signup, cooldown, death, 50 min play cap) use block.timestamp; randomness and the
/// commit window use ArbSys (0x64) arbBlockNumber / arbBlockHash, never block.number or blockhash.
contract PadGame {
    using PadLib for *;

    // ---- constants -------------------------------------------------------------------------
    IArbSys internal constant ARB = IArbSys(address(0x64));
    uint256 public constant COOLDOWN = 60;
    uint256 public constant SIGNUP = 10 minutes;
    uint256 public constant DEATH = 10 minutes;
    uint256 public constant MAX_PLAY = 50 minutes;
    uint256 public constant DRAW_BATCH = 32;
    uint256 public constant MAX_IMPS = 200;
    int256 public constant HEIGHT_CAP = 50;
    uint256 public constant RESOLVE_BATCH = 16;
    uint256 internal constant RESOLVE_GAS_FLOOR = 200_000;
    uint256 public constant HASH_WINDOW = 256;
    uint256 public constant VTOK = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 public constant FINALIZER_BPS = 50;
    /// @notice Funded IMD (carry pot, king share) is paid out only when at least this many seats qualify (living at end or alive when bailed).
    uint256 public constant FUNDED_MIN_LIVING = 5;
    /// @notice Funded IMD paid out is capped at this multiple of the roll-earned pot; the rest returns to the carry.
    uint256 public constant FUNDED_RELEASE_MULTIPLE = 3;
    /// @notice Funded IMD is also capped at 15% of net curve IMD after bail-out sales.
    /// Bail taxes never increase rollPot. See AUDIT.md #13 for the sole-buyer derivation,
    /// with the direct IMD graduation and alive-bail qualification rule.
    uint256 public constant FUNDED_RELEASE_CURVE_BPS = 1_500;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ---- types ----------------------------------------------------------------------------
    struct Imp {
        address owner;
        int16 height;
        uint40 lastRoll;
        uint40 heightReachedAt; // commit L2 block of the roll that reached the current height
        uint32 nonce;
        uint32 pendingRoll; // roll index + 1, 0 when none pending
        uint32 heightRoll; // roll index + 1 that reached the current height (tie-break inside one block)
    }

    struct Roll {
        uint32 imp;
        uint32 nonce;
        uint64 commitBlock;
        bool resolved;
        bool expired;
        int8 delta;
    }

    // ---- state ----------------------------------------------------------------------------
    address public pad;
    address public token;
    address public liquidity;
    uint256 public launchId;
    bool public genesis;
    bool private initialized;
    bool private locked;

    uint256 public imdRaised;
    uint256 public tokensSold;
    uint256 public pot; // total: roll-earned + funded + bail taxes

    uint64 public firstEntryAt;
    uint64 public bellAt;
    uint64 public maxActivity;
    address public bellRinger;
    bool public finalized;
    bool public graduated;
    bool public failed;
    uint32 public livingAtEnd;
    uint32 public paidAtEnd;

    Imp[] internal imps;
    mapping(address => uint256) public impOf; // index + 1
    Roll[] internal rolls;
    uint256 public nextPending;
    uint256 public pendingCount;
    mapping(address => uint256) public claimable;
    uint256 public fundedPot; // part of `pot` that came from the pad (carry pot, king share)

    // Appended state keeps the existing game accounting layout intact.
    address[] internal entrants;
    mapping(address => uint256) public entryOf; // 1-based; zero means not entered
    mapping(uint256 => uint256) private shuffled; // sparse Fisher-Yates, value + 1
    uint256 public drawCommitBlock;
    bytes32 public drawSeed;
    uint256 public drawNonce;
    bool public drawCommitted;
    bool public drawSeeded;
    bool public drawComplete;
    uint64 public playStartedAt;
    uint256 public drawBounty;

    // v4: erasure does not delete pending rolls or their resolver liabilities.
    mapping(address => bool) public erased;
    mapping(address => uint256) public curveSpent;
    uint256 internal bailPot;
    uint256 internal erasedCount;
    uint64 public finalizedAt;
    uint256 public bailedAliveCount;
    address public imd;
    uint256 public unit;

    // ---- events ---------------------------------------------------------------------------
    event Initialized(uint256 indexed launchId, address indexed token, bool genesis, uint256 unit);
    event Entered(address indexed owner, uint256 indexed entry, bool signupStarted);
    event DrawCommitted(uint256 indexed commitBlock);
    event DrawBounty(address indexed capturer, uint256 amount);
    event ResolverTip(uint256 indexed roll, address indexed resolver, uint256 amount, bool expired);
    event DrawSeedReady(uint256 indexed commitBlock, bytes32 seed);
    event Seated(address indexed owner, uint256 indexed imp, uint256 indexed entry);
    event DrawProgress(uint256 seats, uint256 target, uint256 nonce);
    event PlayStarted(uint256 at, uint256 hardEnd);
    event Rolled(address indexed owner, uint256 indexed imp, uint256 indexed roll, uint256 commitBlock, uint256 tokens);
    event Resolved(uint256 indexed roll, uint256 indexed imp, int256 delta, int256 height, bool expired);
    event Bell(uint256 indexed imp, address indexed ringer, int256 height);
    event CurveBuy(uint256 imdIn, uint256 imdToCurve, uint256 tokensOut, uint256 imdToPot);
    event PotFunded(address indexed from, uint256 amount);
    event Finalized(address indexed finalizer, uint256 pot, uint256 living, uint256 paid, bool bell);
    event FundedReturned(uint256 amount);
    event Paid(address indexed to, uint256 amount, bool pushed);
    event Claimed(address indexed to, uint256 amount);
    event Graduated(uint256 imd, uint256 tokens);
    event Failed(uint256 tokensBurned);
    event BailedOut(address indexed player, uint256 coins, uint256 curveValue, uint256 cost, uint256 payout);

    modifier guard() {
        if (!(!locked)) revert PadErrors.PadReentrancy();
        locked = true;
        _;
        locked = false;
    }

    constructor() {
        initialized = true;
    }

    function ROLL_PRICE() public view returns (uint256) {
        return unit;
    }

    function ENTRY_PRICE() public view returns (uint256) {
        return unit / 2;
    }

    function ROLL_TIP() public view returns (uint256) {
        return unit / 100;
    }

    function VIMD() public view returns (uint256) {
        return 400 * unit;
    }

    function K() public view returns (uint256) {
        return 400 * unit * VTOK;
    }

    function FINALIZER_MAX() public view returns (uint256) {
        return 2 * unit;
    }

    // ---- lifecycle ------------------------------------------------------------------------
    function initialize(uint256 launchId_, address token_, address liquidity_, bool genesis_) external {
        if (!(!initialized)) revert PadErrors.PadInitialized();
        initialized = true;
        pad = msg.sender;
        token = token_;
        liquidity = liquidity_;
        launchId = launchId_;
        genesis = genesis_;
        unit = IPvPPad(pad).unit();
        imd = IPvPPad(pad).imd();
        PadLib.approve(imd, pad);
        PadLib.approve(imd, liquidity);
        emit Initialized(launchId_, token_, genesis_, unit);
    }

    /// @notice One nonrefundable entry per wallet, no entry cap. First entry starts signup.
    function enter() external guard {
        _requireOpen();
        IPvPPad(pad).pull(msg.sender, ENTRY_PRICE());
        if (!(entryOf[msg.sender] == 0)) revert PadErrors.PadOneEntryPerWallet();
        bool first = entrants.length == 0;
        if (first) firstEntryAt = uint64(block.timestamp);
        else if (!(block.timestamp < signupEnd())) revert PadErrors.PadSignupOver();
        entrants.push(msg.sender);
        entryOf[msg.sender] = entrants.length;
        emit Entered(msg.sender, entrants.length, first);
        if (first) drawBounty = ENTRY_PRICE();
        else _fundBurn(ENTRY_PRICE());
        if (first) IPvPPad(pad).noteFirstEntry(launchId);
        _upkeep();
    }

    /// @notice Commit or advance the raffle. At most DRAW_BATCH random trials per call.
    /// n cannot select a seed or change the result; it only bounds work.
    function draw(uint256 n) external guard {
        _requireOpen();
        if (!(entrants.length != 0 && block.timestamp >= signupEnd())) revert PadErrors.PadSignupNotOver();
        if (!(n != 0)) revert PadErrors.PadZeroChunk();
        _draw(n, msg.sender);
    }

    function _draw(uint256 n, address caller) internal {
        if (drawComplete || entrants.length == 0 || block.timestamp < signupEnd()) return;
        uint256 cur = ARB.arbBlockNumber();
        if (!drawSeeded) {
            if (!drawCommitted) {
                drawCommitBlock = cur;
                drawCommitted = true;
                emit DrawCommitted(cur);
                return;
            }
            if (cur <= drawCommitBlock + 3) return;
            if (cur > drawCommitBlock + 1 + HASH_WINDOW) {
                drawSeed = keccak256(abi.encode(address(this), drawCommitBlock, entrants.length));
            } else {
                drawSeed = keccak256(
                    abi.encode(
                        address(this),
                        ARB.arbBlockHash(drawCommitBlock + 1),
                        ARB.arbBlockHash(drawCommitBlock + 2),
                        ARB.arbBlockHash(drawCommitBlock + 3)
                    )
                );
            }
            drawSeeded = true;
            emit DrawSeedReady(drawCommitBlock, drawSeed);
            uint256 bounty = drawBounty;
            drawBounty = 0;
            _pay(caller, bounty);
            emit DrawBounty(caller, bounty);
        }
        if (n > DRAW_BATCH) n = DRAW_BATCH;
        uint256 total = entrants.length;
        uint256 target = total < MAX_IMPS ? total : MAX_IMPS;
        for (uint256 trial; trial < n && imps.length < target; ++trial) {
            uint256 remaining = total - imps.length;
            uint256 rand = uint256(keccak256(abi.encode(drawSeed, drawNonce++)));
            // Rejection sampling eliminates modulo bias. Even rejection is bounded by n.
            uint256 threshold;
            unchecked {
                threshold = (0 - remaining) % remaining;
            }
            if (rand < threshold) continue;
            uint256 pick = rand % remaining;
            uint256 entry = shuffled[pick];
            entry = entry == 0 ? pick : entry - 1;
            uint256 last = shuffled[remaining - 1];
            shuffled[pick] = last == 0 ? remaining : last;
            address who = entrants[entry];
            imps.push(Imp(who, 0, 0, 0, 0, 0, 0));
            impOf[who] = imps.length;
            emit Seated(who, imps.length, entry + 1);
        }
        emit DrawProgress(imps.length, target, drawNonce);
        if (imps.length == target) {
            drawComplete = true;
            playStartedAt = uint64(block.timestamp);
            maxActivity = uint64(block.timestamp);
            emit PlayStarted(block.timestamp, block.timestamp + MAX_PLAY);
        }
    }

    /// @notice Roll the dice: one unit of IMD, 60 s cooldown, 90% curve, 7% pot, 2% burn , 1% resolver tip.
    function roll() external guard {
        _requireOpen();
        IPvPPad(pad).pull(msg.sender, ROLL_PRICE());
        if (!(drawComplete)) revert PadErrors.PadNotPlaying();
        uint256 idx = impOf[msg.sender];
        if (!(idx != 0)) revert PadErrors.PadNoImp();
        _notOver();
        Imp storage imp = imps[idx - 1];
        if (!(!erased[msg.sender])) revert PadErrors.PadErased();
        if (!(_lastActivity(imp) + DEATH > block.timestamp)) revert PadErrors.PadImpDead();
        if (!(imp.lastRoll == 0 || imp.lastRoll + COOLDOWN <= block.timestamp)) revert PadErrors.PadCooldown();
        if (imp.pendingRoll != 0) _resolveRoll(imp.pendingRoll - 1, msg.sender);
        _notOver(); // the previous roll may have rung the bell just now

        uint256 curveIMD = ROLL_PRICE() * 90 / 100;
        uint256 burnIMD = ROLL_PRICE() * 2 / 100;
        uint256 potIMD = ROLL_PRICE() - curveIMD - burnIMD - ROLL_TIP();
        (uint256 tokensOut, uint256 imdUsed) = _buy(curveIMD);
        curveSpent[msg.sender] += imdUsed;
        potIMD += curveIMD - imdUsed;
        pot += potIMD;
        emit CurveBuy(ROLL_PRICE(), imdUsed, tokensOut, potIMD);

        uint256 rollId = rolls.length;
        rolls.push(Roll(uint32(idx - 1), imp.nonce, uint64(ARB.arbBlockNumber()), false, false, 0));
        imp.nonce += 1;
        imp.pendingRoll = uint32(rollId + 1);
        imp.lastRoll = uint40(block.timestamp);
        if (block.timestamp > maxActivity) maxActivity = uint64(block.timestamp);
        pendingCount += 1;
        emit Rolled(msg.sender, idx - 1, rollId, rolls[rollId].commitBlock, tokensOut);

        if (tokensOut != 0) if (!(IPadToken(token).transfer(msg.sender, tokensOut))) revert PadErrors.PadToken();
        if (burnIMD != 0) _fundBurn(burnIMD);
        _resolve(RESOLVE_BATCH, msg.sender);
        _upkeep();
    }

    /// @notice Sell every coin back to the curve and permanently erase this seat, during play only.
    /// C records only IMD actually spent by this wallet's rolls, including after a previous sell-out.
    function bailOut(uint256 minOut) external guard {
        if (!(drawComplete && !ended() && !finalized)) revert PadErrors.PadNotPlaying();
        if (!(impOf[msg.sender] != 0 && !erased[msg.sender])) revert PadErrors.PadNoImp();
        uint256 coins = _balance(msg.sender);
        uint256 value = quoteSell(coins);
        uint256 cost = curveSpent[msg.sender];
        uint256 payout;
        unchecked {
            payout = value >= cost ? cost + (value - cost) / 2 : value * 90 / 100;
        }
        if (!(payout >= minOut)) revert PadErrors.PadMinOut();
        if (_lastActivity(imps[impOf[msg.sender] - 1]) + DEATH > block.timestamp) ++bailedAliveCount;
        erased[msg.sender] = true;
        ++erasedCount;
        imdRaised -= value;
        tokensSold -= coins;
        pot += value - payout;
        bailPot += value - payout;
        // The erased Imp's activity must not extend the all-dead timer.
        uint64 latest;
        for (uint256 i; i < imps.length; ++i) {
            if (!erased[imps[i].owner]) {
                uint64 activity = uint64(_lastActivity(imps[i]));
                if (activity > latest) latest = activity;
            }
        }
        // Play follows a ten-minute signup, so timestamp >= DEATH. With no remaining
        // seat, maxActivity + DEATH fixes the all-dead clock at this bailout's timestamp.
        maxActivity = erasedCount == imps.length ? uint64(block.timestamp - DEATH) : latest;
        if (coins != 0) IPadToken(token).reclaim(msg.sender, coins);
        _pay(msg.sender, payout);
        emit BailedOut(msg.sender, coins, value, cost, payout);
    }

    /// @notice Permissionless upkeep for this game plus the pad's bounded upkeep.
    function poke() external guard {
        _draw(DRAW_BATCH, msg.sender);
        _resolve(RESOLVE_BATCH, msg.sender);
        if (entrants.length != 0) {
            if (!finalized) _finalize(msg.sender);
            else if (!graduated) _graduate();
        }
        _upkeep();
    }

    /// @notice Ranks living Imps and pays the pot. Permissionless once the game has ended.
    function finalize() external guard {
        _resolve(RESOLVE_BATCH, msg.sender);
        if (!(_finalize(msg.sender))) revert PadErrors.PadNotFinalizable();
        _upkeep();
    }

    /// @notice Moves curve IMD and remaining tokens into the v4 pool (or burns all when no IMD was raised).
    function graduate() external guard {
        if (!(_graduate())) revert PadErrors.PadNotGraduable();
        _upkeep();
    }

    /// @notice Pad-driven bounded upkeep: one draw chunk, roll resolution and one lifecycle step.
    function upkeepStep(address caller) external {
        _onlyPad();
        if (locked || entrants.length == 0) return;
        locked = true;
        _draw(DRAW_BATCH, caller);
        _resolve(RESOLVE_BATCH, caller);
        if (!finalized) {
            _finalize(caller);
        } else if (!graduated) {
            _graduate();
        }
        locked = false;
    }

    function resolvePending(uint256 max) external guard {
        _resolve(max, msg.sender);
    }

    /// @notice Pad-only top-up (bounded carry at finalization, king's games share). Tracked apart from roll
    /// income: it is paid out only with >= 5 qualifying seats, capped at 3x the roll-earned pot,
    /// and otherwise returns to the carry pot at the end.
    function fundPot(uint256 amount) external {
        _onlyPad();
        if (!(!finalized)) revert PadErrors.PadFinalized();
        PadLib.pullExact(imd, msg.sender, address(this), amount);
        pot += amount;
        fundedPot += amount;
        emit PotFunded(msg.sender, amount);
    }

    function claim() external guard {
        uint256 amount = claimable[msg.sender];
        if (!(amount != 0)) revert PadErrors.PadNothing();
        claimable[msg.sender] = 0;
        PadLib.transfer(imd, msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // ---- views ------------------------------------------------------------------------------
    function playStart() public view returns (uint256) {
        return playStartedAt;
    }

    function hardEnd() public view returns (uint256) {
        return drawComplete ? playStartedAt + MAX_PLAY : 0;
    }

    /// @notice Bell, 50 minutes after draw completion, or 10 minutes after last activity.
    function endTime() public view returns (uint256 e) {
        if (!drawComplete) return 0;
        e = hardEnd();
        uint256 allDead = uint256(maxActivity) + DEATH;
        if (allDead < e) e = allDead;
        if (bellAt != 0 && bellAt < e) e = bellAt;
    }

    function ended() public view returns (bool) {
        return drawComplete && block.timestamp >= endTime();
    }

    function bellRang() public view returns (bool) {
        return bellAt != 0 && bellAt == endTime();
    }

    /// @notice 0 waiting, 1 signup, 2 play, 3 ended, 4 finalized, 5 graduated, 6 failed, 7 drawing.
    function status() external view returns (uint8) {
        if (failed) return 6;
        if (graduated) return 5;
        if (finalized) return 4;
        if (entrants.length == 0) return 0;
        if (block.timestamp < signupEnd()) return 1;
        if (!drawComplete) return 7;
        if (!ended()) return 2;
        return 3;
    }

    /// @notice Live for the king: signup started, not ended, >= 5 entries before the draw completes
    /// or >= 5 Imps afterwards. Weight is the roll-earned pot; funded IMD cannot steer the split.
    function isLiveForKing() external view returns (bool live, uint256 potSize) {
        live = entrants.length != 0 && !ended() && (drawComplete ? imps.length - erasedCount : entrants.length) >= 5;
        potSize = pot - fundedPot - bailPot;
    }

    /// @notice IMD earned from rolls: 7%, genesis burn share, sold-out overflow and expired tips.
    function rollPot() external view returns (uint256) {
        return pot - fundedPot - bailPot;
    }

    /// @notice Most funded IMD this game can pay out at its end (with >= 5 qualifying seats): the smaller of
    /// 3x the roll-earned pot and 15% of the curve IMD raised. Before finalization, as of now.
    function fundedReleaseCap() external view returns (uint256) {
        return _releaseCap(pot - fundedPot - bailPot);
    }

    function _releaseCap(uint256 earned) internal view returns (uint256 cap) {
        cap = earned * FUNDED_RELEASE_MULTIPLE;
        uint256 curveCap = imdRaised * FUNDED_RELEASE_CURVE_BPS / 10_000;
        if (curveCap < cap) cap = curveCap;
    }

    function signupEnd() public view returns (uint256) {
        return entrants.length == 0 ? 0 : firstEntryAt + SIGNUP;
    }

    function entryCount() external view returns (uint256) {
        return entrants.length;
    }

    /// @notice Stable entry order, paginated to at most 200 records. Seat order is randomized.
    function getEntrants(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 total = entrants.length;
        if (offset >= total) return new address[](0);
        if (limit > MAX_IMPS) limit = MAX_IMPS;
        if (limit > total - offset) limit = total - offset;
        page = new address[](limit);
        for (uint256 i; i < limit; ++i) {
            page[i] = entrants[offset + i];
        }
    }

    /// @notice Both indexes are 1-based; a zero seat can mean pending or unselected (see complete).
    function myEntry() external view returns (uint256 entry, uint256 seat, bool complete) {
        return (entryOf[msg.sender], impOf[msg.sender], drawComplete);
    }

    function drawProgress()
        external
        view
        returns (uint256 entries, uint256 seated, uint256 target, uint256 commit, bool seeded, bool complete)
    {
        entries = entrants.length;
        return
            (entries, imps.length, entries < MAX_IMPS ? entries : MAX_IMPS, drawCommitBlock, drawSeeded, drawComplete);
    }

    function impCount() external view returns (uint256) {
        return imps.length;
    }

    function getImp(uint256 i) external view returns (Imp memory) {
        return imps[i];
    }

    function isAlive(uint256 i) public view returns (bool) {
        if (!drawComplete || i >= imps.length || erased[imps[i].owner]) return false;
        uint256 at = ended() ? endTime() : block.timestamp;
        return _lastActivity(imps[i]) + DEATH > at;
    }

    function rollCount() external view returns (uint256) {
        return rolls.length;
    }

    function getRoll(uint256 i) external view returns (Roll memory) {
        return rolls[i];
    }

    function curveState() external view returns (uint256 vIMD, uint256 vTok, uint256 remaining) {
        vIMD = VIMD() + imdRaised;
        vTok = VTOK - tokensSold;
        remaining = CURVE_SUPPLY - tokensSold;
    }

    function quote(uint256 imdIn) public view returns (uint256 tokensOut, uint256 imdUsed) {
        uint256 remaining = CURVE_SUPPLY - tokensSold;
        if (remaining == 0 || imdIn == 0) return (0, 0);
        uint256 vIMD = VIMD() + imdRaised;
        uint256 vTok = VTOK - tokensSold;
        uint256 newTok = (K() + vIMD + imdIn - 1) / (vIMD + imdIn);
        tokensOut = vTok > newTok ? vTok - newTok : 0;
        imdUsed = imdIn;
        if (tokensOut >= remaining) {
            tokensOut = remaining;
            imdUsed = K() / (VTOK - CURVE_SUPPLY) - vIMD;
            if (imdUsed > imdIn) imdUsed = imdIn;
        }
    }

    /// @notice Constant-product sell against the same virtual invariant as buys, rounded against seller.
    function quoteSell(uint256 coins) public view returns (uint256) {
        if (!(coins <= tokensSold)) revert PadErrors.PadCoins();
        unchecked {
            if (coins == 0) return 0;
            uint256 newTok = VTOK - tokensSold + coins;
            uint256 newIMD = (K() + newTok - 1) / newTok;
            return VIMD() + imdRaised > newIMD ? VIMD() + imdRaised - newIMD : 0;
        }
    }

    // ---- internals --------------------------------------------------------------------------
    function _lastActivity(Imp storage imp) internal view returns (uint256) {
        return imp.lastRoll == 0 ? playStart() : imp.lastRoll;
    }

    function _buy(uint256 imdIn) internal returns (uint256 tokensOut, uint256 imdUsed) {
        // quote() bounds cumulative reserves to 1,600 units and CURVE_SUPPLY.
        unchecked {
            (tokensOut, imdUsed) = quote(imdIn);
            imdRaised += imdUsed;
            tokensSold += tokensOut;
        }
    }

    function _resolve(uint256 max, address resolver) internal {
        if (max > RESOLVE_BATCH) max = RESOLVE_BATCH;
        uint256 n = rolls.length;
        uint256 done;
        while (done < max && nextPending < n && gasleft() >= RESOLVE_GAS_FLOOR) {
            ++done;
            if (rolls[nextPending].resolved) {
                nextPending += 1;
                continue;
            }
            if (!_resolveRoll(nextPending, resolver)) break;
            nextPending += 1;
        }
    }

    function _resolveRoll(uint256 id, address resolver) internal returns (bool) {
        Roll storage r = rolls[id];
        if (r.resolved) return true;
        uint256 cur = ARB.arbBlockNumber();
        uint256 commit = r.commitBlock;
        Imp storage imp = imps[r.imp];
        int256 h = imp.height;
        int256 d;
        bool expired;
        if (commit + 1 + HASH_WINDOW < cur) {
            expired = true;
            if (h > 0) d = h >= 4 ? int256(-4) : -h;
            else if (h < 0) d = h <= -4 ? int256(4) : -h;
        } else if (cur > commit + 3) {
            bytes32 h1 = ARB.arbBlockHash(commit + 1);
            bytes32 h2 = ARB.arbBlockHash(commit + 2);
            bytes32 h3 = ARB.arbBlockHash(commit + 3);
            uint256 rand = uint256(keccak256(abi.encode(address(this), uint256(r.imp), uint256(r.nonce), h1, h2, h3)));
            uint256 face = rand % 8;
            d = face < 4 ? -int256(face + 1) : int256(face - 3);
        } else {
            return false;
        }
        if (erased[imp.owner]) d = 0;
        r.resolved = true;
        r.expired = expired;
        r.delta = int8(d);
        pendingCount -= 1;
        if (expired) pot += ROLL_TIP();
        else claimable[resolver] += ROLL_TIP();
        emit ResolverTip(id, resolver, ROLL_TIP(), expired);
        if (imp.pendingRoll == id + 1) imp.pendingRoll = 0;
        int256 nh = h + d;
        if (nh > HEIGHT_CAP) nh = HEIGHT_CAP;
        if (nh < -HEIGHT_CAP) nh = -HEIGHT_CAP;
        if (nh != h) {
            imp.height = int16(nh);
            imp.heightReachedAt = uint40(commit);
            imp.heightRoll = uint32(id + 1);
        }
        emit Resolved(id, r.imp, d, nh, expired);
        bool alive = !erased[imp.owner] && _lastActivity(imp) + DEATH > block.timestamp;
        if (alive && !expired && (nh == HEIGHT_CAP || nh == -HEIGHT_CAP) && bellAt == 0 && !ended()) {
            bellAt = uint64(block.timestamp);
            bellRinger = imp.owner;
            emit Bell(r.imp, imp.owner, nh);
        }
        return true;
    }

    function _finalize(address finalizer) internal returns (bool) {
        if (finalized || !ended() || pendingCount != 0) return false;
        uint256 end = endTime();
        uint256 n = imps.length;
        // one packed key per living Imp, sorted in memory (heap sort: O(n log n) whatever the order)
        uint256[] memory keys = new uint256[](n);
        uint256 living;
        for (uint256 i; i < n; ++i) {
            Imp storage imp = imps[i];
            if (erased[imp.owner] || _lastActivity(imp) + DEATH <= end) continue;
            keys[living++] = _sortKey(imp, i);
        }
        if (living > 1) _heapSort(keys, living);
        // Carry stays in the pad throughout play. Existing king funding consumes this cap first.
        if (living != 0 && living + bailedAliveCount >= FUNDED_MIN_LIVING) {
            uint256 available = _releaseCap(pot - fundedPot - bailPot);
            if (available > fundedPot) IPvPPad(pad).takeCarry(launchId, available - fundedPot);
        }
        finalized = true;
        finalizedAt = uint64(block.timestamp);
        uint256 p = pot;
        uint256 funded = fundedPot;
        uint256 earned = p - funded - bailPot;
        bailPot = 0;
        pot = 0;
        fundedPot = 0;
        // finalizer fee: 0.5% of the pot, max 2 units of IMD, paid from roll-earned IMD only
        uint256 fee = p * FINALIZER_BPS / 10_000;
        if (fee > FINALIZER_MAX()) fee = FINALIZER_MAX();
        if (fee > earned) fee = earned;
        if (finalizer == address(0)) fee = 0;
        p -= fee;
        // funded IMD is released only to a game with enough qualifying seats, at most 3x what rolls earned
        // and at most 15% of the curve IMD (the part a token dump cannot pull back out of the pool)
        uint256 returned;
        if (living + bailedAliveCount < FUNDED_MIN_LIVING) {
            returned = funded;
        } else {
            uint256 cap = _releaseCap(earned);
            if (funded > cap) returned = funded - cap;
        }
        if (returned > p) returned = p;
        p -= returned;
        bool bell = bellAt != 0 && bellAt == end;
        uint256 paid;
        uint256 toCarry = returned;
        if (living == 0) {
            toCarry += p;
        } else {
            uint256 bellShare = bell ? p * 20 / 100 : 0;
            uint256 rankShare = p - bellShare;
            paid = (living + 1) / 2;
            uint256 weightSum = paid * (paid + 1) / 2;
            uint256 sent;
            for (uint256 r; r < paid; ++r) {
                uint256 amount = rankShare * (paid - r) / weightSum;
                sent += amount;
                _pay(imps[_keyIndex(keys[living - 1 - r])].owner, amount);
            }
            if (bellShare != 0) _pay(bellRinger, bellShare);
            toCarry += rankShare - sent;
        }
        livingAtEnd = uint32(living);
        paidAtEnd = uint32(paid);
        if (fee != 0) _pay(finalizer, fee);
        if (returned != 0) emit FundedReturned(returned);
        if (toCarry != 0) IPvPPad(pad).fundCarry(toCarry);
        emit Finalized(finalizer, p, living, paid, bell);
        return true;
    }

    /// @dev Higher key ranks first: |height| desc, then earlier heightReachedAt (commit block), then
    /// earlier roll, then lower Imp index. The index sits in the low 8 bits (MAX_IMPS <= 256).
    function _sortKey(Imp storage imp, uint256 index) internal view returns (uint256) {
        // Stored timestamps/roll indexes fit their declared types; index < MAX_IMPS <= 200.
        unchecked {
            return (PadLib.abs(imp.height) << 80) | (uint256(type(uint40).max - imp.heightReachedAt) << 40)
                | (uint256(type(uint32).max - imp.heightRoll) << 8) | (255 - index);
        }
    }

    function _keyIndex(uint256 key) internal pure returns (uint256) {
        // The masked value is at most 255.
        unchecked {
            return 255 - (key & 0xFF);
        }
    }

    /// @dev In-place ascending heap sort of a[0..n).
    function _heapSort(uint256[] memory a, uint256 n) internal pure {
        // Only called with 2 <= n <= MAX_IMPS (200).
        unchecked {
            for (uint256 i = n / 2; i > 0; --i) {
                _siftDown(a, i - 1, n);
            }
            for (uint256 last = n - 1; last > 0; --last) {
                (a[0], a[last]) = (a[last], a[0]);
                _siftDown(a, 0, last);
            }
        }
    }

    function _siftDown(uint256[] memory a, uint256 root, uint256 n) internal pure {
        // root < n <= MAX_IMPS, so 2 * root + 1 is at most 399.
        unchecked {
            while (true) {
                uint256 child = 2 * root + 1;
                if (child >= n) return;
                if (child + 1 < n && a[child + 1] > a[child]) ++child;
                if (a[root] >= a[child]) return;
                (a[root], a[child]) = (a[child], a[root]);
                root = child;
            }
        }
    }

    function _fundBurn(uint256 amount) internal {
        IPadLiquidity(liquidity).fundBurn(amount);
    }

    function _balance(address who) internal view returns (uint256) {
        return IPadToken(token).balanceOf(who);
    }

    function _onlyPad() internal view {
        if (!(msg.sender == pad)) revert PadErrors.PadNotPad();
    }

    function _notOver() internal view {
        if (!(!ended())) revert PadErrors.PadGameOver();
    }

    function _upkeep() internal {
        IPvPPad(pad).upkeepFor(msg.sender);
    }

    function _requireOpen() internal view {
        if (!(IPvPPad(pad).opened())) revert PadErrors.PadPadNotOpen();
    }

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        bool ok = PadLib.push(imd, to, amount);
        if (!ok) claimable[to] += amount;
        emit Paid(to, amount, ok);
    }

    function _graduate() internal returns (bool) {
        if (!finalized || graduated) return false;
        graduated = true;
        uint256 bal = _balance(address(this));
        if (imdRaised == 0) {
            failed = true;
            if (bal != 0) if (!(IPadToken(token).transfer(DEAD, bal))) revert PadErrors.PadBurn();
            emit Failed(bal);
            return true;
        }
        if (!(IPadToken(token).transfer(liquidity, bal))) revert PadErrors.PadToken();
        IPadLiquidity(liquidity).graduate(launchId, token, bal, imdRaised, VIMD() + imdRaised, VTOK - tokensSold);
        emit Graduated(imdRaised, bal);
        return true;
    }
}
