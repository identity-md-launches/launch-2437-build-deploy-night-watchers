// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {NightWatchers} from "../src/NightWatchers.sol";

/// @notice Deploys NIGHT WATCHERS. The IMD launch deploys it through its factory from the built bytecode
///         with the same two constructor arguments; this script is for rehearsal and for a manual deploy.
contract DeployNightWatchers is Script {
    /// @notice The launch owner: may call `setRenderer` once.
    address public constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    /// @notice The forge fee: 2 IMD.
    uint256 public constant FEE = 2e18;

    /// @notice Deploys with the given configuration. Tests call this directly.
    function deploy(address owner_, uint256 fee_) public returns (NightWatchers) {
        return new NightWatchers(owner_, fee_);
    }

    /// @notice `forge script script/Deploy.s.sol --rpc-url <mainnet> --broadcast --verify`
    function run() external returns (NightWatchers deployed) {
        vm.startBroadcast();
        deployed = deploy(OWNER, FEE);
        vm.stopBroadcast();
    }
}
