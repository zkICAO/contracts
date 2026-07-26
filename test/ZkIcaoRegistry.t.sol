// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {HonkVerifier as RegistrationVerifier} from "../src/RegistrationVerifier.sol";
import {HonkVerifier as NullifierVerifier} from "../src/NullifierVerifier.sol";
import {IVerifier} from "../src/RegistrationVerifier.sol";
import {ZkIcaoRegistry} from "../src/ZkIcaoRegistry.sol";

/// Runs the registry over proofs the circuits actually produced, committed
/// under test/fixtures. The fixtures were proved with domain 42 and context
/// 99, so the registering sender must be address(99): the context is the
/// sender, and these tests exercise exactly that binding.
contract ZkIcaoRegistryTest is Test {
    ZkIcaoRegistry registry;

    address constant HOLDER = address(uint160(99));

    bytes registrationProof;

    bytes32[] registrationInputs;

    bytes nullifierProof;

    bytes32[] nullifierInputs;

    function setUp() public {
        registrationProof = vm.readFileBinary("test/fixtures/registration.proof");

        registrationInputs = split(vm.readFileBinary("test/fixtures/registration.inputs"));

        nullifierProof = vm.readFileBinary("test/fixtures/nullifier.proof");

        nullifierInputs = split(vm.readFileBinary("test/fixtures/nullifier.inputs"));

        registry = new ZkIcaoRegistry(
            IVerifier(address(new RegistrationVerifier())),
            IVerifier(address(new NullifierVerifier())),
            registrationInputs[0],
            registrationInputs[5],
            20260101,
            20261231
        );
    }

    function split(bytes memory raw) internal pure returns (bytes32[] memory elements) {
        require(raw.length % 32 == 0, "field data is whole 32 byte elements");

        elements = new bytes32[](raw.length / 32);

        for (uint256 i = 0; i < elements.length; i++) {
            bytes32 element;

            uint256 offset = 32 + i * 32;

            assembly {
                element := mload(add(raw, offset))
            }

            elements[i] = element;
        }
    }

    function register() internal returns (bytes32, bytes32) {
        return registry.register(registrationProof, registrationInputs, nullifierProof, nullifierInputs);
    }

    function test_registers_a_document_and_measures_gas() public {
        vm.prank(HOLDER);

        uint256 before = gasleft();

        (bytes32 commitment, bytes32 nullifier) = register();

        emit log_named_uint("register() gas", before - gasleft());

        assertTrue(registry.registeredCommitment(commitment));

        assertTrue(registry.nullifierSeen(nullifier));
    }

    function test_rejects_the_same_document_twice() public {
        vm.prank(HOLDER);

        register();

        vm.prank(HOLDER);

        vm.expectRevert(ZkIcaoRegistry.AlreadyRegistered.selector);

        register();
    }

    function test_rejects_another_sender() public {
        // No prank: the test contract is the sender, and the proofs were
        // bound to address(99) at proving time.
        vm.expectRevert(ZkIcaoRegistry.WrongContext.selector);

        register();
    }

    function test_rejects_a_tampered_registration_proof() public {
        registrationProof[1000] ^= 0x01;

        vm.prank(HOLDER);

        // The generated verifier surfaces an invalid proof either as a false
        // return or as its own revert, so only the failure itself is pinned.
        vm.expectRevert();

        register();
    }

    function test_rejects_a_tampered_nullifier_proof() public {
        nullifierProof[1000] ^= 0x01;

        vm.prank(HOLDER);

        vm.expectRevert();

        register();
    }

    function test_rejects_a_swapped_nullifier() public {
        // A nullifier proof for another document: its secret binding cannot
        // match the registration's.
        nullifierInputs[1] = bytes32(uint256(nullifierInputs[1]) ^ 1);

        vm.prank(HOLDER);

        vm.expectRevert(ZkIcaoRegistry.NullifierFromAnotherDocument.selector);

        register();
    }

    function test_rejects_another_registry() public {
        ZkIcaoRegistry other = new ZkIcaoRegistry(
            registry.registrationVerifier(),
            registry.nullifierVerifier(),
            registrationInputs[0],
            bytes32(uint256(1)),
            20260101,
            20261231
        );

        vm.prank(HOLDER);

        vm.expectRevert(ZkIcaoRegistry.WrongRegistry.selector);

        other.register(registrationProof, registrationInputs, nullifierProof, nullifierInputs);
    }

    /// EIP-170 caps deployed code at 24,576 bytes. The generated verifiers
    /// sit just under it, so this is the check that the contracts can be
    /// deployed at all, on any chain, and it fails long before anyone
    /// discovers it during a deployment. Measured on the deployed code
    /// rather than an artifact, which is what a chain would see.
    function test_the_verifiers_fit_the_contract_size_limit() public {
        uint256 limit = 24_576;

        address registration = address(registry.registrationVerifier());

        address nullifier = address(registry.nullifierVerifier());

        uint256 registrationSize = registration.code.length;

        uint256 nullifierSize = nullifier.code.length;

        emit log_named_uint("registration verifier bytes", registrationSize);

        emit log_named_uint("margin to the limit", limit - registrationSize);

        emit log_named_uint("nullifier verifier bytes", nullifierSize);

        assertLt(registrationSize, limit, "the registration verifier cannot be deployed");

        assertLt(nullifierSize, limit, "the nullifier verifier cannot be deployed");

        // The margin is small enough that a circuit change can cross it, so
        // this records what it was rather than only that it passed.
        assertGt(registrationSize, limit / 2, "the verifier shrank unexpectedly, re-measure");
    }

    /// A registration has to fit in a block. Mainnet targets 15 million gas
    /// and caps at 30 million, so a transaction near that ceiling is one no
    /// builder will include.
    function test_a_registration_fits_in_a_block() public {
        vm.prank(HOLDER);

        uint256 before = gasleft();

        register();

        uint256 used = before - gasleft();

        emit log_named_uint("register() gas", used);

        assertLt(used, 15_000_000, "a registration exceeds the mainnet gas target");
    }

    function test_rejects_a_date_outside_the_window() public {
        ZkIcaoRegistry strict = new ZkIcaoRegistry(
            registry.registrationVerifier(),
            registry.nullifierVerifier(),
            registrationInputs[0],
            registrationInputs[5],
            20250101,
            20250131
        );

        vm.prank(HOLDER);

        vm.expectRevert(ZkIcaoRegistry.DateOutsideWindow.selector);

        strict.register(registrationProof, registrationInputs, nullifierProof, nullifierInputs);
    }
}
