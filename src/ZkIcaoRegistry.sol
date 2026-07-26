// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IVerifier} from "./RegistrationVerifier.sol";

/// One application's on chain registry: the aggregate bundle form of the off
/// chain checklist, ported to a contract.
///
/// A holder registers once with two proofs. The registration proof carries
/// the whole document chain, verified recursively in circuit, and exposes
/// only the six values below. The nullifier proof carries the scoped
/// uniqueness value. The contract holds them to each other and to its own
/// policy, then stores the nullifier, which is what makes a second
/// registration of the same document visible without identifying anyone.
///
/// The context is the sender address, so a proof prepared for one sender
/// reverts in anyone else's transaction: relaying is impossible without the
/// holder having chosen the relayer at proving time.
///
/// What this deliberately does not do mirrors the off chain verifier: it
/// stores one value per document, not per person, so a reissued document
/// registers again under a new nullifier, and retiring the old one is an
/// application decision this reference contract does not take.
contract ZkIcaoRegistry {
    /// registration public inputs, in layout order:
    /// [domain, context, commitment, secret_binding, current_yyyymmdd, registry_root]
    IVerifier public immutable registrationVerifier;

    /// nullifier public inputs, in layout order:
    /// [commitment, secret_binding, domain, context, nullifier]
    IVerifier public immutable nullifierVerifier;

    /// The application scope. Every derived value a holder produced for this
    /// registry was hashed against it, so proofs for another domain revert.
    bytes32 public immutable domain;

    /// The signer registry or master list the registration must anchor to.
    bytes32 public immutable signerRegistryRoot;

    /// The inclusive window the proving date has to fall in, as YYYYMMDD.
    /// That date decides the century of a two digit birth year and gates
    /// certificate validity, so leaving it unchecked would let a prover
    /// move a birth date by a hundred years.
    uint256 public immutable earliestDate;

    uint256 public immutable latestDate;

    mapping(bytes32 => bool) public nullifierSeen;

    mapping(bytes32 => bool) public registeredCommitment;

    event Registered(bytes32 indexed commitment, bytes32 indexed nullifier);

    error MalformedInputs();

    error WrongDomain();

    error WrongContext();

    error WrongRegistry();

    error DateOutsideWindow();

    error UnlinkedCommitment();

    error NullifierFromAnotherDocument();

    error AlreadyRegistered();

    error RegistrationProofRejected();

    error NullifierProofRejected();

    constructor(
        IVerifier registrationVerifier_,
        IVerifier nullifierVerifier_,
        bytes32 domain_,
        bytes32 signerRegistryRoot_,
        uint256 earliestDate_,
        uint256 latestDate_
    ) {
        require(earliestDate_ <= latestDate_, "an empty date window accepts nothing");

        registrationVerifier = registrationVerifier_;

        nullifierVerifier = nullifierVerifier_;

        domain = domain_;

        signerRegistryRoot = signerRegistryRoot_;

        earliestDate = earliestDate_;

        latestDate = latestDate_;
    }

    function register(
        bytes calldata registrationProof,
        bytes32[] calldata registrationInputs,
        bytes calldata nullifierProof,
        bytes32[] calldata nullifierInputs
    ) external returns (bytes32 commitment, bytes32 nullifier) {
        if (registrationInputs.length != 6 || nullifierInputs.length != 5) {
            revert MalformedInputs();
        }

        if (registrationInputs[0] != domain || nullifierInputs[2] != domain) {
            revert WrongDomain();
        }

        bytes32 context = bytes32(uint256(uint160(msg.sender)));

        if (registrationInputs[1] != context || nullifierInputs[3] != context) {
            revert WrongContext();
        }

        if (registrationInputs[5] != signerRegistryRoot) {
            revert WrongRegistry();
        }

        uint256 date = uint256(registrationInputs[4]);

        if (date < earliestDate || date > latestDate) {
            revert DateOutsideWindow();
        }

        commitment = registrationInputs[2];

        if (nullifierInputs[0] != commitment) {
            revert UnlinkedCommitment();
        }

        if (nullifierInputs[1] != registrationInputs[3]) {
            revert NullifierFromAnotherDocument();
        }

        nullifier = nullifierInputs[4];

        if (nullifierSeen[nullifier]) {
            revert AlreadyRegistered();
        }

        if (!registrationVerifier.verify(registrationProof, registrationInputs)) {
            revert RegistrationProofRejected();
        }

        if (!nullifierVerifier.verify(nullifierProof, nullifierInputs)) {
            revert NullifierProofRejected();
        }

        nullifierSeen[nullifier] = true;

        registeredCommitment[commitment] = true;

        emit Registered(commitment, nullifier);
    }
}
