// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Stand-in for NIGHT FROGS: a plain ERC-721 with a fixed VRF word and no burn.
contract MockFrogs is ERC721 {
    uint256 public constant WORD = 35429570828173908880356199774237038643724038961364838229381014887099201929822;

    constructor() ERC721("NIGHT FROGS", "NFROG") {}

    function randomWord() external pure returns (uint256) {
        return WORD;
    }

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @notice Stand-in for the NIGHT FROGS renderer: deterministic traits per (id, word), in-range per layer.
contract MockFrogRenderer {
    function rowLength(uint8 layer) public pure returns (uint8) {
        if (layer == 2 || layer == 4 || layer == 5) return 8;
        return 6;
    }

    function traits(uint256 id, uint256 word) external pure returns (uint8[7] memory t) {
        for (uint8 layer; layer < 7; ++layer) {
            t[layer] = uint8(uint256(keccak256(abi.encode(id, word, layer))) % rowLength(layer));
        }
    }

    function traitName(uint8 layer, uint8 index) external pure returns (string memory) {
        return string.concat("L", _d(layer), "-T", _d(index));
    }

    function _d(uint8 v) internal pure returns (string memory) {
        return string(abi.encodePacked(bytes1(uint8(48 + v))));
    }
}

/// @notice Stand-in for IMD.
contract MockIMD is ERC20 {
    constructor() ERC20("IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Stand-in for the Night Watch renderer. Echoes its inputs so tests can check what it was given.
contract MockWatchRenderer {
    function svg(
        uint256 n,
        uint8 tier,
        uint8[7] calldata traits,
        string calldata label,
        uint16[10] calldata inputs,
        uint16 points
    ) external pure returns (string memory) {
        bytes memory t;
        for (uint256 i; i < 7; ++i) {
            t = abi.encodePacked(t, bytes1(uint8(48 + traits[i])));
        }
        bytes memory inp;
        for (uint256 i; i < 10; ++i) {
            inp = abi.encodePacked(inp, _u(inputs[i]), ",");
        }
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg"><text id="n">',
            _u(n),
            '</text><text id="tier">',
            _u(tier),
            '</text><text id="traits">',
            string(t),
            '</text><text id="label">',
            label,
            '</text><text id="inputs">',
            string(inp),
            '</text><text id="points">',
            _u(points),
            "</text></svg>"
        );
    }

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory b;
        while (v != 0) {
            b = abi.encodePacked(bytes1(uint8(48 + v % 10)), b);
            v /= 10;
        }
        return string(b);
    }
}

/// @notice Stand-in for the Night Watch skin.
contract MockWatchSkin {
    function layer(uint256 n, uint8 tier, uint16[10] calldata inputs) external pure returns (string memory) {
        return string.concat(
            '<g id="skin" data-n="', _u(n), '" data-tier="', _u(tier), '" data-first="', _u(inputs[0]), '"/>'
        );
    }

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory b;
        while (v != 0) {
            b = abi.encodePacked(bytes1(uint8(48 + v % 10)), b);
            v /= 10;
        }
        return string(b);
    }
}

/// @notice A renderer whose svg does not end with `</svg>`, to show the splice is lenient.
contract BrokenWatchRenderer {
    function svg(uint256, uint8, uint8[7] calldata, string calldata, uint16[10] calldata, uint16)
        external
        pure
        returns (string memory)
    {
        return "<svg";
    }
}
