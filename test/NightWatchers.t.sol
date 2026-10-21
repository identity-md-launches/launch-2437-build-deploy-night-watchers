// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {NightWatchers} from "../src/NightWatchers.sol";
import {DeployNightWatchers} from "../script/Deploy.s.sol";
import {
    MockFrogs,
    MockFrogRenderer,
    MockIMD,
    MockWatchRenderer,
    MockWatchSkin,
    BrokenWatchRenderer
} from "./mocks/Mocks.sol";
import {Base64Decoder} from "./utils/Base64Decoder.sol";

/// @notice Unit tests against mocks etched at the mainnet addresses the contract hardcodes.
contract NightWatchersTest is Test {
    using Base64Decoder for string;

    address constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address constant TREASURY = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address constant BURN_EXECUTOR = 0xe29386719C155B6847aD5a4E97C6674f10ffc750;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant FROGS_ADDR = 0x55b8C762f1b86fE1D5406EdaAAE0f8ecF3688A0c;
    address constant FROG_RENDERER_ADDR = 0x4D9BfbafE31eC18E9D3066F1475e24906d155D67;
    address constant IMD_ADDR = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 constant FEE = 2e18;

    /// @dev Rarity code (0..4 -> 1,2,4,8,16 points) of frogs 1..500, decoded independently from the brief's words.
    bytes constant CODES = hex"0403030303030303030403030303030303030303030303030303020202030202020202020202020202020202040202020203"
        hex"0202020202020202020202020202020202020302020202020202030002000000010303000200030001020101010000000300"
        hex"0100040004010000010202010301040301000201010002000100010102010001000101010200000201020100000100000101"
        hex"0001010300040200010000010400000002030001000000000200000100010001020000000104000000000000000000000001"
        hex"0200030401000300010000000101000100020100000101000202000200000001010202000000000000020200000101010100"
        hex"0200020201030002010200010301000204020402000001030301030201020102000003020001030100030301000100020202"
        hex"0000000000000200020103000000020000010000000002030104000000000102000001020102000000040004010101040304"
        hex"0000010003030400000100030002030001000301000002010000010201000201010000000200010300010000030001010003"
        hex"0102010001010302000400000000030000000201010100020200010300010401020001030004000000020001010000000000"
        hex"0101010200010100000304000004000000030202000103010204000000030302010000010000010000000003030000000403";

    NightWatchers watch;
    MockFrogs frogs;
    MockFrogRenderer frogRenderer;
    MockIMD imd;
    MockWatchRenderer renderer;
    MockWatchSkin skin;

    address holder = makeAddr("holder");
    address other = makeAddr("other");

    event Forged(address indexed owner, uint256 indexed tokenId, uint8 tier, uint16 points, uint16[10] inputs);
    event Named(uint256 indexed tokenId, string name);
    event RendererSet(address renderer, address skin);

    function setUp() public {
        vm.etch(FROGS_ADDR, address(new MockFrogs()).code);
        vm.etch(FROG_RENDERER_ADDR, address(new MockFrogRenderer()).code);
        vm.etch(IMD_ADDR, address(new MockIMD()).code);
        frogs = MockFrogs(FROGS_ADDR);
        frogRenderer = MockFrogRenderer(FROG_RENDERER_ADDR);
        imd = MockIMD(IMD_ADDR);
        vm.label(FROGS_ADDR, "NIGHT FROGS");
        vm.label(FROG_RENDERER_ADDR, "FrogRenderer");
        vm.label(IMD_ADDR, "IMD");

        // Frogs 1..490 belong to the holder, 491..500 to someone else.
        for (uint256 id = 1; id <= 500; ++id) {
            frogs.mint(id <= 490 ? holder : other, id);
        }
        imd.mint(holder, 1_000e18);
        imd.mint(other, 1_000e18);

        watch = new DeployNightWatchers().deploy(OWNER, FEE);
        renderer = new MockWatchRenderer();
        skin = new MockWatchSkin();

        vm.startPrank(holder);
        frogs.setApprovalForAll(address(watch), true);
        imd.approve(address(watch), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(other);
        frogs.setApprovalForAll(address(watch), true);
        imd.approve(address(watch), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------

    function _setRenderer() internal {
        vm.prank(OWNER);
        watch.setRenderer(address(renderer), address(skin));
    }

    function _ids(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 d,
        uint256 e,
        uint256 f,
        uint256 g,
        uint256 h,
        uint256 i,
        uint256 j
    ) internal pure returns (uint256[10] memory ids) {
        ids = [a, b, c, d, e, f, g, h, i, j];
    }

    function _commons() internal pure returns (uint256[10] memory) {
        return _ids(78, 80, 81, 82, 86, 88, 90, 96, 97, 98);
    }

    function _uncommons() internal pure returns (uint256[10] memory) {
        return _ids(83, 91, 93, 94, 95, 101, 106, 109, 112, 114);
    }

    function _rares() internal pure returns (uint256[10] memory) {
        return _ids(27, 28, 29, 31, 32, 33, 34, 35, 36, 37);
    }

    function _epics() internal pure returns (uint256[10] memory) {
        return _ids(2, 3, 4, 5, 6, 7, 8, 9, 11, 12);
    }

    function _legendaries() internal pure returns (uint256[10] memory) {
        return _ids(10, 45, 103, 105, 115, 156, 163, 188, 204, 267);
    }

    function _withCaptain() internal pure returns (uint256[10] memory) {
        return _ids(1, 10, 45, 103, 105, 115, 156, 163, 188, 204);
    }

    function _expectedPoints(uint256 id) internal pure returns (uint16) {
        return uint16(1) << uint8(CODES[id - 1]);
    }

    function _count(uint8 layer, uint8 index) internal pure returns (uint16) {
        uint16[8][7] memory table = [
            [uint16(122), 78, 97, 86, 40, 77, 65535, 65535],
            [uint16(159), 120, 73, 76, 53, 19, 65535, 65535],
            [uint16(161), 98, 61, 33, 57, 65, 18, 7],
            [uint16(134), 95, 82, 67, 92, 30, 65535, 65535],
            [uint16(206), 44, 65, 35, 55, 51, 36, 8],
            [uint16(89), 100, 90, 27, 92, 38, 5, 59],
            [uint16(82), 95, 138, 69, 48, 68, 65535, 65535]
        ];
        return table[layer][index];
    }

    /// @dev Reference implementation of the forge maths, written independently of the contract.
    function _expected(uint256[10] memory ids)
        internal
        view
        returns (uint8 tier, uint16 points, uint8[7] memory traits)
    {
        uint256 word = frogs.randomWord();
        uint8[7][10] memory all;
        for (uint256 i; i < 10; ++i) {
            points += _expectedPoints(ids[i]);
            all[i] = frogRenderer.traits(ids[i], word);
        }
        for (uint8 layer; layer < 7; ++layer) {
            uint8 best = all[0][layer];
            for (uint256 i = 1; i < 10; ++i) {
                uint8 c = all[i][layer];
                if (_count(layer, c) < _count(layer, best) || (_count(layer, c) == _count(layer, best) && c < best)) {
                    best = c;
                }
            }
            traits[layer] = best;
        }
        if (points >= 128) tier = 5;
        else if (points >= 80) tier = 4;
        else if (points >= 40) tier = 3;
        else if (points >= 20) tier = 2;
        else tier = 1;
    }

    function _assertTraits(uint8[7] memory a, uint8[7] memory b) internal pure {
        for (uint256 i; i < 7; ++i) {
            assertEq(a[i], b[i], "trait mismatch");
        }
    }

    struct Balances {
        uint256 burn;
        uint256 treasury;
        uint256 holder;
    }

    function _balances() internal view returns (Balances memory b) {
        b.burn = imd.balanceOf(BURN_EXECUTOR);
        b.treasury = imd.balanceOf(TREASURY);
        b.holder = imd.balanceOf(holder);
    }

    function _toInputs(uint256[10] memory ids) internal pure returns (uint16[10] memory inputs) {
        for (uint256 i; i < 10; ++i) {
            inputs[i] = uint16(ids[i]);
        }
    }

    function _forgeAndCheck(uint256[10] memory ids, uint8 expectedTier) internal returns (uint256 tokenId) {
        (uint8 eTier, uint16 ePoints, uint8[7] memory eTraits) = _expected(ids);
        assertEq(eTier, expectedTier, "fixture tier");
        Balances memory before = _balances();
        uint256 expectedId = watch.nextId();

        vm.expectEmit(true, true, true, true, address(watch));
        emit Forged(holder, expectedId, eTier, ePoints, _toInputs(ids));
        vm.prank(holder);
        tokenId = watch.forge(ids, expectedTier);

        assertEq(tokenId, expectedId, "token id");
        assertEq(watch.ownerOf(tokenId), holder, "minted to caller");
        assertEq(watch.nextId(), expectedId + 1, "nextId");
        _checkRecord(tokenId, ids, eTier, ePoints, eTraits);
        _checkFees(before);
    }

    function _checkRecord(uint256 tokenId, uint256[10] memory ids, uint8 eTier, uint16 ePoints, uint8[7] memory eTraits)
        internal
        view
    {
        (uint8 tier, uint16 points, uint16[10] memory storedInputs, uint8[7] memory traits, uint64 forgedAt) =
            watch.forgeOf(tokenId);
        assertEq(tier, eTier, "tier");
        assertEq(points, ePoints, "points");
        assertEq(forgedAt, uint64(block.timestamp), "forgedAt");
        for (uint256 i; i < 10; ++i) {
            assertEq(storedInputs[i], uint16(ids[i]), "inputs");
            assertEq(frogs.ownerOf(ids[i]), DEAD, "frog burned to dEaD");
        }
        _assertTraits(traits, eTraits);
    }

    /// @dev Exactly FEE/2 to the BurnExecutor and the rest to the treasury, nothing kept.
    function _checkFees(Balances memory before) internal view {
        assertEq(imd.balanceOf(BURN_EXECUTOR) - before.burn, 1e18, "burn executor fee");
        assertEq(imd.balanceOf(TREASURY) - before.treasury, 1e18, "treasury fee");
        assertEq(before.holder - imd.balanceOf(holder), FEE, "holder paid fee");
        assertEq(imd.balanceOf(address(watch)), 0, "contract never holds IMD");
        assertEq(frogs.balanceOf(address(watch)), 0, "contract never holds frogs");
    }

    // ------------------------------------------------------------------------------------------------
    // Deployment and constants
    // ------------------------------------------------------------------------------------------------

    function test_deployment() public view {
        assertEq(watch.name(), "NIGHT WATCHERS");
        assertEq(watch.symbol(), "WATCH");
        assertEq(watch.owner(), OWNER);
        assertEq(watch.fee(), FEE);
        assertEq(watch.nextId(), 1);
        assertEq(watch.totalSupply(), 0);
        assertFalse(watch.captainForged());
        assertEq(address(watch.renderer()), address(0));
        assertEq(address(watch.skin()), address(0));
        assertEq(address(watch.FROGS()), FROGS_ADDR);
        assertEq(address(watch.FROG_RENDERER()), FROG_RENDERER_ADDR);
        assertEq(address(watch.IMD()), IMD_ADDR);
        assertEq(watch.BURN_EXECUTOR(), BURN_EXECUTOR);
        assertEq(watch.TREASURY(), TREASURY);
        assertTrue(watch.supportsInterface(type(IERC721).interfaceId));
        assertTrue(watch.supportsInterface(type(IERC2981).interfaceId));
    }

    function test_constructorRejectsZeroOwner() public {
        vm.expectRevert(NightWatchers.ZeroOwner.selector);
        new NightWatchers(address(0), FEE);
    }

    function test_constructorNeedsNoCodeAtDependencies() public {
        // The launch rehearses constructors on an empty chain: nothing may be called from the constructor.
        vm.etch(FROGS_ADDR, "");
        vm.etch(FROG_RENDERER_ADDR, "");
        vm.etch(IMD_ADDR, "");
        NightWatchers fresh = new NightWatchers(OWNER, 1);
        assertEq(fresh.fee(), 1);
    }

    function test_royalty() public view {
        (address receiver, uint256 amount) = watch.royaltyInfo(1, 10_000);
        assertEq(receiver, TREASURY);
        assertEq(amount, 500);
    }

    function test_pointsOfMatchesTable() public {
        uint256 legendary;
        uint256 epic;
        uint256 rare;
        uint256 uncommon;
        uint256 common;
        for (uint256 id = 1; id <= 500; ++id) {
            uint16 p = watch.pointsOf(id);
            assertEq(p, _expectedPoints(id), "points table");
            if (p == 16) legendary++;
            else if (p == 8) epic++;
            else if (p == 4) rare++;
            else if (p == 2) uncommon++;
            else if (p == 1) common++;
            else fail();
            if (id >= 2 && id <= 25) assertGe(p, 8, "#2-25 at least epic");
            if (id >= 26 && id <= 77) assertGe(p, 4, "#26-77 at least rare");
        }
        assertEq(watch.pointsOf(1), 16, "#1 is legendary");
        assertEq(legendary, 25);
        assertEq(epic, 70);
        assertEq(rare, 109);
        assertEq(uncommon, 107);
        assertEq(common, 189);
    }

    function test_pointsOfRejectsOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.InvalidFrogId.selector, 0));
        watch.pointsOf(0);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.InvalidFrogId.selector, 501));
        watch.pointsOf(501);
    }

    function test_tierFor() public view {
        assertEq(watch.tierFor(0), 1);
        assertEq(watch.tierFor(10), 1);
        assertEq(watch.tierFor(19), 1);
        assertEq(watch.tierFor(20), 2);
        assertEq(watch.tierFor(39), 2);
        assertEq(watch.tierFor(40), 3);
        assertEq(watch.tierFor(79), 3);
        assertEq(watch.tierFor(80), 4);
        assertEq(watch.tierFor(127), 4);
        assertEq(watch.tierFor(128), 5);
        assertEq(watch.tierFor(160), 5);
    }

    function test_traitCountTable() public view {
        for (uint8 layer; layer < 7; ++layer) {
            for (uint8 index; index < 8; ++index) {
                uint16 expected = _count(layer, index);
                assertEq(watch.traitCount(layer, index), expected == 65535 ? 255 : uint8(expected), "count");
            }
        }
        assertEq(watch.traitCount(7, 0), 255);
        assertEq(watch.traitCount(0, 8), 255);
    }

    function test_tierNames() public view {
        assertEq(watch.tierName(1), "Shift Lead");
        assertEq(watch.tierName(2), "Foreman");
        assertEq(watch.tierName(3), "Supervisor");
        assertEq(watch.tierName(4), "Chief");
        assertEq(watch.tierName(5), "Night Boss");
        assertEq(watch.tierName(6), "Captain");
        assertEq(watch.tierNumeral(1), "I");
        assertEq(watch.tierNumeral(2), "II");
        assertEq(watch.tierNumeral(3), "III");
        assertEq(watch.tierNumeral(4), "IV");
        assertEq(watch.tierNumeral(5), "V");
        assertEq(watch.tierNumeral(6), "C");
    }

    // ------------------------------------------------------------------------------------------------
    // setRenderer
    // ------------------------------------------------------------------------------------------------

    function test_setRendererOnlyOwner() public {
        vm.prank(holder);
        vm.expectRevert(NightWatchers.NotOwner.selector);
        watch.setRenderer(address(renderer), address(skin));
    }

    function test_setRendererRequiresCode() public {
        vm.startPrank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.NotAContract.selector, makeAddr("eoa")));
        watch.setRenderer(makeAddr("eoa"), address(skin));
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.NotAContract.selector, makeAddr("eoa")));
        watch.setRenderer(address(renderer), makeAddr("eoa"));
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.NotAContract.selector, address(0)));
        watch.setRenderer(address(0), address(skin));
        vm.stopPrank();
    }

    function test_setRendererOnce() public {
        vm.expectEmit(true, true, true, true, address(watch));
        emit RendererSet(address(renderer), address(skin));
        _setRenderer();
        assertEq(address(watch.renderer()), address(renderer));
        assertEq(address(watch.skin()), address(skin));

        MockWatchRenderer second = new MockWatchRenderer();
        vm.prank(OWNER);
        vm.expectRevert(NightWatchers.RendererAlreadySet.selector);
        watch.setRenderer(address(second), address(skin));
    }

    // ------------------------------------------------------------------------------------------------
    // forge: success per tier
    // ------------------------------------------------------------------------------------------------

    function test_forgeTier1() public {
        _setRenderer();
        _forgeAndCheck(_commons(), 1);
        assertEq(watch.totalSupply(), 1);
    }

    function test_forgeTier2() public {
        _setRenderer();
        _forgeAndCheck(_uncommons(), 2);
    }

    function test_forgeTier3() public {
        _setRenderer();
        _forgeAndCheck(_rares(), 3);
    }

    function test_forgeTier4() public {
        _setRenderer();
        _forgeAndCheck(_epics(), 4);
    }

    function test_forgeTier5() public {
        _setRenderer();
        _forgeAndCheck(_legendaries(), 5);
        assertFalse(watch.captainForged());
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        watch.ownerOf(0);
    }

    function test_forgeMinTierZeroAcceptsAnything() public {
        _setRenderer();
        vm.prank(holder);
        uint256 id = watch.forge(_commons(), 0);
        assertEq(id, 1);
    }

    function test_forgeSequentialIds() public {
        _setRenderer();
        assertEq(_forgeAndCheck(_commons(), 1), 1);
        assertEq(_forgeAndCheck(_uncommons(), 2), 2);
        assertEq(_forgeAndCheck(_rares(), 3), 3);
        assertEq(watch.totalSupply(), 3);
        assertEq(watch.balanceOf(holder), 3);
    }

    function test_forgeWithCaptainFrog() public {
        _setRenderer();
        uint256[10] memory ids = _withCaptain();
        (uint8 eTier, uint16 ePoints, uint8[7] memory eTraits) = _expected(ids);
        assertEq(eTier, 5);
        Balances memory before = _balances();
        vm.expectEmit(true, true, true, true, address(watch));
        emit Forged(holder, 1, eTier, ePoints, _toInputs(ids));
        vm.expectEmit(true, true, true, true, address(watch));
        emit Forged(holder, 0, 6, ePoints, _toInputs(ids));
        vm.prank(holder);
        uint256 tokenId = watch.forge(ids, 5);
        assertEq(tokenId, 1);
        assertEq(watch.ownerOf(1), holder);
        _checkRecord(1, ids, 5, ePoints, eTraits);
        _checkFees(before);
        assertTrue(watch.captainForged());
        assertEq(watch.ownerOf(0), holder);
        assertEq(watch.totalSupply(), 2);
        assertEq(watch.balanceOf(holder), 2);

        (uint8 tier, uint16 points, uint16[10] memory storedInputs, uint8[7] memory traits, uint64 forgedAt) =
            watch.forgeOf(0);
        assertEq(tier, 6);
        assertEq(points, ePoints);
        assertEq(forgedAt, uint64(block.timestamp));
        for (uint256 i; i < 10; ++i) {
            assertEq(storedInputs[i], uint16(ids[i]));
        }
        _assertTraits(traits, frogRenderer.traits(1, frogs.randomWord()));
        assertEq(frogs.ownerOf(1), DEAD);
    }

    function test_forgeAllFifty() public {
        _setRenderer();
        // 490 frogs owned by the holder: 49 forges of 10. Then the other's 10 make the 50th.
        for (uint256 k; k < 49; ++k) {
            uint256[10] memory ids;
            for (uint256 i; i < 10; ++i) {
                ids[i] = k * 10 + i + 1;
            }
            vm.prank(holder);
            uint256 id = watch.forge(ids, 0);
            assertEq(id, k + 1);
        }
        assertTrue(watch.captainForged());
        assertEq(watch.nextId(), 50);
        uint256[10] memory last;
        for (uint256 i; i < 10; ++i) {
            last[i] = 491 + i;
        }
        vm.prank(other);
        assertEq(watch.forge(last, 0), 50);
        assertEq(watch.totalSupply(), 51);
        assertEq(watch.nextId(), 51);
        assertEq(frogs.balanceOf(DEAD), 500);
        assertEq(imd.balanceOf(BURN_EXECUTOR), 50e18);
        assertEq(imd.balanceOf(TREASURY), 50e18);

        // The 51st forge is impossible even with frogs: sold out.
        vm.expectRevert(NightWatchers.SoldOut.selector);
        watch.preview(last);
        vm.prank(other);
        vm.expectRevert(NightWatchers.SoldOut.selector);
        watch.forge(last, 0);
    }

    // ------------------------------------------------------------------------------------------------
    // forge: reverts
    // ------------------------------------------------------------------------------------------------

    function test_forgeRevertsWithoutRenderer() public {
        vm.prank(holder);
        vm.expectRevert(NightWatchers.RendererNotSet.selector);
        watch.forge(_commons(), 0);
        vm.expectRevert(NightWatchers.RendererNotSet.selector);
        watch.preview(_commons());
    }

    function test_forgeRevertsDuplicate() public {
        _setRenderer();
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.DuplicateFrogId.selector, 78));
        watch.forge(_ids(78, 80, 81, 82, 86, 88, 90, 96, 97, 78), 0);
        // Duplicates above 255 use the second bitmap word.
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.DuplicateFrogId.selector, 300));
        watch.forge(_ids(300, 301, 302, 303, 304, 305, 306, 307, 308, 300), 0);
    }

    function test_forgeRevertsIdZero() public {
        _setRenderer();
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.InvalidFrogId.selector, 0));
        watch.forge(_ids(0, 80, 81, 82, 86, 88, 90, 96, 97, 98), 0);
    }

    function test_forgeRevertsIdAbove500() public {
        _setRenderer();
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.InvalidFrogId.selector, 501));
        watch.forge(_ids(78, 80, 81, 82, 86, 88, 90, 96, 97, 501), 0);
    }

    function test_forgeRevertsSomeoneElsesFrogEvenApproved() public {
        _setRenderer();
        // `other` owns 491 and approves the holder for it; the holder still cannot forge it.
        vm.prank(other);
        frogs.approve(holder, 491);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.NotFrogOwner.selector, 491));
        watch.forge(_ids(78, 80, 81, 82, 86, 88, 90, 96, 97, 491), 0);
        assertEq(frogs.ownerOf(491), other);
    }

    function test_forgeRevertsMinTier() public {
        _setRenderer();
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.TierBelowMinimum.selector, 1, 2));
        watch.forge(_commons(), 2);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.TierBelowMinimum.selector, 4, 5));
        watch.forge(_epics(), 5);
    }

    function test_forgeRevertsWithoutFrogApproval() public {
        _setRenderer();
        vm.startPrank(holder);
        frogs.setApprovalForAll(address(watch), false);
        vm.expectRevert(NightWatchers.FrogsNotApproved.selector);
        watch.forge(_commons(), 0);
        vm.stopPrank();
    }

    function test_forgeRevertsWithoutAllowance() public {
        _setRenderer();
        vm.startPrank(holder);
        imd.approve(address(watch), FEE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(watch), 1e18 - 1, 1e18)
        );
        watch.forge(_commons(), 0);
        vm.stopPrank();
        // Nothing moved.
        assertEq(frogs.ownerOf(78), holder);
        assertEq(watch.nextId(), 1);
    }

    function test_forgeRevertsWithoutBalance() public {
        _setRenderer();
        vm.startPrank(holder);
        imd.transfer(other, imd.balanceOf(holder) - 1e18);
        vm.expectRevert();
        watch.forge(_commons(), 0);
        vm.stopPrank();
    }

    function test_forgeIsNotCallableByAnotherHolderForYourFrogs() public {
        _setRenderer();
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.NotFrogOwner.selector, 78));
        watch.forge(_commons(), 0);
    }

    // ------------------------------------------------------------------------------------------------
    // preview and fuzz
    // ------------------------------------------------------------------------------------------------

    function test_previewMatchesReference() public {
        _setRenderer();
        uint256[10] memory ids = _withCaptain();
        (uint8 tier, uint16 points, uint8[7] memory traits) = watch.preview(ids);
        (uint8 eTier, uint16 ePoints, uint8[7] memory eTraits) = _expected(ids);
        assertEq(tier, eTier);
        assertEq(points, ePoints);
        assertEq(points, 160);
        _assertTraits(traits, eTraits);
    }

    function test_previewDoesNotCheckOwnership() public {
        _setRenderer();
        uint256[10] memory ids = _ids(491, 492, 493, 494, 495, 496, 497, 498, 499, 500);
        (uint8 tier, uint16 points,) = watch.preview(ids);
        (uint8 eTier, uint16 ePoints,) = _expected(ids);
        assertEq(tier, eTier);
        assertEq(points, ePoints);
    }

    function test_previewRejectsBadIds() public {
        _setRenderer();
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.InvalidFrogId.selector, 0));
        watch.preview(_ids(0, 2, 3, 4, 5, 6, 7, 8, 9, 10));
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.InvalidFrogId.selector, 501));
        watch.preview(_ids(501, 2, 3, 4, 5, 6, 7, 8, 9, 10));
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.DuplicateFrogId.selector, 2));
        watch.preview(_ids(2, 2, 3, 4, 5, 6, 7, 8, 9, 10));
    }

    function _distinctIds(uint256[10] memory raw) internal pure returns (uint256[10] memory ids) {
        for (uint256 i; i < 10; ++i) {
            uint256 id = bound(raw[i], 1, 500);
            bool clash = true;
            while (clash) {
                clash = false;
                for (uint256 j; j < i; ++j) {
                    if (ids[j] == id) {
                        clash = true;
                        id = id % 500 + 1;
                        break;
                    }
                }
            }
            ids[i] = id;
        }
    }

    /// @notice preview(ids) == what forge(ids) mints, and both match the reference maths.
    function testFuzz_previewEqualsForge(uint256[10] memory raw) public {
        _setRenderer();
        uint256[10] memory ids = _distinctIds(raw);
        // Make sure the holder owns every chosen frog (491..500 belong to `other`).
        for (uint256 i; i < 10; ++i) {
            if (ids[i] > 490) {
                vm.prank(other);
                frogs.transferFrom(other, holder, ids[i]);
            }
        }
        (uint8 pTier, uint16 pPoints, uint8[7] memory pTraits) = watch.preview(ids);
        (uint8 eTier, uint16 ePoints, uint8[7] memory eTraits) = _expected(ids);
        vm.prank(holder);
        uint256 tokenId = watch.forge(ids, pTier);
        (uint8 tier, uint16 points, uint16[10] memory inputs, uint8[7] memory traits,) = watch.forgeOf(tokenId);
        assertEq(tier, pTier, "tier preview==forge");
        assertEq(points, pPoints, "points preview==forge");
        _assertTraits(traits, pTraits);
        assertEq(tier, eTier, "tier reference");
        assertEq(points, ePoints, "points reference");
        _assertTraits(traits, eTraits);
        for (uint256 i; i < 10; ++i) {
            assertEq(inputs[i], uint16(ids[i]));
            assertEq(frogs.ownerOf(ids[i]), DEAD);
        }
        bool hasOne;
        for (uint256 i; i < 10; ++i) {
            if (ids[i] == 1) hasOne = true;
        }
        assertEq(watch.captainForged(), hasOne, "captain iff #1 forged");
        assertEq(watch.totalSupply(), hasOne ? 2 : 1);
    }

    function testFuzz_pointsOfNeverOutOfRange(uint256 id) public view {
        id = bound(id, 1, 500);
        uint16 p = watch.pointsOf(id);
        assertTrue(p == 1 || p == 2 || p == 4 || p == 8 || p == 16);
    }

    // ------------------------------------------------------------------------------------------------
    // setName
    // ------------------------------------------------------------------------------------------------

    function test_setName() public {
        _setRenderer();
        uint256 id = _forgeAndCheck(_legendaries(), 5);
        vm.expectEmit(true, true, true, true, address(watch));
        emit Named(id, "ZERO-SLEEP 3.0");
        vm.prank(holder);
        watch.setName(id, "ZERO-SLEEP 3.0");
        assertEq(watch.nameOf(id), "ZERO-SLEEP 3.0");
    }

    function test_setNameCaptain() public {
        _setRenderer();
        _forgeAndCheck(_withCaptain(), 5);
        vm.prank(holder);
        watch.setName(0, "CAPTAIN ZERO");
        assertEq(watch.nameOf(0), "CAPTAIN ZERO");
    }

    function test_setNameOnce() public {
        _setRenderer();
        uint256 id = _forgeAndCheck(_legendaries(), 5);
        vm.startPrank(holder);
        watch.setName(id, "FIRST");
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.AlreadyNamed.selector, id));
        watch.setName(id, "SECOND");
        vm.stopPrank();
        assertEq(watch.nameOf(id), "FIRST");
    }

    function test_setNameOnlyTokenOwner() public {
        _setRenderer();
        uint256 id = _forgeAndCheck(_legendaries(), 5);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.NotTokenOwner.selector, id));
        watch.setName(id, "THIEF");
        // Approval is not ownership.
        vm.prank(holder);
        watch.approve(other, id);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.NotTokenOwner.selector, id));
        watch.setName(id, "THIEF");
        // A transfer moves the right along with the token.
        vm.prank(holder);
        watch.transferFrom(holder, other, id);
        vm.prank(other);
        watch.setName(id, "NEW OWNER");
        assertEq(watch.nameOf(id), "NEW OWNER");
    }

    function test_setNameNonexistent() public {
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 7));
        watch.setName(7, "GHOST");
    }

    function test_setNameTierTooLow() public {
        _setRenderer();
        uint256 id = _forgeAndCheck(_epics(), 4);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.TierCannotBeNamed.selector, 4));
        watch.setName(id, "CHIEF");
        assertEq(watch.nameOf(id), "");
    }

    function test_setNameValidation() public {
        _setRenderer();
        uint256 id = _forgeAndCheck(_legendaries(), 5);
        string[9] memory bad = [
            "", " LEAD", "LEAD ", "lowercase", "ABCDEFGHIJKLMNOPQ", "UNDER_SCORE", "HASH#1", "TAB\tX", unicode"NIGHT★"
        ];
        for (uint256 i; i < bad.length; ++i) {
            assertFalse(watch.isValidName(bad[i]), bad[i]);
            vm.prank(holder);
            vm.expectRevert(NightWatchers.InvalidName.selector);
            watch.setName(id, bad[i]);
        }
        assertTrue(watch.isValidName("A"));
        assertTrue(watch.isValidName("ABCDEFGHIJKLMNOP"));
        assertTrue(watch.isValidName("A B.C-D 9"));
        assertTrue(watch.isValidName("...---"));
    }

    // ------------------------------------------------------------------------------------------------
    // tokenURI
    // ------------------------------------------------------------------------------------------------

    function _decodeTokenURI(uint256 tokenId) internal view returns (string memory json) {
        string memory uri = watch.tokenURI(tokenId);
        json = string(uri.stripPrefix("data:application/json;base64,").decode());
    }

    function _expectedImage(uint256 tokenId, string memory label) internal view returns (string memory) {
        (uint8 tier, uint16 points, uint16[10] memory inputs, uint8[7] memory traits,) = watch.forgeOf(tokenId);
        bytes memory svg = bytes(renderer.svg(tokenId, tier, traits, label, inputs, points));
        bytes memory head = new bytes(svg.length - 6);
        for (uint256 i; i < head.length; ++i) {
            head[i] = svg[i];
        }
        assertEq(string(_tail(svg)), "</svg>", "mock svg ends with </svg>");
        return string.concat(string(head), skin.layer(tokenId, tier, inputs), "</svg>");
    }

    function _tail(bytes memory b) internal pure returns (bytes memory t) {
        t = new bytes(6);
        for (uint256 i; i < 6; ++i) {
            t[i] = b[b.length - 6 + i];
        }
    }

    function test_tokenURIWatcher() public {
        _setRenderer();
        uint256 id = _forgeAndCheck(_rares(), 3);
        string memory json = _decodeTokenURI(id);
        assertEq(vm.parseJsonString(json, ".name"), "Night Watcher #1");
        assertEq(
            vm.parseJsonString(json, ".description"),
            "NIGHT FROGS Gen 2, forged from 10 NIGHT FROGS, a seat in the Night Watch. Tier III Supervisor."
        );
        string memory image = vm.parseJsonString(json, ".image");
        string memory svg = string(image.stripPrefix("data:image/svg+xml;base64,").decode());
        assertEq(svg, _expectedImage(id, "SUPERVISOR"), "image = svg minus </svg> + layer + </svg>");
        assertEq(watch.imageOf(id), svg);

        assertEq(vm.parseJsonString(json, ".attributes[0].trait_type"), "Tier");
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "III Supervisor");
        assertEq(vm.parseJsonString(json, ".attributes[1].trait_type"), "Forge Points");
        assertEq(vm.parseJsonUint(json, ".attributes[1].value"), 40);
        assertEq(vm.parseJsonString(json, ".attributes[2].trait_type"), "Forged From");
        assertEq(vm.parseJsonString(json, ".attributes[2].value"), "#27 #28 #29 #31 #32 #33 #34 #35 #36 #37");
        string[7] memory layers = ["Background", "Body", "Skin", "Mouth", "Eyes", "Headwear", "Accessory"];
        (,,, uint8[7] memory traits,) = watch.forgeOf(id);
        for (uint256 l; l < 7; ++l) {
            string memory path = string.concat(".attributes[", vm.toString(l + 3), "]");
            assertEq(vm.parseJsonString(json, string.concat(path, ".trait_type")), layers[l]);
            assertEq(
                vm.parseJsonString(json, string.concat(path, ".value")), frogRenderer.traitName(uint8(l), traits[l])
            );
        }
        // No Name attribute when unnamed: exactly 10 attributes.
        assertEq(vm.parseJsonString(json, ".attributes[9].trait_type"), "Accessory");
        assertTrue(vm.keyExistsJson(json, ".attributes[9]"));
        assertFalse(vm.keyExistsJson(json, ".attributes[10]"));
    }

    function test_tokenURIUsesNameAsLabelAndAttribute() public {
        _setRenderer();
        uint256 id = _forgeAndCheck(_legendaries(), 5);
        string memory before = _decodeTokenURI(id);
        string memory imageBefore =
            string(vm.parseJsonString(before, ".image").stripPrefix("data:image/svg+xml;base64,").decode());
        assertEq(imageBefore, _expectedImage(id, "NIGHT BOSS"));
        assertEq(vm.parseJsonString(before, ".attributes[0].value"), "V Night Boss");

        vm.prank(holder);
        watch.setName(id, "MOON UNIT 9");
        string memory json = _decodeTokenURI(id);
        string memory image =
            string(vm.parseJsonString(json, ".image").stripPrefix("data:image/svg+xml;base64,").decode());
        assertEq(image, _expectedImage(id, "MOON UNIT 9"));
        assertEq(vm.parseJsonString(json, ".attributes[10].trait_type"), "Name");
        assertEq(vm.parseJsonString(json, ".attributes[10].value"), "MOON UNIT 9");
    }

    function test_tokenURICaptain() public {
        _setRenderer();
        _forgeAndCheck(_withCaptain(), 5);
        string memory json = _decodeTokenURI(0);
        assertEq(vm.parseJsonString(json, ".name"), "The Captain");
        assertEq(
            vm.parseJsonString(json, ".description"),
            "The one Night Watcher forged from NIGHT FROG #1, the Zero-Sleep Captain. Tier C Captain."
        );
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "C Captain");
        assertEq(vm.parseJsonUint(json, ".attributes[1].value"), 160);
        assertEq(vm.parseJsonString(json, ".attributes[2].value"), "#1 #10 #45 #103 #105 #115 #156 #163 #188 #204");
        string memory image =
            string(vm.parseJsonString(json, ".image").stripPrefix("data:image/svg+xml;base64,").decode());
        assertEq(image, _expectedImage(0, "CAPTAIN"));
        // The Captain carries #1's own traits, not the forge's rarest-of-layer traits.
        uint8[7] memory one = frogRenderer.traits(1, frogs.randomWord());
        for (uint256 l; l < 7; ++l) {
            string memory path = string.concat(".attributes[", vm.toString(l + 3), "].value");
            assertEq(vm.parseJsonString(json, path), frogRenderer.traitName(uint8(l), one[l]));
        }
        // Token 1 from the same forge is a normal Night Watcher.
        string memory json1 = _decodeTokenURI(1);
        assertEq(vm.parseJsonString(json1, ".name"), "Night Watcher #1");
        assertEq(vm.parseJsonString(json1, ".attributes[0].value"), "V Night Boss");
    }

    function test_tokenURIRevertsForNonexistent() public {
        _setRenderer();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        watch.tokenURI(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        watch.tokenURI(0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        watch.forgeOf(0);
    }

    function test_imageWithShortSvgIsLenient() public {
        BrokenWatchRenderer broken = new BrokenWatchRenderer();
        vm.prank(OWNER);
        watch.setRenderer(address(broken), address(skin));
        vm.prank(holder);
        uint256 id = watch.forge(_commons(), 0);
        (uint8 tier,, uint16[10] memory inputs,,) = watch.forgeOf(id);
        // "<svg" is shorter than 6 bytes: kept whole, then the layer, then the closing tag.
        assertEq(watch.imageOf(id), string.concat("<svg", skin.layer(id, tier, inputs), "</svg>"));
    }

    // ------------------------------------------------------------------------------------------------
    // Transfers are plain ERC-721
    // ------------------------------------------------------------------------------------------------

    function test_plainTransfers() public {
        _setRenderer();
        uint256 id = _forgeAndCheck(_commons(), 1);
        vm.prank(holder);
        watch.transferFrom(holder, other, id);
        assertEq(watch.ownerOf(id), other);
        vm.prank(other);
        watch.safeTransferFrom(other, holder, id);
        assertEq(watch.ownerOf(id), holder);
        assertEq(watch.totalSupply(), 1);
    }
}
