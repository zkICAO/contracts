// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";

import {HonkVerifier as RegistrationVerifier} from "../src/RegistrationVerifier.sol";
import {HonkVerifier as NullifierVerifier} from "../src/NullifierVerifier.sol";
import {IVerifier} from "../src/RegistrationVerifier.sol";
import {ZkIcaoRegistry} from "../src/ZkIcaoRegistry.sol";

/// Deploys one application's registry, with its policy supplied rather than
/// written down here.
///
/// Nothing in this repository knows a domain, a trust root or a date window,
/// because those are the deploying application's and differ per deployment.
/// They are read from the environment and every one is required: a missing
/// value stops the script rather than taking a default, since a default
/// domain would put two applications in one scope and a default root would
/// anchor to a registry nobody chose.
///
///     ZKICAO_DOMAIN            your application scope, a non zero bytes32
///                              distinct from every other application
///     ZKICAO_REGISTRY_ROOT     the signer registry or master list root you
///                              publish, as bytes32
///     ZKICAO_EARLIEST_DATE     the earliest proving date you accept, YYYYMMDD
///     ZKICAO_LATEST_DATE       the latest, YYYYMMDD
///
/// The private key is passed to forge, not read here, so no key material
/// reaches this file or any other in the repository:
///
///     forge script script/Deploy.s.sol --rpc-url <your rpc> \
///       --account <your keystore account> --broadcast
contract Deploy is Script {
    function run() external returns (ZkIcaoRegistry registry) {
        bytes32 domain = vm.envBytes32("ZKICAO_DOMAIN");

        bytes32 registryRoot = vm.envBytes32("ZKICAO_REGISTRY_ROOT");

        uint256 earliest = vm.envUint("ZKICAO_EARLIEST_DATE");

        uint256 latest = vm.envUint("ZKICAO_LATEST_DATE");

        require(domain != bytes32(0), "ZKICAO_DOMAIN must not be zero");

        require(registryRoot != bytes32(0), "ZKICAO_REGISTRY_ROOT must not be zero");

        require(earliest <= latest, "an empty date window accepts nothing");

        vm.startBroadcast();

        // The verifiers are generated from the circuits' verification keys.
        // Deploying them here ties this registry to the exact circuit
        // revision in the repository these were generated from.
        IVerifier registrationVerifier = IVerifier(address(new RegistrationVerifier()));

        IVerifier nullifierVerifier = IVerifier(address(new NullifierVerifier()));

        registry = new ZkIcaoRegistry(registrationVerifier, nullifierVerifier, domain, registryRoot, earliest, latest);

        vm.stopBroadcast();
    }
}
