// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IAggregator {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @dev SwapRouter V3 with deadline: Uniswap V3 (Ethereum) and PancakeSwap V3 (BNB Chain) use the same interface.
interface ISwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @title DepositBox
/// @notice Personal deposit address (EIP-1167 clone, one per user, via CREATE2). Only MacroSwap moves what
///         arrives here, and only in two ways: buying the basket for the owner or returning it to the owner.
///         Once created, it refuses native currency (no receive).
contract DepositBox {
    address public immutable macroSwap; // written in the implementation's code, holds for every clone

    constructor() {
        macroSwap = msg.sender;
    }

    /// @param token address(0) = native currency sent before the address existed
    // False positive: `ret.length == 0` accepts a token with no bool return; the return is checked when it exists.
    // Low-level call on purpose: sends native currency and accepts tokens with no bool return; the result is checked in the require.
    // slither-disable-next-line incorrect-equality,low-level-calls
    function send(address token, address to, uint256 amount) external {
        require(msg.sender == macroSwap, "not macroswap");
        require(to != address(0), "zero address");
        // only MacroSwap calls this, and always for the owner, the treasury, the keeper or itself; the return is checked below
        bool ok = false;
        bytes memory ret = "";
        if (token == address(0)) {
            // aderyn-ignore-next-line(eth-send-unchecked-address)
            (ok, ret) = to.call{value: amount}("");
        } else {
            // aderyn-ignore-next-line(unsafe-erc20-operation)
            (ok, ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        }
        require(ok && (token == address(0) || ret.length == 0 || abi.decode(ret, (bool))), "send failed");
    }
}

/// @title MacroSwap
/// @notice Orders to buy a basket in stablecoin via a V3 DEX (multi-hop).
///   The user only gives approval and registers an order; the stablecoin stays in their wallet until execution.
///   An order only executes when:
///     - BTC is at least `dipBps` below the high of the window chosen in the order
///       (30 days = "short dip", ~1 year = "macro dip"; the signal is mandatory), and
///     - after the 1st buy, BTC is below the order's own average BTC price (average-price rule:
///       strict, with tolerance of up to X% above the average, or off; chosen in the order).
///   Allocation: btcBps in BTC (or the split the user chose in `setMix`); groupA and groupB with weights
///   proportional to (BASE_WEIGHT + individual drawdown vs the 30-day high, capped at 50%).
///   Buys of up to `btcOnlyMax` go 100% to BTC, whatever the allocation.
///   The highs come only from Chainlink: `snapshot()` records the current price and `backfill()`
///   accepts old rounds, which the contract reads and checks against the feed itself.
///   Each feed keeps 30 daily buckets; the BTC feed also keeps 53 weekly buckets (~1 year).
///   Anyone can execute (keeper) and receives the `keeperTip` set by the user.
///   Optional "deposit" mode: each user has their own deposit address (`depositAddress`). Whoever sends
///   stable there, from any source, has the basket bought immediately (`sweep`, no dip signal) and delivered to
///   the address's owner, never to the sender. The owner can withdraw it back at any time.
///   The contract never holds funds between calls.
///   A second stable (`altStable`) is accepted in orders and deposit addresses: it is converted 1:1 (minus a small limit) to the
///   main stable right before buying. The wallet does not choose: the main one pays when it can. Sales always pay in the main one.
// The Tracker reads MacroSwap through its own interface (IMacroSwapRead) with its own structs: inheriting would not compile.
// aderyn-ignore-next-line(missing-inheritance)
contract MacroSwap {
    struct Asset {
        address token;
        IAggregator feed; // Chainlink TOKEN/USD feed
        uint8 tokenDecimals; // checked against token.decimals()
        uint16 slippageBps; // tolerance vs the oracle price (covers feed delay + pool fees)
        uint32 maxStaleness; // maximum age of this feed's price (heartbeat + margin), 1 h to 48 h
        bytes path; // V3 route stable -> ... -> token (abi.encodePacked(stable, fee, hub, fee, token))
    }

    /// @dev Field names differ from the state variables on purpose (no shadowing).
    struct Config {
        address stableToken;
        address swapRouter;
        address feeTreasury;
        address initialOwner;
        uint96 minBuy; // minimum per buy, in stable units
        uint96 dustLimit; // a slice smaller than this is not bought and goes to BTC
        uint16 depositTip; // keeper tip in deposit mode (bps); depends on the network's gas
        address altStableToken; // second accepted stable, same decimals; address(0) = none
        uint24 altPoolFee; // fee tier of the altStableToken/stableToken pool
    }

    struct Order {
        uint128 budget; // maximum the order can spend (includes fee and tip)
        uint128 spent;
        uint96 amountPerBuy; // gross amount per execution
        uint96 keeperTip; // paid to whoever executes
        uint32 minInterval; // minimum time between executions
        uint32 lastExec;
        uint64 expiry; // 0 = no expiry
        uint16 dipBps; // minimum BTC drop vs the window's high to execute
        bool active;
        uint8 window; // 0 = 30-day high; 1 = ~1-year high (53 weeks); 2 = all-time high (btcAth)
        uint16 refRule; // margin below the reference (bps); REF_AUTO = covers fee + tip + DEX; REF_OFF = no rule
        uint64 refPrice; // BTC at order creation (USD, 8 decimals): reference until the 1st buy
        uint32 maxWait; // 0 = no limit; after this with no buy, the next dip buys even above the reference
        uint32 createdAt;
        uint128 btcCost; // stable spent on BTC (basis for the average price)
        uint128 btcBought; // BTC received
    }

    /// @dev Allocation chosen by the user, in bps. All 0 = use the contract's default allocation.
    struct Mix {
        uint16 btcPart;
        uint16 aPart;
        uint16 bPart;
    }

    /// @dev Prices and weights read ONCE per transaction (execute, executeMany, sweep), on demand, instead of once
    ///      per order and per token: the oracle and history do not change within the same transaction. Price 0 = unavailable.
    struct Market {
        bool priced;
        bool btcOk;
        uint256 btcPrice; // 18 decimals
        bool has30;
        uint256 dd30; // BTC drop vs the 30-day high (bps)
        bool hasYear;
        uint256 ddYear; // vs the 53-week high
        bool hasA;
        uint256[] wA; // group A weights
        uint256[] pA; // group A prices
        bool hasB;
        uint256[] wB;
        uint256[] pB;
    }

    /// @dev BTC bought per wallet across all buys (orders and deposit); never resets. Basis for the average
    ///      buy price used by profit-taking.
    struct Position {
        uint128 btcCost; // stable spent on BTC
        uint128 btcBought; // BTC received
    }

    /// @dev High of one day (or week). A bucket only goes up within its own period: nobody can erase
    ///      a legitimate high.
    struct Bucket {
        uint192 high; // price in 18 decimals
        uint64 period; // timestamp / 1 days (or / 1 weeks)
    }

    uint256 public constant HISTORY = 30; // days
    uint256 public constant YEAR_WEEKS = 53; // current week + 52 previous: a window of 364 to 371 days
    uint256 public constant BASE_WEIGHT = 500; // bps; guarantees weight > 0 even with no drawdown
    uint256 public constant WEIGHT_DRAWDOWN_CAP = 5000; // drawdown above 50% does not increase the weight further
    uint256 public constant MAX_DRAWDOWN_BPS = 9900; // drawdown > 99% vs the 30d high => token excluded on its own
    uint256 public constant MAX_GROUP = 10;
    uint256 public constant MAX_SLIPPAGE_BPS = 500;
    uint256 public constant MIN_INTERVAL = 1 hours;
    uint256 public constant MAX_TIP_BPS = 500; // keeper tip <= 5% of each buy (the user chooses)
    uint256 public constant MAX_DEPOSIT_TIP_BPS = 100; // deposit tip (set by the owner) <= 1%: only pays for gas
    uint256 public constant TIMELOCK = 24 hours; // every parameter change is announced and only takes effect after this
    uint256 public constant PROPOSAL_GRACE = 7 days; // a proposal not executed within this period after TIMELOCK expires
    uint16 public constant REF_OFF = type(uint16).max; // refRule: buy on any dip, ignoring the reference
    uint16 public constant REF_AUTO = type(uint16).max - 1; // refRule: margin = fee + tip + DEX_COST_BPS
    uint256 public constant MAX_REF_MARGIN_BPS = 5000;
    uint256 public constant DEX_COST_BPS = 30; // estimate of pool + slippage for one buy, for the automatic margin
    uint256 public constant MIN_BTC_BPS = 7500; // allocation: BTC from 75% to 100% (so group A sits between 0% and 25%)
    uint256 public constant MAX_GROUP_B_BPS = 500; // group B from 0% to 5%
    uint256 public constant SWAP_GAS_RESERVE = 5e5; // stops the keeper from forcing failures by limiting gas
    uint256 public constant MIN_DIP_BPS = 100; // minimum dip for an order: 1%

    uint256 internal constant BPS = 1e4; // 100% in basis points
    uint8 internal constant WAD_DECIMALS = 18; // internal prices and values in 18 decimals
    uint256 internal constant DECIMAL_BASE = 10; // DECIMAL_BASE ** decimals
    uint256 internal constant FEED_TO_WAD = 1e10; // Chainlink feed with 8 decimals -> 18 decimals (refPrice stores 8)
    uint256 internal constant MIN_BUY_USD = 5; // minimum-per-buy range: $5 to $1000
    uint256 internal constant MAX_USD = 1000; // ceiling for the minimum per buy and for btcOnlyMax
    uint256 internal constant BTC_ONLY_DEFAULT_USD = 100; // buys of up to $100 go entirely to BTC
    uint256 internal constant DUST_MIN_DIVISOR = 100; // minimum dust = $1 / 100 = $0.01
    uint256 internal constant DUST_MAX_USD = 5; // maximum dust = $5
    uint256 internal constant ALT_MIN_OUT_BPS = 9950; // converting the second stable: at least 99.5% of 1:1, or the buy reverts
    uint8 internal constant WINDOW_ATH = 2;
    uint256 internal constant ADDR_LEN = 20; // V3 route: token(20) + [fee(3) + token(20)]*n
    uint256 internal constant HOP_LEN = 23;

    IERC20 public immutable stable;
    IERC20 public immutable altStable; // address(0) = only the main stable
    uint24 public immutable altFee;
    uint8 public immutable stableDecimals;
    uint256 internal immutable usdScale; // 10^(18 - stableDecimals)
    ISwapRouter public immutable router;
    address public immutable treasury; // receives the fee; the only one who can rescue lost tokens; never changes
    address public immutable boxImpl; // implementation of the deposit addresses

    address public owner; // Safe: only adjusts parameters, always through the timelock; the basket (tokens, routes, feeds) is fixed
    uint16 public depositTipBps; // keeper tip in deposit mode (pays for gas); max MAX_DEPOSIT_TIP_BPS
    uint16 public btcBps = 7500;
    uint16 public groupABps = 2000;
    uint16 public groupBBps = 500;
    // Fixed fees, nobody changes them (not even the owner): only 0.25% (slow) and 0.50% (instant) exist, straight to the treasury.
    uint16 public constant feeBps = 25; // order via approve (buy on the dip)
    uint16 public constant depositFeeBps = 50; // deposit mode (instant, market buy)
    uint96 public minAmountPerBuy;
    uint96 public dust;
    uint96 public btcOnlyMax; // a gross buy up to this value goes 100% to BTC (small slices would only spend gas)
    /// @notice BTC all-time high (18 decimals): only goes up, and only from rounds the contract reads on the feed itself
    ///         (`snapshot`, `backfill`). 0 until the first record.
    uint256 public btcAth;

    Asset internal btc;
    Asset[] internal groupA;
    Asset[] internal groupB;

    mapping(address feed => Bucket[HISTORY]) internal highs;
    mapping(address feed => Bucket[YEAR_WEEKS]) internal weekHighs; // BTC feed only
    mapping(address user => Order) internal orders; // read via getOrder (the automatic getter would blow the stack)
    mapping(address user => Mix) internal mixes;
    mapping(address user => Position) public positions;
    /// @notice Maximum accepted age of each basket feed's price (0 = feed outside the basket: price never counts).
    mapping(address feed => uint32) public maxStalenessOf;
    /// @notice Pending parameter-change proposals: keccak256(calldata) => timestamp from which it can execute.
    mapping(bytes32 id => uint256) public proposalEta;

    bool private locked;

    event OrderCreated(address indexed user, uint256 budget, uint256 amountPerBuy, uint256 dipBps, uint8 window);
    event OrderCancelled(address indexed user);
    event Executed(address indexed user, address indexed keeper, uint256 gross, uint256 fee, uint256 tip);
    event MixSet(address indexed user, uint16 btc, uint16 a, uint16 b);
    event DepositOpened(address indexed user, address box);
    event Swept(address indexed user, address indexed keeper, uint256 gross, uint256 fee, uint256 tip);
    event Swapped(address indexed token, uint256 amountIn, uint256 amountOut);
    event AltConverted(address indexed user, uint256 amountIn, uint256 amountOut);
    event SwapSkipped(address indexed token, uint256 amountIn);
    event Proposed(bytes32 indexed id, bytes data, uint256 eta);
    event ProposalExecuted(bytes32 indexed id);
    event ProposalCancelled(bytes32 indexed id);
    event OwnershipRenounced();
    event AllocationSet(uint16 btc, uint16 a, uint16 b);
    event DepositTipSet(uint16 bps);
    event MinAmountPerBuySet(uint96 amount);
    event DustSet(uint96 amount);
    event BtcOnlyMaxSet(uint96 amount);
    event Snapshot(uint256 timestamp);
    event Backfilled(address indexed feed, uint256 rounds);
    event Rescued(address indexed token, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @dev Parameters only change via `executeProposal` (the contract itself calls it), after TIMELOCK.
    modifier onlyTimelock() {
        require(msg.sender == address(this), "timelock only");
        _;
    }

    modifier nonReentrant() {
        require(!locked, "reentrancy");
        locked = true;
        _;
        locked = false;
    }

    constructor(Config memory c, Asset memory _btc, Asset[] memory _a, Asset[] memory _b) {
        require(
            c.stableToken != address(0) && c.swapRouter != address(0) && c.feeTreasury != address(0)
                && c.initialOwner != address(0),
            "zero address"
        );
        // only reads the decimals of the stable chosen at deploy time (no reentrancy is possible in the constructor)
        // aderyn-ignore-next-line(reentrancy-state-change)
        uint8 d = IERC20(c.stableToken).decimals();
        require(d <= WAD_DECIMALS, "stable decimals");
        // same decimals: amounts in both stables read the same, and the 99.5% limit compares them directly
        // aderyn-ignore-next-line(reentrancy-state-change)
        require(c.altStableToken == address(0) || (c.altStableToken != c.stableToken && c.altPoolFee > 0 && IERC20(c.altStableToken).decimals() == d), "bad alt stable");
        stable = IERC20(c.stableToken);
        altStable = IERC20(c.altStableToken);
        altFee = c.altPoolFee;
        stableDecimals = d;
        usdScale = DECIMAL_BASE ** (WAD_DECIMALS - d);
        router = ISwapRouter(c.swapRouter);
        treasury = c.feeTreasury;
        owner = c.initialOwner; // no transferOwnership: pass the Safe as owner at deploy time
        boxImpl = address(new DepositBox());

        _setMinAmountPerBuy(c.minBuy, d);
        _setDust(c.dustLimit, d);
        require(c.depositTip <= MAX_DEPOSIT_TIP_BPS, "tip too high");
        depositTipBps = c.depositTip;
        btcOnlyMax = uint96(BTC_ONLY_DEFAULT_USD * DECIMAL_BASE ** d);
        // basket fixed forever: there is no function to change a token, route or feed (changing = a new contract)
        _register(_btc, c.stableToken);
        btc = _btc;
        _setGroup(groupA, _a, c.stableToken);
        _setGroup(groupB, _b, c.stableToken);
    }

    // ---------------------------------------------------------------- orders

    /// @notice Creates (or replaces) the caller's order. Just approve stable >= budget afterwards.
    /// @param window 0 = dip against the 30-day high; 1 = against the ~1-year high; 2 = against the all-time high
    /// @param refRule only buys with BTC below the reference minus this margin (bps, up to 50%). The reference is the
    ///        BTC price at order creation until the 1st buy and, after that, the order's average price. REF_AUTO = margin
    ///        that covers fee + tip + DEX (each buy already lowers the average with costs included); REF_OFF = any dip
    /// @param maxWait 0 = wait for the reference with no limit; otherwise, after maxWait with no buy, the next dip
    ///        buys even above the reference (a market that only goes up does not lock the order forever)
    // Slither: depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // slither-disable-next-line timestamp
    function createOrder(
        uint128 budget,
        uint96 amountPerBuy,
        uint96 keeperTip,
        uint32 minInterval,
        uint64 expiry,
        uint16 dipBps,
        uint8 window,
        uint16 refRule,
        uint32 maxWait
    ) external {
        require(amountPerBuy >= minAmountPerBuy, "below minimum");
        require(amountPerBuy <= budget, "bad amount");
        require(uint256(keeperTip) * BPS <= uint256(amountPerBuy) * MAX_TIP_BPS, "tip too high");
        require(minInterval >= MIN_INTERVAL, "interval too short");
        require(window <= WINDOW_ATH, "bad window");
        require(dipBps >= MIN_DIP_BPS && dipBps <= MAX_DRAWDOWN_BPS, "bad dip");
        require(expiry == 0 || expiry > block.timestamp, "expired");
        require(refRule <= MAX_REF_MARGIN_BPS || refRule >= REF_AUTO, "bad ref rule");
        require(maxWait == 0 || maxWait >= 1 days, "bad wait");

        // field by field: fewer stack values than the literal Order({...}) with 9 parameters
        Order storage o = orders[msg.sender];
        o.budget = budget;
        o.spent = 0;
        o.amountPerBuy = amountPerBuy;
        o.keeperTip = keeperTip;
        o.minInterval = minInterval;
        o.lastExec = 0;
        o.expiry = expiry;
        o.dipBps = dipBps;
        o.active = true;
        o.window = window;
        o.refRule = refRule;
        {
            (bool ok, uint256 p) = _tryPrice(btc.feed); // in a block: leaves the stack before the emit
            require(ok, "btc oracle"); // no price means no reference: the order would never execute
            // 18 -> 8 decimals: BTC fits in uint64 up to ~$184 billion
            // aderyn-ignore-next-line(unsafe-casting)
            o.refPrice = uint64(p / FEED_TO_WAD);
        }
        o.maxWait = maxWait;
        o.createdAt = uint32(block.timestamp);
        o.btcCost = 0;
        o.btcBought = 0;
        emit OrderCreated(msg.sender, budget, amountPerBuy, dipBps, window);
    }

    function cancelOrder() external {
        orders[msg.sender].active = false;
        emit OrderCancelled(msg.sender);
    }

    /// @notice Chooses the BTC / group A / group B split for one's own buys (order and deposit), in bps.
    ///         Takes effect from the next buy on. BTC 75-100%, A up to 25%, B up to 5%, sum 100%;
    ///         (0, 0, 0) reverts to the default allocation.
    function setMix(uint16 _btc, uint16 _a, uint16 _b) external {
        if ((_btc | _a | _b) != 0) _checkMix(_btc, _a, _b);
        mixes[msg.sender] = Mix(_btc, _a, _b);
        emit MixSet(msg.sender, _btc, _a, _b);
    }

    /// @notice Allocation that applies to `user`'s buys above `btcOnlyMax`.
    /// @return custom false = the contract's default allocation
    function mixOf(address user) public view returns (uint16, uint16, uint16, bool custom) {
        Mix memory m = mixes[user];
        if (m.btcPart == 0 && m.aPart == 0 && m.bPart == 0) return (btcBps, groupABps, groupBBps, false);
        return (m.btcPart, m.aPart, m.bPart, true);
    }

    /// @notice For the keeper to check before spending gas. Returns the reason when it cannot execute.
    function canExecute(address user) external view returns (bool, string memory) {
        Market memory m = _newMarket();
        return _canExecute(orders[user], user, m);
    }

    /// @dev Same rules as canExecute, reusing what has already been read from the oracle and history (`m`).
    // Slither: external call in a loop: one token/oracle of the fixed basket per round (max. 21); the failure is handled or intentional; depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // slither-disable-next-line calls-loop,timestamp
    function _canExecute(Order storage o, address user, Market memory m) internal view returns (bool, string memory) {
        if (!o.active) return (false, "inactive");
        if (o.expiry != 0 && block.timestamp > o.expiry) return (false, "expired");
        if (block.timestamp < uint256(o.lastExec) + o.minInterval) return (false, "too soon");
        uint256 amount = o.amountPerBuy;
        if (uint256(o.spent) + amount > o.budget) return (false, "budget exhausted");
        (IERC20 pay, string memory why) = _payer(user, amount);
        if (address(pay) == address(0)) return (false, why);

        if (!_btcPrice(m)) return (false, "btc oracle");
        if (_btcDrawdown(m, o.window) < o.dipBps) return (false, "no dip");
        uint256 rule = o.refRule;
        if (rule != REF_OFF && block.timestamp < _waitEnds(o)) {
            // reference in USD 18 decimals: the order's average BTC price; before the 1st buy, the price at creation
            uint256 bought = o.btcBought;
            uint256 ref = bought > 0
                ? (uint256(o.btcCost) * usdScale * DECIMAL_BASE ** btc.tokenDecimals) / bought
                : uint256(o.refPrice) * FEED_TO_WAD;
            uint256 margin = rule == REF_AUTO ? feeBps + (uint256(o.keeperTip) * BPS) / amount + DEX_COST_BPS : rule;
            if (m.btcPrice > (ref * (BPS - margin)) / BPS) return (false, "above reference");
        }
        return (true, "");
    }

    /// @dev Which stable pays `amount` from the wallet: the main one if it can, otherwise the second one.
    ///      address(0) = neither can, with the reason ("allowance" or "balance").
    // Slither: external call in a loop: reads the two fixed stables of this contract, once per order in a batch.
    // slither-disable-next-line calls-loop
    function _payer(address user, uint256 amount) internal view returns (IERC20, string memory) {
        bool allowed = stable.allowance(user, address(this)) >= amount;
        if (allowed && stable.balanceOf(user) >= amount) return (stable, "");
        if (address(altStable) != address(0) && altStable.allowance(user, address(this)) >= amount) {
            if (altStable.balanceOf(user) >= amount) return (altStable, "");
            allowed = true;
        }
        return (IERC20(address(0)), allowed ? "balance" : "allowance");
    }

    /// @dev `amount` of `pay` is already in this contract: converts it to the main stable if needed, pays fee and tip and returns
    ///      what is left to buy. Reverts below ALT_MIN_OUT_BPS of 1:1: if the second stable loses its peg, the buy does not happen.
    // Slither: external call in a loop: the fixed router, once per order in a batch; a failure reverts on purpose (the keeper simulates and sends one by one); the deadline is the current block.
    // slither-disable-next-line calls-loop,timestamp
    function _settle(IERC20 pay, address user, uint256 amount, uint256 fee, uint256 tip) internal returns (uint256) {
        uint256 out = amount;
        if (pay != stable) {
            _safeApprove(address(pay), address(router), amount);
            out = router.exactInput(
                ISwapRouter.ExactInputParams({
                    path: abi.encodePacked(address(pay), altFee, address(stable)),
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amount,
                    amountOutMinimum: (amount * ALT_MIN_OUT_BPS) / BPS
                })
            );
            emit AltConverted(user, amount, out);
        }
        if (fee > 0) _safeTransfer(address(stable), treasury, fee);
        if (tip > 0) _safeTransfer(address(stable), msg.sender, tip);
        return out - fee - tip;
    }

    /// @dev Empty cache: everything is read on demand the first time it is needed.
    function _newMarket() internal pure returns (Market memory empty) {
        return empty;
    }

    /// @dev BTC price, read once per transaction.
    function _btcPrice(Market memory m) internal view returns (bool) {
        if (!m.priced) {
            (m.btcOk, m.btcPrice) = _tryPrice(btc.feed);
            m.priced = true;
        }
        return m.btcOk;
    }

    /// @dev BTC drawdown vs the window's high, computed once per transaction (needs the price). The all-time high is one
    ///      storage read: no cache needed. Before its round is recorded it is the current price at least, so: no dip.
    function _btcDrawdown(Market memory m, uint8 window) internal view returns (uint256) {
        if (window == WINDOW_ATH) {
            uint256 ath = btcAth;
            return ath > m.btcPrice ? _dd(ath, m.btcPrice) : 0;
        }
        if (window == 1) {
            if (!m.hasYear) {
                m.ddYear = _dd(_yearHigh(address(btc.feed), m.btcPrice), m.btcPrice);
                m.hasYear = true;
            }
            return m.ddYear;
        }
        if (!m.has30) {
            m.dd30 = _dd(_high30(address(btc.feed), m.btcPrice), m.btcPrice);
            m.has30 = true;
        }
        return m.dd30;
    }

    /// @dev End of the wait for the reference: maxWait after the last buy (or creation). No limit = never.
    function _waitEnds(Order storage o) internal view returns (uint256) {
        if (o.maxWait == 0) return type(uint256).max;
        return uint256(o.lastExec > 0 ? o.lastExec : o.createdAt) + o.maxWait;
    }

    /// @notice Anyone can call it; it only executes if the strategy allows it. The caller receives the tip.
    function execute(address user) external nonReentrant {
        Order storage o = orders[user];
        Market memory m = _newMarket();
        (bool ok, string memory why) = _canExecute(o, user, m);
        require(ok, why);
        _execute(o, user, m);
    }

    /// @notice Several orders in one transaction (the keeper saves the base cost and repeated cold accesses).
    ///         An order that cannot execute now is skipped; it only reverts if none execute. The caller receives all tips.
    ///         The oracle, highs and weights are read once for the whole batch (`Market`), not once per order.
    function executeMany(address[] calldata users) external nonReentrant returns (uint256 n) {
        Market memory m = _newMarket();
        uint256 len = users.length;
        // Each round only writes that wallet's order (unavoidable); everything that repeated (oracle, highs, weights)
        // left the loop. A failing transfer reverts the whole batch on purpose (the keeper simulates and sends one by one).
        // aderyn-ignore-next-line(costly-loop,require-revert-in-loop)
        for (uint256 i = 0; i < len; i++) {
            address user = users[i];
            Order storage o = orders[user];
            (bool ok,) = _canExecute(o, user, m);
            if (!ok) continue;
            _execute(o, user, m);
            n++;
        }
        require(n > 0, "nothing to execute");
    }

    // False positive: btcCost/btcBought depend on the swap's result, so they can only be written after it.
    // Reentering would require a malicious token or router (the basket is fixed at deploy time) and `execute`/`executeMany` have nonReentrant.
    // Slither: depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // slither-disable-next-line reentrancy-no-eth,timestamp
    function _execute(Order storage o, address user, Market memory m) internal {
        uint256 gross = o.amountPerBuy;
        o.spent += uint128(gross); // uint96 -> uint128: never truncates
        o.lastExec = uint32(block.timestamp);

        uint256 fee = (gross * feeBps) / BPS;
        uint256 tip = o.keeperTip;

        (IERC20 pay,) = _payer(user, gross);
        _safeTransferFrom(address(pay), user, address(this), gross);
        uint256 net = _settle(pay, user, gross, fee, tip);

        (uint256 btcIn, uint256 btcOut) = _buyBasket(net, user, gross, m);
        // one read and one write of the slot (btcCost and btcBought share the same slot)
        (o.btcCost, o.btcBought) = (o.btcCost + _u128(btcIn), o.btcBought + _u128(btcOut));

        emit Executed(user, msg.sender, gross, fee, tip);
    }

    // ---------------------------------------------------------- deposit mode

    /// @notice `user`'s deposit address on this network. It exists (and can receive) even before it is created.
    function depositAddress(address user) public view returns (address) {
        return _predictClone(boxImpl, _boxSalt(user));
    }

    /// @notice Creates `user`'s deposit address so the keeper can start watching it. Anyone can pay
    ///         for this (e.g. for someone who only has stable and no gas). Does nothing if it already exists.
    function openDepositAddress(address user) external returns (address) {
        return _openBox(user);
    }

    /// @notice For the keeper: how much there is to buy at `user`'s address and whether a buy is possible.
    function canSweep(address user) external view returns (bool, uint256 amount, string memory) {
        (, amount) = _boxBalance(depositAddress(user));
        if (amount < minAmountPerBuy) return (false, amount, "below minimum");
        (bool ok,) = _tryPrice(btc.feed);
        if (!ok) return (false, amount, "btc oracle");
        return (true, amount, "");
    }

    /// @notice Buys the basket immediately with what arrived at `user`'s deposit address (no dip signal) and
    ///         delivers it to `user`. Anyone can call it and receives `depositTipBps` of the amount.
    /// @param amount 0 = the whole balance; the keeper can split large deposits
    // False positive: `bal` (the balance before the transfers) is used on purpose to decide "small buy":
    // splitting a large deposit does not make it small. The token is the fixed stable and the function has nonReentrant.
    // Slither: depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // slither-disable-next-line reentrancy-balance,timestamp
    function sweep(address user, uint256 amount) external nonReentrant {
        DepositBox box = DepositBox(_openBox(user));
        (IERC20 pay, uint256 bal) = _boxBalance(address(box));
        if (amount == 0) amount = bal;
        require(amount <= bal, "balance");
        require(amount >= minAmountPerBuy, "below minimum");

        uint256 fee = (amount * depositFeeBps) / BPS;
        uint256 tip = (amount * depositTipBps) / BPS;
        box.send(address(pay), address(this), amount);
        uint256 net = _settle(pay, user, amount, fee, tip);

        // decided by the balance, not the slice: splitting a large deposit does not turn it "small"
        Market memory m = _newMarket();
        (uint256 btcIn,) = _buyBasket(net, user, bal, m);
        // the wallet's position was already recorded in _buyBasket; the deposit has no order average price
        assert(btcIn > 0); // BTC >= 75% of the buy: there is always a BTC slice (the buy reverts if the swap fails)
        emit Swept(user, msg.sender, amount, fee, tip);
    }

    /// @dev What a deposit address has to buy with: the main stable first; the second one only when the main one is below the minimum.
    function _boxBalance(address box) internal view returns (IERC20, uint256) {
        uint256 bal = stable.balanceOf(box);
        if (bal < minAmountPerBuy && address(altStable) != address(0)) {
            uint256 alt = altStable.balanceOf(box);
            if (alt >= minAmountPerBuy) return (altStable, alt);
        }
        return (stable, bal);
    }

    /// @notice The owner withdraws any token from their own deposit address, including one sent by mistake.
    /// @param token address(0) = native currency sent before the address was created
    /// @param amount 0 = the whole balance
    function withdrawDeposit(address token, uint256 amount) external nonReentrant {
        address box = _openBox(msg.sender);
        if (amount == 0) amount = token == address(0) ? box.balance : IERC20(token).balanceOf(box);
        DepositBox(box).send(token, msg.sender, amount);
    }

    // Assembly on purpose: minimal EIP-1167 clone via CREATE2 (predictable address before it exists); the constant is the clone's bytecode.
    // slither-disable-next-line assembly,too-many-digits
    function _openBox(address user) internal returns (address box) {
        require(user != address(0), "zero address");
        box = depositAddress(user);
        if (box.code.length == 0) {
            bytes32 salt = _boxSalt(user);
            address impl = boxImpl;
            address created;
            assembly {
                // EIP-1167: 3d602d80600a3d3981f3 363d3d373d3d3d363d73 <impl> 5af43d82803e903d91602b57fd5bf3
                mstore(0x00, or(shr(0xe8, shl(0x60, impl)), 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000))
                mstore(0x20, or(shl(0x78, impl), 0x5af43d82803e903d91602b57fd5bf3))
                created := create2(0, 0x09, 0x37, salt)
            }
            require(created == box, "clone failed");
            emit DepositOpened(user, box);
        }
    }

    function _boxSalt(address user) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(user)));
    }

    // Assembly on purpose: computes the CREATE2 address of the EIP-1167 clone without creating anything.
    // slither-disable-next-line assembly
    function _predictClone(address impl, bytes32 salt) internal view returns (address predicted) {
        address deployer = address(this);
        assembly {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x38), deployer)
            mstore(add(ptr, 0x24), 0x5af43d82803e903d91602b57fd5bf3ff)
            mstore(add(ptr, 0x14), impl)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73)
            mstore(add(ptr, 0x58), salt)
            mstore(add(ptr, 0x78), keccak256(add(ptr, 0x0c), 0x37))
            predicted := and(keccak256(add(ptr, 0x43), 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    // ---------------------------------------------------------------- buying

    /// @return btcIn stable spent on BTC (includes what fell back from the groups)
    /// @return btcOut BTC received by the user
    /// @param size value that decides whether the buy is small (<= btcOnlyMax => 100% BTC)
    /// @param m prices and weights already read in this transaction (whatever is missing is read here, once)
    // Slither: depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock); position recorded after the swap (needs its result); tokens/router fixed; nonReentrant at the entry point.
    // slither-disable-next-line timestamp,reentrancy-benign
    function _buyBasket(uint256 net, address to, uint256 size, Market memory m)
        internal
        returns (uint256 btcIn, uint256 btcOut)
    {
        (uint256 bBps, uint256 aBps,,) = mixOf(to);
        if (size <= btcOnlyMax) (bBps, aBps) = (BPS, 0);
        uint256 btcAmt = (net * bBps) / BPS;
        uint256 aAmt = (net * aBps) / BPS;
        uint256 bAmt = net - btcAmt - aAmt; // the remainder goes to B (no rounding dust)

        // excluded slices, below the dust threshold or with a failed swap do not sit idle: they go to BTC
        btcIn = btcAmt;
        if (aAmt > 0) {
            if (!m.hasA) {
                (m.wA, m.pA) = _weights(groupA);
                m.hasA = true;
            }
            btcIn += _buyGroup(groupA, aAmt, to, m.wA, m.pA);
        }
        if (bAmt > 0) {
            if (!m.hasB) {
                (m.wB, m.pB) = _weights(groupB);
                m.hasB = true;
            }
            btcIn += _buyGroup(groupB, bAmt, to, m.wB, m.pB);
        }
        if (btcIn > 0) {
            bool ok;
            (ok, btcOut) = _trySwap(btc, btcIn, to, _btcPrice(m) ? m.btcPrice : 0);
            require(ok, "btc swap failed");
            Position storage p = positions[to];
            (p.btcCost, p.btcBought) = (p.btcCost + _u128(btcIn), p.btcBought + _u128(btcOut));
        }
    }

    /// @return fallbackAmt value that was not bought in the group and goes to BTC
    /// @param w group weights (0 = token excluded)
    /// @param price group prices (18 decimals), read together with the weights
    // Slither: depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // slither-disable-next-line timestamp
    function _buyGroup(Asset[] storage g, uint256 amount, address to, uint256[] memory w, uint256[] memory price)
        internal
        returns (uint256 fallbackAmt)
    {
        uint256 n = w.length;
        uint256 total = 0;
        uint256 last = 0;
        for (uint256 i = 0; i < n; i++) {
            total += w[i];
            if (w[i] > 0) last = i;
        }
        if (total == 0) return amount;

        uint256 spent = 0;
        uint256 minPart = dust; // read once, outside the loop
        // One swap per basket token (at most MAX_GROUP); the gas `require` inside the swap is on purpose:
        // it stops the keeper from forcing failures by limiting gas.
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < n; i++) {
            if (w[i] == 0) continue; // excluded token: its slice is redistributed among the others
            uint256 part = i == last ? amount - spent : (amount * w[i]) / total;
            spent += part;
            Asset storage a = g[i];
            if (part < minPart) {
                fallbackAmt += part;
                emit SwapSkipped(a.token, part);
                continue;
            }
            (bool ok,) = _trySwap(a, part, to, price[i]);
            if (!ok) fallbackAmt += part;
        }
    }

    /// @dev Weight 0 = token excluded (broken/stale oracle or drawdown > 99%). Also returns each token's price,
    ///      so the swap does not read the oracle again.
    function _weights(Asset[] storage g) internal view returns (uint256[] memory w, uint256[] memory price) {
        uint256 n = g.length;
        w = new uint256[](n);
        price = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            (bool ok, uint256 cur, uint256 dd) = _drawdown(g[i].feed);
            if (!ok || dd > MAX_DRAWDOWN_BPS) continue;
            price[i] = cur;
            w[i] = BASE_WEIGHT + (dd > WEIGHT_DRAWDOWN_CAP ? WEIGHT_DRAWDOWN_CAP : dd);
        }
    }

    /// @dev Never reverts because of the token: returns false (dead pool, slippage, bad oracle).
    /// @param p token price (18 decimals) already read in this transaction; 0 = oracle unavailable (skip)
    // False positive: `minOut == 0` only skips a buy too small to have price protection.
    // Slither: external call in a loop: one token/oracle of the fixed basket per round (max. 21); the failure is handled or intentional; depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // slither-disable-next-line incorrect-equality,calls-loop,timestamp
    function _trySwap(Asset storage a, uint256 amountIn, address to, uint256 p) internal returns (bool, uint256) {
        // with gas to spare, a swap only fails for a real reason, never because the keeper limited the gas
        require(gasleft() > SWAP_GAS_RESERVE, "low gas");
        if (p == 0) return _skip(a.token, amountIn);

        // minimum from the oracle, in a single division: usd(18) * 10^dec * (1 - tolerance) / price(18).
        // Worst case ~1e49 ($1 bi, 18 decimals): far from the 1e77 limit.
        uint256 minOut = (amountIn * usdScale * DECIMAL_BASE ** a.tokenDecimals * (BPS - a.slippageBps)) / (p * BPS);
        if (minOut == 0) return _skip(a.token, amountIn);

        _safeApprove(address(stable), address(router), amountIn);
        try router.exactInput(
            ISwapRouter.ExactInputParams({
                path: a.path,
                recipient: to,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut
            })
        ) returns (uint256 out) {
            emit Swapped(a.token, amountIn, out);
            return (true, out);
        } catch {
            _safeApprove(address(stable), address(router), 0);
            return _skip(a.token, amountIn);
        }
    }

    function _skip(address token, uint256 amountIn) internal returns (bool, uint256) {
        emit SwapSkipped(token, amountIn);
        return (false, 0);
    }

    // -------------------------------------------------------------- history

    /// @notice Records the current price of each basket asset. Anyone can call it, at any time.
    function snapshot() external {
        Clock memory c = _clock();
        _recordLatest(btc.feed, true, c);
        _snapshotGroup(groupA, c);
        _snapshotGroup(groupB, c);
        emit Snapshot(block.timestamp);
    }

    /// @dev One feed per round, each with its own buckets (the write is unavoidable and only happens if the high
    ///      goes up); group size and timestamp read once, outside the loop.
    function _snapshotGroup(Asset[] storage g, Clock memory c) internal {
        uint256 n = g.length;
        // aderyn-ignore-next-line(costly-loop,require-revert-in-loop)
        for (uint256 i = 0; i < n; i++) _recordLatest(g[i].feed, false, c);
    }

    /// @dev "Today" and "current week" computed once per call, not once per round.
    struct Clock {
        uint256 today;
        uint256 week;
    }

    function _clock() internal view returns (Clock memory) {
        return Clock(block.timestamp / 1 days, block.timestamp / 1 weeks);
    }

    /// @notice Fills in the history with old Chainlink rounds. The price and date come from the feed
    ///         itself, so no data can be invented: your API only needs to find the roundIds.
    // False positive: roundId, startedAt and answeredInRound are not needed (answeredInRound is obsolete on
    // Chainlink); only price > 0 and timestamp matter.
    // Slither: external call in a loop: one token/oracle of the fixed basket per round (max. 21); the failure is handled or intentional; depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // slither-disable-next-line unused-return,calls-loop,timestamp
    function backfill(IAggregator feed, uint80[] calldata roundIds) external {
        uint8 d = feed.decimals();
        require(d <= WAD_DECIMALS, "feed decimals");
        uint256 scale = DECIMAL_BASE ** (WAD_DECIMALS - d);
        bool isBtc = address(feed) == address(btc.feed); // read once, not on every round
        Clock memory c = _clock();
        uint256 n = roundIds.length;
        uint256 used = 0;
        // Each round only writes if it raises that day's/week's high; everything else (decimals, BTC feed, timestamp)
        // left the loop. The `require` inside (checked cast of the high) never fails with a real price.
        // aderyn-ignore-next-line(costly-loop,require-revert-in-loop)
        for (uint256 i = 0; i < n; i++) {
            try feed.getRoundData(roundIds[i]) returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
                if (answer > 0 && updatedAt != 0 && updatedAt <= block.timestamp) {
                    _record(address(feed), uint256(answer) * scale, updatedAt, isBtc, c);
                    used++;
                }
            } catch {}
        }
        emit Backfilled(address(feed), used);
    }

    // False positive: same ignored fields as in backfill.
    // Slither: depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // slither-disable-next-line unused-return,timestamp
    function _recordLatest(IAggregator feed, bool isBtc, Clock memory c) internal {
        try feed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) return;
            try feed.decimals() returns (uint8 d) {
                if (d <= WAD_DECIMALS) {
                    _record(address(feed), uint256(answer) * DECIMAL_BASE ** (WAD_DECIMALS - d), updatedAt, isBtc, c);
                }
            } catch {}
        } catch {}
    }

    // Slither: depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock); the btcAth write
    // inside the backfill loop only happens when a round beats the current high, so it is not a cost per iteration.
    // slither-disable-next-line timestamp,costly-loop
    function _record(address feed, uint256 price, uint256 ts, bool isBtc, Clock memory c) internal {
        uint256 day = ts / 1 days;
        if (day + HISTORY > c.today) _bump(highs[feed][day % HISTORY], day, price);
        if (!isBtc) return;
        if (price > btcAth) btcAth = price;
        uint256 week = ts / 1 weeks;
        if (week + YEAR_WEEKS > c.week) _bump(weekHighs[feed][week % YEAR_WEEKS], week, price);
    }

    /// @dev Reads the bucket once and writes at most once (high and period share the slot).
    function _bump(Bucket storage b, uint256 period, uint256 price) internal {
        Bucket memory cur = b;
        if (cur.period == period) {
            if (price > cur.high) b.high = _u192(price);
        } else if (period > cur.period) {
            // day/week since 1970: fits in uint64 for billions of years
            // aderyn-ignore-next-line(unsafe-casting)
            (b.high, b.period) = (_u192(price), uint64(period));
        }
    }

    /// @return ok false if the oracle fails
    /// @return cur current price (18 decimals)
    /// @return dd drawdown in bps vs the 30-day high
    function _drawdown(IAggregator feed) internal view returns (bool ok, uint256 cur, uint256 dd) {
        (ok, cur) = _tryPrice(feed);
        if (!ok) return (false, 0, 0);
        dd = _dd(_high30(address(feed), cur), cur);
    }

    /// @dev Same as `_drawdown`, against the high of the last 53 weeks (only makes sense for the BTC feed).
    function _yearDrawdown(IAggregator feed) internal view returns (bool ok, uint256 cur, uint256 dd) {
        (ok, cur) = _tryPrice(feed);
        if (!ok) return (false, 0, 0);
        dd = _dd(_yearHigh(address(feed), cur), cur);
    }

    /// @dev Highest price of the last 30 days (at least the current one). One SLOAD per bucket.
    // Slither: depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // slither-disable-next-line timestamp
    function _high30(address feed, uint256 cur) internal view returns (uint256 high) {
        high = cur;
        uint256 today = block.timestamp / 1 days;
        Bucket[HISTORY] storage h = highs[feed];
        for (uint256 j = 0; j < HISTORY; j++) {
            Bucket memory b = h[j];
            if (b.period + HISTORY > today && b.high > high) high = b.high;
        }
    }

    /// @dev Highest price of the last 53 weeks (at least the current one). One SLOAD per bucket.
    // Slither: depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // slither-disable-next-line timestamp
    function _yearHigh(address feed, uint256 cur) internal view returns (uint256 high) {
        high = cur;
        uint256 week = block.timestamp / 1 weeks;
        Bucket[YEAR_WEEKS] storage h = weekHighs[feed];
        for (uint256 j = 0; j < YEAR_WEEKS; j++) {
            Bucket memory b = h[j];
            if (b.period + YEAR_WEEKS > week && b.high > high) high = b.high;
        }
    }

    /// @dev Drawdown in bps of `cur` vs `high` (high >= cur > 0).
    function _dd(uint256 high, uint256 cur) internal pure returns (uint256) {
        return ((high - cur) * BPS) / high;
    }

    // ----------------------------------------------------------------- oracle

    /// @return ok false if the feed is not in the basket, reverts, is stale (vs the feed's own staleness window) or gives an invalid price
    /// @return price price in 18 decimals
    // False positive: same ignored fields as in backfill (the staleness window is checked via updatedAt).
    // Slither: external call in a loop: one token/oracle of the fixed basket per round (max. 21); the failure is handled or intentional; depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // slither-disable-next-line unused-return,calls-loop,timestamp
    function _tryPrice(IAggregator feed) internal view returns (bool ok, uint256 price) {
        uint256 maxAge = maxStalenessOf[address(feed)];
        if (maxAge == 0) return (false, 0);
        try feed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) {
                return (false, 0);
            }
            try feed.decimals() returns (uint8 d) {
                if (d > WAD_DECIMALS) return (false, 0);
                return (true, uint256(answer) * DECIMAL_BASE ** (WAD_DECIMALS - d));
            } catch {
                return (false, 0);
            }
        } catch {
            return (false, 0);
        }
    }

    // ------------------------------------------------------------------ reads

    function getBtc() external view returns (Asset memory) {
        return btc;
    }

    function getOrder(address user) external view returns (Order memory) {
        return orders[user];
    }

    /// @param group 0 = A, 1 = B
    function getGroup(uint8 group) external view returns (Asset[] memory) {
        return group == 0 ? groupA : groupB;
    }

    /// @notice Current weights of a group (0 = A, 1 = B), in bps that add up to 10_000.
    function currentWeights(uint8 group) external view returns (address[] memory tokens, uint256[] memory bps) {
        Asset[] storage g = group == 0 ? groupA : groupB;
        (uint256[] memory w,) = _weights(g);
        uint256 n = w.length;
        uint256 total = 0;
        for (uint256 i = 0; i < n; i++) total += w[i];
        tokens = new address[](n);
        bps = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            tokens[i] = g[i].token;
            bps[i] = total == 0 ? 0 : (w[i] * BPS) / total;
        }
    }

    /// @notice Current drawdown of a feed vs the 30-day high, in bps.
    function drawdownOf(IAggregator feed) external view returns (bool ok, uint256 price, uint256 dd) {
        return _drawdown(feed);
    }

    /// @notice Current BTC drawdown vs the ~1-year high (53 weeks), in bps.
    function btcYearDrawdown() external view returns (bool ok, uint256 price, uint256 dd) {
        return _yearDrawdown(btc.feed);
    }

    // ------------------------------------------------------------------- admin

    //  The basket (tokens, routes, feeds and tolerances) is fixed: there is no setBtc/setGroup. The parameters below only
    //  change through the timelock: the owner proposes the call (the `Proposed` event with the calldata), waits TIMELOCK and
    //  executes within PROPOSAL_GRACE. Anyone who disagrees has 24 h to cancel their order and revoke the approval.

    /// @param data calldata of one of the `onlyTimelock` functions (e.g. abi.encodeCall(MacroSwap.setDust, (x)))
    // Centralization accepted and mitigated: the owner is a Safe, only touches parameters (basket and fees are fixed) and every
    // change stays announced for 24 h before it takes effect.
    // Slither (propose/cancel/execute): the timelock's deadline depends on timestamp on purpose; the executeProposal
    // event fires after the call to the contract itself (only the owner calls it).
    // slither-disable-start timestamp,reentrancy-events,assembly,low-level-calls
    // aderyn-ignore-next-line(centralization-risk)
    function propose(bytes calldata data) external onlyOwner returns (bytes32 id) {
        id = keccak256(data);
        require(proposalEta[id] == 0, "already proposed");
        uint256 eta = block.timestamp + TIMELOCK;
        proposalEta[id] = eta;
        emit Proposed(id, data, eta);
    }

    // aderyn-ignore-next-line(centralization-risk)
    function cancelProposal(bytes32 id) external onlyOwner {
        require(proposalEta[id] != 0, "not proposed");
        delete proposalEta[id];
        emit ProposalCancelled(id);
    }

    // aderyn-ignore-next-line(centralization-risk)
    function executeProposal(bytes calldata data) external onlyOwner {
        bytes32 id = keccak256(data);
        uint256 eta = proposalEta[id];
        require(eta != 0 && block.timestamp >= eta, "timelock");
        require(block.timestamp <= eta + PROPOSAL_GRACE, "proposal expired");
        delete proposalEta[id];
        (bool ok, bytes memory ret) = address(this).call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret)) // forwards the reason (e.g. "tip too high")
            }
        }
        emit ProposalExecuted(id);
    }
    // slither-disable-end timestamp,reentrancy-events,assembly,low-level-calls

    // The setters also emit their own event with the new value (in addition to Proposed/ProposalExecuted).

    function setAllocation(uint16 _btc, uint16 _a, uint16 _b) external onlyTimelock {
        _checkMix(_btc, _a, _b);
        (btcBps, groupABps, groupBBps) = (_btc, _a, _b);
        emit AllocationSet(_btc, _a, _b);
    }

    function setDepositTip(uint16 bps) external onlyTimelock {
        require(bps <= MAX_DEPOSIT_TIP_BPS, "tip too high");
        depositTipBps = bps;
        emit DepositTipSet(bps);
    }

    /// @dev Applies to new orders; existing orders keep their own value.
    function setMinAmountPerBuy(uint96 amount) external onlyTimelock {
        _setMinAmountPerBuy(amount, stableDecimals);
    }

    function setDust(uint96 amount) external onlyTimelock {
        _setDust(amount, stableDecimals);
    }

    /// @param amount 0 = every buy uses the user's own allocation
    function setBtcOnlyMax(uint96 amount) external onlyTimelock {
        require(amount <= MAX_USD * DECIMAL_BASE ** stableDecimals, "range $0-$1000");
        btcOnlyMax = amount;
        emit BtcOnlyMaxSet(amount);
    }

    /// @notice Gives up the parameters forever (no timelock: it only removes power). Pending proposals die.
    ///         Does not affect the treasury or the fee.
    // aderyn-ignore-next-line(centralization-risk)
    function renounceOwnership() external onlyOwner {
        owner = address(0);
        emit OwnershipRenounced();
    }

    /// @dev Group A up to 25% needs no check: with BTC >= 75% and a 100% sum, A + B <= 25%.
    function _checkMix(uint256 _btc, uint256 _a, uint256 _b) internal pure {
        require(_btc + _a + _b == BPS, "must sum 100%");
        require(_btc >= MIN_BTC_BPS, "btc 75%-100%");
        require(_b <= MAX_GROUP_B_BPS, "group b max 5%");
    }

    function _setMinAmountPerBuy(uint96 amount, uint8 d) internal {
        uint256 one = DECIMAL_BASE ** d; // $1 in stable units
        require(amount >= MIN_BUY_USD * one && amount <= MAX_USD * one, "range $5-$1000");
        minAmountPerBuy = amount;
        emit MinAmountPerBuySet(amount);
    }

    function _setDust(uint96 amount, uint8 d) internal {
        uint256 one = DECIMAL_BASE ** d;
        require(amount >= one / DUST_MIN_DIVISOR && amount <= DUST_MAX_USD * one, "range $0.01-$5");
        dust = amount;
        emit DustSet(amount);
    }

    /// @dev Constructor only (fixed basket). At most MAX_GROUP assets; writing each one is unavoidable.
    function _setGroup(Asset[] storage g, Asset[] memory src, address stableAddr) internal {
        uint256 n = src.length;
        require(n > 0 && n <= MAX_GROUP, "bad group size");
        // aderyn-ignore-next-line(costly-loop)
        for (uint256 i = 0; i < n; i++) {
            _register(src[i], stableAddr);
            g.push(src[i]);
        }
    }

    /// @dev Checks the asset and records its feed's price validity window.
    function _register(Asset memory a, address stableAddr) internal {
        require(a.token != address(0) && address(a.feed) != address(0), "zero address");
        require(a.slippageBps > 0 && a.slippageBps <= MAX_SLIPPAGE_BPS, "bad slippage");
        require(a.maxStaleness >= 1 hours && a.maxStaleness <= 48 hours, "bad staleness");
        require(maxStalenessOf[address(a.feed)] == 0, "feed repeated");
        require(IERC20(a.token).decimals() == a.tokenDecimals, "decimals mismatch");
        (address first, address last) = _pathEnds(a.path);
        require(first == stableAddr && last == a.token, "bad path ends");
        maxStalenessOf[address(a.feed)] = a.maxStaleness;
    }

    /// @dev V3 path = token(20) + [fee(3) + token(20)]*n, with at least one pool
    // Assembly on purpose: reads the first and last address of the path without copying the array.
    // slither-disable-next-line assembly
    function _pathEnds(bytes memory p) internal pure returns (address first, address last) {
        uint256 len = p.length;
        require(len >= ADDR_LEN + HOP_LEN && (len - ADDR_LEN) % HOP_LEN == 0, "bad path");
        uint256 lastAt = len - ADDR_LEN;
        assembly {
            first := shr(96, mload(add(p, 32)))
            last := shr(96, mload(add(add(p, 32), lastAt)))
        }
    }

    // -------------------------------------------------------------- treasury

    /// @notice Rescues tokens sent to the contract by mistake. The contract does not hold users' funds
    ///         between calls, so only dust/sending mistakes are left to recover.
    // False positive: `ret.length == 0` accepts a token with no bool return; the return is checked.
    // Low-level call on purpose: accepts tokens with no bool return; the result is checked in the require.
    // slither-disable-next-line incorrect-equality,low-level-calls
    function rescue(address token, uint256 amount) external nonReentrant {
        require(msg.sender == treasury, "not treasury");
        require(token != address(0), "zero address");
        // aderyn-ignore-next-line(unsafe-erc20-operation)
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (treasury, amount)));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "rescue failed");
        emit Rescued(token, amount);
    }

    // ----------------------------------------------------------------- helpers

    /// @dev Checked cast: the values fit with plenty of room (stable in uint96, real swap output), but a router outside
    ///      the standard would never silently corrupt the accounting by truncating.
    // Slither: depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // slither-disable-next-line timestamp
    function _u128(uint256 x) internal pure returns (uint128) {
        require(x <= type(uint128).max, "overflow");
        // checked on the line above
        // aderyn-ignore-next-line(unsafe-casting)
        return uint128(x);
    }

    /// @dev Same as above, for the history high (price in 18 decimals).
    function _u192(uint256 x) internal pure returns (uint192) {
        require(x <= type(uint192).max, "overflow");
        // checked on the line above
        // aderyn-ignore-next-line(unsafe-casting)
        return uint192(x);
    }

    // The wrappers below ARE the safe form (they accept tokens with no bool return and check the return when it exists).
    // False positive: `ret.length == 0` is the standard for tokens with no bool return (e.g. USDT on Ethereum).
    // Slither: external call in a loop: one token/oracle of the fixed basket per round (max. 21); the failure is handled or intentional; depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // Low-level call on purpose: accepts tokens with no bool return; the result is checked in the require.
    // slither-disable-next-line incorrect-equality,calls-loop,timestamp,low-level-calls
    function _safeTransferFrom(address token, address from, address to, uint256 amt) internal {
        // aderyn-ignore-next-line(unsafe-erc20-operation)
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transferFrom, (from, to, amt)));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "transferFrom failed");
    }

    // Slither: external call in a loop: one token/oracle of the fixed basket per round (max. 21); the failure is handled or intentional; depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // Low-level call on purpose: accepts tokens with no bool return; the result is checked in the require.
    // slither-disable-next-line incorrect-equality,calls-loop,timestamp,low-level-calls
    function _safeTransfer(address token, address to, uint256 amt) internal {
        // aderyn-ignore-next-line(unsafe-erc20-operation)
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amt)));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "transfer failed");
    }

    // Slither: external call in a loop: one token/oracle of the fixed basket per round (max. 21); the failure is handled or intentional; depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // Low-level call on purpose: accepts tokens with no bool return; the result is checked in the require.
    // slither-disable-next-line incorrect-equality,calls-loop,timestamp,low-level-calls
    function _safeApprove(address token, address spender, uint256 amt) internal {
        // aderyn-ignore-next-line(unsafe-erc20-operation)
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.approve, (spender, amt)));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "approve failed");
    }
}
