// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Calls} from "./libraries/Calls.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {PoolOracle} from "./libraries/PoolOracle.sol";

/// @notice Basket's ERC-20 share and custody vault for Stock Tokens.
contract BaskVault {
    string public constant name = "Basket";
    string public constant symbol = "BASK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    enum Setting {
        Band,
        MaxAge,
        NoPoolAge,
        FreshCount,
        FreshHours,
        HoursFrom,
        HoursTo,
        PoolWindow,
        PoolDeviation,
        FeedGas,
        PauseGas,
        PoolGas,
        BalanceGas,
        PayGas,
        MaxAssets,
        DirectLimit
    }
    enum Action {
        List,
        Feed,
        Recentre,
        Reopen,
        Retire,
        Pool,
        Resync,
        Guardian,
        RaiseCap,
        FeeRecipient,
        SettingChange
    }
    enum ProposalState {
        Missing,
        Waiting,
        Ready,
        Expired,
        Cancelled,
        Executed,
        Voided
    }
    enum Reason {
        OK,
        Genesis,
        Paused,
        Hours,
        Unlisted,
        Closed,
        Duplicate,
        Unreadable,
        Deficit,
        Feed,
        Band,
        OraclePaused,
        QuoteFeed,
        PoolDeviation,
        NoPoolAge,
        Freshness,
        RetiredBacking
    }

    struct Asset {
        address feed;
        uint8 tokenDecimals;
        uint8 feedDecimals;
        bool open;
        bool retired;
        bool hasPause;
        bool baseIsToken0;
        uint8 quoteDecimals;
        uint8 quoteFeedDecimals;
        address pool;
        address quoteFeed;
        uint128 minLiquidity;
        uint256 centre;
    }

    struct ProposalData {
        Action action;
        address token;
        address target;
        address pool;
        address quoteFeed;
        uint256 value;
        Setting setting;
    }

    struct Proposal {
        ProposalData data;
        uint256 readyAt;
        uint256 epoch;
        uint256 closeEpoch;
        ProposalState state;
    }

    struct Deficit {
        uint256 amount;
        uint256 since;
    }

    struct AssetView {
        address token;
        Asset config;
        uint256 answer;
        uint256 updatedAt;
        uint256 band;
        uint256 poolPrice;
        uint256 managed;
        bool short;
        bool unreadable;
        uint256 totalOwed;
        Reason priceStatus;
    }

    address public owner;
    address public pendingOwner;
    address public guardian;
    address public feeRecipient;
    bool public genesisFinalized;
    bool public depositsPaused;
    uint256 public NAV_CAP = 1_000_000e18;
    uint256[16] private _settings;
    address[] public assets;
    mapping(address => uint256) private _index;
    mapping(address => Asset) private _assets;
    mapping(address => address) public feedAsset;
    mapping(address => uint256) public managed;
    // One bit per registry index. Zero-managed assets need no storage reads in redeem.
    mapping(uint256 => uint256) private _managedBits;
    mapping(address => mapping(address => uint256)) public owed;
    mapping(address => uint256) public totalOwed;
    mapping(address => Deficit) public deficits;
    mapping(address => uint256) private _assetEpoch;
    mapping(address => uint256) private _closeEpoch;
    uint256 private _capEpoch;
    uint256 public proposalCount;
    mapping(uint256 => Proposal) private _proposals;
    uint256 private _entered = 1;
    bytes32 private immutable _transferTopic = keccak256("Transfer(address,address,uint256)");

    error Unauthorized();
    error Reentrant();
    error InvalidAddress();
    error InvalidInput();
    error InvalidSetting();
    error InvalidAsset(address token);
    error InvalidFeed(address feed);
    error InvalidPool();
    error InvalidProposal();
    error NotReady();
    error DepositUnavailable(Reason reason, address token);
    error Expired();
    error Slippage();
    error CapExceeded();
    error ZeroNAV();
    error InsufficientShares();
    error PaymentFailed();
    error BalanceUnreadable(address token);
    error NoDeficit();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed account, address indexed spender, uint256 value);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event GenesisFinalized();
    event AssetListed(address indexed token, address indexed feed, address pool);
    event AssetRemoved(address indexed token);
    event AssetClosed(address indexed token);
    event DepositsPaused(bool paused);
    event CapLowered(uint256 cap);
    event Proposed(uint256 indexed id, ProposalData data, uint256 readyAt);
    event ProposalCancelled(uint256 indexed id);
    event ProposalExecuted(uint256 indexed id);
    event Deposit(address indexed caller, address indexed receiver, uint256 value, uint256 shares, uint256 fee);
    event Redeem(address indexed caller, address indexed receiver, uint256 shares, uint256 burned, uint256 fee);
    event Payment(address indexed token, address indexed receiver, uint256 amount);
    event Claimed(address indexed account, address indexed to, address indexed token, uint256 amount);
    event DeficitFlagged(address indexed token, uint256 amount, uint256 since);
    event LossRecognized(address indexed token, uint256 amount);
    event DeficitCleared(address indexed token);
    event Resynced(address indexed token, uint256 amount);

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrant();
        _entered = 2;
        _;
        _entered = 1;
    }
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    modifier onlyRole() {
        if (msg.sender != owner && msg.sender != guardian) revert Unauthorized();
        _;
    }

    constructor(address owner_, address guardian_) {
        if (owner_ == address(0) || guardian_ == address(0) || owner_ == guardian_) revert InvalidAddress();
        owner = owner_;
        guardian = guardian_;
        _settings = [
            uint256(4), 80 hours, 26 hours, 0, 4, 0, 0, 1800, 300, 100_000, 100_000, 150_000, 50_000, 250_000, 250, 25
        ];
        emit OwnershipTransferred(address(0), owner_);
    }

    function approve(address spender, uint256 amount) external nonReentrant returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external nonReentrant returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external nonReentrant returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientShares();
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowed - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert InvalidAddress();
        if (balanceOf[from] < amount) revert InsufficientShares();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        _emitTransfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) private {
        totalSupply += amount;
        balanceOf[to] += amount;
        _emitTransfer(address(0), to, amount);
    }

    function _emitTransfer(address from, address to, uint256 amount) private {
        // Immutable references are PUSH immediates. This avoids placing a raw
        // topic hash in the data section visited by the deployment opcode scan.
        bytes32 topic = _transferTopic;
        assembly ("memory-safe") {
            mstore(0, amount)
            log3(
                0,
                32,
                topic,
                and(from, 0xffffffffffffffffffffffffffffffffffffffff),
                and(to, 0xffffffffffffffffffffffffffffffffffffffff)
            )
        }
    }

    function _fee(uint256 amount) private view returns (uint256) {
        return feeRecipient == address(0) ? 0 : amount / 200 + (amount % 200 == 0 ? 0 : 1);
    }

    function transferOwnership(address next) external onlyOwner nonReentrant {
        if (next == address(0) || next == guardian) revert InvalidAddress();
        pendingOwner = next;
        emit OwnershipTransferStarted(owner, next);
    }

    function acceptOwnership() external nonReentrant {
        if (msg.sender != pendingOwner) revert Unauthorized();
        if (msg.sender == guardian) revert InvalidAddress();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, owner);
    }

    function setDepositsPaused(bool paused) external onlyRole nonReentrant {
        if (!paused && msg.sender != owner) revert Unauthorized();
        depositsPaused = paused;
        emit DepositsPaused(paused);
    }

    function closeAsset(address token) external onlyRole nonReentrant {
        _requireAsset(token);
        _assets[token].open = false;
        ++_closeEpoch[token];
        emit AssetClosed(token);
    }

    function lowerNAVCap(uint256 cap) external onlyOwner nonReentrant {
        if (cap >= NAV_CAP) revert InvalidInput();
        NAV_CAP = cap;
        ++_capEpoch;
        emit CapLowered(cap);
    }

    function genesisList(address token, address feed, address pool, address quoteFeed, uint128 minLiquidity)
        external
        onlyOwner
        nonReentrant
    {
        if (genesisFinalized) revert InvalidInput();
        _list(token, feed, pool, quoteFeed, minLiquidity);
    }

    function finalizeGenesis() external onlyOwner nonReentrant {
        if (genesisFinalized || assets.length < 3) revert InvalidInput();
        genesisFinalized = true;
        emit GenesisFinalized();
    }

    function removeAsset(address token) external nonReentrant {
        _requireAsset(token);
        if (!_assets[token].retired || managed[token] != 0 || totalOwed[token] != 0) revert InvalidAsset(token);
        uint256 index = _index[token] - 1;
        uint256 lastIndex = assets.length - 1;
        address last = assets[lastIndex];
        if (index != lastIndex && managed[last] != 0) {
            _markManaged(lastIndex, false);
            _markManaged(index, true);
        }
        assets[index] = last;
        _index[last] = index + 1;
        assets.pop();
        delete _index[token];
        delete _assets[token];
        delete deficits[token];
        ++_assetEpoch[token];
        emit AssetRemoved(token);
    }

    function propose(ProposalData calldata data) external onlyOwner nonReentrant returns (uint256 id) {
        _validateProposal(data);
        id = ++proposalCount;
        Proposal storage p = _proposals[id];
        p.data = data;
        p.readyAt = block.timestamp + 2 days;
        p.epoch = data.action == Action.RaiseCap ? _capEpoch : _assetEpoch[data.token];
        p.closeEpoch = _closeEpoch[data.token];
        p.state = ProposalState.Waiting;
        emit Proposed(id, data, p.readyAt);
    }

    function cancelProposal(uint256 id) external onlyRole nonReentrant {
        ProposalState status = proposalStatus(id);
        if (status != ProposalState.Waiting && status != ProposalState.Ready) revert InvalidProposal();
        if (msg.sender == guardian && _proposals[id].data.action == Action.Guardian) revert Unauthorized();
        _proposals[id].state = ProposalState.Cancelled;
        emit ProposalCancelled(id);
    }

    function executeProposal(uint256 id) external onlyOwner nonReentrant {
        if (proposalStatus(id) != ProposalState.Ready) revert NotReady();
        ProposalData memory d = _proposals[id].data;
        _validateProposal(d);
        _proposals[id].state = ProposalState.Executed;
        Asset storage a = _assets[d.token];
        if (d.action == Action.List) {
            _list(d.token, d.target, d.pool, d.quoteFeed, uint128(d.value));
        } else if (d.action == Action.Feed) {
            delete feedAsset[a.feed];
            a.feed = d.target;
            feedAsset[d.target] = d.token;
            a.feedDecimals = _decimals(d.target);
            (a.centre,) = _listingPrice(d.target);
        } else if (d.action == Action.Recentre) {
            (a.centre,) = _listingPrice(a.feed);
        } else if (d.action == Action.Reopen) {
            a.open = true;
        } else if (d.action == Action.Retire) {
            a.retired = true;
            delete feedAsset[a.feed];
            ++_assetEpoch[d.token];
        } else if (d.action == Action.Pool) {
            _setPool(a, d.token, d.pool, d.quoteFeed, uint128(d.value));
        } else if (d.action == Action.Resync) {
            (bool ok, uint256 available) = _available(d.token);
            if (!ok) revert BalanceUnreadable(d.token);
            uint256 extra = available > managed[d.token] ? available - managed[d.token] : 0;
            _writeManaged(d.token, managed[d.token] + extra);
            emit Resynced(d.token, extra);
        } else if (d.action == Action.Guardian) {
            guardian = d.target;
        } else if (d.action == Action.RaiseCap) {
            NAV_CAP = d.value;
        } else if (d.action == Action.FeeRecipient) {
            feeRecipient = d.target;
        } else {
            _settings[uint256(d.setting)] = d.value;
        }
        emit ProposalExecuted(id);
    }

    function _validateProposal(ProposalData memory d) private view {
        if (d.action == Action.List) {
            if (d.value > type(uint128).max) revert InvalidPool();
            _validateListing(d.token, d.target);
            _poolConfig(d.token, d.pool, d.quoteFeed, d.value);
        } else if (d.action <= Action.Resync) {
            _requireAsset(d.token);
            Asset storage a = _assets[d.token];
            if (a.retired) revert InvalidAsset(d.token);
            if (d.action == Action.Feed) {
                if (feedAsset[d.target] != address(0) && feedAsset[d.target] != d.token) revert InvalidFeed(d.target);
                _decimals(d.target);
                _listingPrice(d.target);
            } else if (d.action == Action.Recentre) {
                _listingPrice(a.feed);
            } else if (d.action == Action.Retire || d.action == Action.Reopen) {
                if (a.open) revert InvalidAsset(d.token);
            } else if (d.action == Action.Pool) {
                _poolConfig(d.token, d.pool, d.quoteFeed, d.value);
            }
        } else if (d.action == Action.Guardian) {
            if (d.target == address(0) || d.target == owner || d.target == pendingOwner) revert InvalidAddress();
        } else if (d.action == Action.RaiseCap) {
            if (d.value <= NAV_CAP || d.value > 10_000_000_000e18) revert InvalidInput();
        } else if (d.action == Action.FeeRecipient) {
            if (d.target == address(0) || d.target == address(this)) revert InvalidAddress();
        } else {
            _validateSetting(d.setting, d.value);
        }
    }

    function _validateSetting(Setting key, uint256 value) private view {
        uint256[16] memory s = _settings;
        s[uint256(key)] = value;
        if (
            s[0] < 2 || s[0] > 100 || s[1] < 1 hours || s[1] > 30 days || s[2] < 1 hours || s[2] > 30 days || s[3] > 10
                || s[4] < 1 || s[4] > 48 || s[5] >= 1 days || s[6] > 1 days
                || ((s[5] != 0 || s[6] != 0) && s[5] >= s[6]) || s[7] < 300 || s[7] > 86400 || s[8] < 50 || s[8] > 2000
        ) revert InvalidSetting();
        for (uint256 i = 9; i <= 13; ++i) {
            if (s[i] < 20_000 || s[i] > 500_000) revert InvalidSetting();
        }
        // Division avoids overflow for arbitrary proposed integers.
        if (
            s[14] < assets.length || s[14] > 28_000_000 / (s[12] + 60_000)
                || s[15] > 28_000_000 / (s[12] + s[13] + 60_000)
        ) revert InvalidSetting();
    }

    function _requireAsset(address token) private view {
        if (_index[token] == 0) revert InvalidAsset(token);
    }

    function _decimals(address target) private view returns (uint8) {
        (bool ok, uint256 d) = Calls.word(target, _settings[9], abi.encodeWithSignature("decimals()"));
        if (!ok || d > 18) revert InvalidFeed(target);
        return uint8(d);
    }

    function _feed(address feed) private view returns (bool ok, uint256 answer, uint256 updatedAt) {
        bytes memory out;
        (ok, out) = Calls.read(feed, _settings[9], abi.encodeWithSignature("latestRoundData()"), 160);
        int256 signedAnswer;
        assembly ("memory-safe") {
            signedAnswer := mload(add(out, 64))
            updatedAt := mload(add(out, 128))
        }
        if (!ok || signedAnswer <= 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > _settings[1]) {
            return (false, signedAnswer > 0 ? uint256(signedAnswer) : 0, updatedAt);
        }
        return (true, uint256(signedAnswer), updatedAt);
    }

    function _listingPrice(address feed) private view returns (uint256 answer, uint256 updatedAt) {
        bool ok;
        (ok, answer, updatedAt) = _feed(feed);
        if (!ok) revert InvalidFeed(feed);
    }

    function _validateListing(address token, address feed) private view {
        if (_index[token] != 0 || assets.length >= _settings[14]) revert InvalidAsset(token);
        if (feedAsset[feed] != address(0)) revert InvalidFeed(feed);
        _decimals(token);
        _decimals(feed);
        _listingPrice(feed);
    }

    function _list(address token, address feed, address pool, address quoteFeed, uint128 minLiquidity) private {
        _validateListing(token, feed);
        Asset storage a = _assets[token];
        a.feed = feed;
        a.tokenDecimals = _decimals(token);
        a.feedDecimals = _decimals(feed);
        a.open = true;
        (a.centre,) = _listingPrice(feed);
        (bool ok, uint256 paused) = Calls.word(token, _settings[10], abi.encodeWithSignature("oraclePaused()"));
        a.hasPause = ok && paused <= 1;
        _setPool(a, token, pool, quoteFeed, minLiquidity);
        assets.push(token);
        _index[token] = assets.length;
        feedAsset[feed] = token;
        ++_assetEpoch[token];
        emit AssetListed(token, feed, pool);
    }

    function _poolConfig(address token, address pool, address quoteFeed, uint256 minLiquidity)
        private
        view
        returns (bool baseIsToken0, uint8 quoteDecimals, uint8 quoteFeedDecimals)
    {
        if (pool == address(0)) {
            if (quoteFeed != address(0) || minLiquidity != 0) revert InvalidPool();
            return (false, 0, 0);
        }
        if (minLiquidity > type(uint128).max) revert InvalidPool();
        (bool ok0, uint256 t0) = Calls.word(pool, _settings[11], abi.encodeWithSignature("token0()"));
        (bool ok1, uint256 t1) = Calls.word(pool, _settings[11], abi.encodeWithSignature("token1()"));
        if (
            !ok0 || !ok1 || t0 > type(uint160).max || t1 > type(uint160).max || t0 == t1
                || (address(uint160(t0)) != token && address(uint160(t1)) != token)
        ) revert InvalidPool();
        baseIsToken0 = address(uint160(t0)) == token;
        quoteDecimals = _decimals(address(uint160(baseIsToken0 ? t1 : t0)));
        quoteFeedDecimals = _decimals(quoteFeed);
    }

    function _setPool(Asset storage a, address token, address pool, address quoteFeed, uint128 minLiquidity) private {
        (a.baseIsToken0, a.quoteDecimals, a.quoteFeedDecimals) = _poolConfig(token, pool, quoteFeed, minLiquidity);
        a.pool = pool;
        a.quoteFeed = quoteFeed;
        a.minLiquidity = minLiquidity;
    }

    function _markManaged(uint256 index, bool funded) private {
        uint256 mask = uint256(1) << (index & 255);
        if (funded) _managedBits[index >> 8] |= mask;
        else _managedBits[index >> 8] &= ~mask;
    }

    function _writeManaged(address token, uint256 amount) private {
        if ((managed[token] == 0) != (amount == 0)) _markManaged(_index[token] - 1, amount != 0);
        managed[token] = amount;
    }

    function _balance(address token) private view returns (bool ok, uint256 amount) {
        return _readBalance(token, _settings[12]);
    }

    function _unlimitedBalance(address token) private view returns (bool ok, uint256 amount) {
        return _readBalance(token, gasleft());
    }

    function _readBalance(address token, uint256 budget) private view returns (bool ok, uint256 amount) {
        assembly ("memory-safe") {
            mstore(0, shl(224, 0x70a08231))
            mstore(4, address())
            ok := staticcall(budget, token, 0, 36, 0, 32)
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            amount := mload(0)
        }
    }

    function _available(address token) private view returns (bool ok, uint256 amount) {
        (ok, amount) = _balance(token);
        uint256 debt = totalOwed[token];
        amount = amount > debt ? amount - debt : 0;
    }

    function _value(uint256 amount, uint256 answer, uint8 tokenDec, uint8 feedDec) private pure returns (uint256) {
        uint256 sum = uint256(tokenDec) + feedDec;
        if (sum >= 18) return FullMath.mulDiv(amount, answer, 10 ** (sum - 18));
        return FullMath.mulDiv(amount, answer, 1) * 10 ** (18 - sum);
    }

    function _price(address token)
        private
        view
        returns (Reason reason, uint256 answer, uint256 updatedAt, uint256 poolPrice)
    {
        Asset storage a = _assets[token];
        bool ok;
        (ok, answer, updatedAt) = _feed(a.feed);
        if (!ok) return (Reason.Feed, answer, updatedAt, 0);
        uint256 band = _settings[0];
        if (answer < a.centre / band || answer / band + (answer % band == 0 ? 0 : 1) > a.centre) {
            return (Reason.Band, answer, updatedAt, 0);
        }
        if (a.hasPause) {
            uint256 paused;
            (ok, paused) = Calls.word(token, _settings[10], abi.encodeWithSignature("oraclePaused()"));
            if (!ok || paused != 0) return (Reason.OraclePaused, answer, updatedAt, 0);
        }
        if (a.pool != address(0)) {
            int24 tick;
            uint128 liquidity;
            (ok, tick, liquidity) = PoolOracle.consult(a.pool, uint32(_settings[7]), _settings[11]);
            if (ok && liquidity >= a.minLiquidity) {
                uint256 quoteAnswer;
                (ok, quoteAnswer,) = _feed(a.quoteFeed);
                if (!ok) return (Reason.QuoteFeed, answer, updatedAt, 0);
                // Carry 18 extra decimals through the tick quote, even for low-decimal quote tokens.
                uint256 quoteAmount =
                    PoolOracle.quote(tick, uint128(10 ** uint256(a.tokenDecimals) * 1e18), a.baseIsToken0);
                poolPrice =
                    FullMath.mulDiv(quoteAmount, quoteAnswer, 10 ** (uint256(a.quoteDecimals) + a.quoteFeedDecimals));
                uint256 usd = _value(10 ** uint256(a.tokenDecimals), answer, a.tokenDecimals, a.feedDecimals);
                uint256 diff = poolPrice > usd ? poolPrice - usd : usd - poolPrice;
                if (diff > FullMath.mulDiv(usd, _settings[8], 10_000)) {
                    return (Reason.PoolDeviation, answer, updatedAt, poolPrice);
                }
                return (Reason.OK, answer, updatedAt, poolPrice);
            }
        }
        if (block.timestamp - updatedAt > _settings[2]) return (Reason.NoPoolAge, answer, updatedAt, 0);
        return (Reason.OK, answer, updatedAt, 0);
    }

    function _insideHours() private view returns (bool) {
        uint256 from = _settings[5];
        uint256 to = _settings[6];
        if (from == 0 && to == 0) return true;
        // Unix epoch was Thursday; Monday = 0.
        uint256 day = (block.timestamp / 1 days + 3) % 7;
        uint256 time = block.timestamp % 1 days;
        return day < 5 && time >= from && time < to;
    }

    function _depositContext(address[] memory tokens)
        private
        view
        returns (Reason reason, address fault, uint256 nav, uint256[] memory prices)
    {
        prices = new uint256[](tokens.length);
        if (!genesisFinalized) return (Reason.Genesis, address(0), 0, prices);
        if (depositsPaused) return (Reason.Paused, address(0), 0, prices);
        if (!_insideHours()) return (Reason.Hours, address(0), 0, prices);
        // Index-based lookup keeps the all-asset pass linear in the number of listed assets.
        uint256[] memory selected = new uint256[](assets.length);
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 index = _index[token];
            if (index == 0) return (Reason.Unlisted, token, 0, prices);
            if (!_assets[token].open || _assets[token].retired) return (Reason.Closed, token, 0, prices);
            if (selected[index - 1] != 0) return (Reason.Duplicate, token, 0, prices);
            selected[index - 1] = i + 1;
        }
        uint256 fresh;
        for (uint256 i; i < assets.length; ++i) {
            address token = assets[i];
            Asset storage a = _assets[token];
            if (a.retired) {
                // New shares must not acquire backing that was omitted from their deposit NAV.
                if (managed[token] != 0) return (Reason.RetiredBacking, token, 0, prices);
                continue;
            }
            (bool readable, uint256 bal) = _balance(token);
            if (!readable) return (Reason.Unreadable, token, 0, prices);
            uint256 debt = totalOwed[token];
            uint256 available = bal > debt ? bal - debt : 0;
            if (available < managed[token] || (selected[i] != 0 && bal < debt)) {
                return (Reason.Deficit, token, 0, prices);
            }
            uint256 answer;
            uint256 updatedAt;
            if (managed[token] != 0 || selected[i] != 0) {
                (reason, answer, updatedAt,) = _price(token);
                if (reason != Reason.OK) return (reason, token, 0, prices);
                nav += _value(managed[token], answer, a.tokenDecimals, a.feedDecimals);
                if (selected[i] != 0) prices[selected[i] - 1] = answer;
                readable = true;
            } else if (_settings[3] != 0) {
                (readable, answer, updatedAt) = _feed(a.feed);
            } else {
                readable = false;
            }
            if (readable && block.timestamp - updatedAt <= _settings[4] * 1 hours) ++fresh;
        }
        if (fresh < _settings[3]) return (Reason.Freshness, address(0), 0, prices);
        return (Reason.OK, address(0), nav, prices);
    }

    function _depositQuote(address[] memory tokens, uint256[] memory amounts)
        private
        view
        returns (uint256 shares, uint256 fee, uint256 value, uint256 nav)
    {
        if (tokens.length == 0 || tokens.length != amounts.length) revert InvalidInput();
        (Reason reason, address fault, uint256 beforeNAV, uint256[] memory prices) = _depositContext(tokens);
        if (reason != Reason.OK) revert DepositUnavailable(reason, fault);
        nav = beforeNAV;
        for (uint256 i; i < tokens.length; ++i) {
            if (amounts[i] == 0) revert InvalidInput();
            Asset storage a = _assets[tokens[i]];
            value += _value(amounts[i], prices[i], a.tokenDecimals, a.feedDecimals);
        }
        if (nav > NAV_CAP || value > NAV_CAP - nav) revert CapExceeded();
        uint256 supply = totalSupply;
        if (supply != 0 && nav == 0) revert ZeroNAV();
        uint256 gross = supply == 0 ? value : FullMath.mulDiv(value, supply, nav);
        fee = _fee(gross);
        shares = gross - fee;
        if (supply == 0) {
            if (shares <= 1e15) revert Slippage();
            shares -= 1e15;
        }
        if (shares == 0) revert Slippage();
    }

    function deposit(
        address[] calldata tokens,
        uint256[] calldata amounts,
        address receiver,
        uint256 minSharesOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 shares) {
        if (block.timestamp > deadline) revert Expired();
        if (receiver == address(0) || receiver == address(this)) revert InvalidAddress();
        uint256 fee;
        uint256 value;
        (shares, fee, value,) = _depositQuote(tokens, amounts);
        if (shares < minSharesOut) revert Slippage();
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            (bool ok, uint256 beforeBalance) = _balance(token);
            if (!ok) revert BalanceUnreadable(token);
            if (!Calls.transfer(
                    token,
                    abi.encodeWithSignature(
                        "transferFrom(address,address,uint256)", msg.sender, address(this), amounts[i]
                    )
                )) {
                revert PaymentFailed();
            }
            uint256 afterBalance;
            (ok, afterBalance) = _balance(token);
            if (!ok || afterBalance < beforeBalance || afterBalance - beforeBalance != amounts[i]) {
                revert PaymentFailed();
            }
            _writeManaged(token, managed[token] + amounts[i]);
        }
        for (uint256 i; i < assets.length; ++i) {
            address token = assets[i];
            if (!_assets[token].retired && deficits[token].amount != 0) {
                delete deficits[token];
                emit DeficitCleared(token);
            }
        }
        if (totalSupply == 0) _mint(address(0xdEaD), 1e15);
        if (fee != 0) _mint(feeRecipient, fee);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, value, shares, fee);
    }

    /// @dev Only an already-guarded vault operation can enter this payment sandbox.
    /// Reverting rolls back even a token transfer that returned false or moved the wrong amount.
    function pay(address token, address receiver, uint256 amount) external {
        if (msg.sender != address(this)) revert Unauthorized();
        (bool ok, uint256 beforeBalance) = _unlimitedBalance(token);
        if (!ok) revert PaymentFailed();
        if (!Calls.transfer(token, abi.encodeWithSignature("transfer(address,uint256)", receiver, amount))) {
            revert PaymentFailed();
        }
        uint256 afterBalance;
        (ok, afterBalance) = _unlimitedBalance(token);
        if (!ok || beforeBalance < afterBalance || beforeBalance - afterBalance != amount) revert PaymentFailed();
        emit Payment(token, receiver, amount);
    }

    function _tryPay(address token, address receiver, uint256 amount) private returns (bool ok) {
        bytes memory input = abi.encodeCall(this.pay, (token, receiver, amount));
        uint256 budget = _settings[13];
        assembly ("memory-safe") { ok := call(budget, address(), 0, add(input, 32), mload(input), 0, 0) }
    }

    function redeem(uint256 shares, address receiver, uint256[] calldata minAmountsOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (block.timestamp > deadline) revert Expired();
        if (receiver == address(0) || receiver == address(this)) revert InvalidAddress();
        if (shares == 0 || shares > balanceOf[msg.sender]) revert InsufficientShares();
        uint256 supply = totalSupply;
        uint256 fee = _fee(shares);
        uint256 net = shares - fee;
        if (fee != 0) _transfer(msg.sender, feeRecipient, fee);
        balanceOf[msg.sender] -= net;
        totalSupply -= net;
        _emitTransfer(msg.sender, address(0), net);
        uint256 count;
        uint256 length = assets.length;
        // A removed trailing index has no output; its minimum must not disappear.
        for (uint256 i = length; i < minAmountsOut.length; ++i) {
            if (minAmountsOut[i] != 0) revert Slippage();
        }
        uint256[] memory bits = new uint256[]((length + 255) / 256);
        for (uint256 i; i < bits.length; ++i) {
            uint256 word = _managedBits[i];
            bits[i] = word;
            while (word != 0) {
                unchecked {
                    word &= word - 1;
                    ++count;
                }
            }
        }
        bool direct = count <= _settings[15];
        amounts = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            if (bits[i >> 8] & (uint256(1) << (i & 255)) == 0) {
                if (i < minAmountsOut.length && minAmountsOut[i] != 0) revert Slippage();
                continue;
            }
            address token = assets[i];
            uint256 m = managed[token];
            uint256 debt = totalOwed[token];
            (bool ok, uint256 bal) = _balance(token);
            uint256 available = ok ? (bal > debt ? bal - debt : 0) : m;
            uint256 leg = FullMath.mulDiv(available < m ? available : m, net, supply);
            if (i < minAmountsOut.length && leg < minAmountsOut[i]) revert Slippage();
            amounts[i] = leg;
            if (leg == 0) continue;
            managed[token] = m - leg;
            if (m == leg) _markManaged(i, false);
            if (!direct || !_tryPay(token, receiver, leg)) {
                owed[receiver][token] += leg;
                totalOwed[token] = debt + leg;
            }
        }
        emit Redeem(msg.sender, receiver, shares, net, fee);
    }

    function claim(address[] calldata tokens, address to) external nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 amount = owed[msg.sender][token];
            if (amount == 0) continue;
            (bool ok, uint256 bal) = _unlimitedBalance(token);
            if (!ok) revert BalanceUnreadable(token);
            if (bal < amount) amount = bal;
            if (amount == 0) continue;
            owed[msg.sender][token] -= amount;
            totalOwed[token] -= amount;
            this.pay(token, to, amount);
            emit Claimed(msg.sender, to, token, amount);
        }
    }

    function flagDeficit(address token) external nonReentrant {
        _requireAsset(token);
        (bool ok, uint256 available) = _available(token);
        if (!ok) revert BalanceUnreadable(token);
        uint256 m = managed[token];
        uint256 shortfall = m > available ? m - available : 0;
        if (shortfall == 0 || shortfall <= deficits[token].amount) revert NoDeficit();
        deficits[token] = Deficit(shortfall, block.timestamp);
        emit DeficitFlagged(token, shortfall, block.timestamp);
    }

    function recognizeLoss(address token) external nonReentrant {
        _requireAsset(token);
        Deficit memory d = deficits[token];
        if (d.amount == 0 || block.timestamp < d.since + 7 days) revert NotReady();
        (bool ok, uint256 available) = _available(token);
        if (!ok) revert BalanceUnreadable(token);
        uint256 m = managed[token];
        uint256 shortfall = m > available ? m - available : 0;
        uint256 loss = d.amount < shortfall ? d.amount : shortfall;
        _writeManaged(token, managed[token] - loss);
        delete deficits[token];
        emit LossRecognized(token, loss);
    }

    function setting(Setting key) external view returns (uint256) {
        return _settings[uint256(key)];
    }

    function settings() external view returns (uint256[16] memory) {
        return _settings;
    }

    function assetCount() external view returns (uint256) {
        return assets.length;
    }

    function asset(address token) external view returns (Asset memory) {
        return _assets[token];
    }

    function assetPrice(address token) external view returns (Reason, uint256, uint256, uint256) {
        _requireAsset(token);
        return _price(token);
    }

    function allAssets() external view returns (AssetView[] memory result) {
        result = new AssetView[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            address token = assets[i];
            (bool ok, uint256 available) = _available(token);
            (Reason reason, uint256 answer, uint256 updatedAt, uint256 poolPrice) = _price(token);
            result[i] = AssetView(
                token,
                _assets[token],
                answer,
                updatedAt,
                _settings[0],
                poolPrice,
                managed[token],
                ok && available < managed[token],
                !ok,
                totalOwed[token],
                reason
            );
        }
    }

    function previewDeposit(address[] calldata tokens, uint256[] calldata amounts)
        external
        view
        returns (uint256 shares, uint256 fee, uint256 value, uint256 nav)
    {
        return _depositQuote(tokens, amounts);
    }

    function previewRedeem(uint256 shares) external view returns (uint256[] memory amounts, uint256 fee) {
        if (shares > totalSupply) revert InsufficientShares();
        fee = _fee(shares);
        uint256 net = shares - fee;
        amounts = new uint256[](assets.length);
        if (totalSupply == 0) return (amounts, fee);
        for (uint256 i; i < assets.length; ++i) {
            address token = assets[i];
            uint256 m = managed[token];
            if (m == 0) continue;
            (bool ok, uint256 available) = _available(token);
            if (!ok) available = m;
            amounts[i] = FullMath.mulDiv(available < m ? available : m, net, totalSupply);
        }
    }

    function depositStatus(address[] calldata tokens) external view returns (Reason reason, address fault) {
        (reason, fault,,) = _depositContext(tokens);
    }

    function proposal(uint256 id) external view returns (Proposal memory result) {
        result = _proposals[id];
        result.state = proposalStatus(id);
    }

    function proposalStatus(uint256 id) public view returns (ProposalState) {
        Proposal storage p = _proposals[id];
        if (p.state != ProposalState.Waiting) return p.state;
        Action action = p.data.action;
        if (action <= Action.Resync && p.epoch != _assetEpoch[p.data.token]) return ProposalState.Voided;
        if (action == Action.Reopen && p.closeEpoch != _closeEpoch[p.data.token]) return ProposalState.Voided;
        if (action == Action.RaiseCap && p.epoch != _capEpoch) return ProposalState.Voided;
        if (block.timestamp > p.readyAt + 7 days) return ProposalState.Expired;
        return block.timestamp < p.readyAt ? ProposalState.Waiting : ProposalState.Ready;
    }

    /// @notice Scan at most `count` consecutive proposal IDs, starting at `start` (IDs begin at 1).
    function pendingProposals(uint256 start, uint256 count)
        external
        view
        returns (uint256[] memory ids, Proposal[] memory result)
    {
        if (start == 0) start = 1;
        if (start > proposalCount) return (new uint256[](0), new Proposal[](0));
        uint256 remaining = proposalCount - start + 1;
        if (count > remaining) count = remaining;
        ids = new uint256[](count);
        result = new Proposal[](count);
        uint256 n;
        for (uint256 i; i < count; ++i) {
            uint256 id = start + i;
            ProposalState status = proposalStatus(id);
            if (status == ProposalState.Waiting || status == ProposalState.Ready) {
                ids[n] = id;
                result[n] = _proposals[id];
                result[n++].state = status;
            }
        }
        assembly ("memory-safe") {
            mstore(ids, n)
            mstore(result, n)
        }
    }
}
