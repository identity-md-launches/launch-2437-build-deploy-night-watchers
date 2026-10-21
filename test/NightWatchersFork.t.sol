// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {NightWatchers} from "../src/NightWatchers.sol";
import {INightFrogs, INightFrogsRenderer} from "../src/interfaces/INightFrogs.sol";
import {DeployNightWatchers} from "../script/Deploy.s.sol";
import {MockWatchRenderer, MockWatchSkin} from "./mocks/Mocks.sol";
import {Base64Decoder} from "./utils/Base64Decoder.sol";

/// @notice Mainnet-fork tests against the real NIGHT FROGS, its renderer and IMD, with impersonated holders.
///         The fork is pinned to a block. When no RPC is reachable (the offline verifier) every test here is
///         skipped; the unit suite in NightWatchers.t.sol covers the same behaviour against mocks.
contract NightWatchersForkTest is Test {
    using Base64Decoder for string;

    uint256 constant BLOCK = 26_244_100;

    address constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address constant TREASURY = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address constant BURN_EXECUTOR = 0xe29386719C155B6847aD5a4E97C6674f10ffc750;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    INightFrogs constant FROGS = INightFrogs(0x55b8C762f1b86fE1D5406EdaAAE0f8ecF3688A0c);
    IERC721 constant FROGS721 = IERC721(0x55b8C762f1b86fE1D5406EdaAAE0f8ecF3688A0c);
    INightFrogsRenderer constant FROG_RENDERER = INightFrogsRenderer(0x4D9BfbafE31eC18E9D3066F1475e24906d155D67);
    IERC20 constant IMD = IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    uint256 constant FEE = 2e18;

    bool forked;
    NightWatchers watch;
    MockWatchRenderer renderer;
    MockWatchSkin skin;

    function setUp() public {
        try vm.createSelectFork("mainnet", BLOCK) returns (uint256) {
            forked = true;
        } catch {
            forked = false;
            return;
        }
        watch = new DeployNightWatchers().deploy(OWNER, FEE);
        renderer = new MockWatchRenderer();
        skin = new MockWatchSkin();
        vm.prank(OWNER);
        watch.setRenderer(address(renderer), address(skin));
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------

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

    /// @dev The real holder of `ids[0]` is impersonated; the other frogs are moved to them by impersonating
    ///      their real holders, so one address owns all ten. Returns the holder, funded and approved.
    function _gather(uint256[10] memory ids) internal returns (address holder) {
        holder = FROGS.ownerOf(ids[0]);
        for (uint256 i; i < 10; ++i) {
            address from = FROGS.ownerOf(ids[i]);
            if (from != holder) {
                vm.prank(from);
                FROGS.transferFrom(from, holder, ids[i]);
            }
        }
        deal(address(IMD), holder, 100e18);
        vm.startPrank(holder);
        FROGS721.setApprovalForAll(address(watch), true);
        IMD.approve(address(watch), type(uint256).max);
        vm.stopPrank();
    }

    struct Balances {
        uint256 burn;
        uint256 treasury;
        uint256 holder;
    }

    function _balances(address holder) internal view returns (Balances memory b) {
        b.burn = IMD.balanceOf(BURN_EXECUTOR);
        b.treasury = IMD.balanceOf(TREASURY);
        b.holder = IMD.balanceOf(holder);
    }

    function _forgeAndCheck(uint256[10] memory ids, uint8 expectedTier) internal returns (address holder, uint256 id) {
        holder = _gather(ids);
        (uint8 pTier, uint16 pPoints, uint8[7] memory pTraits) = watch.preview(ids);
        assertEq(pTier, expectedTier, "fixture tier");
        Balances memory before = _balances(holder);
        uint256 expectedId = watch.nextId();

        vm.prank(holder);
        id = watch.forge(ids, expectedTier);

        assertEq(id, expectedId, "token id");
        assertEq(watch.ownerOf(id), holder, "minted to the holder");
        _checkRecord(id, ids, expectedTier, pPoints, pTraits);
        _checkFees(holder, before);
    }

    function _checkRecord(uint256 id, uint256[10] memory ids, uint8 eTier, uint16 ePoints, uint8[7] memory eTraits)
        internal
        view
    {
        (uint8 tier, uint16 points, uint16[10] memory inputs, uint8[7] memory traits, uint64 forgedAt) =
            watch.forgeOf(id);
        assertEq(tier, eTier, "tier");
        assertEq(points, ePoints, "points == preview");
        assertEq(forgedAt, uint64(block.timestamp));
        for (uint256 i; i < 10; ++i) {
            assertEq(inputs[i], uint16(ids[i]));
            assertEq(FROGS.ownerOf(ids[i]), DEAD, "frog at dEaD");
        }
        for (uint256 l; l < 7; ++l) {
            assertEq(traits[l], eTraits[l], "traits == preview");
        }
    }

    function _checkFees(address holder, Balances memory before) internal view {
        assertEq(IMD.balanceOf(BURN_EXECUTOR) - before.burn, 1e18, "exactly 1 IMD to the BurnExecutor");
        if (holder == TREASURY) {
            // The holder of #1 at the pinned block is the treasury itself: it pays 2 IMD and gets 1 back.
            assertEq(before.treasury - IMD.balanceOf(TREASURY), 1e18, "treasury paid 2 IMD and received 1");
        } else {
            assertEq(IMD.balanceOf(TREASURY) - before.treasury, 1e18, "exactly 1 IMD to the treasury");
            assertEq(before.holder - IMD.balanceOf(holder), 2e18, "holder paid 2 IMD");
        }
        assertEq(IMD.balanceOf(address(watch)), 0, "never holds IMD");
        assertEq(FROGS721.balanceOf(address(watch)), 0, "never holds a frog");
    }

    // ------------------------------------------------------------------------------------------------
    // Source contracts are what the brief says
    // ------------------------------------------------------------------------------------------------

    function testFork_sourceContracts() public onlyFork {
        assertEq(FROGS.ownerOf(1), OWNER, "#1 is held by the owner at the pinned block");
        assertGt(FROGS.randomWord(), 0, "revealed");
        uint8[7] memory one = FROG_RENDERER.traits(1, FROGS.randomWord());
        assertEq(FROG_RENDERER.traitName(0, one[0]), "Genesis Sunburst");
        assertEq(FROG_RENDERER.traitName(1, one[1]), "Gold Tracksuit");
        assertEq(FROG_RENDERER.traitName(2, one[2]), "Chrome");
        assertEq(FROG_RENDERER.traitName(5, one[5]), "Gold Crown");
        assertGt(BURN_EXECUTOR.code.length, 0, "BurnExecutor has code");
        assertEq(address(watch.FROGS()), address(FROGS));
        assertEq(address(watch.FROG_RENDERER()), address(FROG_RENDERER));
        assertEq(address(watch.IMD()), address(IMD));
    }

    // ------------------------------------------------------------------------------------------------
    // Every tier with an impersonated holder
    // ------------------------------------------------------------------------------------------------

    function testFork_tier1() public onlyFork {
        _forgeAndCheck(_ids(78, 80, 81, 82, 86, 88, 90, 96, 97, 98), 1);
    }

    function testFork_tier2() public onlyFork {
        _forgeAndCheck(_ids(83, 91, 93, 94, 95, 101, 106, 109, 112, 114), 2);
    }

    function testFork_tier3() public onlyFork {
        _forgeAndCheck(_ids(27, 28, 29, 31, 32, 33, 34, 35, 36, 37), 3);
    }

    function testFork_tier4() public onlyFork {
        _forgeAndCheck(_ids(2, 3, 4, 5, 6, 7, 8, 9, 11, 12), 4);
    }

    function testFork_tier5() public onlyFork {
        (, uint256 id) = _forgeAndCheck(_ids(10, 45, 103, 105, 115, 156, 163, 188, 204, 267), 5);
        (, uint16 points,,,) = watch.forgeOf(id);
        assertEq(points, 160);
        assertFalse(watch.captainForged());
        assertEq(watch.totalSupply(), 1);
    }

    function testFork_captain() public onlyFork {
        uint256[10] memory ids = _ids(1, 10, 45, 103, 105, 115, 156, 163, 188, 204);
        (address holder, uint256 id) = _forgeAndCheck(ids, 5);
        assertEq(id, 1);
        assertTrue(watch.captainForged());
        assertEq(watch.ownerOf(0), holder);
        assertEq(watch.totalSupply(), 2);
        (uint8 tier, uint16 points, uint16[10] memory inputs, uint8[7] memory traits,) = watch.forgeOf(0);
        assertEq(tier, 6);
        assertEq(points, 160);
        uint8[7] memory one = FROG_RENDERER.traits(1, FROGS.randomWord());
        for (uint256 i; i < 7; ++i) {
            assertEq(traits[i], one[i], "captain has #1's traits");
        }
        for (uint256 i; i < 10; ++i) {
            assertEq(inputs[i], uint16(ids[i]));
        }

        // The Captain's metadata names #1's real traits.
        string memory json = string(watch.tokenURI(0).stripPrefix("data:application/json;base64,").decode());
        assertEq(vm.parseJsonString(json, ".name"), "The Captain");
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "C Captain");
        assertEq(vm.parseJsonUint(json, ".attributes[1].value"), 160);
        assertEq(vm.parseJsonString(json, ".attributes[3].trait_type"), "Background");
        assertEq(vm.parseJsonString(json, ".attributes[3].value"), "Genesis Sunburst");
        assertEq(vm.parseJsonString(json, ".attributes[4].value"), "Gold Tracksuit");
        assertEq(vm.parseJsonString(json, ".attributes[5].value"), "Chrome");
        assertEq(vm.parseJsonString(json, ".attributes[8].value"), "Gold Crown");
        string memory image =
            string(vm.parseJsonString(json, ".image").stripPrefix("data:image/svg+xml;base64,").decode());
        assertEq(image, _expectedImage(0, "CAPTAIN"));

        // Frog #1 is gone, so The Captain can never be minted again.
        assertEq(FROGS.ownerOf(1), DEAD);
    }

    function _expectedImage(uint256 tokenId, string memory label) internal view returns (string memory) {
        (uint8 tier, uint16 points, uint16[10] memory inputs, uint8[7] memory traits,) = watch.forgeOf(tokenId);
        bytes memory svg = bytes(renderer.svg(tokenId, tier, traits, label, inputs, points));
        bytes memory head = new bytes(svg.length - 6);
        for (uint256 i; i < head.length; ++i) {
            head[i] = svg[i];
        }
        return string.concat(string(head), skin.layer(tokenId, tier, inputs), "</svg>");
    }

    // ------------------------------------------------------------------------------------------------
    // Reverts on the fork
    // ------------------------------------------------------------------------------------------------

    function testFork_revertsSomeoneElsesFrogEvenApproved() public onlyFork {
        uint256[10] memory ids = _ids(78, 80, 81, 82, 86, 88, 90, 96, 97, 98);
        address holder = _gather(ids);
        // #500 belongs to someone else, who approves the holder for it: still not forgeable by the holder.
        address stranger = FROGS.ownerOf(500);
        assertTrue(stranger != holder);
        vm.prank(stranger);
        FROGS721.approve(holder, 500);
        ids[9] = 500;
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.NotFrogOwner.selector, 500));
        watch.forge(ids, 0);
        assertEq(FROGS.ownerOf(500), stranger);
    }

    function testFork_revertsNoApprovalOrAllowance() public onlyFork {
        uint256[10] memory ids = _ids(78, 80, 81, 82, 86, 88, 90, 96, 97, 98);
        address holder = _gather(ids);
        vm.startPrank(holder);
        FROGS721.setApprovalForAll(address(watch), false);
        vm.expectRevert(NightWatchers.FrogsNotApproved.selector);
        watch.forge(ids, 0);
        FROGS721.setApprovalForAll(address(watch), true);
        IMD.approve(address(watch), 0);
        vm.expectRevert();
        watch.forge(ids, 0);
        vm.stopPrank();
        assertEq(FROGS.ownerOf(78), holder);
        assertEq(watch.nextId(), 1);
    }

    function testFork_revertsMinTierDuplicateAndRange() public onlyFork {
        uint256[10] memory ids = _ids(78, 80, 81, 82, 86, 88, 90, 96, 97, 98);
        address holder = _gather(ids);
        vm.startPrank(holder);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.TierBelowMinimum.selector, 1, 2));
        watch.forge(ids, 2);
        uint256[10] memory dup = ids;
        dup[9] = 78;
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.DuplicateFrogId.selector, 78));
        watch.forge(dup, 0);
        uint256[10] memory zero = ids;
        zero[0] = 0;
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.InvalidFrogId.selector, 0));
        watch.forge(zero, 0);
        uint256[10] memory big = ids;
        big[0] = 501;
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.InvalidFrogId.selector, 501));
        watch.forge(big, 0);
        vm.stopPrank();
    }

    function testFork_revertsWithoutRenderer() public onlyFork {
        NightWatchers fresh = new DeployNightWatchers().deploy(OWNER, FEE);
        uint256[10] memory ids = _ids(78, 80, 81, 82, 86, 88, 90, 96, 97, 98);
        address holder = _gather(ids);
        vm.prank(holder);
        vm.expectRevert(NightWatchers.RendererNotSet.selector);
        fresh.forge(ids, 0);
    }

    function testFork_setRendererOnceAndOwnerOnly() public onlyFork {
        NightWatchers fresh = new DeployNightWatchers().deploy(OWNER, FEE);
        vm.prank(FROGS.ownerOf(500));
        vm.expectRevert(NightWatchers.NotOwner.selector);
        fresh.setRenderer(address(renderer), address(skin));
        vm.startPrank(OWNER);
        fresh.setRenderer(address(renderer), address(skin));
        vm.expectRevert(NightWatchers.RendererAlreadySet.selector);
        fresh.setRenderer(address(renderer), address(skin));
        vm.stopPrank();
        assertEq(address(fresh.renderer()), address(renderer));
        assertEq(address(fresh.skin()), address(skin));
    }

    function testFork_setNameAndTokenURI() public onlyFork {
        (address holder, uint256 id) = _forgeAndCheck(_ids(10, 45, 103, 105, 115, 156, 163, 188, 204, 267), 5);
        vm.prank(holder);
        watch.setName(id, "NIGHT BOSS 1");
        assertEq(watch.nameOf(id), "NIGHT BOSS 1");
        string memory json = string(watch.tokenURI(id).stripPrefix("data:application/json;base64,").decode());
        assertEq(vm.parseJsonString(json, ".name"), "Night Watcher #1");
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "V Night Boss");
        assertEq(vm.parseJsonString(json, ".attributes[10].trait_type"), "Name");
        assertEq(vm.parseJsonString(json, ".attributes[10].value"), "NIGHT BOSS 1");
        (,,, uint8[7] memory traits,) = watch.forgeOf(id);
        for (uint256 l; l < 7; ++l) {
            string memory path = string.concat(".attributes[", vm.toString(l + 3), "].value");
            assertEq(vm.parseJsonString(json, path), FROG_RENDERER.traitName(uint8(l), traits[l]));
        }
        string memory image =
            string(vm.parseJsonString(json, ".image").stripPrefix("data:image/svg+xml;base64,").decode());
        assertEq(image, _expectedImage(id, "NIGHT BOSS 1"));
    }
}
