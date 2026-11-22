// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAggregator, IERC20, ISwapRouter, MacroSwap} from "./MacroSwap.sol";

/// @title MacroSwapSell
/// @notice Sells the basket back to stable, using the same tokens, routes, oracles and tolerances as
///         MacroSwap (read from it on every sale; nothing is copied).
///   - `sell(bps)`: the user instantly sells a slice of what they approved of each basket token.
///   - Profit-taking: the user registers `setTakeProfit` and anyone (keeper) calls `takeProfit` when
///     BTC reaches `gainBps` above the reference. Reference = the greater of the entry price (the one given or the
///     wallet's average buy price on MacroSwap) and the price of the last automatic sale, which forms a
///     ladder: with +50% and 25%, it sells 25% at 1.5x, then 25% of the rest at 2.25x, and so on.
///   How much of each token can be sold is the approval the user gave this contract: with no approval, the token
///   is left out. The stable always goes to the user themselves; fee to MacroSwap's treasury, tip to the keeper.
///   No swap goes out below the oracle price minus the token's tolerance: if it would, the token stays in the wallet.
///   Fixed fees (as on the buy side): market sale (`sell`) = `marketFeeBps` 0.50%; profit-taking
///   (`takeProfit`) = `feeBps` 0.25%. Nobody changes them, not even MacroSwap's owner.
///   The contract never holds funds between calls.
contract MacroSwapSell {
    struct TakeProfit {
        uint16 gainBps; // sells when BTC >= reference * (1 + gainBps)
        uint16 sellBps; // slice of each token's approval sold per time; 10000 = everything (and ends it)
        bool active;
        uint64 expiry; // 0 = no expiry
        uint96 keeperTip; // in stable, taken out of the sale amount
        uint128 entryPrice; // BTC entry price (USD 18 dec); 0 = average buy price on MacroSwap
        uint128 lastPrice; // BTC price at the last automatic sale; 0 = none yet
    }

    uint256 public constant MAX_TIP_BPS = 500; // tip <= 5% of the sale amount
    uint256 public constant MAX_GAIN_BPS = 5e4; // trigger of up to +500%
    uint256 public constant SWAP_GAS_RESERVE = 5e5; // same as MacroSwap: the keeper cannot force swaps to fail
    uint256 public constant MIN_SETTING_BPS = 100; // profit-taking trigger and slice: at least 1%

    uint256 internal constant BPS = 1e4; // 100% in basis points
    uint8 internal constant WAD_DECIMALS = 18; // internal prices in 18 decimals
    uint256 internal constant DECIMAL_BASE = 10; // DECIMAL_BASE ** decimals
    uint256 internal constant ADDR_LEN = 20; // V3 route: token(20) + [fee(3) + token(20)]*n
    uint256 internal constant FEE_LEN = 3;
    uint256 internal constant HOP_LEN = ADDR_LEN + FEE_LEN;

    MacroSwap public immutable macroSwap;
    IERC20 public immutable stable;
    ISwapRouter public immutable router;
    address public immutable treasury;
    uint256 internal immutable usdScale; // 10^(18 - stable decimals)

    // fixed fees as in MacroSwap: nobody changes them
    uint16 public constant feeBps = 25; // profit-taking (sell at target), on the sale amount
    uint16 public constant marketFeeBps = 50; // instant market sale (`sell`)
    mapping(address user => TakeProfit) public takeProfits;
    bool private locked;

    event TakeProfitSet(address indexed user, uint256 gainBps, uint256 sellBps, uint256 entryPrice);
    event TakeProfitCancelled(address indexed user);
    event Sold(address indexed user, address indexed keeper, uint256 gross, uint256 fee, uint256 tip);
    event Swapped(address indexed token, uint256 amountIn, uint256 amountOut);
    event SwapSkipped(address indexed token, uint256 amountIn);

    modifier nonReentrant() {
        require(!locked, "reentrancy");
        locked = true;
        _;
        locked = false;
    }

    // Reads from MacroSwap itself (the project's contract, given at deploy time) to set the immutables: in the
    // constructor no reentrancy is possible.
    constructor(MacroSwap _macroSwap) {
        macroSwap = _macroSwap;
        // aderyn-ignore-next-line(reentrancy-state-change)
        stable = _macroSwap.stable();
        // aderyn-ignore-next-line(reentrancy-state-change)
        router = _macroSwap.router();
        // aderyn-ignore-next-line(reentrancy-state-change)
        treasury = _macroSwap.treasury();
        usdScale = DECIMAL_BASE ** (WAD_DECIMALS - _macroSwap.stableDecimals());
    }

    // ------------------------------------------------------------ instant sale

    /// @notice Sells `sellBps` (1-10000) of what you approved of each basket token and receives the stable.
    function sell(uint16 sellBps) external nonReentrant {
        require(sellBps > 0 && sellBps <= BPS, "bad sell bps");
        _sell(msg.sender, sellBps, 0, marketFeeBps);
    }

    // ----------------------------------------------------- profit-taking

    /// @param entryPrice BTC entry price in USD with 18 decimals; 0 = your average buy price on MacroSwap
    // Slither: depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // slither-disable-next-line timestamp
    function setTakeProfit(uint16 gainBps, uint16 sellBps, uint96 keeperTip, uint64 expiry, uint128 entryPrice)
        external
    {
        require(gainBps >= MIN_SETTING_BPS && gainBps <= MAX_GAIN_BPS, "bad gain");
        require(sellBps >= MIN_SETTING_BPS && sellBps <= BPS, "bad sell bps");
        require(expiry == 0 || expiry > block.timestamp, "expired");
        takeProfits[msg.sender] = TakeProfit({
            gainBps: gainBps,
            sellBps: sellBps,
            active: true,
            expiry: expiry,
            keeperTip: keeperTip,
            entryPrice: entryPrice,
            lastPrice: 0
        });
        emit TakeProfitSet(msg.sender, gainBps, sellBps, entryPrice);
    }

    function cancelTakeProfit() external {
        takeProfits[msg.sender].active = false;
        emit TakeProfitCancelled(msg.sender);
    }

    /// @notice BTC price (USD 18 dec) from which `user`'s profit-taking sells. 0 = no reference.
    function triggerPrice(address user) public view returns (uint256) {
        TakeProfit storage t = takeProfits[user];
        uint256 ref = t.entryPrice != 0 ? t.entryPrice : avgBtcPrice(user);
        if (t.lastPrice > ref) ref = t.lastPrice;
        return (ref * (BPS + t.gainBps)) / BPS;
    }

    /// @notice `user`'s average BTC buy price across all MacroSwap buys (USD 18 dec; 0 = none).
    function avgBtcPrice(address user) public view returns (uint256) {
        (uint128 cost, uint128 bought) = macroSwap.positions(user);
        if (bought == 0) return 0;
        return (uint256(cost) * usdScale * DECIMAL_BASE ** macroSwap.getBtc().tokenDecimals) / bought;
    }

    /// @notice For the keeper: whether a sale can happen now and the value estimated by the oracle (stable).
    // Slither: depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // slither-disable-next-line timestamp
    function canTakeProfit(address user) public view returns (bool, uint256 estimate, string memory) {
        TakeProfit storage t = takeProfits[user];
        if (!t.active) return (false, 0, "inactive");
        if (t.expiry != 0 && block.timestamp > t.expiry) return (false, 0, "expired");
        (bool ok, uint256 cur) = _price(macroSwap.getBtc().feed);
        if (!ok) return (false, 0, "btc oracle");
        uint256 trigger = triggerPrice(user);
        if (trigger == 0) return (false, 0, "no entry price");
        if (cur < trigger) return (false, 0, "below target");
        estimate = _estimate(user, t.sellBps);
        if (estimate < macroSwap.minAmountPerBuy()) return (false, estimate, "below minimum");
        if (uint256(t.keeperTip) * BPS > estimate * MAX_TIP_BPS) return (false, estimate, "tip too high");
        return (true, estimate, "");
    }

    /// @notice Anyone can call it; it only sells if BTC reached the target. The caller receives the tip.
    function takeProfit(address user) external nonReentrant {
        (bool ok,, string memory why) = canTakeProfit(user);
        require(ok, why);
        TakeProfit storage t = takeProfits[user];
        // view-only read of the oracle; the writes come before the sale (checks-effects-interactions)
        // aderyn-ignore-next-line(reentrancy-state-change)
        (, uint256 cur) = _price(macroSwap.getBtc().feed);
        t.lastPrice = _u128(cur);
        if (t.sellBps == BPS) t.active = false; // sold everything: nothing left to take profit on
        _sell(user, t.sellBps, t.keeperTip, feeBps);
    }

    // ---------------------------------------------------------------- selling

    // False positive: `gross` is the sum of what each swap returned, not a balance read beforehand. `sell`/`takeProfit`
    // have nonReentrant and the tokens/router are fixed (MacroSwap's basket).
    // Slither: depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // slither-disable-next-line reentrancy-balance,timestamp
    function _sell(address user, uint256 sellBps, uint256 tip, uint256 feeRate) internal {
        MacroSwap.Asset[] memory basket = _basket(); // 3 reads from MacroSwap per sale, not one per token
        uint256 minValue = macroSwap.dust(); // same: read once, outside the loop
        uint256 n = basket.length;
        uint256 gross = 0;
        // One swap per basket token (unavoidable); the gas `require` inside is on purpose (the keeper cannot force
        // swaps to fail).
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < n; i++) gross += _sellOne(basket[i], user, sellBps, minValue);
        require(gross > 0, "nothing sold");
        require(tip * BPS <= gross * MAX_TIP_BPS, "tip too high");

        uint256 fee = (gross * feeRate) / BPS;
        if (fee > 0) _safeTransfer(address(stable), treasury, fee);
        if (tip > 0) _safeTransfer(address(stable), msg.sender, tip);
        _safeTransfer(address(stable), user, gross - fee - tip);
        emit Sold(user, msg.sender, gross, fee, tip);
    }

    /// @return out stable received (0 = token with no approval, no balance or swap outside the price: stays in the wallet)
    // False positive: `amount` (the approved slice) is what actually gets sold, so the expected value has to be based on it;
    // `== 0` only skips an empty or too-small slice.
    // Slither: external call in a loop: one token/oracle of the fixed basket per round (max. 21); the failure is handled or intentional.
    // slither-disable-next-line divide-before-multiply,incorrect-equality,calls-loop
    function _sellOne(MacroSwap.Asset memory a, address user, uint256 sellBps, uint256 minValue)
        internal
        returns (uint256 out)
    {
        uint256 amount = (_sellable(a.token, user) * sellBps) / BPS;
        if (amount == 0) return 0;
        require(gasleft() > SWAP_GAS_RESERVE, "low gas");

        (bool ok, uint256 p) = _price(a.feed);
        if (!ok) return _skip(a.token, amount);
        // value by the oracle, in stable, in a single division: token * price(18) / (10^dec * usdScale)
        uint256 scale = DECIMAL_BASE ** a.tokenDecimals * usdScale;
        uint256 expected = (amount * p) / scale;
        uint256 minOut = (amount * p * (BPS - a.slippageBps)) / (scale * BPS);
        if (minOut == 0 || expected < minValue) return _skip(a.token, amount);

        _safeTransferFrom(a.token, user, address(this), amount);
        _safeApprove(a.token, address(router), amount);
        try router.exactInput(
            ISwapRouter.ExactInputParams({
                path: _reverse(a.path),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: minOut
            })
        ) returns (uint256 got) {
            emit Swapped(a.token, amount, got);
            return got;
        } catch {
            _safeApprove(a.token, address(router), 0);
            _safeTransfer(a.token, user, amount); // returns it: nothing stays here
            return _skip(a.token, amount);
        }
    }

    function _skip(address token, uint256 amount) internal returns (uint256) {
        emit SwapSkipped(token, amount);
        return 0;
    }

    // Slither: external call in a loop: one token/oracle of the fixed basket per round (max. 21); the failure is handled or intentional.
    // slither-disable-next-line calls-loop
    function _sellable(address token, address user) internal view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(user);
        uint256 allowed = IERC20(token).allowance(user, address(this));
        return bal < allowed ? bal : allowed;
    }

    /// @dev Value by the oracle (stable) of what would be sold now, without deducting the tolerance.
    function _estimate(address user, uint256 sellBps) internal view returns (uint256 total) {
        MacroSwap.Asset[] memory basket = _basket();
        uint256 n = basket.length;
        total = 0;
        for (uint256 i = 0; i < n; i++) total += _estimateOne(basket[i], user, sellBps);
    }

    /// @dev BTC + group A + group B in a single list (the basket is fixed in MacroSwap).
    function _basket() internal view returns (MacroSwap.Asset[] memory all) {
        MacroSwap.Asset[] memory a = macroSwap.getGroup(0);
        MacroSwap.Asset[] memory b = macroSwap.getGroup(1);
        uint256 na = a.length;
        uint256 nb = b.length;
        all = new MacroSwap.Asset[](1 + na + nb);
        all[0] = macroSwap.getBtc();
        for (uint256 i = 0; i < na; i++) all[1 + i] = a[i];
        for (uint256 i = 0; i < nb; i++) all[1 + na + i] = b[i];
    }

    // False positive: same as in _sellOne (the estimate is based on the same slice that will be sold).
    // slither-disable-next-line divide-before-multiply,incorrect-equality
    function _estimateOne(MacroSwap.Asset memory a, address user, uint256 sellBps) internal view returns (uint256) {
        uint256 amount = (_sellable(a.token, user) * sellBps) / BPS;
        if (amount == 0) return 0;
        (bool ok, uint256 p) = _price(a.feed);
        return ok ? (amount * p) / (DECIMAL_BASE ** a.tokenDecimals * usdScale) : 0;
    }

    /// @dev Same rule as MacroSwap: price > 0, not from the future and within the feed's own staleness window.
    // False positive: roundId, startedAt and answeredInRound (obsolete on Chainlink) are not needed.
    // Slither: external call in a loop: one token/oracle of the fixed basket per round (max. 21); the failure is handled or intentional; depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // slither-disable-next-line unused-return,calls-loop,timestamp
    function _price(IAggregator feed) internal view returns (bool, uint256) {
        uint256 maxAge = macroSwap.maxStalenessOf(address(feed));
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

    /// @dev Buy-side V3 route (stable -> ... -> token) flipped for selling (token -> ... -> stable).
    ///      Format: token(20) + [fee(3) + token(20)]*n.
    function _reverse(bytes memory p) internal pure returns (bytes memory r) {
        uint256 n = (p.length - ADDR_LEN) / HOP_LEN; // number of pools
        r = new bytes(p.length);
        for (uint256 i = 0; i <= n; i++) {
            // token i goes to position n - i
            uint256 from = i * HOP_LEN;
            uint256 to = (n - i) * HOP_LEN;
            for (uint256 j = 0; j < ADDR_LEN; j++) r[to + j] = p[from + j];
            if (i < n) {
                // the fee between tokens i and i+1 sits between (n-i-1) and (n-i)
                uint256 feeTo = (n - i - 1) * HOP_LEN + ADDR_LEN;
                for (uint256 j = 0; j < FEE_LEN; j++) r[feeTo + j] = p[from + ADDR_LEN + j];
            }
        }
    }

    /// @dev Checked cast (BTC price in 18 decimals fits up to ~3.4e20 USD), with no silent truncation.
    function _u128(uint256 x) internal pure returns (uint128) {
        require(x <= type(uint128).max, "overflow");
        // checked on the line above
        // aderyn-ignore-next-line(unsafe-casting)
        return uint128(x);
    }

    // False positive: `ret.length == 0` is the standard for tokens with no bool return.
    // Slither: external call in a loop: one token/oracle of the fixed basket per round (max. 21); the failure is handled or intentional; depends on timestamp on purpose (interval, expiry, oracle staleness, buckets, timelock).
    // Low-level call on purpose: accepts tokens with no bool return; the result is checked in the require.
    // slither-disable-next-line incorrect-equality,calls-loop,timestamp,low-level-calls
    function _safeTransfer(address token, address to, uint256 amt) internal {
        // aderyn-ignore-next-line(unsafe-erc20-operation)
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amt)));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "transfer failed");
    }

    // Slither: external call in a loop: one token/oracle of the fixed basket per round (max. 21); the failure is handled or intentional.
    // Low-level call on purpose: accepts tokens with no bool return; the result is checked in the require.
    // slither-disable-next-line incorrect-equality,calls-loop,low-level-calls
    function _safeTransferFrom(address token, address from, address to, uint256 amt) internal {
        // aderyn-ignore-next-line(unsafe-erc20-operation)
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transferFrom, (from, to, amt)));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "transferFrom failed");
    }

    // Slither: external call in a loop: one token/oracle of the fixed basket per round (max. 21); the failure is handled or intentional.
    // Low-level call on purpose: accepts tokens with no bool return; the result is checked in the require.
    // slither-disable-next-line incorrect-equality,calls-loop,low-level-calls
    function _safeApprove(address token, address spender, uint256 amt) internal {
        // aderyn-ignore-next-line(unsafe-erc20-operation)
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.approve, (spender, amt)));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "approve failed");
    }
}
