// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev What the NFT reads from MacroSwap for the on-chain version of the data.
interface IMacroSwapRead {
    struct Asset {
        address token;
        address feed;
        uint8 tokenDecimals;
        uint16 slippageBps;
        uint32 maxStaleness;
        bytes path;
    }

    struct Order {
        uint128 budget;
        uint128 spent;
        uint96 amountPerBuy;
        uint96 keeperTip;
        uint32 minInterval;
        uint32 lastExec;
        uint64 expiry;
        uint16 dipBps;
        bool active;
        uint8 window;
        uint16 refRule;
        uint64 refPrice; // USD, 8 decimals
        uint32 maxWait;
        uint32 createdAt;
        uint128 btcCost;
        uint128 btcBought;
    }

    function getOrder(address user) external view returns (Order memory);
    function getBtc() external view returns (Asset memory);
    function mixOf(address user) external view returns (uint16 btc, uint16 a, uint16 b, bool custom);
    function stableDecimals() external view returns (uint8);
    function btcYearDrawdown() external view returns (bool ok, uint256 price, uint256 dd);
}

/// @title MacroSwapTracker
/// @notice Non-transferable NFT (soulbound, ERC-5192): one per wallet, with the wallet's buy history and
///         unrealized result on MacroSwap. The data and image come from the API (`baseURI`), which computes everything
///         from MacroSwap's public events; the NFT holds and represents no asset.
///         - Only the owner mints their own NFT (nobody receives an NFT unintentionally) and only the owner burns it.
///         - There is no transfer and no approval.
///         - tokenId = the wallet's address, so each wallet has at most one NFT.
///         - ERC-4906: tells marketplaces to refresh the image when the data changes.
///         - No API: with an empty `baseURI`, the `tokenURI` is generated 100% on-chain (`onchainURI`), with the
///           current order's data read from MacroSwap. Never blank, even if the API goes down.
contract MacroSwapTracker {
    string public constant name = "MacroSwap Tracker";
    string public constant symbol = "MSTRACK";

    address public immutable macroSwap; // the contract whose buys the NFT shows (same network)
    address public owner; // Safe: only adjusts the API URI; no access to anything of the users'
    string public baseURI; // e.g.: https://nft.macroswap.dev/tracker/1/  (ends with /)

    mapping(uint256 tokenId => bool) internal minted;
    uint256 public totalSupply;

    // formatting constants (numbers, USD, base64, hex) and scale
    uint256 internal constant BPS = 1e4;
    uint8 internal constant WAD_DECIMALS = 18;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant CENT_WAD = 1e16; // $0.01 in 18 decimals
    uint256 internal constant FEED_TO_WAD = 1e10; // 8-decimal price -> 18
    uint8 internal constant BTC_SHOW_DECIMALS = 8; // BTC shown with 8 decimals in the image
    uint256 internal constant TEN = 10; // decimal base
    uint256 internal constant PERCENT = 100; // bps -> % and cents
    uint256 internal constant THOUSAND = 1e3; // thousands separator
    uint256 internal constant ASCII_ZERO = 48; // "0"
    uint256 internal constant ROW_Y0 = 316; // first table row in the SVG
    uint256 internal constant ROW_STEP = 32; // height of each row
    uint256 internal constant BYTE_BITS = 8;
    uint256 internal constant B64_IN = 3; // 3 bytes become 4 characters
    uint256 internal constant B64_OUT = 4;
    uint256 internal constant B64_MASK = 63; // 6 bits
    uint256 internal constant B64_SHIFT_1 = 18; // 1st character: bits 23..18
    uint256 internal constant B64_SHIFT_2 = 12;
    uint256 internal constant B64_SHIFT_3 = 6;
    uint256 internal constant HEX_BITS = 4;
    uint256 internal constant HEX_LEN = 42; // "0x" + 40 digits

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Locked(uint256 tokenId); // ERC-5192
    event MetadataUpdate(uint256 tokenId); // ERC-4906
    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId); // ERC-4906
    event OwnershipRenounced();

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address _macroSwap, address _owner, string memory _baseURI) {
        require(_macroSwap != address(0) && _owner != address(0), "zero address");
        macroSwap = _macroSwap;
        owner = _owner;
        baseURI = _baseURI;
    }

    // ------------------------------------------------------------------- tracker

    function tokenIdOf(address holder) public pure returns (uint256) {
        return uint256(uint160(holder));
    }

    /// @notice Mints the caller's own NFT. Free (just the gas).
    function mint() external returns (uint256 id) {
        id = tokenIdOf(msg.sender);
        require(!minted[id], "already minted");
        minted[id] = true;
        totalSupply++;
        emit Transfer(address(0), msg.sender, id);
        emit Locked(id);
    }

    /// @notice The owner deletes their own NFT (e.g. no longer wants the history tied to the wallet).
    function burn() external {
        uint256 id = tokenIdOf(msg.sender);
        require(minted[id], "not minted");
        minted[id] = false;
        totalSupply--;
        emit Transfer(msg.sender, address(0), id);
    }

    /// @notice Asks marketplaces to reload the NFT's image (NFT owner or collection owner).
    function refresh(uint256 id) external {
        require(minted[id], "not minted");
        require(msg.sender == address(uint160(id)) || msg.sender == owner, "not allowed");
        emit MetadataUpdate(id);
    }

    // ----------------------------------------------------------------- ERC-721

    function balanceOf(address holder) external view returns (uint256) {
        require(holder != address(0), "zero address");
        return minted[tokenIdOf(holder)] ? 1 : 0;
    }

    function ownerOf(uint256 id) public view returns (address) {
        require(minted[id], "not minted");
        // a minted id = the wallet's address (tokenIdOf), so it fits in uint160; a larger id is never minted (reverts above)
        // aderyn-ignore-next-line(unsafe-casting)
        return address(uint160(id));
    }

    /// @notice API when configured; with no `baseURI`, the data and image come from the contract itself.
    function tokenURI(uint256 id) external view returns (string memory) {
        address holder = ownerOf(id);
        if (bytes(baseURI).length == 0) return _onchainURI(holder);
        return string.concat(baseURI, _hex(holder));
    }

    /// @notice 100% on-chain version of the metadata (data: URI), always available. Shows the wallet's
    ///         current order; what is not recorded in the contract (deposit buys, other tokens) only the API shows.
    function onchainURI(uint256 id) external view returns (string memory) {
        return _onchainURI(ownerOf(id));
    }

    /// @notice Collection metadata (OpenSea).
    function contractURI() external view returns (string memory) {
        return string.concat(baseURI, "collection");
    }

    /// @notice ERC-5192: every NFT is locked forever.
    function locked(uint256 id) external view returns (bool) {
        require(minted[id], "not minted");
        return true;
    }

    function getApproved(uint256 id) external view returns (address) {
        require(ownerOf(id) != address(0), "not minted"); // reverts if it does not exist (ERC-721); there is never an approved address
        return address(0);
    }

    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }

    function approve(address, uint256) external pure {
        revert("soulbound");
    }

    function setApprovalForAll(address, bool) external pure {
        revert("soulbound");
    }

    function transferFrom(address, address, uint256) external pure {
        revert("soulbound");
    }

    function safeTransferFrom(address, address, uint256) external pure {
        revert("soulbound");
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) external pure {
        revert("soulbound");
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 // ERC-165
            || id == 0x80ac58cd // ERC-721
            || id == 0x5b5e139f // ERC-721 Metadata
            || id == 0xb45a3c0e // ERC-5192
            || id == 0x49064906; // ERC-4906
    }

    // ------------------------------------------------------------------- admin

    /// @dev Changes the API (new domain, etc.). Tells marketplaces to reload everything.
    // Centralization accepted: the owner (Safe) only changes the image URI; no access to any funds; empty = 100% on-chain.
    // aderyn-ignore-next-line(centralization-risk)
    function setBaseURI(string calldata uri) external onlyOwner {
        baseURI = uri;
        emit BatchMetadataUpdate(0, type(uint160).max);
    }

    // Only removes power (owner becomes zero).
    // aderyn-ignore-next-line(centralization-risk)
    function renounceOwnership() external onlyOwner {
        owner = address(0);
        emit OwnershipRenounced();
    }

    // -------------------------------------------------------------- on-chain

    struct View {
        bool hasBuys;
        bool active;
        uint8 window;
        uint16 dipBps;
        uint256 spent; // USD 18 decimals (current order, with fee and tip)
        uint256 btcAmount; // 8 decimals
        uint256 avgPrice; // USD 18 decimals
        uint256 btcPrice; // USD 18 decimals (0 = oracle unavailable)
        uint256 startPrice; // BTC at order creation, USD 18 decimals (0 = no record)
        int256 pnlBps; // the order's unrealized BTC result
        string mix; // BTC / group A / group B split chosen by the wallet, e.g.: "75 / 20 / 5%"
    }

    // False positive: the drawdown (dd) from btcYearDrawdown does not go into the image; only `ok` and the price do.
    // slither-disable-next-line unused-return
    function _view(address holder) internal view returns (View memory v) {
        IMacroSwapRead core = IMacroSwapRead(macroSwap);
        uint256 usdScale = TEN ** (WAD_DECIMALS - core.stableDecimals());
        uint8 btcDec = core.getBtc().tokenDecimals;
        IMacroSwapRead.Order memory o = core.getOrder(holder);
        (bool ok, uint256 price,) = core.btcYearDrawdown();

        v.active = o.active;
        v.window = o.window;
        v.dipBps = o.dipBps;
        v.spent = o.spent * usdScale;
        v.btcPrice = ok ? price : 0;
        v.startPrice = uint256(o.refPrice) * FEED_TO_WAD;
        v.mix = _mixText(core, holder);
        uint256 bought = o.btcBought;
        if (bought == 0) return v;
        v.hasBuys = true;
        v.btcAmount = btcDec >= BTC_SHOW_DECIMALS
            ? bought / TEN ** (btcDec - BTC_SHOW_DECIMALS)
            : bought * TEN ** (BTC_SHOW_DECIMALS - btcDec);
        uint256 cost = o.btcCost * usdScale;
        v.avgPrice = (cost * TEN ** btcDec) / bought;
        if (ok) {
            uint256 value = (bought * price) / TEN ** btcDec;
            v.pnlBps = ((int256(value) - int256(cost)) * int256(BPS)) / int256(cost);
        }
    }

    // False positive: `custom` does not change the text (it shows the allocation in use, default or chosen).
    // slither-disable-next-line unused-return
    function _mixText(IMacroSwapRead core, address holder) internal view returns (string memory) {
        (uint16 b, uint16 a, uint16 g,) = core.mixOf(holder);
        return string.concat(_share(b), " / ", _share(a), " / ", _share(g), "%");
    }

    function _onchainURI(address holder) internal view returns (string memory) {
        View memory v = _view(holder);
        string memory pnl = v.hasBuys && v.btcPrice > 0 ? _pct(v.pnlBps) : unicode"—";
        string memory json = string.concat(
            '{"name":"MacroSwap Tracker ',
            _hex(holder),
            '","description":"Non-transferable record of this wallet\'s buys on MacroSwap (on-chain data of the current order). Unrealized result: does not account for sales or transfers and is not a promise of returns.","image":"data:image/svg+xml;base64,',
            _base64(bytes(_svg(holder, v, pnl))),
            '",',
            _attributes(v, pnl),
            "}"
        );
        return string.concat("data:application/json;base64,", _base64(bytes(json)));
    }

    function _attributes(View memory v, string memory pnl) internal pure returns (string memory) {
        return string.concat(
            '"attributes":[{"trait_type":"Unrealized BTC result","value":"',
            pnl,
            '"},{"trait_type":"Invested in the current order (USD)","value":"',
            _usd(v.spent, 2),
            '"},{"trait_type":"Average BTC price (USD)","value":"',
            v.hasBuys ? _usd(v.avgPrice, 0) : unicode"—",
            '"},{"trait_type":"BTC at order creation (USD)","value":"',
            v.startPrice > 0 ? _usd(v.startPrice, 0) : unicode"—",
            '"},{"trait_type":"BTC / A / B split","value":"',
            v.mix,
            '"},{"trait_type":"Source","value":"on-chain"}]'
        );
    }

    function _svg(address holder, View memory v, string memory pnl) internal pure returns (string memory) {
        string memory tone = !v.hasBuys || v.btcPrice == 0 ? "#9AA4B8" : v.pnlBps >= 0 ? "#34D399" : "#F87171";
        string memory head = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 600" font-family="Helvetica,Arial,sans-serif">',
            '<rect width="600" height="600" fill="#0A0E17"/><rect x="24" y="24" width="552" height="552" rx="28" fill="#111726" stroke="#1F2738"/>',
            '<g transform="translate(56 56) scale(1.5)"><path d="M4 25 L10.5 8 L16 19.5 L21.5 8 L28 25" stroke="#E8ECF5" stroke-width="3.2" fill="none" stroke-linecap="round" stroke-linejoin="round"/><circle cx="16" cy="19.5" r="3.4" fill="#FFB020"/></g>',
            '<text x="112" y="82" fill="#E8ECF5" font-size="24" font-weight="600">MacroSwap Tracker</text>',
            '<text x="112" y="104" fill="#9AA4B8" font-size="13">',
            _hex(holder),
            "</text>"
        );
        string memory big = string.concat(
            '<text x="56" y="178" fill="#9AA4B8" font-size="14" letter-spacing="1.5">UNREALIZED BTC RESULT</text>',
            '<text x="56" y="240" fill="',
            tone,
            '" font-size="56" font-weight="600" font-family="Menlo,monospace">',
            pnl,
            "</text>"
        );
        string memory order = v.spent == 0 && !v.active
            ? "none"
            : string.concat(v.active ? "active" : "closed", v.window == 2 ? " - ATH dip -" : v.window == 1 ? " - macro dip -" : " - short dip -", _dec(v.dipBps, 2), "%");
        // in two parts: 7 lines in a single concat would overflow the stack
        string memory rows = string.concat(
            _row(0, "Invested in the current order", _usd(v.spent, 2)),
            _row(1, "BTC bought", v.hasBuys ? _dec(v.btcAmount, BTC_SHOW_DECIMALS) : unicode"—"),
            _row(2, "Average BTC price", _avgText(v)),
            _row(3, "BTC at order creation", v.startPrice > 0 ? _usd(v.startPrice, 0) : unicode"—")
        );
        rows = string.concat(
            rows,
            _row(4, "BTC now (Chainlink)", v.btcPrice > 0 ? _usd(v.btcPrice, 0) : unicode"—"),
            _row(5, "Order", order),
            _row(6, "BTC / A / B split", v.mix)
        );
        return string.concat(
            head,
            big,
            rows,
            '<text x="56" y="548" fill="#9AA4B8" font-size="12">On-chain data of the current order &#183; non-transferable &#183; not a promise of returns</text></svg>'
        );
    }

    /// @dev Average price and how far it is below (or above) the price at creation: "$91,200 (-7.30%)".
    function _avgText(View memory v) internal pure returns (string memory) {
        if (!v.hasBuys) return unicode"—";
        if (v.startPrice == 0) return _usd(v.avgPrice, 0);
        int256 diff = ((int256(v.avgPrice) - int256(v.startPrice)) * int256(BPS)) / int256(v.startPrice);
        return string.concat(_usd(v.avgPrice, 0), " (", _pct(diff), ")");
    }

    function _row(uint256 i, string memory k, string memory val) internal pure returns (string memory) {
        string memory y = _u(ROW_Y0 + i * ROW_STEP);
        return string.concat(
            '<text x="56" y="',
            y,
            '" fill="#9AA4B8" font-size="15">',
            k,
            '</text><text x="544" y="',
            y,
            '" fill="#E8ECF5" font-size="15" text-anchor="end" font-family="Menlo,monospace">',
            val,
            "</text>"
        );
    }

    // ----------------------------------------------------------------- helpers

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len = 0;
        for (uint256 t = v; t > 0; t /= TEN) len++;
        bytes memory b = new bytes(len);
        for (; v > 0; v /= TEN) b[--len] = bytes1(uint8(ASCII_ZERO + (v % TEN)));
        return string(b);
    }

    /// @dev bps as a percentage with no unneeded decimals: 7500 -> "75", 1250 -> "12.5".
    function _share(uint256 bps) internal pure returns (string memory) {
        if (bps % PERCENT == 0) return _u(bps / PERCENT);
        return bps % TEN == 0 ? _dec(bps / TEN, 1) : _dec(bps, 2);
    }

    /// @dev Integer with a thousands separator: 78409 -> "78,409".
    function _grouped(uint256 v) internal pure returns (string memory) {
        string memory tail = "";
        for (; v >= THOUSAND; v /= THOUSAND) {
            uint256 part = v % THOUSAND;
            tail = string.concat(",", part < TEN ? "00" : part < PERCENT ? "0" : "", _u(part), tail);
        }
        return string.concat(_u(v), tail);
    }

    /// @dev Value with `d` decimals: (12345, 2) -> "123.45".
    function _dec(uint256 v, uint256 d) internal pure returns (string memory) {
        if (d == 0) return _u(v);
        uint256 unit = TEN ** d;
        string memory frac = _u(v % unit);
        while (bytes(frac).length < d) frac = string.concat("0", frac);
        return string.concat(_u(v / unit), ".", frac);
    }

    /// @dev USD with 18 decimals, shown with 0 or 2 places: "$78,409" or "$200.00".
    function _usd(uint256 v18, uint256 d) internal pure returns (string memory) {
        string memory whole = string.concat("$", _grouped(v18 / WAD));
        if (d == 0) return whole;
        uint256 cents = (v18 / CENT_WAD) % PERCENT;
        return string.concat(whole, cents < TEN ? ".0" : ".", _u(cents));
    }

    function _pct(int256 bps) internal pure returns (string memory) {
        uint256 a = uint256(bps < 0 ? -bps : bps);
        return string.concat(bps < 0 ? "-" : "+", _dec(a, 2), "%");
    }

    // False positive: 4 * ceil(len / 3) is the exact size of the base64 output (the integer division is on purpose).
    // slither-disable-next-line divide-before-multiply
    function _base64(bytes memory data) internal pure returns (string memory) {
        bytes memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint256 len = data.length;
        if (len == 0) return "";
        bytes memory out = new bytes(B64_OUT * ((len + B64_IN - 1) / B64_IN));
        uint256 j = 0;
        for (uint256 i = 0; i < len; i += B64_IN) {
            uint256 n = uint256(uint8(data[i])) << (2 * BYTE_BITS);
            if (i + 1 < len) n |= uint256(uint8(data[i + 1])) << BYTE_BITS;
            if (i + 2 < len) n |= uint256(uint8(data[i + 2]));
            out[j++] = table[(n >> B64_SHIFT_1) & B64_MASK];
            out[j++] = table[(n >> B64_SHIFT_2) & B64_MASK];
            out[j++] = i + 1 < len ? table[(n >> B64_SHIFT_3) & B64_MASK] : bytes1("=");
            out[j++] = i + 2 < len ? table[n & B64_MASK] : bytes1("=");
        }
        return string(out);
    }

    /// @dev Address as lowercase hex with 0x (the path the API receives).
    function _hex(address a) internal pure returns (string memory) {
        bytes memory s = new bytes(HEX_LEN);
        s[0] = "0";
        s[1] = "x";
        uint160 v = uint160(a);
        for (uint256 i = HEX_LEN - 1; i > 1; i--) {
            s[i] = bytes16("0123456789abcdef")[v & 0xf];
            v >>= HEX_BITS;
        }
        return string(s);
    }
}
