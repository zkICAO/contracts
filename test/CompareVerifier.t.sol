// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {Groth16Verifier} from "../src/CompareVerifier.sol";

/// Verifies a Groth16 predicate on chain, over proofs the circom stack
/// produced from a commitment the Noir circuits made.
///
/// This is the other proving system, verified the other way. The registry
/// verifies an UltraHonk registration proof, which costs millions of gas
/// because the verifier is large; a Groth16 proof is a fixed pairing check
/// and a few hundred bytes, which is the whole reason the second stack
/// exists. The numbers this prints are the comparison.
///
/// The proving key behind this verifier came from a local phase 2
/// contribution, so this verifier belongs to a development ceremony and to
/// nothing else. A deployment exports its own from its own key.
contract CompareVerifierTest is Test {
    Groth16Verifier verifier;

    function setUp() public {
        verifier = new Groth16Verifier();
    }

    /// snarkjs writes the calldata as the four arrays the verifier takes,
    /// comma separated. Parsing it here rather than hardcoding the numbers
    /// keeps the fixture regenerable.
    function load(string memory name)
        internal
        view
        returns (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c, uint256[5] memory signals)
    {
        string memory raw = vm.readFile(string.concat("test/fixtures/groth16/", name, ".calldata"));

        // The file is a flat list of quoted hex values in the order the
        // verifier takes them: 2 for A, 4 for B, 2 for C, then the signals.
        bytes memory data = bytes(raw);

        uint256[] memory values = new uint256[](13);

        uint256 found = 0;

        uint256 index = 0;

        while (index < data.length && found < 13) {
            if (data[index] == '"') {
                uint256 end = index + 1;

                while (data[end] != '"') {
                    end++;
                }

                bytes memory slice = new bytes(end - index - 1);

                for (uint256 i = 0; i < slice.length; i++) {
                    slice[i] = data[index + 1 + i];
                }

                values[found] = vm.parseUint(string(slice));

                found++;

                index = end + 1;
            } else {
                index++;
            }
        }

        require(found == 13, "the calldata fixture is not thirteen values");

        a = [values[0], values[1]];

        // snarkjs writes B in the order the verifier reads it.
        b = [[values[2], values[3]], [values[4], values[5]]];

        c = [values[6], values[7]];

        for (uint256 i = 0; i < 5; i++) {
            signals[i] = values[8 + i];
        }
    }

    function test_verifies_a_predicate_and_measures_gas() public {
        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c, uint256[5] memory signals) = load("compare");

        uint256 before = gasleft();

        bool ok = verifier.verifyProof(a, b, c, signals);

        emit log_named_uint("Groth16 verifyProof gas", before - gasleft());

        assertTrue(ok, "a proof the circom stack made must verify");
    }

    /// The proof rapidsnark produced from a witness that satisfies nothing.
    /// It exists because neither the witness calculator nor the prover
    /// checks a constraint, and this is where it is refused.
    function test_refuses_a_proof_over_an_unsatisfied_witness() public view {
        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c, uint256[5] memory signals) = load("forged");

        assertFalse(verifier.verifyProof(a, b, c, signals), "an unsatisfied witness must not verify");
    }

    /// Changing a public signal changes what is being claimed, so the proof
    /// no longer matches it.
    function test_refuses_an_altered_public_signal() public view {
        (uint256[2] memory a, uint256[2][2] memory b, uint256[2] memory c, uint256[5] memory signals) = load("compare");

        signals[1] = signals[1] ^ 1;

        assertFalse(verifier.verifyProof(a, b, c, signals), "an altered signal must not verify");
    }

    function test_the_verifier_is_small() public {
        uint256 size = address(verifier).code.length;

        emit log_named_uint("Groth16 verifier bytes", size);

        // The UltraHonk verifier sits a few hundred bytes under the EIP-170
        // limit of 24,576. This one has room to spare, which is the other
        // half of what the second stack buys.
        assertLt(size, 8_000, "the Groth16 verifier grew unexpectedly");
    }
}
