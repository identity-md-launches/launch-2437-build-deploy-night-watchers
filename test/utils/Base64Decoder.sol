// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal standard-alphabet base64 decoder for tests (handles `=` padding).
library Base64Decoder {
    function decode(string memory input) internal pure returns (bytes memory) {
        bytes memory data = bytes(input);
        uint256 len = data.length;
        if (len == 0) return "";
        require(len % 4 == 0, "base64: bad length");
        uint256 outLen = (len / 4) * 3;
        if (data[len - 1] == "=") outLen--;
        if (data[len - 2] == "=") outLen--;
        bytes memory out = new bytes(outLen);
        uint256 o;
        for (uint256 i; i < len; i += 4) {
            uint256 n = (_val(data[i]) << 18) | (_val(data[i + 1]) << 12) | (_val(data[i + 2]) << 6) | _val(data[i + 3]);
            if (o < outLen) out[o++] = bytes1(uint8(n >> 16));
            if (o < outLen) out[o++] = bytes1(uint8(n >> 8));
            if (o < outLen) out[o++] = bytes1(uint8(n));
        }
        return out;
    }

    function _val(bytes1 c) private pure returns (uint256) {
        if (c >= "A" && c <= "Z") return uint8(c) - 65;
        if (c >= "a" && c <= "z") return uint8(c) - 97 + 26;
        if (c >= "0" && c <= "9") return uint8(c) - 48 + 52;
        if (c == "+") return 62;
        if (c == "/") return 63;
        if (c == "=") return 0;
        revert("base64: bad char");
    }

    /// @dev Strips `prefix` from the front of `s`; reverts if it does not start with it.
    function stripPrefix(string memory s, string memory prefix) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory p = bytes(prefix);
        require(b.length >= p.length, "prefix: too short");
        for (uint256 i; i < p.length; ++i) {
            require(b[i] == p[i], "prefix: mismatch");
        }
        bytes memory out = new bytes(b.length - p.length);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[i + p.length];
        }
        return string(out);
    }
}
