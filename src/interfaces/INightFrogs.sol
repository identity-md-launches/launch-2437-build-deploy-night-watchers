// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The parts of NIGHT FROGS (0x55b8c762f1b86fe1d5406edaaae0f8ecf3688a0c) that NIGHT WATCHERS reads.
interface INightFrogs {
    function ownerOf(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function transferFrom(address from, address to, uint256 tokenId) external;
    /// @notice The collection's Chainlink VRF word, fixed since the reveal.
    function randomWord() external view returns (uint256);
}

/// @notice The NIGHT FROGS renderer (0x4D9BfbafE31eC18E9D3066F1475e24906d155D67).
interface INightFrogsRenderer {
    /// @notice Trait indices of a frog: Background, Body, Skin, Mouth, Eyes, Headwear, Accessory.
    function traits(uint256 tokenId, uint256 word) external view returns (uint8[7] memory);
    /// @notice Display name of trait `index` on `layer`.
    function traitName(uint8 layer, uint8 index) external view returns (string memory);
}
