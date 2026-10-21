# NIGHT WATCHERS (WATCH) — NIGHT FROGS Gen 2

A fully onchain ERC-721 on Ethereum mainnet. A NIGHT FROGS holder forges exactly 10 of their frogs into
one Night Watcher. The forge that burns NIGHT FROG #1 also mints **The Captain**, token 0. At most 51
tokens can ever exist (50 Night Watchers, tokens 1–50, plus The Captain). Nothing is pre-minted; only
`forge()` mints.

- Contract: `src/NightWatchers.sol` (`contract NightWatchers`, OpenZeppelin v5.4.0, solc 0.8.26)
- Not upgradeable, not pausable, no proxy, no delegatecall, no selfdestruct.
- Plain ERC-721 transfers, no fee or limit. ERC-2981 royalty of 5% to `0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5`.
- The owner has exactly one power: `setRenderer(renderer, skin)`, once.

## Source contracts (read only)

| What | Address | Used for |
| --- | --- | --- |
| NIGHT FROGS (NFROG, 500 frogs, revealed) | `0x55b8C762f1b86fE1D5406EdaAAE0f8ecF3688A0c` | `ownerOf`, `isApprovedForAll`, `transferFrom`, `randomWord()` |
| NIGHT FROGS renderer | `0x4D9BfbafE31eC18E9D3066F1475e24906d155D67` | `traits(id, word) → uint8[7]`, `traitName(layer, index) → string` |
| IMD (18 decimals) | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` | fee token, moved with `transferFrom` |
| IMD BurnExecutor | `0xe29386719C155B6847aD5a4E97C6674f10ffc750` | receives `FEE / 2` of every forge |
| Treasury / owner | `0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5` | receives `FEE - FEE / 2` of every forge and the 5% royalty |

All five are constants in the contract. They were read from mainnet while building (the frog collection
reports 500 supply and a non-zero `randomWord()`, the renderer answers `traits(uint256,uint256)` and
`traitName(uint8,uint8)`, IMD reports 18 decimals and the BurnExecutor has code). The constructor calls
none of them, so the contract deploys on an empty chain; they are first touched by `forge()`.

## Forge

`forge(uint256[10] ids, uint8 minTier) returns (uint256 tokenId)` — `nonReentrant`, checks → effects → interactions.

1. Reverts with `RendererNotSet` until the owner has called `setRenderer`, and with `SoldOut` once 50 Night
   Watchers exist.
2. The 10 ids must be distinct and in 1..500 (`DuplicateFrogId`, `InvalidFrogId`), each with
   `ownerOf(id) == msg.sender` (`NotFrogOwner`; an approval from someone else is not ownership), and the
   caller must have `setApprovalForAll(nightWatchers, true)` on NIGHT FROGS (`FrogsNotApproved`).
3. **Points** = sum of `pointsOf(id)`, the frog's rarity tier: Legendary 16, Epic 8, Rare 4, Uncommon 2,
   Common 1, decoded from the six packed `WORDS` constants in the brief (3 bits per frog, 85 per word).
   Distribution: 25 legendary, 70 epic, 109 rare, 107 uncommon, 189 common; #2–25 are at least epic and
   #26–77 at least rare.
4. **Tier** = `tierFor(points)`: 5 if ≥ 128, 4 if ≥ 80, 3 if ≥ 40, 2 if ≥ 20, else 1
   (I Shift Lead, II Foreman, III Supervisor, IV Chief, V Night Boss). Reverts with `TierBelowMinimum`
   if `tier < minTier`; pass 0 to accept any tier.
5. **Traits**: for each of the 7 layers, among the 10 frogs' `renderer.traits(id, randomWord())`, the index
   with the lowest Gen 1 count (`traitCount(layer, index)`, the `COUNT` table from the brief); ties go to
   the lower index.
6. Mints `tokenId = nextId` (1, 2, 3, …, at most 50) to the caller with `_mint` (no receiver hook), stores
   `{tier, points, inputs, traits, forgedAt}`, emits `Forged(owner, tokenId, tier, points, inputs)`.
7. If the 10 include #1: also mints token 0, **The Captain**, to the caller with tier 6, the same points and
   inputs, and traits = `renderer.traits(1, randomWord())`; `captainForged` becomes true; emits `Forged` for
   it too. Since #1 burns, this can happen once.
8. Interactions last: each frog moves with `transferFrom(msg.sender, 0x…dEaD, id)` (the contract never
   holds a frog), then `FEE / 2` IMD moves from the caller to the BurnExecutor and `FEE - FEE / 2` to the
   treasury by IMD `transferFrom` (the contract never holds IMD). The caller needs an IMD allowance of at
   least `fee()` for this contract.

`preview(ids)` returns `(tier, points, traits)` with every check except ownership and approvals, so a UI can
show the outcome before the holder approves anything. A fuzz test asserts `preview == forge`.

### Views

`nextId()`, `captainForged()`, `totalSupply()`, `fee()`, `forgeOf(tokenId) → (tier, points, inputs[10],
traits[7], forgedAt)`, `pointsOf(frogId)`, `tierFor(points)`, `traitCount(layer, index)`, `tierName(tier)`,
`tierNumeral(tier)`, `nameOf(tokenId)`, `isValidName(name)`, `imageOf(tokenId)`, `renderer()`, `skin()`,
`owner()`, plus the ERC-721 and ERC-2981 standard views.

### Names

`setName(tokenId, name)`: token owner only, tier 5 or 6 only, once per token. 1–16 bytes of `A-Z`, `0-9`,
space, `.` and `-`, without a leading or trailing space. Emits `Named(tokenId, name)`. The name becomes the
renderer label and a `Name` attribute.

## Art and metadata

`setRenderer(address r, address skin)`: owner only, exactly once, both must have code; emits
`RendererSet(r, skin)`. Both contracts are ordered from IMD separately:

- `NightWatchRenderer.svg(uint256 n, uint8 tier, uint8[7] traits, string label, uint16[10] inputs, uint16 points) view returns (string)` — always ends with `</svg>`.
- `NightWatchSkin.layer(uint256 n, uint8 tier, uint16[10] inputs) view returns (string)`.

IMAGE = the renderer's svg without its last 6 bytes (`</svg>`), then `skin.layer(n, tier, inputs)`, then
`</svg>`. If a renderer ever returned fewer than 6 bytes the whole output is kept and the layer and closing
tag are still appended (lenient, so metadata never bricks).

`tokenURI(n)` = `data:application/json;base64,` + base64 of:

```json
{
  "name": "Night Watcher #<n>",            // "The Captain" for token 0
  "description": "NIGHT FROGS Gen 2, forged from 10 NIGHT FROGS, a seat in the Night Watch. Tier <roman> <name>.",
  "image": "data:image/svg+xml;base64,<base64(IMAGE)>",
  "attributes": [
    {"trait_type": "Tier", "value": "<roman> <name>"},
    {"trait_type": "Forge Points", "display_type": "number", "value": <points>},
    {"trait_type": "Forged From", "value": "#a #b #c #d #e #f #g #h #i #j"},
    {"trait_type": "Background", "value": "<traitName(0, traits[0])>"},
    ... Body, Skin, Mouth, Eyes, Headwear, Accessory ...
    {"trait_type": "Name", "value": "<name>"}          // only if set
  ]
}
```

The Captain's description is "The one Night Watcher forged from NIGHT FROG #1, the Zero-Sleep Captain.
Tier C Captain." and its Tier attribute is "C Captain". The renderer is called with
`LABEL = nameOf(n)` if set, else the tier name in capitals (`SHIFT LEAD`, `FOREMAN`, `SUPERVISOR`, `CHIEF`,
`NIGHT BOSS`, `CAPTAIN`). Trait names are read live from the NIGHT FROGS renderer.

## Deployment parameters

The IMD launch (`evm_contracts`, chain id 1) deploys `NightWatchers` from the built bytecode through its
factory. Constructor arguments, in order:

| # | Type | Value | Meaning |
| --- | --- | --- | --- |
| 1 | `address` | `$owner` → `0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5` | `owner()`, may call `setRenderer` once. Never the deployer. |
| 2 | `uint256` | `2000000000000000000` (2e18) | `FEE`, immutable; `fee()` returns it. 1 IMD to the BurnExecutor and 1 IMD to the treasury per forge. |

Everything else is a constant: the five source addresses above, the royalty (500 bps), the 50-token cap, the
rarity words, the trait counts, the tier thresholds.

`foundry.toml` pins `solc = "0.8.26"`, `bytecode_hash = "none"`, `cbor_metadata = false`, optimizer on with
200 runs, `evm_version = "cancun"`, no `ffi`, no `fs_permissions`. Runtime is 16,242 bytes (EIP-170 limit
24,576), with no reachable DELEGATECALL, CALLCODE or SELFDESTRUCT.

`script/Deploy.s.sol` (`DeployNightWatchers`) holds the same two values as constants; `deploy(owner, fee)` is
what the tests call, `run()` broadcasts it for a manual deployment. It reads no environment variables.

## After launch (operational responsibilities)

1. **`setRenderer(renderer, skin)` — the owner, once.** Until it is called, `forge()` and `preview()` revert
   with `RendererNotSet`; nothing can be minted. Both addresses come from the separately ordered
   NightWatchRenderer and NightWatchSkin deployments and must have code. This cannot be undone or repeated:
   check `svg(...)` ends with `</svg>` and `layer(...)` returns a valid SVG fragment on mainnet before calling
   it. The owner has no other power; there is no ownership transfer, pause, withdraw or upgrade.
2. **Holders**, before forging: `NIGHT FROGS.setApprovalForAll(nightWatchers, true)` and
   `IMD.approve(nightWatchers, 2e18)` (or more for several forges). Call `preview(ids)` first; pass the
   previewed tier as `minTier` to be protected against a front-run that changes nothing here (points and
   traits are deterministic per id set) but makes the intent explicit.
3. **Verification** (deployer, after the launch; not done by this job):

   ```sh
   forge verify-contract <address> src/NightWatchers.sol:NightWatchers \
     --chain 1 --verifier etherscan --etherscan-api-key <key> \
     --constructor-args $(cast abi-encode "constructor(address,uint256)" 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5 2000000000000000000)
   forge verify-contract <address> src/NightWatchers.sol:NightWatchers --chain 1 --verifier sourcify
   ```

   `bytecode_hash = "none"` means Sourcify records a partial (runtime) match rather than a full metadata
   match; Etherscan verifies normally with the pinned compiler settings.

## Assumptions

- NIGHT FROGS is a standard ERC-721 with no burn and no transfer restrictions to `0x…dEaD`; its
  `randomWord()` is fixed since the reveal (verified non-zero at block 26,244,100). The frog renderer's trait
  indices are within each layer's row of the `COUNT` table (6, 6, 8, 6, 8, 8, 6 entries).
- IMD is a plain ERC-20 (no fee on transfer, no hooks); the fork tests show exactly 1 IMD arriving at each
  recipient per forge. The BurnExecutor accepts plain ERC-20 transfers.
- The forge fee is fixed at deployment (`FEE` immutable) and has no setter, as requested. A different fee
  needs a new deployment.
- The IMD launch fills the owner argument with `$owner`; the contract never uses `msg.sender` or
  `tx.origin` for ownership.
- The renderer and skin are trusted for `tokenURI` output only; they cannot touch tokens, frogs or IMD.

## Trust and security notes

- Checks, effects, interactions plus `ReentrancyGuard` on `forge`. Mints use `_mint`, so no receiver hook
  runs; ERC-721 `transferFrom` to `0x…dEaD` and ERC-20 `transferFrom` have no callbacks on these tokens.
- The contract custodies nothing: no ETH entry point (no `receive`/`fallback`), never holds frogs or IMD.
- Ownership check for frogs is `ownerOf(id) == msg.sender`; approvals or operator rights on someone else's
  frog cannot be used.
- Duplicate detection uses a 512-bit bitmap over the id range, so a frog cannot be counted twice.
- This is not an audit. Tests passing do not replace an independent adversarial review before release.

## Tests

```sh
forge build
forge test                       # unit suite with mocks; fork suite skips without an RPC
forge test --match-contract NightWatchersForkTest   # mainnet fork at block 26,244,100 via [rpc_endpoints].mainnet
forge fmt --check
```

- `test/NightWatchers.t.sol` (49 tests): mocks etched at the real addresses. Every tier, the Captain forge,
  all reverts (duplicate, id 0 and 501, someone else's frog even when approved, minTier, no frog approval,
  no IMD allowance or balance, no renderer), frogs ending at `0x…dEaD`, exact fee split, 50-forge sell-out,
  `setRenderer` once and owner only, `setName` rules, `tokenURI` as valid JSON (parsed with `vm.parseJson`)
  with image = svg minus `</svg>` + layer + `</svg>`, the full 500-frog points table, the `COUNT` table, and
  the fuzz `preview == forge`.
- `test/NightWatchersFork.t.sol` (13 tests): the real NIGHT FROGS, renderer and IMD at a pinned block. Real
  holders are impersonated and their frogs gathered to one of them; every tier, the Captain (token 0 carries
  #1's real traits: Genesis Sunburst, Gold Tracksuit, Chrome, Gold Crown), reverts, exact 1 IMD + 1 IMD fee
  flow on the real token, `setRenderer`, `setName` and `tokenURI` with mock renderer and skin. When no RPC is
  reachable the fork cannot be created and every test is skipped, so the suite stays green offline.
- Fuzz tests were run with the verifier's seed
  `FOUNDRY_FUZZ_SEED=0xd3395d601fbfe88da80f89ed64344c13a238525675e6ff8ff9f53966a6bf7772`.

Dependencies are vendored as plain files in `lib/` (forge-std v1.11.0, OpenZeppelin Contracts v5.4.0); there
are no git submodules.
