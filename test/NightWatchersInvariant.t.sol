// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {NightWatchers} from "../src/NightWatchers.sol";
import {MockFrogs, MockFrogRenderer, MockIMD, MockWatchRenderer, MockWatchSkin} from "./mocks/Mocks.sol";

/// @notice Drives NightWatchers with random sequences of forges (valid and invalid), frog and Night Watcher
///         transfers, approvals, allowance changes, names and setRenderer attempts, by several actors.
///         Every call compares the outcome against an independent model; a mismatch is counted in `bad`,
///         which the invariant suite requires to stay 0 (handler reverts are ignored by the runner, so a
///         counter is used instead of assertions).
contract NightWatchersHandler is Test {
    address constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant FEE = 2e18;

    NightWatchers public immutable watch;
    MockFrogs public immutable frogs;
    MockFrogRenderer public immutable frogRenderer;
    MockIMD public immutable imd;

    address[] public actors;
    mapping(address => uint256[]) internal _owned;

    // Ghost state.
    uint256 public forges;
    bool public captain;
    uint256 public bad;
    string public lastBad;
    mapping(uint256 => bytes32) public nameHash;
    mapping(address => bool) public approvedFrogs;

    // Call counters, to show the campaign does reach the interesting paths.
    uint256 public okForges;
    uint256 public failedForges;
    uint256 public captainForges;
    uint256 public names;

    constructor(NightWatchers watch_, MockFrogs frogs_, MockFrogRenderer fr_, MockIMD imd_, address[] memory actors_) {
        watch = watch_;
        frogs = frogs_;
        frogRenderer = fr_;
        imd = imd_;
        actors = actors_;
        for (uint256 id = 1; id <= 500; ++id) {
            _owned[frogs.ownerOf(id)].push(id);
        }
        for (uint256 i; i < actors_.length; ++i) {
            approvedFrogs[actors_[i]] = true;
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function ownedCount(address a) external view returns (uint256) {
        return _owned[a].length;
    }

    function _flag(string memory why) internal {
        ++bad;
        lastBad = why;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _removeOwned(address a, uint256 id) internal {
        uint256[] storage list = _owned[a];
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == id) {
                list[i] = list[list.length - 1];
                list.pop();
                return;
            }
        }
        _flag("model lost a frog");
    }

    // ------------------------------------------------------------------------------------------------
    // Model
    // ------------------------------------------------------------------------------------------------

    function _tierOf(uint256 points) internal pure returns (uint8) {
        if (points >= 128) return 5;
        if (points >= 80) return 4;
        if (points >= 40) return 3;
        if (points >= 20) return 2;
        return 1;
    }

    /// @dev Whether forge(ids, minTier) from `who` must succeed, from the brief's rules alone.
    function _shouldSucceed(address who, uint256[10] memory ids, uint8 minTier)
        internal
        view
        returns (bool ok, bool hasOne)
    {
        if (forges >= 50) return (false, false);
        uint256 points;
        for (uint256 i; i < 10; ++i) {
            uint256 id = ids[i];
            if (id == 0 || id > 500) return (false, false);
            for (uint256 j; j < i; ++j) {
                if (ids[j] == id) return (false, false);
            }
            if (frogs.ownerOf(id) != who) return (false, false);
            points += watch.pointsOf(id);
            if (id == 1) hasOne = true;
        }
        if (_tierOf(points) < minTier) return (false, false);
        if (!approvedFrogs[who] || imd.allowance(who, address(watch)) < FEE || imd.balanceOf(who) < FEE) {
            return (false, false);
        }
        ok = true;
    }

    function _doForge(address who, uint256[10] memory ids, uint8 minTier) internal {
        (bool expectOk, bool hasOne) = _shouldSucceed(who, ids, minTier);
        uint256 burnBefore = imd.balanceOf(0xe29386719C155B6847aD5a4E97C6674f10ffc750);
        uint256 treasuryBefore = imd.balanceOf(OWNER);
        uint256 payerBefore = imd.balanceOf(who);
        uint256 expectedId = forges + 1;

        vm.prank(who);
        try watch.forge(ids, minTier) returns (uint256 tokenId) {
            if (!expectOk) {
                _flag("forge succeeded where the model says revert");
                return;
            }
            ++okForges;
            ++forges;
            if (tokenId != expectedId) _flag("token id not sequential");
            if (watch.ownerOf(tokenId) != who) _flag("watcher not minted to caller");
            if (imd.balanceOf(0xe29386719C155B6847aD5a4E97C6674f10ffc750) - burnBefore != FEE / 2) {
                _flag("burn executor share");
            }
            if (imd.balanceOf(OWNER) - treasuryBefore != FEE - FEE / 2) _flag("treasury share");
            if (payerBefore - imd.balanceOf(who) != FEE) _flag("payer charged");
            for (uint256 i; i < 10; ++i) {
                if (frogs.ownerOf(ids[i]) != DEAD) _flag("frog not at dEaD");
                _removeOwned(who, ids[i]);
            }
            if (hasOne) {
                ++captainForges;
                if (captain) _flag("captain minted twice");
                captain = true;
                if (watch.ownerOf(0) != who) _flag("captain not minted to caller");
            }
        } catch {
            if (expectOk) _flag("forge reverted where the model says success");
            ++failedForges;
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------------------------------------

    /// @notice A forge from 10 distinct frogs the actor owns, with a random minimum tier.
    function forgeOwn(uint256 actorSeed, uint256 pickSeed, uint8 minTier) external {
        address who = _actor(actorSeed);
        uint256[] memory pool = _owned[who];
        if (pool.length < 10) return;
        _prepare(who);
        uint256[10] memory ids;
        for (uint256 i; i < 10; ++i) {
            uint256 j = i + uint256(keccak256(abi.encode(pickSeed, i))) % (pool.length - i);
            (pool[i], pool[j]) = (pool[j], pool[i]);
            ids[i] = pool[i];
        }
        // Half the time any tier is accepted, so valid forges stay frequent.
        _doForge(who, ids, pickSeed % 2 == 0 ? 0 : uint8(bound(minTier, 0, 6)));
    }

    /// @dev The holder approves the frogs and the fee, as the brief requires before a forge.
    function _prepare(address who) internal {
        vm.startPrank(who);
        frogs.setApprovalForAll(address(watch), true);
        imd.approve(address(watch), type(uint256).max);
        vm.stopPrank();
        approvedFrogs[who] = true;
    }

    /// @notice A forge that includes NIGHT FROG #1 if it is still alive, forged by whoever holds it.
    function forgeWithFrogOne(uint256 pickSeed) external {
        if (captain) return;
        address who = frogs.ownerOf(1);
        uint256[] memory pool = _owned[who];
        if (pool.length < 10) return;
        uint256[10] memory ids;
        ids[0] = 1;
        uint256 n = 1;
        for (uint256 i; i < pool.length && n < 10; ++i) {
            uint256 j = i + uint256(keccak256(abi.encode(pickSeed, i))) % (pool.length - i);
            (pool[i], pool[j]) = (pool[j], pool[i]);
            if (pool[i] != 1) ids[n++] = pool[i];
        }
        if (n < 10) return;
        _prepare(who);
        _doForge(who, ids, 0);
    }

    /// @notice A forge with arbitrary ids (out of range, duplicates, other people's frogs, burned frogs).
    function forgeRandom(uint256 actorSeed, uint256[10] memory raw, uint8 minTier) external {
        address who = _actor(actorSeed);
        uint256[10] memory ids;
        for (uint256 i; i < 10; ++i) {
            ids[i] = bound(raw[i], 0, 501);
        }
        // Only ids in range can be queried for ownership by the model; out-of-range ids must fail.
        _doForge(who, ids, uint8(bound(minTier, 0, 6)));
    }

    function transferFrog(uint256 fromSeed, uint256 toSeed, uint256 idxSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256[] storage list = _owned[from];
        if (list.length == 0 || from == to) return;
        uint256 id = list[idxSeed % list.length];
        vm.prank(from);
        frogs.transferFrom(from, to, id);
        _removeOwned(from, id);
        _owned[to].push(id);
    }

    function transferWatcher(uint256 fromSeed, uint256 toSeed, uint256 tokenSeed) external {
        uint256 supply = watch.nextId();
        uint256 tokenId = tokenSeed % supply; // 0 .. nextId-1
        if (tokenId == 0 && !captain) return;
        address from = watch.ownerOf(tokenId);
        address to = _actor(toSeed);
        fromSeed; // the current owner moves it; a non-owner attempt is below
        vm.prank(from);
        watch.transferFrom(from, to, tokenId);
        if (watch.ownerOf(tokenId) != to) _flag("plain transfer failed");
    }

    function transferWatcherNotOwner(uint256 callerSeed, uint256 tokenSeed) external {
        uint256 tokenId = tokenSeed % watch.nextId();
        if (tokenId == 0 && !captain) return;
        address owner_ = watch.ownerOf(tokenId);
        address caller = _actor(callerSeed);
        if (caller == owner_ || watch.isApprovedForAll(owner_, caller) || watch.getApproved(tokenId) == caller) {
            return;
        }
        vm.prank(caller);
        try watch.transferFrom(owner_, caller, tokenId) {
            _flag("stranger moved a Night Watcher");
        } catch {}
    }

    function toggleFrogApproval(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        bool next = !approvedFrogs[who];
        vm.prank(who);
        frogs.setApprovalForAll(address(watch), next);
        approvedFrogs[who] = next;
    }

    function toggleAllowance(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        amount = bound(amount, 0, 3 * FEE);
        vm.prank(who);
        imd.approve(address(watch), amount);
    }

    function setName(uint256 callerSeed, uint256 tokenSeed, uint256 nameSeed) external {
        // A quarter of the attempts target The Captain, the token most likely to be nameable.
        uint256 tokenId = tokenSeed % 4 == 0 ? 0 : tokenSeed % (watch.nextId() + 1);
        address caller = _actor(callerSeed);
        string[6] memory candidates = ["NIGHT OWL", "", " LEAD", "zz", "ABCDEFGHIJKLMNOPQ", "Z-9.Q"];
        string memory name_ = candidates[nameSeed % candidates.length];
        bool valid = nameSeed % candidates.length == 0 || nameSeed % candidates.length == 5;

        bool exists = tokenId != 0 ? tokenId < watch.nextId() : captain;
        // Half the attempts come from the token's owner.
        if (exists && callerSeed % 2 == 0) caller = watch.ownerOf(tokenId);
        bool expectOk;
        if (exists) {
            (uint8 tier,,,,) = watch.forgeOf(tokenId);
            expectOk = watch.ownerOf(tokenId) == caller && tier >= 5 && nameHash[tokenId] == bytes32(0) && valid;
        }
        vm.prank(caller);
        try watch.setName(tokenId, name_) {
            if (!expectOk) _flag("setName succeeded where the model says revert");
            nameHash[tokenId] = keccak256(bytes(name_));
            ++names;
        } catch {
            if (expectOk) _flag("setName reverted where the model says success");
        }
    }

    /// @notice setRenderer was called once in setUp; nobody, the owner included, can call it again.
    function setRendererAgain(uint256 callerSeed) external {
        address caller = callerSeed % 2 == 0 ? OWNER : _actor(callerSeed);
        address r = address(new MockWatchRenderer());
        address s = address(new MockWatchSkin());
        vm.prank(caller);
        try watch.setRenderer(r, s) {
            _flag("setRenderer succeeded twice");
        } catch {}
    }
}

/// @notice Invariants over random call sequences. Mocks are etched at the mainnet addresses the contract
///         hardcodes (NIGHT FROGS, its renderer, IMD).
contract NightWatchersInvariantTest is Test {
    address constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address constant BURN_EXECUTOR = 0xe29386719C155B6847aD5a4E97C6674f10ffc750;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant FROGS_ADDR = 0x55b8C762f1b86fE1D5406EdaAAE0f8ecF3688A0c;
    address constant FROG_RENDERER_ADDR = 0x4D9BfbafE31eC18E9D3066F1475e24906d155D67;
    address constant IMD_ADDR = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 constant FEE = 2e18;
    uint256 constant FUND = 1_000e18;

    NightWatchers watch;
    MockFrogs frogs;
    MockIMD imd;
    NightWatchersHandler handler;
    address renderer;
    address skin;
    address[] actors;

    function setUp() public {
        vm.etch(FROGS_ADDR, address(new MockFrogs()).code);
        vm.etch(FROG_RENDERER_ADDR, address(new MockFrogRenderer()).code);
        vm.etch(IMD_ADDR, address(new MockIMD()).code);
        frogs = MockFrogs(FROGS_ADDR);
        imd = MockIMD(IMD_ADDR);

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));

        watch = new NightWatchers(OWNER, FEE);
        renderer = address(new MockWatchRenderer());
        skin = address(new MockWatchSkin());
        vm.prank(OWNER);
        watch.setRenderer(renderer, skin);

        for (uint256 id = 1; id <= 500; ++id) {
            frogs.mint(actors[id % 3], id);
        }
        for (uint256 i; i < 3; ++i) {
            imd.mint(actors[i], FUND);
            vm.startPrank(actors[i]);
            frogs.setApprovalForAll(address(watch), true);
            imd.approve(address(watch), type(uint256).max);
            vm.stopPrank();
        }

        handler = new NightWatchersHandler(watch, frogs, MockFrogRenderer(FROG_RENDERER_ADDR), imd, actors);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = NightWatchersHandler.forgeOwn.selector;
        selectors[1] = NightWatchersHandler.forgeOwn.selector; // weighted: valid forges twice as likely
        selectors[2] = NightWatchersHandler.forgeWithFrogOne.selector;
        selectors[3] = NightWatchersHandler.forgeRandom.selector;
        selectors[4] = NightWatchersHandler.transferFrog.selector;
        selectors[5] = NightWatchersHandler.transferWatcher.selector;
        selectors[6] = NightWatchersHandler.transferWatcherNotOwner.selector;
        selectors[7] = NightWatchersHandler.toggleFrogApproval.selector;
        selectors[8] = NightWatchersHandler.toggleAllowance.selector;
        selectors[9] = NightWatchersHandler.setName.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        // setRendererAgain is exercised in test_handlerReachesPaths; it deploys contracts, so it is kept out of
        // the random sequences to keep them fast. invariant_rendererFrozen still checks nothing changed it.
        excludeSender(address(watch));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_modelAgrees() public view {
        assertEq(handler.bad(), 0, handler.lastBad());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_supply() public view {
        uint256 forges = handler.forges();
        bool captain = handler.captain();
        assertLe(forges, 50, "at most 50 Night Watchers");
        assertEq(watch.nextId(), forges + 1, "nextId");
        assertEq(watch.captainForged(), captain, "captainForged");
        assertEq(watch.totalSupply(), forges + (captain ? 1 : 0), "totalSupply");
        assertLe(watch.totalSupply(), 51, "at most 51 NFTs");
        uint256 held;
        for (uint256 i; i < actors.length; ++i) {
            held += watch.balanceOf(actors[i]);
        }
        assertEq(held, watch.totalSupply(), "every token is held by an actor");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_custodyAndFees() public view {
        uint256 forges = handler.forges();
        assertEq(imd.balanceOf(address(watch)), 0, "never holds IMD");
        assertEq(frogs.balanceOf(address(watch)), 0, "never holds a frog");
        assertEq(address(watch).balance, 0, "never holds ETH");
        assertEq(imd.balanceOf(BURN_EXECUTOR), forges * (FEE / 2), "1 IMD per forge to the BurnExecutor");
        assertEq(imd.balanceOf(OWNER), forges * (FEE - FEE / 2), "1 IMD per forge to the treasury");
        uint256 sum = imd.balanceOf(BURN_EXECUTOR) + imd.balanceOf(OWNER);
        for (uint256 i; i < actors.length; ++i) {
            sum += imd.balanceOf(actors[i]);
        }
        assertEq(sum, 3 * FUND, "IMD conserved");
        assertEq(frogs.balanceOf(DEAD), 10 * forges, "10 frogs at dEaD per forge");
        uint256 alive;
        for (uint256 i; i < actors.length; ++i) {
            alive += frogs.balanceOf(actors[i]);
            assertEq(frogs.balanceOf(actors[i]), handler.ownedCount(actors[i]), "model frog count");
        }
        assertEq(alive + 10 * forges, 500, "frogs conserved");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_records() public view {
        uint256 next = watch.nextId();
        for (uint256 id = 1; id < next; ++id) {
            (uint8 tier, uint16 points, uint16[10] memory inputs,,) = watch.forgeOf(id);
            uint256 sum;
            for (uint256 i; i < 10; ++i) {
                assertEq(frogs.ownerOf(inputs[i]), DEAD, "input at dEaD");
                sum += watch.pointsOf(inputs[i]);
            }
            assertEq(points, sum, "points = sum of inputs");
            assertEq(tier, watch.tierFor(points), "tier = tierFor(points)");
            assertTrue(tier >= 1 && tier <= 5, "watcher tier 1..5");
            if (handler.nameHash(id) != bytes32(0)) {
                assertEq(keccak256(bytes(watch.nameOf(id))), handler.nameHash(id), "name never changes");
            }
        }
        if (watch.captainForged()) {
            (uint8 tier,, uint16[10] memory inputs,,) = watch.forgeOf(0);
            assertEq(tier, 6, "captain tier 6");
            bool hasOne;
            for (uint256 i; i < 10; ++i) {
                if (inputs[i] == 1) hasOne = true;
            }
            assertTrue(hasOne, "captain forged from #1");
            assertEq(frogs.ownerOf(1), DEAD, "#1 burned");
        } else {
            assertTrue(frogs.ownerOf(1) != DEAD, "#1 alive while no captain");
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_rendererFrozen() public view {
        assertEq(address(watch.renderer()), renderer, "renderer frozen");
        assertEq(address(watch.skin()), skin, "skin frozen");
        assertEq(watch.owner(), OWNER, "owner fixed");
        assertEq(watch.fee(), FEE, "fee fixed");
    }

    /// @notice Not an invariant: shows the handler reaches both outcomes so the invariants are not vacuous.
    function test_handlerReachesPaths() public {
        handler.forgeWithFrogOne(1);
        handler.forgeOwn(0, 7, 0);
        handler.forgeOwn(2, 9, 6);
        handler.forgeRandom(0, [uint256(0), 1, 2, 3, 4, 5, 6, 7, 8, 9], 0);
        handler.setName(1, 0, 0);
        handler.setRendererAgain(0);
        assertEq(handler.bad(), 0, handler.lastBad());
        assertEq(handler.okForges(), 2);
        assertEq(handler.captainForges(), 1);
        assertGe(handler.failedForges(), 2);
        assertTrue(watch.captainForged());
    }
}
