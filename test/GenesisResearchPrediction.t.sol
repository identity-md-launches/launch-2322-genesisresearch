// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GenesisResearch} from "../src/GenesisResearch.sol";
import {GenesisFixture} from "./helpers/GenesisHarness.sol";

contract GenesisResearchPredictionTest is GenesisFixture {
    bytes32 internal constant OUTPUT = keccak256("public prediction test document");
    bytes32 internal constant SALT = keccak256("public test salt, not a secret seed");

    function testInvalidEpochDefinitionsAndMissingEpochsAreRejected() public {
        uint64 now_ = uint64(block.timestamp);
        vm.startPrank(OWNER);
        vm.expectRevert(GenesisResearch.InvalidEpoch.selector);
        research.openEpoch(0, now_ + 10, now_ + 20);
        vm.expectRevert(GenesisResearch.InvalidEpoch.selector);
        research.openEpoch("target", now_, now_ + 20);
        vm.expectRevert(GenesisResearch.InvalidEpoch.selector);
        research.openEpoch("target", now_ - 1, now_ + 20);
        vm.expectRevert(GenesisResearch.InvalidEpoch.selector);
        research.openEpoch("target", now_ + 10, now_ + 10);
        vm.expectRevert(GenesisResearch.InvalidEpoch.selector);
        research.openEpoch("target", now_ + 10, now_ + 9);
        vm.stopPrank();
        vm.expectRevert(GenesisResearch.InvalidEpoch.selector);
        research.commitPrediction(0, OUTPUT);
        vm.expectRevert(GenesisResearch.InvalidEpoch.selector);
        research.revealPrediction(1, OUTPUT, SALT);
        require(research.epochCount() == 0, "invalid epoch consumed an id");
    }

    function testZeroCommitmentAndUncommittedOrZeroPredictionRevealFail() public {
        uint256 epoch = open(10, 20);
        vm.prank(DONOR);
        vm.expectRevert(GenesisResearch.InvalidPrediction.selector);
        research.commitPrediction(epoch, 0);
        bytes32 zeroOutputCommitment = research.predictionCommitment(epoch, DONOR, 0, SALT);
        vm.prank(DONOR);
        research.commitPrediction(epoch, zeroOutputCommitment);
        vm.warp(block.timestamp + 10);
        vm.prank(STRANGER);
        vm.expectRevert(GenesisResearch.InvalidPrediction.selector);
        research.revealPrediction(epoch, OUTPUT, SALT);
        vm.prank(DONOR);
        vm.expectRevert(GenesisResearch.InvalidPrediction.selector);
        research.revealPrediction(epoch, 0, SALT);
        (bytes32 commitment, bytes32 output, bool revealed) = research.predictions(epoch, DONOR);
        require(commitment == zeroOutputCommitment && output == 0 && !revealed, "invalid reveal changed prediction");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzzCommitRevealRoundTripAndWrongPreimages(
        bytes32 hashSeed,
        bytes32 salt,
        uint32 lead,
        uint32 duration
    ) public {
        bytes32 output = hashSeed == 0 ? bytes32(uint256(1)) : hashSeed;
        uint64 commitAt = uint64(vm.getBlockTimestamp() + bound(lead, 1, 30 days));
        uint64 revealUntil = uint64(uint256(commitAt) + bound(duration, 1, 30 days));
        vm.prank(OWNER);
        uint256 epoch = research.openEpoch(keccak256("fuzz target"), commitAt, revealUntil);
        bytes32 commitment = research.predictionCommitment(epoch, DONOR, output, salt);
        vm.prank(DONOR);
        research.commitPrediction(epoch, commitment);
        vm.warp(commitAt - 1);
        vm.prank(DONOR);
        vm.expectRevert(GenesisResearch.TooEarly.selector);
        research.revealPrediction(epoch, output, salt);
        vm.warp(commitAt);
        vm.startPrank(DONOR);
        vm.expectRevert(GenesisResearch.InvalidPrediction.selector);
        research.revealPrediction(epoch, output ^ bytes32(uint256(1)), salt);
        vm.expectRevert(GenesisResearch.InvalidPrediction.selector);
        research.revealPrediction(epoch, output, salt ^ bytes32(uint256(1)));
        research.revealPrediction(epoch, output, salt);
        vm.expectRevert(GenesisResearch.InvalidPrediction.selector);
        research.revealPrediction(epoch, output, salt);
        vm.stopPrank();
        (bytes32 storedCommitment, bytes32 storedOutput, bool revealed) = research.predictions(epoch, DONOR);
        require(storedCommitment == commitment && storedOutput == output && revealed, "round trip failed");
        require(token.balanceOf(address(research)) == 3 ether && research.spent() == 0, "prediction paid a prize");
    }

    function testOneSecondWindowsHaveExactCommitAndRevealBoundaries() public {
        uint256 start = vm.getBlockTimestamp();
        uint256 epoch = open(1, 2);
        bytes32 commitment = research.predictionCommitment(epoch, DONOR, OUTPUT, SALT);
        vm.prank(DONOR);
        research.commitPrediction(epoch, commitment);
        vm.warp(start + 1);
        vm.prank(STRANGER);
        vm.expectRevert(GenesisResearch.CommitClosed.selector);
        research.commitPrediction(epoch, commitment);
        vm.prank(DONOR);
        research.revealPrediction(epoch, OUTPUT, SALT);
        vm.warp(start + 2);
        vm.prank(DONOR);
        vm.expectRevert(GenesisResearch.RevealClosed.selector);
        research.revealPrediction(epoch, OUTPUT, SALT);
        (, bytes32 output, bool revealed) = research.predictions(epoch, DONOR);
        require(revealed && output == OUTPUT, "deadline destroyed accepted reveal");
    }

    function testExpiredUnrevealedPredictionStaysCommitted() public {
        uint256 epoch = open(10, 20);
        bytes32 commitment = research.predictionCommitment(epoch, DONOR, OUTPUT, SALT);
        vm.prank(DONOR);
        research.commitPrediction(epoch, commitment);
        vm.warp(block.timestamp + 20);
        vm.prank(DONOR);
        vm.expectRevert(GenesisResearch.RevealClosed.selector);
        research.revealPrediction(epoch, OUTPUT, SALT);
        vm.prank(DONOR);
        vm.expectRevert(GenesisResearch.CommitClosed.selector);
        research.commitPrediction(epoch, commitment);
        (bytes32 stored, bytes32 output, bool revealed) = research.predictions(epoch, DONOR);
        require(stored == commitment && output == 0 && !revealed, "expired prediction overwritten");
    }

    function testParticipantAndChainReplayCannotReveal() public {
        vm.chainId(1);
        uint256 epoch = open(10, 20);
        bytes32 commitment = research.predictionCommitment(epoch, DONOR, OUTPUT, SALT);
        vm.prank(DONOR);
        research.commitPrediction(epoch, commitment);
        vm.prank(STRANGER);
        research.commitPrediction(epoch, commitment);
        vm.warp(block.timestamp + 10);
        vm.prank(STRANGER);
        vm.expectRevert(GenesisResearch.InvalidPrediction.selector);
        research.revealPrediction(epoch, OUTPUT, SALT);
        vm.chainId(4663);
        require(research.predictionCommitment(epoch, DONOR, OUTPUT, SALT) != commitment, "chain not bound");
        vm.prank(DONOR);
        vm.expectRevert(GenesisResearch.InvalidPrediction.selector);
        research.revealPrediction(epoch, OUTPUT, SALT);
        vm.chainId(1);
        vm.prank(DONOR);
        research.revealPrediction(epoch, OUTPUT, SALT);
        (, bytes32 output, bool revealed) = research.predictions(epoch, DONOR);
        require(revealed && output == OUTPUT, "correct chain did not reveal");
    }

    function testCopiedCommitmentCannotCrossContractsOrSameTargetEpochs() public {
        uint256 first = open(10, 20);
        uint256 second = open(10, 20); // Same target and deadlines: epoch number must still separate commitments.
        bytes32 commitment = research.predictionCommitment(first, DONOR, OUTPUT, SALT);
        vm.prank(DONOR);
        research.commitPrediction(second, commitment);
        GenesisResearch other = new GenesisResearch(OWNER, address(intake), address(token), WORLD, CAP, PRICE);
        vm.prank(OWNER);
        other.openEpoch(keccak256("fixed target"), uint64(block.timestamp + 10), uint64(block.timestamp + 20));
        vm.prank(DONOR);
        other.commitPrediction(first, commitment);
        vm.warp(block.timestamp + 10);
        vm.prank(DONOR);
        vm.expectRevert(GenesisResearch.InvalidPrediction.selector);
        research.revealPrediction(second, OUTPUT, SALT);
        vm.prank(DONOR);
        vm.expectRevert(GenesisResearch.InvalidPrediction.selector);
        other.revealPrediction(first, OUTPUT, SALT);
    }

    function testFutureEpochCommitmentCannotAnticipateAnUnpinnedTarget() public {
        bytes32 premature = research.predictionCommitment(1, DONOR, OUTPUT, SALT);
        uint256 epoch = open(10, 20);
        require(research.predictionCommitment(epoch, DONOR, OUTPUT, SALT) != premature, "target not bound");
        vm.prank(DONOR);
        research.commitPrediction(epoch, premature);
        vm.warp(block.timestamp + 10);
        vm.prank(DONOR);
        vm.expectRevert(GenesisResearch.InvalidPrediction.selector);
        research.revealPrediction(epoch, OUTPUT, SALT);
    }

    function testWorldBindingAtTheSameConsumerAddress() public {
        uint256 epoch = open(10, 20);
        bytes32 original = research.predictionCommitment(epoch, DONOR, OUTPUT, SALT);
        GenesisResearch differentWorld = new GenesisResearch(
            OWNER, address(intake), address(token), keccak256("different public world"), CAP, PRICE
        );
        // Isolate the immutable world input while keeping chain, address, epoch and target identical.
        // This is a test-only code replacement; the application has no upgrade mechanism.
        bytes memory originalCode = address(research).code;
        vm.etch(address(research), address(differentWorld).code);
        require(research.predictionCommitment(epoch, DONOR, OUTPUT, SALT) != original, "world not bound");
        vm.etch(address(research), originalCode);
        require(research.predictionCommitment(epoch, DONOR, OUTPUT, SALT) == original, "fixture restoration failed");
    }

    function testEpochAtUint64DeadlineLimitAndOldTargetsRemainImmutable() public {
        vm.prank(OWNER);
        uint256 first = research.openEpoch("far target", type(uint64).max - 1, type(uint64).max);
        open(10, 20);
        (bytes32 target, uint64 commitAt, uint64 revealUntil) = research.epochs(first);
        require(target == bytes32("far target"), "target overwritten");
        require(commitAt == type(uint64).max - 1 && revealUntil == type(uint64).max, "deadline truncated");
        bytes32 commitment = research.predictionCommitment(first, DONOR, OUTPUT, SALT);
        vm.prank(DONOR);
        research.commitPrediction(first, commitment);
        vm.warp(type(uint64).max - 1);
        vm.prank(DONOR);
        research.revealPrediction(first, OUTPUT, SALT);
        (, bytes32 output, bool revealed) = research.predictions(first, DONOR);
        require(revealed && output == OUTPUT, "uint64 boundary reveal failed");
    }

    function open(uint64 commitDelay, uint64 revealDelay) internal returns (uint256) {
        vm.prank(OWNER);
        return research.openEpoch(
            keccak256("fixed target"), uint64(block.timestamp + commitDelay), uint64(block.timestamp + revealDelay)
        );
    }
}
