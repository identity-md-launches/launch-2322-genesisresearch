// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GenesisResearch, IERC20Genesis} from "../src/GenesisResearch.sol";
import {GenesisFixture, GenesisVm, GenesisTokenDouble, GenesisIntakeDouble} from "./helpers/GenesisHarness.sol";

contract GenesisResearchAdversarialTest is GenesisFixture {
    function testEveryOwnerPermissionRejectsDonorsResearchersAndStrangers() public {
        bytes32 id = order("authorization");
        address[4] memory callers = [DONOR, RESEARCHER, STRANGER, address(intake)];
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeCall(research.setResearcher, (STRANGER, true));
        calls[1] = abi.encodeCall(research.setPrice, (1));
        calls[2] = abi.encodeCall(research.setIntake, (address(token)));
        calls[3] = abi.encodeCall(research.withdrawUnused, (STRANGER, 1));
        calls[4] = abi.encodeCall(research.abandonResearch, (id));
        calls[5] = abi.encodeCall(
            research.openEpoch, (keccak256("target"), uint64(block.timestamp + 1), uint64(block.timestamp + 2))
        );
        bytes32 beforeState = snapshot("authorization");
        for (uint256 i; i < callers.length; ++i) {
            for (uint256 j; j < calls.length; ++j) {
                vm.prank(callers[i]);
                (bool ok, bytes memory errorData) = address(research).call(calls[j]);
                assertError(ok, errorData, GenesisResearch.Unauthorized.selector);
            }
        }
        require(snapshot("authorization") == beforeState, "unauthorized call changed accounting");
        require(!research.researchers(STRANGER) && research.price() == PRICE, "unauthorized configuration");
        require(research.intake() == address(intake) && research.epochCount() == 0, "unauthorized admin");
    }

    function testDonationsDoNotGrantEitherOrderPermission() public {
        bytes32 beforeState = snapshot("unauthorized");
        vm.prank(DONOR);
        vm.expectRevert(GenesisResearch.Unauthorized.selector);
        research.orderResearch("unauthorized");
        vm.prank(DONOR);
        vm.expectRevert(GenesisResearch.Unauthorized.selector);
        research.orderResearch("unauthorized", PRICE);
        require(snapshot("unauthorized") == beforeState, "donor changed state");
    }

    function testOwnerRejectsInvalidAdministrativeValues() public {
        vm.startPrank(OWNER);
        vm.expectRevert(GenesisResearch.InvalidConfiguration.selector);
        research.setResearcher(address(0), true);
        vm.expectRevert(GenesisResearch.InvalidConfiguration.selector);
        research.setPrice(0);
        vm.expectRevert(GenesisResearch.InvalidConfiguration.selector);
        research.setPrice(CAP + 1);
        vm.expectRevert(GenesisResearch.InvalidConfiguration.selector);
        research.setIntake(address(0));
        vm.expectRevert(GenesisResearch.InvalidConfiguration.selector);
        research.withdrawUnused(address(0), 1);
        vm.stopPrank();
        require(research.price() == PRICE && research.intake() == address(intake), "bad config persisted");
    }

    function testExactRawBodyPayerPaymentAndCallbackMetadata() public {
        bytes memory body = bytes('{"objective":"Review the published GENESIS methods.","template":"research"}');
        vm.recordLogs();
        bytes32 id = order(body);
        GenesisVm.Log[] memory logs = vm.getRecordedLogs();
        require(keccak256(intake.lastBody()) == keccak256(body), "body changed");
        require(intake.lastAsset() == address(token) && intake.lastAmount() == PRICE, "payment changed");
        require(
            intake.lastAction() == 0x6a6f622e6f70656e406a6f622d31000000000000000000000000000000000000,
            "action is not canonical"
        );
        (address payer, address target, bytes4 resultSelector, bytes4 failureSelector, bool completed,) =
            intake.asks(id);
        require(payer == address(research) && target == address(research), "wrong payer/target");
        require(resultSelector == 0x4374622e && failureSelector == 0x5a0df71e && !completed, "callback ABI");
        require(token.balanceOf(TREASURY) == PRICE && token.balanceOf(address(intake)) == 0, "not forwarded");
        require(token.allowance(address(research), address(intake)) == 0, "residual allowance");
        (bytes32 hash,,, address recordedIntake, uint64 time, GenesisResearch.RequestState state) =
            research.requests(id);
        require(hash == keccak256(body) && recordedIntake == address(intake), "provenance mismatch");
        require(time == block.timestamp && state == GenesisResearch.RequestState.Pending, "request metadata");
        require(logs.length == 1 && logs[0].emitter == address(research), "order event missing");
        require(logs[0].topics[0] == keccak256("ResearchOrdered(bytes32,bytes32,uint256)"), "order event signature");
        require(logs[0].topics[1] == id && logs[0].topics[2] == hash, "indexed provenance");
        require(abi.decode(logs[0].data, (uint256)) == PRICE, "event price");
    }

    function testBodyLengthEndpointsAndRejectedBodyCanBeCorrected() public {
        expectOrderRollback("", GenesisResearch.InvalidBody.selector);
        expectOrderRollback(new bytes(16 * 1024 + 1), GenesisResearch.InvalidBody.selector);
        bytes memory maximum = new bytes(16 * 1024);
        maximum[0] = 0x61;
        bytes32 id = order(maximum);
        require(keccak256(intake.lastBody()) == keccak256(maximum), "maximum body truncated");
        succeed(id);
        id = order(hex"01");
        require(research.pendingRequestId() == id, "one-byte body refused");
    }

    function testZeroIdRollsBackTreasuryTransferBudgetAndBody() public {
        intake.configureFault(true, bytes32(0), false, false, 0);
        expectOrderRollback("zero id", GenesisResearch.InvalidRequest.selector);
        intake.configureFault(false, 0, false, false, 0);
        require(order("zero id") != 0, "failed purchase burned body");
    }

    function testIntakeRevertAfterTransferRollsBackEverything() public {
        intake.configureFault(false, 0, true, false, 0);
        expectOrderRollback("revert after transfer", bytes4(0));
        intake.configureFault(false, 0, false, false, 0);
        order("revert after transfer");
    }

    function testPartialOrMissingPullCannotConsumeBudget() public {
        intake.configureFault(false, 0, false, true, 0);
        expectOrderRollback("no pull", GenesisResearch.UnsupportedToken.selector);
        intake.configureFault(false, 0, false, true, PRICE - 1);
        expectOrderRollback("short pull", GenesisResearch.UnsupportedToken.selector);
        intake.configureFault(false, 0, false, true, PRICE + 1);
        expectOrderRollback("excess pull", bytes4(0));
    }

    function testUnpricedAndUnderpricedActionsRollBackApprovals() public {
        intake.setQuote(0);
        expectOrderRollback("not sold", bytes4(0));
        intake.setQuote(PRICE + 1);
        expectOrderRollback("price moved", bytes4(0));
        intake.setQuote(PRICE);
        order("price moved");
    }

    function testAllThreeApprovalFailuresRollBackPurchase() public {
        for (uint256 occurrence = 1; occurrence <= 3; ++occurrence) {
            token.configureReturn(IERC20Genesis.approve.selector, occurrence, GenesisTokenDouble.ReturnMode.False);
            expectOrderRollback("approval failure", GenesisResearch.TokenCallFailed.selector);
        }
        token.configureReturn(IERC20Genesis.approve.selector, 0, GenesisTokenDouble.ReturnMode.Standard);
        order("approval failure");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzzMalformedTokenReturnNeverLeavesPartialFunding(uint8 modeSeed) public {
        uint256 choice = bound(modeSeed, 1, 5);
        GenesisTokenDouble.ReturnMode mode =
            choice <= 2 ? GenesisTokenDouble.ReturnMode(choice) : GenesisTokenDouble.ReturnMode(choice + 1);
        // False, Revert, Short, Long, InvalidBool; empty return is a supported ERC-20 convention.
        token.configureReturn(IERC20Genesis.transferFrom.selector, 0, mode);
        bytes32 beforeState = snapshot("fund fault");
        vm.prank(DONOR);
        (bool ok, bytes memory result) = address(research).call(abi.encodeCall(research.fund, (PRICE)));
        require(!ok, "invalid ERC-20 response accepted");
        if (mode != GenesisTokenDouble.ReturnMode.InvalidBool) {
            assertError(ok, result, GenesisResearch.TokenCallFailed.selector);
        }
        require(snapshot("fund fault") == beforeState, "failed funding retained token writes");
    }

    function testEmptyReturnTokenWorksForFundingPaymentAndWithdrawal() public {
        token.configureReturn(IERC20Genesis.transferFrom.selector, 0, GenesisTokenDouble.ReturnMode.Empty);
        vm.prank(DONOR);
        research.fund(1);
        token.configureReturn(IERC20Genesis.approve.selector, 0, GenesisTokenDouble.ReturnMode.Empty);
        bytes32 id = order("optional token returns");
        require(research.pendingRequestId() == id && token.balanceOf(TREASURY) == PRICE, "empty approval failed");
        token.configureReturn(IERC20Genesis.transfer.selector, 0, GenesisTokenDouble.ReturnMode.Empty);
        uint256 beforeBalance = token.balanceOf(DONOR);
        vm.prank(OWNER);
        research.withdrawUnused(DONOR, 1);
        require(token.balanceOf(DONOR) == beforeBalance + 1, "empty transfer failed");
    }

    function testZeroUnderfundedAndUnapprovedDepositsAreAtomic() public {
        bytes32 beforeState = snapshot("fund");
        vm.prank(DONOR);
        vm.expectRevert(GenesisResearch.InvalidConfiguration.selector);
        research.fund(0);
        vm.prank(STRANGER);
        vm.expectRevert(GenesisResearch.TokenCallFailed.selector);
        research.fund(1);
        vm.prank(DONOR);
        vm.expectRevert(GenesisResearch.TokenCallFailed.selector);
        research.fund(8 ether);
        require(snapshot("fund") == beforeState, "failed deposit moved balances");
    }

    function testFeeOnReceiptAndExcessPaymentDebitAreRejectedAtomically() public {
        token.configureFees(1, 0);
        bytes32 beforeState = snapshot("fee");
        uint256 supply = token.totalSupply();
        vm.prank(DONOR);
        vm.expectRevert(GenesisResearch.UnsupportedToken.selector);
        research.fund(PRICE);
        require(snapshot("fee") == beforeState && token.totalSupply() == supply, "fee deposit leaked");

        token.configureFees(0, 1);
        // Let the intake pay its own outgoing surcharge; the registry must still reject its excess debit.
        token.mint(address(intake), 1);
        expectOrderRollback("excess sender debit", GenesisResearch.UnsupportedToken.selector);
    }

    function testRejectedWithdrawalDoesNotChangeCustodyOrBudget() public {
        bytes32 beforeState = snapshot("withdraw");
        vm.prank(OWNER);
        vm.expectRevert(GenesisResearch.TokenCallFailed.selector);
        research.withdrawUnused(DONOR, 3 ether + 1);
        token.configureReturn(IERC20Genesis.transfer.selector, 0, GenesisTokenDouble.ReturnMode.False);
        vm.prank(OWNER);
        vm.expectRevert(GenesisResearch.TokenCallFailed.selector);
        research.withdrawUnused(DONOR, PRICE);
        require(snapshot("withdraw") == beforeState, "withdrawal not atomic");
    }

    function testTokenHooksCannotReenterFundingOrderingOrCallbacks() public {
        token.configureHook(address(research), IERC20Genesis.transferFrom.selector, abi.encodeCall(research.fund, (1)));
        vm.prank(DONOR);
        research.fund(1);
        assertError(token.hookSucceeded(), token.hookResult(), GenesisResearch.ReentrantCall.selector);
        token.configureHook(
            address(research), IERC20Genesis.approve.selector, abi.encodeWithSignature("orderResearch(bytes)", "nested")
        );
        bytes32 id = order("outer order");
        assertError(token.hookSucceeded(), token.hookResult(), GenesisResearch.ReentrantCall.selector);
        require(research.spent() == PRICE && research.requestCount() == 1, "nested purchase");
        succeed(id);
        token.configureHook(
            address(research),
            IERC20Genesis.transfer.selector,
            abi.encodeCall(research.onResult, (id, bytes32("forged"), "forged"))
        );
        vm.prank(OWNER);
        research.withdrawUnused(DONOR, 1);
        assertError(token.hookSucceeded(), token.hookResult(), GenesisResearch.ReentrantCall.selector);
        require(requestState(research, id) == GenesisResearch.RequestState.Succeeded, "result overwritten");
    }

    function testSynchronousFailureIsRejectedAndLaterDeliverySucceeds() public {
        bytes32 fixedId = keccak256("synchronous request");
        intake.configureFault(true, fixedId, false, false, 0);
        intake.configureHook(
            address(research),
            abi.encodeCall(research.onFailure, (fixedId, 1, bytes32("body_refused"), 0, 0, bytes("")))
        );
        require(order("synchronous failure") == fixedId, "unexpected request id");
        assertError(intake.hookSucceeded(), intake.hookResult(), GenesisResearch.ReentrantCall.selector);
        require(requestState(research, fixedId) == GenesisResearch.RequestState.Pending, "settled while ordering");
        fail(fixedId, 1);
        require(requestState(research, fixedId) == GenesisResearch.RequestState.Failed, "async failure lost");
    }

    function testOnlyWriterCanDeliverAndCompletionIsOneShot() public {
        bytes32 id = order("writer");
        bytes memory args = abi.encode(id, bytes32("result"), "ipfs://result");
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "not writer"));
        intake.complete(id, 0, args);
        require(requestState(research, id) == GenesisResearch.RequestState.Pending, "nonwriter settled");
        succeed(id);
        vm.prank(WRITER);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "not open"));
        intake.complete(id, 0, args);
    }

    function testBothFailureStatusesFitStipendEmitReasonAndNeverRefund() public {
        for (uint8 status = 1; status <= 2; ++status) {
            bytes32 id = order(abi.encode(status));
            uint256 balanceBefore = token.balanceOf(address(research));
            uint256 treasuryBefore = token.balanceOf(TREASURY);
            vm.recordLogs();
            fail(id, status);
            GenesisVm.Log[] memory logs = vm.getRecordedLogs();
            require(logs.length == 1 && logs[0].emitter == address(research), "failure event missing");
            require(logs[0].topics[0] == keccak256("ResearchFailed(bytes32,uint8,bytes32)"), "failure event ABI");
            require(logs[0].topics[1] == id, "failure event id");
            (uint8 emittedStatus, bytes32 reason) = abi.decode(logs[0].data, (uint8, bytes32));
            require(emittedStatus == status && reason == bytes32("body_refused"), "failure detail lost");
            require(token.balanceOf(address(research)) == balanceBefore, "failure moved custody");
            require(token.balanceOf(TREASURY) == treasuryBefore, "failure refunded");
            require(
                research.spent() == uint256(status) * PRICE && research.pendingRequestId() == 0, "failure accounting"
            );
            require(requestState(research, id) == GenesisResearch.RequestState.Failed, "not failed");
        }
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzzInvalidFailureStatusCannotClearRequest(uint8 rawStatus) public {
        uint8 status = rawStatus <= 2 ? 0 : rawStatus;
        bytes32 id = order("invalid status");
        bytes32 beforeState = snapshot("invalid status");
        vm.prank(address(intake));
        vm.expectRevert(GenesisResearch.InvalidCallback.selector);
        research.onFailure(id, status, "reason", type(uint16).max, type(uint16).max, hex"010203");
        require(snapshot("invalid status") == beforeState, "invalid status changed state");
        require(requestState(research, id) == GenesisResearch.RequestState.Pending, "invalid status settled");
    }

    function testResultEmitsFullUriAndStoresHashWithinStipend() public {
        bytes32 id = order("long uri");
        bytes memory uri = new bytes(2048);
        for (uint256 i; i < uri.length; ++i) {
            uri[i] = bytes1(uint8(33 + i % 90));
        }
        bytes32 result = keccak256("canonical result bytes");
        uint256 balanceBefore = token.balanceOf(address(research));
        vm.recordLogs();
        vm.prank(WRITER);
        require(intake.complete(id, 0, abi.encode(id, result, string(uri))), "200k stipend exceeded");
        GenesisVm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1 && logs[0].emitter == address(research), "result event missing");
        require(logs[0].topics[0] == keccak256("ResearchResult(bytes32,bytes32,string)"), "result event ABI");
        require(logs[0].topics[1] == id, "result event id");
        (bytes32 emittedHash, string memory emittedUri) = abi.decode(logs[0].data, (bytes32, string));
        require(emittedHash == result && keccak256(bytes(emittedUri)) == keccak256(uri), "event truncated");
        (, bytes32 storedResult, bytes32 storedUri,,,) = research.requests(id);
        require(storedResult == result && storedUri == keccak256(uri), "stored provenance");
        require(token.balanceOf(address(research)) == balanceBefore && research.spent() == PRICE, "result moved value");
    }

    function testRejectedDeliveryCanBeAbandonedAtExactTimeout() public {
        bytes32 id = order("lost delivery");
        uint256 orderedAt = vm.getBlockTimestamp();
        // A malformed writer payload fails; Intake records the one attempt, registry stays Pending.
        vm.prank(WRITER);
        require(!intake.complete(id, 0, hex"01"), "malformed payload accepted");
        (,,,, bool completed, bool delivered) = intake.asks(id);
        require(completed && !delivered && research.pendingRequestId() == id, "lost-delivery model");
        vm.warp(orderedAt + 7 days - 1);
        vm.prank(OWNER);
        vm.expectRevert(GenesisResearch.TooEarly.selector);
        research.abandonResearch(id);
        vm.warp(orderedAt + 7 days);
        vm.prank(OWNER);
        research.abandonResearch(id);
        require(requestState(research, id) == GenesisResearch.RequestState.Abandoned, "timeout did not unlock");
        require(research.spent() == PRICE && token.balanceOf(TREASURY) == PRICE, "timeout refunded");
        expectOrderRollback("lost delivery", GenesisResearch.DuplicateBody.selector);
        order("different after timeout");
    }

    function testEveryTerminalStateRejectsBothCallbacksAndAbandonment() public {
        for (uint256 terminal; terminal < 3; ++terminal) {
            bytes32 id = order(abi.encode("terminal", terminal));
            if (terminal == 0) {
                succeed(id);
            } else if (terminal == 1) {
                fail(id, 2);
            } else {
                vm.warp(block.timestamp + 7 days);
                vm.prank(OWNER);
                research.abandonResearch(id);
            }
            GenesisResearch.RequestState state = requestState(research, id);
            vm.startPrank(address(intake));
            vm.expectRevert(GenesisResearch.InvalidCallback.selector);
            research.onResult(id, "changed", "changed");
            vm.expectRevert(GenesisResearch.InvalidCallback.selector);
            research.onFailure(id, 1, "changed", 1, 1, hex"aa");
            vm.stopPrank();
            vm.prank(OWNER);
            vm.expectRevert(GenesisResearch.InvalidRequest.selector);
            research.abandonResearch(id);
            require(requestState(research, id) == state, "terminal state reopened");
            expectOrderRollback(abi.encode("terminal", terminal), GenesisResearch.DuplicateBody.selector);
        }
    }

    function testUnknownAndForeignCallbacksLeavePendingRequestUntouched() public {
        bytes32 id = order("pending");
        bytes32 unknown = keccak256("unknown");
        vm.startPrank(address(intake));
        vm.expectRevert(GenesisResearch.InvalidCallback.selector);
        research.onResult(unknown, "result", "uri");
        vm.expectRevert(GenesisResearch.InvalidCallback.selector);
        research.onFailure(unknown, 1, "reason", 0, 0, "");
        vm.stopPrank();
        vm.prank(STRANGER);
        vm.expectRevert(GenesisResearch.InvalidCallback.selector);
        research.onFailure(id, 2, "reason", 0, 0, "");
        vm.prank(OWNER);
        vm.expectRevert(GenesisResearch.InvalidRequest.selector);
        research.abandonResearch(unknown);
        require(research.pendingRequestId() == id && research.spent() == PRICE, "foreign callback changed state");
    }

    function testIntakeMigrationDoesNotAuthorizeOldIntakeOrReuseOldIds() public {
        bytes32 oldId = order("old intake");
        fail(oldId, 1);
        GenesisIntakeDouble next = new GenesisIntakeDouble(WRITER, TREASURY, PRICE);
        vm.prank(OWNER);
        research.setIntake(address(next));
        next.configureFault(true, oldId, false, false, 0);
        uint256 treasuryBefore = token.balanceOf(TREASURY);
        vm.prank(RESEARCHER);
        vm.expectRevert(GenesisResearch.InvalidRequest.selector);
        research.orderResearch("new intake", PRICE);
        require(token.balanceOf(TREASURY) == treasuryBefore, "reused id paid");
        require(!research.usedBodies(keccak256("new intake")) && research.requestCount() == 1, "reused id recorded");
        require(token.allowance(address(research), address(next)) == 0, "reused id left allowance");
        next.configureFault(false, 0, false, false, 0);
        bytes32 newId = order("new intake");
        vm.prank(address(intake));
        vm.expectRevert(GenesisResearch.InvalidCallback.selector);
        research.onResult(newId, "wrong intake", "uri");
        vm.prank(OWNER);
        vm.expectRevert(GenesisResearch.PendingResearch.selector);
        research.setIntake(address(intake));
        intake = next;
        succeed(newId);
        require(requestState(research, oldId) == GenesisResearch.RequestState.Failed, "old history rewritten");
    }

    function snapshot(bytes memory body) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                research.spent(),
                research.requestCount(),
                research.pendingRequestId(),
                research.usedBodies(keccak256(body)),
                token.balanceOf(address(research)),
                token.balanceOf(address(intake)),
                token.balanceOf(TREASURY),
                token.balanceOf(DONOR),
                token.allowance(address(research), address(intake)),
                token.allowance(DONOR, address(research)),
                intake.nonce()
            )
        );
    }

    function expectOrderRollback(bytes memory body, bytes4 errorSelector) internal {
        bytes32 beforeState = snapshot(body);
        vm.prank(RESEARCHER);
        (bool ok, bytes memory result) =
            address(research).call(abi.encodeWithSignature("orderResearch(bytes,uint256)", body, PRICE));
        require(!ok, "invalid order accepted");
        if (errorSelector != bytes4(0)) assertError(ok, result, errorSelector);
        require(snapshot(body) == beforeState, "order did not roll back");
    }
}
