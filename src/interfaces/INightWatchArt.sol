// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The Night Watcher art contract, ordered separately. Its output always ends with `</svg>`.
interface INightWatchRenderer {
    function svg(
        uint256 n,
        uint8 tier,
        uint8[7] calldata traits,
        string calldata label,
        uint16[10] calldata inputs,
        uint16 points
    ) external view returns (string memory);
}

/// @notice The Night Watcher skin contract, ordered separately. Its output is spliced in before `</svg>`.
interface INightWatchSkin {
    function layer(uint256 n, uint8 tier, uint16[10] calldata inputs) external view returns (string memory);
}
