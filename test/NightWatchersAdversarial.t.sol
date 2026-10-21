// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";

import {NightWatchers} from "../src/NightWatchers.sol";
import {MockFrogs, MockFrogRenderer, MockIMD, MockWatchRenderer, MockWatchSkin} from "./mocks/Mocks.sol";

/// @notice IMD stand-in that calls back into NightWatchers from inside `transferFrom`, as a hostile token would.
contract ReentrantIMD is ERC20 {
    address public target;
    bytes public payload;
    bytes public lastRevert;
    bool public reentered;

    constructor() ERC20("IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (target != address(0) && !reentered) {
            reentered = true;
            (bool ok, bytes memory ret) = target.call(payload);
            if (!ok) lastRevert = ret;
        }
        return super.transferFrom(from, to, value);
    }
}

/// @notice NIGHT FROGS stand-in that calls back from inside `transferFrom` and records what it saw.
contract HookFrogs is ERC721 {
    address public target;
    bytes public payload;
    bytes public lastRevert;
    bool public reentered;
    // What the hook saw of NightWatchers mid-forge.
    uint256 public seenNextId;
    address public seenOwnerOf1;
    bool public seenCaptain;

    constructor() ERC721("NIGHT FROGS", "NFROG") {}

    function randomWord() external pure returns (uint256) {
        return 35429570828173908880356199774237038643724038961364838229381014887099201929822;
    }

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function transferFrom(address from, address to, uint256 id) public override {
        if (target != address(0) && !reentered) {
            reentered = true;
            NightWatchers w = NightWatchers(target);
            seenNextId = w.nextId();
            try w.ownerOf(1) returns (address o) {
                seenOwnerOf1 = o;
            } catch {}
            seenCaptain = w.captainForged();
            if (payload.length != 0) {
                (bool ok, bytes memory ret) = target.call(payload);
                if (!ok) lastRevert = ret;
            }
        }
        super.transferFrom(from, to, id);
    }
}

/// @notice A contract holder with no onERC721Received: `_mint` (not `_safeMint`) must still deliver to it.
contract PlainContractHolder {
    function call(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}

contract NightWatchersAdversarialTest is Test {
    address constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address constant TREASURY = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address constant BURN_EXECUTOR = 0xe29386719C155B6847aD5a4E97C6674f10ffc750;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant FROGS_ADDR = 0x55b8C762f1b86fE1D5406EdaAAE0f8ecF3688A0c;
    address constant FROG_RENDERER_ADDR = 0x4D9BfbafE31eC18E9D3066F1475e24906d155D67;
    address constant IMD_ADDR = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 constant FEE = 2e18;

    NightWatchers watch;
    MockWatchRenderer renderer;
    MockWatchSkin skin;
    address holder = makeAddr("holder");
    address other = makeAddr("other");

    event Forged(address indexed owner, uint256 indexed tokenId, uint8 tier, uint16 points, uint16[10] inputs);

    function setUp() public {
        vm.etch(FROG_RENDERER_ADDR, address(new MockFrogRenderer()).code);
        renderer = new MockWatchRenderer();
        skin = new MockWatchSkin();
    }

    // ------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------

    /// @dev Plain mocks: every frog to `holder`, IMD to holder and other, approvals in place.
    function _standard(uint256 fee_) internal {
        vm.etch(FROGS_ADDR, address(new MockFrogs()).code);
        vm.etch(IMD_ADDR, address(new MockIMD()).code);
        for (uint256 id = 1; id <= 500; ++id) {
            MockFrogs(FROGS_ADDR).mint(holder, id);
        }
        MockIMD(IMD_ADDR).mint(holder, 1_000e18);
        _deploy(fee_);
    }

    /// @dev Just the contract, for its pure views.
    function _bare() internal {
        watch = new NightWatchers(OWNER, FEE);
    }

    function _deploy(uint256 fee_) internal {
        watch = new NightWatchers(OWNER, fee_);
        vm.prank(OWNER);
        watch.setRenderer(address(renderer), address(skin));
        vm.startPrank(holder);
        ERC721(FROGS_ADDR).setApprovalForAll(address(watch), true);
        ERC20(IMD_ADDR).approve(address(watch), type(uint256).max);
        vm.stopPrank();
    }

    function _range(uint256 first) internal pure returns (uint256[10] memory ids) {
        for (uint256 i; i < 10; ++i) {
            ids[i] = first + i;
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Reentrancy and CEI
    // ------------------------------------------------------------------------------------------------

    function test_reentryThroughImdIsBlocked() public {
        vm.etch(FROGS_ADDR, address(new MockFrogs()).code);
        vm.etch(IMD_ADDR, address(new ReentrantIMD()).code);
        ReentrantIMD imd = ReentrantIMD(IMD_ADDR);
        for (uint256 id = 1; id <= 30; ++id) {
            MockFrogs(FROGS_ADDR).mint(holder, id);
        }
        imd.mint(holder, 100e18);
        _deploy(FEE);
        // The token re-enters forge with another 10 frogs while the first forge is moving the fee.
        imd.arm(address(watch), abi.encodeCall(NightWatchers.forge, (_range(11), 0)));

        vm.prank(holder);
        uint256 id = watch.forge(_range(1), 0);

        assertTrue(imd.reentered(), "hook fired");
        assertEq(
            imd.lastRevert(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            "inner forge blocked by the guard"
        );
        assertEq(id, 1);
        assertEq(watch.nextId(), 2, "exactly one Night Watcher");
        assertEq(watch.totalSupply(), 2, "Night Watcher #1 and The Captain");
        assertEq(MockFrogs(FROGS_ADDR).ownerOf(11), holder, "second batch untouched");
        assertEq(imd.balanceOf(BURN_EXECUTOR), 1e18);
        assertEq(imd.balanceOf(TREASURY), 1e18);
    }

    /// @notice Effects come before the frog transfers: a callback during the transfer sees the forge done.
    function test_ceiStateSettledBeforeFrogTransfers() public {
        vm.etch(FROGS_ADDR, address(new HookFrogs()).code);
        vm.etch(IMD_ADDR, address(new MockIMD()).code);
        HookFrogs frogs = HookFrogs(FROGS_ADDR);
        for (uint256 id = 1; id <= 30; ++id) {
            frogs.mint(holder, id);
        }
        MockIMD(IMD_ADDR).mint(holder, 100e18);
        _deploy(FEE);
        frogs.arm(address(watch), abi.encodeCall(NightWatchers.forge, (_range(11), 0)));

        vm.prank(holder);
        watch.forge(_range(1), 0);

        assertEq(frogs.seenNextId(), 2, "nextId already advanced");
        assertEq(frogs.seenOwnerOf1(), holder, "watcher #1 already minted");
        assertTrue(frogs.seenCaptain(), "captain already recorded");
        assertEq(frogs.lastRevert(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(frogs.ownerOf(11), holder);
        assertEq(frogs.balanceOf(DEAD), 10);
    }

    // ------------------------------------------------------------------------------------------------
    // Fee split
    // ------------------------------------------------------------------------------------------------

    function test_feeIsTwoImdSplitOneAndOne() public {
        _standard(FEE);
        assertEq(watch.fee(), 2e18);
        vm.prank(holder);
        watch.forge(_range(100), 0);
        assertEq(MockIMD(IMD_ADDR).balanceOf(BURN_EXECUTOR), 1e18);
        assertEq(MockIMD(IMD_ADDR).balanceOf(TREASURY), 1e18);
        assertEq(MockIMD(IMD_ADDR).balanceOf(holder), 998e18);
    }

    /// @notice The split is FEE/2 down to the BurnExecutor and the odd wei to the treasury, nothing kept.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_feeSplitAnyFee(uint256 fee_) public {
        fee_ = bound(fee_, 0, 1_000e18 / 50);
        _standard(fee_);
        uint256 forges = 3;
        for (uint256 k; k < forges; ++k) {
            vm.prank(holder);
            watch.forge(_range(100 + 10 * k), 0);
        }
        MockIMD imd = MockIMD(IMD_ADDR);
        assertEq(imd.balanceOf(BURN_EXECUTOR), forges * (fee_ / 2), "burn executor");
        assertEq(imd.balanceOf(TREASURY), forges * (fee_ - fee_ / 2), "treasury");
        assertEq(imd.balanceOf(holder), 1_000e18 - forges * fee_, "payer");
        assertEq(imd.balanceOf(address(watch)), 0);
    }

    function test_feeRevertsWhenPayerShort() public {
        _standard(FEE);
        // Allowance of exactly FEE works (OZ ERC20 spends it to 0); the next forge has none left and fails.
        vm.prank(holder);
        ERC20(IMD_ADDR).approve(address(watch), FEE);
        vm.prank(holder);
        watch.forge(_range(100), 0);
        assertEq(ERC20(IMD_ADDR).allowance(holder, address(watch)), 0);
        vm.prank(holder);
        vm.expectRevert();
        watch.forge(_range(110), 0);
        assertEq(MockFrogs(FROGS_ADDR).ownerOf(110), holder, "nothing moved on revert");
        assertEq(watch.nextId(), 2);
    }

    // ------------------------------------------------------------------------------------------------
    // Supply edges and The Captain
    // ------------------------------------------------------------------------------------------------

    /// @notice #1 in the 50th and last forge: supply reaches exactly 51 and then nothing more mints.
    function test_captainOnTheFiftiethForge() public {
        _standard(FEE);
        // Frogs 2..491 for forges 1..49, then #1 with 492..500 for the 50th.
        for (uint256 k; k < 49; ++k) {
            vm.prank(holder);
            watch.forge(_range(2 + 10 * k), 0);
        }
        assertFalse(watch.captainForged());
        assertEq(watch.totalSupply(), 49);
        uint256[10] memory last = [uint256(1), 492, 493, 494, 495, 496, 497, 498, 499, 500];
        vm.prank(holder);
        assertEq(watch.forge(last, 0), 50);
        assertTrue(watch.captainForged());
        assertEq(watch.ownerOf(0), holder);
        assertEq(watch.totalSupply(), 51);
        assertEq(watch.balanceOf(holder), 51);
        vm.expectRevert(NightWatchers.SoldOut.selector);
        watch.preview(_range(2));
    }

    /// @notice The Captain is tier 6 whatever the points; minTier applies to the Night Watcher's tier.
    function test_captainWithLowPointsAndMinTier() public {
        _standard(FEE);
        // #1 (Legendary, 16) + 9 Commons = 25 points: the Night Watcher is tier 2.
        uint256[10] memory ids = [uint256(1), 78, 80, 81, 82, 86, 88, 90, 96, 97];
        (uint8 tier, uint16 points,) = watch.preview(ids);
        assertEq(points, 25);
        assertEq(tier, 2);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.TierBelowMinimum.selector, 2, 3));
        watch.forge(ids, 3);
        assertFalse(watch.captainForged(), "a reverted forge mints no captain");

        vm.prank(holder);
        watch.forge(ids, 2);
        (uint8 cTier, uint16 cPoints,,,) = watch.forgeOf(0);
        assertEq(cTier, 6);
        assertEq(cPoints, 25);
        (uint8 wTier,,,,) = watch.forgeOf(1);
        assertEq(wTier, 2);
        // The Captain is nameable (tier 6) even though its Night Watcher is not.
        vm.prank(holder);
        watch.setName(0, "ZERO SLEEP");
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.TierCannotBeNamed.selector, 2));
        watch.setName(1, "NOPE");
    }

    function test_minTierAboveFiveAlwaysReverts() public {
        _standard(FEE);
        uint256[10] memory legendaries = [uint256(10), 45, 103, 105, 115, 156, 163, 188, 204, 267];
        for (uint8 m = 6; m != 0; ++m) {
            vm.prank(holder);
            vm.expectRevert(abi.encodeWithSelector(NightWatchers.TierBelowMinimum.selector, 5, m));
            watch.forge(legendaries, m);
            if (m == 255) break;
        }
        vm.prank(holder);
        assertEq(watch.forge(legendaries, 5), 1);
    }

    // ------------------------------------------------------------------------------------------------
    // Callers
    // ------------------------------------------------------------------------------------------------

    /// @notice An operator approved for all of the holder's frogs still cannot forge them.
    function test_operatorForAllCannotForge() public {
        _standard(FEE);
        vm.prank(holder);
        ERC721(FROGS_ADDR).setApprovalForAll(other, true);
        MockIMD(IMD_ADDR).mint(other, 10e18);
        vm.startPrank(other);
        ERC721(FROGS_ADDR).setApprovalForAll(address(watch), true);
        ERC20(IMD_ADDR).approve(address(watch), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.NotFrogOwner.selector, 100));
        watch.forge(_range(100), 0);
        vm.stopPrank();
    }

    /// @notice Per-token approval of every frog is not setApprovalForAll: the forge refuses it.
    function test_perTokenApprovalIsNotEnough() public {
        _standard(FEE);
        vm.startPrank(holder);
        ERC721(FROGS_ADDR).setApprovalForAll(address(watch), false);
        for (uint256 i; i < 10; ++i) {
            ERC721(FROGS_ADDR).approve(address(watch), 100 + i);
        }
        vm.expectRevert(NightWatchers.FrogsNotApproved.selector);
        watch.forge(_range(100), 0);
        vm.stopPrank();
    }

    /// @notice The owner has no power over forging or other people's frogs.
    function test_ownerCannotForgeOthersFrogs() public {
        _standard(FEE);
        vm.prank(OWNER);
        ERC721(FROGS_ADDR).setApprovalForAll(address(watch), true);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.NotFrogOwner.selector, 100));
        watch.forge(_range(100), 0);
    }

    /// @notice A contract without onERC721Received receives its Night Watcher (plain _mint).
    function test_contractHolderWithoutReceiver() public {
        vm.etch(FROGS_ADDR, address(new MockFrogs()).code);
        vm.etch(IMD_ADDR, address(new MockIMD()).code);
        PlainContractHolder box = new PlainContractHolder();
        for (uint256 id = 1; id <= 10; ++id) {
            MockFrogs(FROGS_ADDR).mint(address(box), id);
        }
        MockIMD(IMD_ADDR).mint(address(box), 2e18);
        watch = new NightWatchers(OWNER, FEE);
        vm.prank(OWNER);
        watch.setRenderer(address(renderer), address(skin));
        box.call(FROGS_ADDR, abi.encodeCall(ERC721.setApprovalForAll, (address(watch), true)));
        box.call(IMD_ADDR, abi.encodeCall(ERC20.approve, (address(watch), 2e18)));
        box.call(address(watch), abi.encodeCall(NightWatchers.forge, (_range(1), 0)));
        assertEq(watch.ownerOf(1), address(box));
        assertEq(watch.ownerOf(0), address(box));
    }

    /// @notice No admin surface beyond setRenderer: common admin selectors do not exist.
    function test_noOtherAdminFunctions() public {
        _standard(FEE);
        bytes[7] memory calls = [
            abi.encodeWithSignature("transferOwnership(address)", other),
            abi.encodeWithSignature("renounceOwnership()"),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", other, ""),
            abi.encodeWithSignature("setDefaultRoyalty(address,uint96)", other, 1000),
            abi.encodeWithSignature("mint(address,uint256)", OWNER, 2),
            abi.encodeWithSignature("burn(uint256)", 1)
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(OWNER);
            (bool ok,) = address(watch).call(calls[i]);
            assertFalse(ok);
        }
        vm.deal(OWNER, 1 ether);
        vm.prank(OWNER);
        (bool sent,) = address(watch).call{value: 1}("");
        assertFalse(sent, "no receive: cannot be sent ETH");
    }

    // ------------------------------------------------------------------------------------------------
    // Pure views against independent references
    // ------------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_tierForMatchesBrief(uint16 points) public {
        _bare();
        uint8 expected = points >= 128 ? 5 : points >= 80 ? 4 : points >= 40 ? 3 : points >= 20 ? 2 : 1;
        assertEq(watch.tierFor(points), expected);
    }

    function test_tierForBoundaries() public {
        _bare();
        uint16[10] memory p = [uint16(19), 20, 39, 40, 79, 80, 127, 128, 0, 160];
        uint8[10] memory t = [uint8(1), 2, 2, 3, 3, 4, 4, 5, 1, 5];
        for (uint256 i; i < 10; ++i) {
            assertEq(watch.tierFor(p[i]), t[i]);
        }
    }

    /// @notice The brief: frogs #2-25 are at least Epic (8), #26-77 at least Rare (4).
    function test_pointsFloorsFromBrief() public {
        _bare();
        for (uint256 id = 2; id <= 25; ++id) {
            assertGe(watch.pointsOf(id), 8);
        }
        for (uint256 id = 26; id <= 77; ++id) {
            assertGe(watch.pointsOf(id), 4);
        }
    }

    function _refValid(bytes memory b) internal pure returns (bool) {
        if (b.length == 0 || b.length > 16) return false;
        if (b[0] == " " || b[b.length - 1] == " ") return false;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (!((c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == " " || c == "." || c == "-")) return false;
        }
        return true;
    }

    /// @notice isValidName equals the brief's rule on names built from an alphabet with near-miss characters.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_isValidNameMatchesBrief(uint256 len, uint256 seed) public {
        _bare();
        len = bound(len, 0, 18);
        bytes memory alphabet = "AZ09 .-@[/:_`az{\x00\xff\x2c\x2f";
        bytes memory b = new bytes(len);
        for (uint256 i; i < len; ++i) {
            b[i] = alphabet[uint256(keccak256(abi.encode(seed, i))) % alphabet.length];
        }
        assertEq(watch.isValidName(string(b)), _refValid(b), string(b));
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_royaltyIsFivePercentToTreasury(uint256 tokenId, uint256 price) public {
        _bare();
        price = bound(price, 0, type(uint256).max / 500);
        (address receiver, uint256 amount) = watch.royaltyInfo(tokenId, price);
        assertEq(receiver, TREASURY);
        assertEq(amount, price * 500 / 10_000);
    }

    function test_supportsInterfaces() public {
        _standard(FEE);
        assertTrue(watch.supportsInterface(0x80ac58cd), "ERC721");
        assertTrue(watch.supportsInterface(0x5b5e139f), "ERC721Metadata");
        assertTrue(watch.supportsInterface(type(IERC2981).interfaceId), "ERC2981");
        assertTrue(watch.supportsInterface(0x01ffc9a7), "ERC165");
        assertFalse(watch.supportsInterface(0x780e9d63), "not Enumerable");
        assertFalse(watch.supportsInterface(0xffffffff));
    }

    /// @notice Nothing is pre-minted and nothing mints before a renderer is set.
    function test_nothingPreMinted() public {
        vm.etch(FROGS_ADDR, address(new MockFrogs()).code);
        NightWatchers fresh = new NightWatchers(OWNER, FEE);
        assertEq(fresh.totalSupply(), 0);
        assertEq(fresh.nextId(), 1);
        assertFalse(fresh.captainForged());
        assertEq(address(fresh.renderer()), address(0));
        assertEq(address(fresh.skin()), address(0));
        assertEq(fresh.balanceOf(OWNER), 0);
    }

    /// @notice setRenderer emits RendererSet and rejects a skin without code even from the owner.
    function test_setRendererSkinWithoutCode() public {
        vm.etch(FROGS_ADDR, address(new MockFrogs()).code);
        NightWatchers fresh = new NightWatchers(OWNER, FEE);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.NotAContract.selector, other));
        fresh.setRenderer(address(renderer), other);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(NightWatchers.NotAContract.selector, address(0)));
        fresh.setRenderer(address(0), address(skin));
        // A failed attempt does not use up the one call.
        vm.prank(OWNER);
        fresh.setRenderer(address(renderer), address(skin));
        assertEq(address(fresh.renderer()), address(renderer));
        assertEq(address(fresh.skin()), address(skin));
    }
}
