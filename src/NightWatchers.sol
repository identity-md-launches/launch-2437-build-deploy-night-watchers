// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {INightFrogs, INightFrogsRenderer} from "./interfaces/INightFrogs.sol";
import {INightWatchRenderer, INightWatchSkin} from "./interfaces/INightWatchArt.sol";

/// @title NIGHT WATCHERS (WATCH), NIGHT FROGS Gen 2
/// @notice A holder forges exactly 10 NIGHT FROGS into one Night Watcher. The 10 frogs are sent to
///         0x…dEaD forever, a 2 IMD fee is split between IMD's BurnExecutor and the treasury, and the
///         Night Watcher inherits the rarest trait of each layer among its inputs. The forge that burns
///         NIGHT FROG #1 also mints The Captain, token 0. Fully onchain: metadata and image are built from
///         the renderer and skin contracts the owner sets once.
/// @dev Not upgradeable, not pausable. The owner's only power is `setRenderer`, exactly once.
contract NightWatchers is ERC721, ERC2981, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    // ------------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------------

    /// @notice NIGHT FROGS, the Gen 1 collection (500 frogs).
    INightFrogs public constant FROGS = INightFrogs(0x55b8C762f1b86fE1D5406EdaAAE0f8ecF3688A0c);
    /// @notice The NIGHT FROGS renderer: trait indices and trait names.
    INightFrogsRenderer public constant FROG_RENDERER = INightFrogsRenderer(0x4D9BfbafE31eC18E9D3066F1475e24906d155D67);
    /// @notice IMD, the fee token.
    IERC20 public constant IMD = IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    /// @notice IMD's BurnExecutor: receives FEE / 2 of every forge.
    address public constant BURN_EXECUTOR = 0xe29386719C155B6847aD5a4E97C6674f10ffc750;
    /// @notice Receives FEE - FEE / 2 of every forge and the 5% ERC-2981 royalty.
    address public constant TREASURY = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    /// @notice Where the forged frogs go, forever.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice ERC-2981 royalty in basis points (5%).
    uint96 public constant ROYALTY_BPS = 500;
    /// @notice Number of frogs in Gen 1.
    uint256 public constant FROG_COUNT = 500;
    /// @notice Frogs per forge.
    uint256 public constant INPUTS = 10;
    /// @notice Night Watchers (tokens 1..50) that can ever exist. The Captain (token 0) is on top.
    uint256 public constant MAX_WATCHERS = 50;
    /// @notice The Captain's token id.
    uint256 public constant CAPTAIN_ID = 0;
    /// @notice The frog whose forge also mints The Captain.
    uint256 public constant CAPTAIN_FROG = 1;
    /// @notice Tier of The Captain.
    uint8 public constant CAPTAIN_TIER = 6;
    /// @notice Number of trait layers.
    uint256 public constant LAYERS = 7;
    /// @notice Longest name `setName` accepts (bytes).
    uint256 public constant MAX_NAME_LENGTH = 16;

    /// @dev Rarity codes of the 500 frogs, 3 bits each, 85 per word: code 0..4 -> 1, 2, 4, 8, 16 points.
    uint256 private constant WORD0 = 0x364008349249349249249249249a49449249249249a49b6db6db6db6e36db6dc;
    uint256 private constant WORD1 = 0x10d002100850324120100a2804490414482102502e1652201820218009288610;
    uint256 private constant WORD2 = 0x1482049202400002448010481201408240043063088000000021002208202000;
    uint256 private constant WORD3 = 0x8a20220010b40004040065040000248105b05909808a2996c80a2881642283;
    uint256 private constant WORD4 = 0x24092800c00204c90516090c021908004a05100a00b0434182046c1023849820;
    uint256 private constant WORD5 = 0xe001b00020100a6c01116424c01008c02422480002420040c84610c8;

    /// @dev Gen 1 trait counts, one byte per index, 8 bytes per layer (0xff pads a layer with fewer indices):
    ///      [[122,78,97,86,40,77],[159,120,73,76,53,19],[161,98,61,33,57,65,18,7],[134,95,82,67,92,30],
    ///       [206,44,65,35,55,51,36,8],[89,100,90,27,92,38,5,59],[82,95,138,69,48,68]].
    bytes private constant COUNT = hex"7a4e6156284dffff" hex"9f78494c3513ffff" hex"a1623d2139411207"
        hex"865f52435c1effff" hex"ce2c412337332408" hex"59645a1b5c26053b" hex"525f8a453044ffff";

    // ------------------------------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------------------------------

    /// @notice What a forge produced.
    struct ForgeRecord {
        uint8 tier;
        uint16 points;
        uint64 forgedAt;
        uint16[10] inputs;
        uint8[7] traits;
    }

    /// @notice The only privileged address. Its one power is `setRenderer`, once.
    address public immutable owner;
    /// @notice The forge fee in IMD (wei), e.g. 2e18.
    uint256 private immutable FEE;

    /// @notice The Night Watcher renderer, set once by the owner.
    INightWatchRenderer public renderer;
    /// @notice The Night Watcher skin, set once by the owner.
    INightWatchSkin public skin;
    /// @notice Token id of the next Night Watcher (1, 2, 3, ...).
    uint256 public nextId = 1;
    /// @notice True once NIGHT FROG #1 has been forged and The Captain minted.
    bool public captainForged;

    mapping(uint256 tokenId => ForgeRecord) private _forges;
    mapping(uint256 tokenId => string) private _names;

    // ------------------------------------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------------------------------------

    event Forged(address indexed owner, uint256 indexed tokenId, uint8 tier, uint16 points, uint16[10] inputs);
    event Named(uint256 indexed tokenId, string name);
    event RendererSet(address renderer, address skin);

    error ZeroOwner();
    error NotOwner();
    error RendererAlreadySet();
    error RendererNotSet();
    error NotAContract(address target);
    error SoldOut();
    error InvalidFrogId(uint256 id);
    error DuplicateFrogId(uint256 id);
    error NotFrogOwner(uint256 id);
    error FrogsNotApproved();
    error TierBelowMinimum(uint8 tier, uint8 minTier);
    error NotTokenOwner(uint256 tokenId);
    error TierCannotBeNamed(uint8 tier);
    error AlreadyNamed(uint256 tokenId);
    error InvalidName();

    // ------------------------------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------------------------------

    /// @param owner_ The owner (may call `setRenderer` once). Never the deployer by default.
    /// @param fee_ The forge fee in IMD wei (2e18 at launch).
    constructor(address owner_, uint256 fee_) ERC721("NIGHT WATCHERS", "WATCH") {
        if (owner_ == address(0)) revert ZeroOwner();
        owner = owner_;
        FEE = fee_;
        _setDefaultRoyalty(TREASURY, ROYALTY_BPS);
    }

    // ------------------------------------------------------------------------------------------------
    // Owner: setRenderer, once
    // ------------------------------------------------------------------------------------------------

    /// @notice Sets the Night Watcher renderer and skin. Owner only, exactly once; both must have code.
    function setRenderer(address r, address skin_) external {
        if (msg.sender != owner) revert NotOwner();
        if (address(renderer) != address(0)) revert RendererAlreadySet();
        if (r.code.length == 0) revert NotAContract(r);
        if (skin_.code.length == 0) revert NotAContract(skin_);
        renderer = INightWatchRenderer(r);
        skin = INightWatchSkin(skin_);
        emit RendererSet(r, skin_);
    }

    // ------------------------------------------------------------------------------------------------
    // Forge
    // ------------------------------------------------------------------------------------------------

    /// @notice Forges 10 NIGHT FROGS owned by the caller into one Night Watcher.
    /// @dev Requires `FROGS.setApprovalForAll(this, true)` and an IMD allowance of at least `fee()`.
    ///      The frogs go to 0x…dEaD; FEE/2 IMD goes to the BurnExecutor and the rest to the treasury.
    ///      Checks, effects (mint and records), then interactions (frog and IMD transfers).
    /// @param ids 10 distinct frog ids in 1..500, each owned by the caller.
    /// @param minTier Reverts if the resulting tier is below this (0 or 1 accepts any tier).
    /// @return tokenId The new Night Watcher's id. If `ids` include #1, The Captain (token 0) is minted too.
    function forge(uint256[10] calldata ids, uint8 minTier) external nonReentrant returns (uint256 tokenId) {
        // Checks.
        (uint8 tier, uint16 points, uint8[7] memory traits) = _preview(ids);
        if (tier < minTier) revert TierBelowMinimum(tier, minTier);
        if (!FROGS.isApprovedForAll(msg.sender, address(this))) revert FrogsNotApproved();
        uint16[10] memory inputs;
        bool hasCaptainFrog;
        for (uint256 i; i < INPUTS; ++i) {
            uint256 id = ids[i];
            if (FROGS.ownerOf(id) != msg.sender) revert NotFrogOwner(id);
            inputs[i] = uint16(id);
            if (id == CAPTAIN_FROG) hasCaptainFrog = true;
        }

        // Effects.
        tokenId = nextId;
        nextId = tokenId + 1;
        _record(tokenId, tier, points, inputs, traits);
        _mint(msg.sender, tokenId);
        emit Forged(msg.sender, tokenId, tier, points, inputs);
        if (hasCaptainFrog) {
            captainForged = true;
            uint8[7] memory captainTraits = FROG_RENDERER.traits(CAPTAIN_FROG, FROGS.randomWord());
            _record(CAPTAIN_ID, CAPTAIN_TIER, points, inputs, captainTraits);
            _mint(msg.sender, CAPTAIN_ID);
            emit Forged(msg.sender, CAPTAIN_ID, CAPTAIN_TIER, points, inputs);
        }

        // Interactions.
        for (uint256 i; i < INPUTS; ++i) {
            FROGS.transferFrom(msg.sender, DEAD, ids[i]);
        }
        uint256 half = FEE / 2;
        IMD.safeTransferFrom(msg.sender, BURN_EXECUTOR, half);
        IMD.safeTransferFrom(msg.sender, TREASURY, FEE - half);
    }

    /// @notice What `forge(ids, 0)` would produce, with every check except ownership and approvals.
    function preview(uint256[10] calldata ids)
        external
        view
        returns (uint8 tier, uint16 points, uint8[7] memory traits)
    {
        return _preview(ids);
    }

    function _preview(uint256[10] calldata ids)
        internal
        view
        returns (uint8 tier, uint16 points, uint8[7] memory traits)
    {
        if (address(renderer) == address(0)) revert RendererNotSet();
        if (nextId > MAX_WATCHERS) revert SoldOut();
        uint256 seen;
        uint256 seenHigh;
        uint256 word = FROGS.randomWord();
        uint8[7] memory best;
        uint256 total;
        for (uint256 i; i < INPUTS; ++i) {
            uint256 id = ids[i];
            if (id == 0 || id > FROG_COUNT) revert InvalidFrogId(id);
            if (id < 256) {
                uint256 bit = 1 << id;
                if (seen & bit != 0) revert DuplicateFrogId(id);
                seen |= bit;
            } else {
                uint256 bit = 1 << (id - 256);
                if (seenHigh & bit != 0) revert DuplicateFrogId(id);
                seenHigh |= bit;
            }
            total += pointsOf(id);
            uint8[7] memory t = FROG_RENDERER.traits(id, word);
            if (i == 0) {
                best = t;
                continue;
            }
            for (uint8 layer; layer < LAYERS; ++layer) {
                uint8 candidate = t[layer];
                uint8 current = best[layer];
                uint8 cc = traitCount(layer, candidate);
                uint8 bc = traitCount(layer, current);
                if (cc < bc || (cc == bc && candidate < current)) best[layer] = candidate;
            }
        }
        points = uint16(total);
        tier = tierFor(points);
        traits = best;
    }

    function _record(uint256 tokenId, uint8 tier, uint16 points, uint16[10] memory inputs, uint8[7] memory traits)
        internal
    {
        ForgeRecord storage f = _forges[tokenId];
        f.tier = tier;
        f.points = points;
        f.forgedAt = uint64(block.timestamp);
        f.inputs = inputs;
        f.traits = traits;
    }

    // ------------------------------------------------------------------------------------------------
    // Names
    // ------------------------------------------------------------------------------------------------

    /// @notice Names a tier 5 or 6 token, once. 1-16 chars of A-Z, 0-9, space, '.' and '-', no leading or
    ///         trailing space. Token owner only.
    function setName(uint256 tokenId, string calldata name_) external {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);
        uint8 tier = _forges[tokenId].tier;
        if (tier < 5) revert TierCannotBeNamed(tier);
        if (bytes(_names[tokenId]).length != 0) revert AlreadyNamed(tokenId);
        if (!isValidName(name_)) revert InvalidName();
        _names[tokenId] = name_;
        emit Named(tokenId, name_);
    }

    /// @notice The name of a token, or "" if unset.
    function nameOf(uint256 tokenId) external view returns (string memory) {
        return _names[tokenId];
    }

    /// @notice Whether `name_` is acceptable to `setName`.
    function isValidName(string calldata name_) public pure returns (bool) {
        bytes calldata b = bytes(name_);
        uint256 len = b.length;
        if (len == 0 || len > MAX_NAME_LENGTH) return false;
        if (b[0] == 0x20 || b[len - 1] == 0x20) return false;
        for (uint256 i; i < len; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= 0x41 && c <= 0x5a) // A-Z
                || (c >= 0x30 && c <= 0x39) // 0-9
                || c == 0x20 || c == 0x2e || c == 0x2d; // space . -
            if (!ok) return false;
        }
        return true;
    }

    // ------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------

    /// @notice The forge fee in IMD wei.
    function fee() external view returns (uint256) {
        return FEE;
    }

    /// @notice Tokens minted so far (nothing can be burned).
    function totalSupply() external view returns (uint256) {
        return nextId - 1 + (captainForged ? 1 : 0);
    }

    /// @notice The forge record of a minted token.
    function forgeOf(uint256 tokenId)
        external
        view
        returns (uint8 tier, uint16 points, uint16[10] memory inputs, uint8[7] memory traits, uint64 forgedAt)
    {
        _requireOwned(tokenId);
        ForgeRecord storage f = _forges[tokenId];
        return (f.tier, f.points, f.inputs, f.traits, f.forgedAt);
    }

    /// @notice Rarity points of a frog: Legendary 16, Epic 8, Rare 4, Uncommon 2, Common 1.
    function pointsOf(uint256 frogId) public pure returns (uint16) {
        if (frogId == 0 || frogId > FROG_COUNT) revert InvalidFrogId(frogId);
        uint256 index = frogId - 1;
        uint256 word = _word(index / 85);
        uint256 code = (word >> ((index % 85) * 3)) & 7;
        if (code > 4) revert InvalidFrogId(frogId);
        return uint16(1) << uint16(code);
    }

    /// @notice Tier for a points total: 5 if >= 128, 4 if >= 80, 3 if >= 40, 2 if >= 20, else 1.
    function tierFor(uint16 points) public pure returns (uint8) {
        if (points >= 128) return 5;
        if (points >= 80) return 4;
        if (points >= 40) return 3;
        if (points >= 20) return 2;
        return 1;
    }

    /// @notice Gen 1 count of trait `index` on `layer` (255 for an index the layer does not have).
    function traitCount(uint8 layer, uint8 index) public pure returns (uint8) {
        if (layer >= LAYERS || index >= 8) return 255;
        return uint8(COUNT[uint256(layer) * 8 + index]);
    }

    /// @notice Tier name: I Shift Lead, II Foreman, III Supervisor, IV Chief, V Night Boss, C Captain.
    function tierName(uint8 tier) public pure returns (string memory) {
        if (tier == 1) return "Shift Lead";
        if (tier == 2) return "Foreman";
        if (tier == 3) return "Supervisor";
        if (tier == 4) return "Chief";
        if (tier == 5) return "Night Boss";
        if (tier == CAPTAIN_TIER) return "Captain";
        return "";
    }

    /// @notice Tier numeral: I, II, III, IV, V, C.
    function tierNumeral(uint8 tier) public pure returns (string memory) {
        if (tier == 1) return "I";
        if (tier == 2) return "II";
        if (tier == 3) return "III";
        if (tier == 4) return "IV";
        if (tier == 5) return "V";
        if (tier == CAPTAIN_TIER) return "C";
        return "";
    }

    function _tierLabel(uint8 tier) internal pure returns (string memory) {
        if (tier == 1) return "SHIFT LEAD";
        if (tier == 2) return "FOREMAN";
        if (tier == 3) return "SUPERVISOR";
        if (tier == 4) return "CHIEF";
        if (tier == 5) return "NIGHT BOSS";
        if (tier == CAPTAIN_TIER) return "CAPTAIN";
        return "";
    }

    // ------------------------------------------------------------------------------------------------
    // Metadata
    // ------------------------------------------------------------------------------------------------

    /// @notice The image SVG: the renderer's svg with the skin layer spliced in before `</svg>`.
    function imageOf(uint256 tokenId) public view returns (string memory) {
        _requireOwned(tokenId);
        ForgeRecord storage f = _forges[tokenId];
        uint8 tier = f.tier;
        uint16[10] memory inputs = f.inputs;
        string memory name_ = _names[tokenId];
        string memory label = bytes(name_).length != 0 ? name_ : _tierLabel(tier);
        bytes memory svg = bytes(renderer.svg(tokenId, tier, f.traits, label, inputs, f.points));
        string memory layer = skin.layer(tokenId, tier, inputs);
        uint256 keep = svg.length >= 6 ? svg.length - 6 : svg.length;
        assembly ("memory-safe") {
            mstore(svg, keep)
        }
        return string.concat(string(svg), layer, "</svg>");
    }

    /// @inheritdoc ERC721
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        ForgeRecord storage f = _forges[tokenId];
        string memory image = imageOf(tokenId);
        string memory json = string.concat(
            '{"name":"',
            _tokenName(tokenId),
            '","description":"',
            _description(f.tier),
            '","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(image)),
            '","attributes":',
            _attributes(tokenId, f),
            "}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _tokenName(uint256 tokenId) internal pure returns (string memory) {
        if (tokenId == CAPTAIN_ID) return "The Captain";
        return string.concat("Night Watcher #", tokenId.toString());
    }

    function _description(uint8 tier) internal pure returns (string memory) {
        if (tier == CAPTAIN_TIER) {
            return "The one Night Watcher forged from NIGHT FROG #1, the Zero-Sleep Captain. Tier C Captain.";
        }
        return string.concat(
            "NIGHT FROGS Gen 2, forged from 10 NIGHT FROGS, a seat in the Night Watch. Tier ",
            tierNumeral(tier),
            " ",
            tierName(tier),
            "."
        );
    }

    function _attributes(uint256 tokenId, ForgeRecord storage f) internal view returns (string memory) {
        uint8 tier = f.tier;
        string memory from;
        for (uint256 i; i < INPUTS; ++i) {
            from = string.concat(from, i == 0 ? "#" : " #", uint256(f.inputs[i]).toString());
        }
        string memory out = string.concat(
            '[{"trait_type":"Tier","value":"',
            tierNumeral(tier),
            " ",
            tierName(tier),
            '"},{"trait_type":"Forge Points","display_type":"number","value":',
            uint256(f.points).toString(),
            '},{"trait_type":"Forged From","value":"',
            from,
            '"}'
        );
        string[7] memory layers = ["Background", "Body", "Skin", "Mouth", "Eyes", "Headwear", "Accessory"];
        for (uint8 layer; layer < LAYERS; ++layer) {
            out = string.concat(
                out,
                ',{"trait_type":"',
                layers[layer],
                '","value":"',
                FROG_RENDERER.traitName(layer, f.traits[layer]),
                '"}'
            );
        }
        string memory name_ = _names[tokenId];
        if (bytes(name_).length != 0) {
            out = string.concat(out, ',{"trait_type":"Name","value":"', name_, '"}');
        }
        return string.concat(out, "]");
    }

    // ------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------

    function _word(uint256 i) internal pure returns (uint256) {
        if (i == 0) return WORD0;
        if (i == 1) return WORD1;
        if (i == 2) return WORD2;
        if (i == 3) return WORD3;
        if (i == 4) return WORD4;
        return WORD5;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
