// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GenesisResearch} from "../src/GenesisResearch.sol";
import {GenesisTestBase, GenesisTokenDouble, GenesisIntakeDouble} from "./helpers/GenesisHarness.sol";

/// @dev Ghost balances are updated from successful operation INPUTS, never copied from the SUT.
/// Every expected rejection checks its exact error; an unexpected revert fails the campaign.
contract GenesisBudgetHandler is GenesisTestBase {
    struct Record {
        bytes32 id;
        bytes body;
        address intake;
        uint64 time;
        GenesisResearch.RequestState state;
        bytes32 result;
        bytes32 uri;
    }

    uint256 public constant CAP = 8 ether;
    uint256 public constant INITIAL_ACTOR_BALANCE = 100 ether;
    address public constant WRITER = address(uint160(uint256(keccak256("invariant writer"))));
    address public constant TREASURY = address(uint160(uint256(keccak256("invariant treasury"))));
    bytes32 public constant WORLD = keccak256("public invariant world fixture");
    GenesisTokenDouble public immutable token;
    GenesisResearch public immutable research;
    GenesisIntakeDouble[2] public intakes;
    address[3] public actors;
    uint256[3] public actorBalances;
    bool[3] public authorized;
    Record[] private records;
    uint256 public funded;
    uint256 public donated;
    uint256 public withdrawn;
    uint256 public paid;
    uint256 public modelPrice = 0.5 ether;
    uint256 public modelPending;
    uint256 public modelIntake;
    uint256 public attempts;
    uint256 public successfulOrders;
    uint256 public rejectedOrders;
    uint256 public successfulResults;
    uint256 public successfulFailures;
    uint256 public successfulAbandonments;

    constructor() {
        token = new GenesisTokenDouble();
        intakes[0] = new GenesisIntakeDouble(WRITER, TREASURY, modelPrice);
        intakes[1] = new GenesisIntakeDouble(WRITER, TREASURY, modelPrice);
        research = new GenesisResearch(address(this), address(intakes[0]), address(token), WORLD, CAP, modelPrice);
        for (uint256 i; i < 3; ++i) {
            actors[i] = address(uint160(uint256(keccak256(abi.encode("budget actor", i)))));
            actorBalances[i] = INITIAL_ACTOR_BALANCE;
            token.mint(actors[i], INITIAL_ACTOR_BALANCE);
        }
        authorized[0] = true;
        research.setResearcher(actors[0], true);
        _fund(0, 10 ether, false);
    }

    function fund(uint256 actorSeed, uint256 amountSeed, bool directDonation) external {
        uint256 index = bound(actorSeed, 0, 2);
        uint256 available = actorBalances[index];
        if (available == 0) return;
        uint256 maximum = available < 5 ether ? available : 5 ether;
        _fund(index, bound(amountSeed, 1, maximum), directDonation);
    }

    function withdraw(uint256 actorSeed, uint256 amountSeed) external {
        uint256 index = bound(actorSeed, 0, 2);
        uint256 amount = bound(amountSeed, 0, modelBalance());
        research.withdrawUnused(actors[index], amount);
        withdrawn += amount;
        actorBalances[index] += amount;
    }

    function setPrice(uint256 seed) external {
        modelPrice = bound(seed, 1, CAP / 16);
        research.setPrice(modelPrice);
        intakes[0].setQuote(modelPrice);
        intakes[1].setQuote(modelPrice);
    }

    function setResearcher(bool allowed) external {
        // Actor 0 is a persistent researcher, actor 1 can be revoked, actor 2 stays unprivileged.
        research.setResearcher(actors[1], allowed);
        authorized[1] = allowed;
    }

    function rotateIntake(uint256 seed) external {
        uint256 index = bound(seed, 0, 1);
        if (modelPending != 0) {
            (bool ok, bytes memory errorData) =
                address(research).call(abi.encodeCall(research.setIntake, (address(intakes[index]))));
            assertError(ok, errorData, GenesisResearch.PendingResearch.selector);
        } else {
            research.setIntake(address(intakes[index]));
            modelIntake = index;
        }
    }

    function order(uint256 actorSeed, bool legacy) external {
        uint256 index = bound(actorSeed, 0, 3);
        address caller = index == 3 ? address(this) : actors[index];
        bytes memory body = abi.encode("invariant raw body", ++attempts);
        bytes4 expected;
        if (index != 3 && !authorized[index]) expected = GenesisResearch.Unauthorized.selector;
        else if (modelPending != 0) expected = GenesisResearch.PendingResearch.selector;
        else if (modelPrice > CAP - paid) expected = GenesisResearch.BudgetExceeded.selector;
        else if (modelBalance() < modelPrice) expected = GenesisResearch.InsufficientFunds.selector;
        bytes memory input = legacy
            ? abi.encodeWithSignature("orderResearch(bytes)", body)
            : abi.encodeWithSignature("orderResearch(bytes,uint256)", body, modelPrice);
        vm.prank(caller);
        (bool ok, bytes memory result) = address(research).call(input);
        if (expected != bytes4(0)) {
            assertError(ok, result, expected);
            ++rejectedOrders;
            require(!research.usedBodies(keccak256(body)), "rejected order burned body");
            return;
        }
        require(ok, "valid order reverted");
        bytes32 id = abi.decode(result, (bytes32));
        require(id != 0, "zero id");
        for (uint256 i; i < records.length; ++i) {
            require(records[i].id != id, "duplicate id");
        }
        records.push(
            Record(
                id,
                body,
                address(intakes[modelIntake]),
                uint64(block.timestamp),
                GenesisResearch.RequestState.Pending,
                0,
                0
            )
        );
        modelPending = records.length;
        paid += modelPrice;
        ++successfulOrders;
    }

    function settle(uint256 statusSeed, bytes32 result) external {
        if (modelPending == 0) return;
        Record storage record = records[modelPending - 1];
        uint8 status = uint8(bound(statusSeed, 0, 2));
        bytes memory args;
        if (status == 0) args = abi.encode(record.id, result, "ipfs://invariant/result.json");
        else args = abi.encode(record.id, status, bytes32("failed"), uint16(0), uint16(0), bytes(""));
        vm.prank(WRITER);
        require(GenesisIntakeDouble(record.intake).complete(record.id, status, args), "legitimate callback failed");
        if (status == 0) {
            record.state = GenesisResearch.RequestState.Succeeded;
            record.result = result;
            record.uri = keccak256("ipfs://invariant/result.json");
            ++successfulResults;
        } else {
            record.state = GenesisResearch.RequestState.Failed;
            ++successfulFailures;
        }
        modelPending = 0;
    }

    function advanceTime(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 0, 7 days));
    }

    function abandon(bool reachDeadline) external {
        if (modelPending == 0) return;
        Record storage record = records[modelPending - 1];
        uint256 deadline = uint256(record.time) + 7 days;
        if (reachDeadline && vm.getBlockTimestamp() < deadline) vm.warp(deadline);
        if (vm.getBlockTimestamp() < deadline) {
            (bool ok, bytes memory errorData) =
                address(research).call(abi.encodeCall(research.abandonResearch, (record.id)));
            assertError(ok, errorData, GenesisResearch.TooEarly.selector);
        } else {
            research.abandonResearch(record.id);
            record.state = GenesisResearch.RequestState.Abandoned;
            modelPending = 0;
            ++successfulAbandonments;
        }
    }

    function replayBody(uint256 seed) external {
        if (records.length == 0) return;
        bytes memory body = records[bound(seed, 0, records.length - 1)].body;
        (bool ok, bytes memory errorData) =
            address(research).call(abi.encodeWithSignature("orderResearch(bytes,uint256)", body, modelPrice));
        assertError(
            ok,
            errorData,
            modelPending == 0 ? GenesisResearch.DuplicateBody.selector : GenesisResearch.PendingResearch.selector
        );
    }

    function attackCallback(uint256 seed, bool failure, bool spoofSender) external {
        bytes32 id = keccak256("never requested by this registry");
        address sender = address(intakes[modelIntake]);
        if (records.length != 0) {
            Record storage record = records[bound(seed, 0, records.length - 1)];
            sender = record.intake;
            if (record.state != GenesisResearch.RequestState.Pending || spoofSender) id = record.id;
        }
        if (spoofSender) sender = actors[2];
        bytes memory input = failure
            ? abi.encodeCall(research.onFailure, (id, 1, bytes32("forged"), 100, 100, bytes("signature")))
            : abi.encodeCall(research.onResult, (id, bytes32("forged"), "forged"));
        vm.prank(sender);
        (bool ok, bytes memory errorData) = address(research).call(input);
        assertError(ok, errorData, GenesisResearch.InvalidCallback.selector);
    }

    function attackAdministration(uint256 seed) external {
        bytes memory input;
        uint256 action = bound(seed, 0, 7);
        if (action == 0) {
            input = abi.encodeCall(research.setResearcher, (actors[2], true));
        } else if (action == 1) {
            input = abi.encodeCall(research.setPrice, (1));
        } else if (action == 2) {
            input = abi.encodeCall(research.setIntake, (address(intakes[1])));
        } else if (action == 3) {
            input = abi.encodeCall(research.withdrawUnused, (actors[2], 1));
        } else if (action == 4) {
            bytes32 id = modelPending == 0 ? bytes32(0) : records[modelPending - 1].id;
            input = abi.encodeCall(research.abandonResearch, (id));
        } else if (action == 5) {
            input = abi.encodeCall(
                research.openEpoch, (bytes32("target"), uint64(block.timestamp + 1), uint64(block.timestamp + 2))
            );
        } else if (action == 6) {
            input = abi.encodeWithSignature("orderResearch(bytes)", "attack");
        } else {
            input = abi.encodeWithSignature("orderResearch(bytes,uint256)", "attack", modelPrice);
        }
        vm.prank(actors[2]);
        (bool ok, bytes memory errorData) = address(research).call(input);
        assertError(ok, errorData, GenesisResearch.Unauthorized.selector);
    }

    function stalePriceOrder(uint256 seed) external {
        uint256 incorrectPrice = modelPrice + bound(seed, 1, CAP);
        bytes memory body = abi.encode("stale quote", ++attempts);
        (bool ok, bytes memory errorData) =
            address(research).call(abi.encodeWithSignature("orderResearch(bytes,uint256)", body, incorrectPrice));
        assertError(ok, errorData, GenesisResearch.UnexpectedPrice.selector);
        require(!research.usedBodies(keccak256(body)), "stale quote burned body");
    }

    function assertAccounting() external view {
        require(token.balanceOf(address(research)) == modelBalance(), "custody != inflows - outflows");
        require(token.balanceOf(TREASURY) == paid, "treasury != total successful prices");
        require(research.spent() == paid && paid <= CAP, "lifetime spending mismatch");
        require(research.remainingBudget() + paid == CAP, "budget restored or lost");
        require(research.price() == modelPrice && research.intake() == address(intakes[modelIntake]), "config mismatch");
        require(research.owner() == address(this) && research.asset() == address(token), "authority changed");
        require(research.spendCap() == CAP && research.worldCommitment() == WORLD, "immutable changed");
        uint256 sum = modelBalance() + paid;
        for (uint256 i; i < 3; ++i) {
            require(token.balanceOf(actors[i]) == actorBalances[i], "actor balance changed without authorization");
            require(research.researchers(actors[i]) == authorized[i], "researcher permissions differ");
            sum += actorBalances[i];
        }
        require(sum == 3 * INITIAL_ACTOR_BALANCE && token.totalSupply() == sum, "token conservation");
        for (uint256 i; i < 2; ++i) {
            require(token.balanceOf(address(intakes[i])) == 0, "intake escrowed payment");
            require(token.allowance(address(research), address(intakes[i])) == 0, "intake allowance left behind");
        }
        require(research.epochCount() == 0, "unauthorized epoch opened");
    }

    function assertHistory() external view {
        require(research.requestCount() == records.length && records.length == successfulOrders, "request count drift");
        uint256 pendingCount;
        for (uint256 i; i < records.length; ++i) {
            Record storage expected = records[i];
            (
                bytes32 body,
                bytes32 result,
                bytes32 uri,
                address source,
                uint64 time,
                GenesisResearch.RequestState state
            ) = research.requests(expected.id);
            require(body == keccak256(expected.body) && research.usedBodies(body), "paid body missing");
            require(source == expected.intake && time == expected.time, "provenance rewritten");
            require(state == expected.state && result == expected.result && uri == expected.uri, "history rewritten");
            if (state == GenesisResearch.RequestState.Pending) {
                ++pendingCount;
                require(modelPending == i + 1 && research.pendingRequestId() == expected.id, "wrong pending pointer");
            }
        }
        require(pendingCount <= 1, "multiple pending requests");
        if (modelPending == 0) require(pendingCount == 0 && research.pendingRequestId() == 0, "stale pending pointer");
        else require(pendingCount == 1, "missing pending request");
        require(
            successfulResults + successfulFailures + successfulAbandonments + pendingCount == records.length,
            "request lost or settled twice"
        );
    }

    function modelBalance() public view returns (uint256) {
        return funded + donated - withdrawn - paid;
    }

    function _fund(uint256 index, uint256 amount, bool direct) private {
        vm.startPrank(actors[index]);
        if (direct) {
            token.transfer(address(research), amount);
            donated += amount;
        } else {
            token.approve(address(research), amount);
            research.fund(amount);
            funded += amount;
        }
        vm.stopPrank();
        actorBalances[index] -= amount;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract GenesisResearchInvariantTest is GenesisTestBase {
    GenesisBudgetHandler public handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        handler = new GenesisBudgetHandler();
    }

    // Foundry's native targeting ABI. Only the handler's mutators can be randomized;
    // token mint/configuration and direct SUT calls cannot bypass the ghost accounting.
    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function invariant_CustodyConservationAndLifetimeBudget() public view {
        handler.assertAccounting();
    }

    function invariant_RequestHistoryIsPermanentAndSinglePending() public view {
        handler.assertHistory();
    }

    function testHandlerReachesPaymentsAllTerminalStatesAndRejections() public {
        handler.order(0, false);
        handler.order(0, true); // pending rejection
        handler.abandon(false); // early rejection
        handler.settle(0, keccak256("result"));
        handler.replayBody(0);
        handler.order(3, true);
        handler.settle(1, 0);
        handler.rotateIntake(1);
        handler.setResearcher(true);
        handler.order(1, false);
        handler.abandon(true);
        handler.setResearcher(false);
        handler.order(1, false); // revoked researcher
        handler.fund(2, 1 ether, true);
        handler.withdraw(2, 1 ether);
        handler.stalePriceOrder(1);
        handler.attackAdministration(0);
        handler.attackCallback(0, false, false);
        handler.assertAccounting();
        handler.assertHistory();
        require(handler.successfulOrders() == 3 && handler.rejectedOrders() == 2, "handler has no useful calls");
        require(
            handler.successfulResults() == 1 && handler.successfulFailures() == 1
                && handler.successfulAbandonments() == 1,
            "handler omitted terminal state"
        );
    }
}
