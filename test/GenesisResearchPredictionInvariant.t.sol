// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GenesisResearch} from "../src/GenesisResearch.sol";
import {GenesisTestBase, GenesisTokenDouble, GenesisIntakeDouble} from "./helpers/GenesisHarness.sol";

contract GenesisPredictionHandler is GenesisTestBase {
    struct EpochModel {
        bytes32 target;
        uint64 commitAt;
        uint64 revealUntil;
    }

    struct PredictionModel {
        bytes32 commitment;
        bytes32 output;
        bytes32 salt;
        uint256 committedAt;
        uint256 revealedAt;
        bool revealed;
    }

    GenesisResearch public immutable research;
    GenesisTokenDouble public immutable token;
    address[3] public actors;
    EpochModel[] private epochs;
    mapping(uint256 => mapping(uint256 => PredictionModel)) private predictions;
    uint256 public acceptedCommits;
    uint256 public acceptedReveals;
    uint256 public rejectedCalls;

    constructor() {
        token = new GenesisTokenDouble();
        GenesisIntakeDouble intake = new GenesisIntakeDouble(address(this), address(this), 1);
        research =
            new GenesisResearch(address(this), address(intake), address(token), keccak256("prediction world"), 1, 1);
        for (uint256 i; i < 3; ++i) {
            actors[i] = address(uint160(uint256(keccak256(abi.encode("prediction actor", i)))));
        }
        _open(keccak256("first target"), 1 days, 2 days);
    }

    function openEpoch(bytes32 targetSeed, uint256 leadSeed, uint256 durationSeed) external {
        if (epochs.length == 32) return;
        bytes32 target = targetSeed == 0 ? keccak256("nonzero target") : targetSeed;
        _open(target, bound(leadSeed, 1, 3 days), bound(durationSeed, 1, 3 days));
    }

    function commit(uint256 epochSeed, uint256 actorSeed, bytes32 outputSeed, bytes32 salt) external {
        uint256 index = bound(epochSeed, 0, epochs.length - 1);
        uint256 actor = bound(actorSeed, 0, 2);
        PredictionModel storage prediction = predictions[index][actor];
        bytes32 output = outputSeed == 0 ? keccak256("nonzero prediction") : outputSeed;
        bytes32 commitment = research.predictionCommitment(index + 1, actors[actor], output, salt);
        bytes4 expected;
        if (block.timestamp >= epochs[index].commitAt) expected = GenesisResearch.CommitClosed.selector;
        else if (prediction.commitment != 0) expected = GenesisResearch.InvalidPrediction.selector;
        vm.prank(actors[actor]);
        (bool ok, bytes memory result) =
            address(research).call(abi.encodeCall(research.commitPrediction, (index + 1, commitment)));
        if (expected != bytes4(0)) {
            assertError(ok, result, expected);
            ++rejectedCalls;
        } else {
            require(ok, "valid commitment rejected");
            predictions[index][actor] = PredictionModel(commitment, output, salt, block.timestamp, 0, false);
            ++acceptedCommits;
        }
    }

    function reveal(uint256 epochSeed, uint256 actorSeed, bool tamper) external {
        uint256 index = bound(epochSeed, 0, epochs.length - 1);
        uint256 actor = bound(actorSeed, 0, 2);
        EpochModel storage epoch = epochs[index];
        PredictionModel storage prediction = predictions[index][actor];
        bytes32 salt = tamper ? prediction.salt ^ bytes32(uint256(1)) : prediction.salt;
        bytes4 expected;
        if (block.timestamp < epoch.commitAt) {
            expected = GenesisResearch.TooEarly.selector;
        } else if (block.timestamp >= epoch.revealUntil) {
            expected = GenesisResearch.RevealClosed.selector;
        } else if (prediction.commitment == 0 || prediction.revealed || tamper) {
            expected = GenesisResearch.InvalidPrediction.selector;
        }
        vm.prank(actors[actor]);
        (bool ok, bytes memory result) =
            address(research).call(abi.encodeCall(research.revealPrediction, (index + 1, prediction.output, salt)));
        if (expected != bytes4(0)) {
            assertError(ok, result, expected);
            ++rejectedCalls;
        } else {
            require(ok, "valid reveal rejected");
            prediction.revealed = true;
            prediction.revealedAt = block.timestamp;
            ++acceptedReveals;
        }
    }

    function advanceTime(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 0, 2 days));
    }

    function advanceToBoundary(uint256 epochSeed, bool revealEnd, uint256 offsetSeed) external {
        EpochModel storage epoch = epochs[bound(epochSeed, 0, epochs.length - 1)];
        uint256 boundary = revealEnd ? epoch.revealUntil : epoch.commitAt;
        uint256 time = boundary - 1 + bound(offsetSeed, 0, 2);
        if (time > block.timestamp) vm.warp(time);
    }

    function attackEpoch(uint256 actorSeed, bool missingEpoch) external {
        vm.prank(actors[bound(actorSeed, 0, 2)]);
        bytes memory input = missingEpoch
            ? abi.encodeCall(research.commitPrediction, (epochs.length + 1, bytes32("bad")))
            : abi.encodeCall(
                research.openEpoch, (bytes32("replacement"), uint64(block.timestamp + 1), uint64(block.timestamp + 2))
            );
        (bool ok, bytes memory result) = address(research).call(input);
        assertError(
            ok, result, missingEpoch ? GenesisResearch.InvalidEpoch.selector : GenesisResearch.Unauthorized.selector
        );
        ++rejectedCalls;
    }

    function assertRegistry() external view {
        require(research.epochCount() == epochs.length, "phantom epoch");
        uint256 commits;
        uint256 reveals;
        for (uint256 i; i < epochs.length; ++i) {
            EpochModel storage epoch = epochs[i];
            (bytes32 target, uint64 commitAt, uint64 revealUntil) = research.epochs(i + 1);
            require(
                target == epoch.target && commitAt == epoch.commitAt && revealUntil == epoch.revealUntil,
                "epoch mutated"
            );
            for (uint256 j; j < 3; ++j) {
                PredictionModel storage expected = predictions[i][j];
                (bytes32 commitment, bytes32 output, bool revealed) = research.predictions(i + 1, actors[j]);
                require(commitment == expected.commitment && revealed == expected.revealed, "prediction overwritten");
                require(output == (revealed ? expected.output : bytes32(0)), "unrevealed output leaked or changed");
                if (commitment != 0) {
                    ++commits;
                    require(expected.committedAt < commitAt, "late commitment accepted");
                }
                if (revealed) {
                    ++reveals;
                    require(commitment != 0 && output != 0, "revealed without valid commitment");
                    require(
                        expected.revealedAt >= commitAt && expected.revealedAt < revealUntil, "out-of-window reveal"
                    );
                }
            }
        }
        require(commits == acceptedCommits && reveals == acceptedReveals, "counter drift");
        require(token.balanceOf(address(research)) == 0 && research.spent() == 0, "prediction moved value");
        require(research.requestCount() == 0 && research.pendingRequestId() == 0, "prediction opened a job");
    }

    function _open(bytes32 target, uint256 lead, uint256 duration) private {
        uint64 commitAt = uint64(block.timestamp + lead);
        uint64 revealUntil = uint64(uint256(commitAt) + duration);
        uint256 id = research.openEpoch(target, commitAt, revealUntil);
        epochs.push(EpochModel(target, commitAt, revealUntil));
        require(id == epochs.length, "epoch number skipped or reused");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract GenesisResearchPredictionInvariantTest is GenesisTestBase {
    GenesisPredictionHandler public handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        handler = new GenesisPredictionHandler();
    }

    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function invariant_TargetsCommitmentsAndRevealsArePermanentAndTimeBound() public view {
        handler.assertRegistry();
    }

    function testHandlerReachesValidAndInvalidPredictionTransitions() public {
        handler.commit(0, 0, keccak256("output"), keccak256("salt"));
        handler.commit(0, 0, keccak256("replacement"), keccak256("salt"));
        handler.reveal(0, 0, false); // too early
        handler.advanceToBoundary(0, false, 1); // exactly commit deadline
        handler.reveal(0, 0, true); // wrong preimage
        handler.reveal(0, 0, false);
        handler.reveal(0, 0, false); // replay
        handler.advanceToBoundary(0, true, 1); // exactly reveal deadline
        handler.reveal(0, 0, false); // closed
        handler.assertRegistry();
        require(handler.acceptedCommits() == 1 && handler.acceptedReveals() == 1, "vacuous prediction handler");
        require(handler.rejectedCalls() == 5, "negative prediction paths missing");
    }
}
