// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GenesisResearch, IERC20Genesis, IIMDIntake} from "../src/GenesisResearch.sol";

interface Vm {
    function prank(address) external;
    function warp(uint256) external;
    function expectRevert(bytes4) external;
}

contract MockToken is IERC20Genesis {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public returnsFalse;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setReturnsFalse(bool value) external {
        returnsFalse = value;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (returnsFalse) return false;
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (returnsFalse) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (returnsFalse) return false;
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockIntake is IIMDIntake {
    uint256 public nonce;
    bool public failRequest;
    bool public synchronousCallback;
    bool public synchronousCallbackSucceeded;
    bytes32 public forcedId;
    bytes32 public lastAction;
    bytes4 public lastSelector;
    bytes4 public lastFailureSelector;
    address public lastTarget;

    function setFailRequest(bool value) external {
        failRequest = value;
    }

    function setSynchronousCallback(bool value) external {
        synchronousCallback = value;
    }

    function setForcedId(bytes32 id) external {
        forcedId = id;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata,
        Callback calldata callback,
        bytes4 failureSelector,
        address asset,
        uint256 amount
    ) external returns (bytes32 id) {
        require(!failRequest, "intake failed");
        require(IERC20Genesis(asset).transferFrom(msg.sender, address(this), amount), "pull failed");
        lastAction = action;
        lastSelector = callback.selector;
        lastFailureSelector = failureSelector;
        lastTarget = callback.target;
        id = forcedId == 0 ? keccak256(abi.encode(address(this), ++nonce)) : forcedId;
        if (synchronousCallback) {
            (synchronousCallbackSucceeded,) =
                callback.target.call(abi.encodeWithSelector(callback.selector, id, bytes32("early"), "ipfs://early"));
        }
    }

    function success(GenesisResearch target, bytes32 id, bytes32 resultHash) external {
        target.onResult(id, resultHash, "ipfs://research-result");
    }

    function failure(GenesisResearch target, bytes32 id, uint8 status) external {
        target.onFailure(id, status, "refused", 0, 0, "");
    }
}

contract GenesisResearchTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant PRICE = 0.5 ether;
    address private constant ALICE = address(0xa11ce);
    address private constant BOB = address(0xb0b);
    bytes32 private constant WORLD = keccak256("world-seed-and-engine-v1");
    bytes32 private constant OUTPUT = keccak256("prediction-document");
    bytes32 private constant SALT = keccak256("private-random-salt");
    MockToken private token;
    MockIntake private intake;
    GenesisResearch private research;

    function setUp() public {
        vm.warp(1000);
        token = new MockToken();
        intake = new MockIntake();
        research = new GenesisResearch(address(this), address(intake), address(token), WORLD, 2 * PRICE, PRICE);
        token.mint(address(this), 10 ether);
        token.approve(address(research), 10 ether);
        research.fund(3 * PRICE);
    }

    function testOrdersExactProtocolAndClearsAllowance() public {
        bytes32 id = research.orderResearch(bytes("{\"objective\":\"research\"}"));
        require(research.pendingRequestId() == id && research.spent() == PRICE, "accounting");
        require(token.balanceOf(address(intake)) == PRICE, "not paid");
        require(token.allowance(address(research), address(intake)) == 0, "allowance remains");
        require(intake.lastAction() == bytes32("job.open@job-1"), "wrong action");
        require(intake.lastTarget() == address(research), "wrong target");
        require(intake.lastSelector() == bytes4(0x4374622e), "wrong result ABI");
        require(intake.lastFailureSelector() == bytes4(0x5a0df71e), "wrong failure ABI");
    }

    function testBoundedOrderUsesReviewedPriceAndAuthenticatesCallback() public {
        bytes32 id = research.orderResearch(bytes("bounded-job"), PRICE);
        require(research.pendingRequestId() == id && research.spent() == PRICE, "bounded accounting");
        require(token.balanceOf(address(intake)) == PRICE, "bounded payment");
        require(token.allowance(address(research), address(intake)) == 0, "bounded allowance remains");
        intake.success(research, id, OUTPUT);
        require(research.pendingRequestId() == 0, "bounded callback did not settle");
    }

    function testBoundedOrderRejectsChangedPriceBeforeAnyPaymentOrBookkeeping() public {
        research.setPrice(PRICE + 1);
        vm.expectRevert(GenesisResearch.UnexpectedPrice.selector);
        research.orderResearch(bytes("reviewed-job"), PRICE);
        require(research.spent() == 0 && research.requestCount() == 0, "changed price spent budget");
        require(research.pendingRequestId() == 0, "changed price pending");
        require(!research.usedBodies(keccak256("reviewed-job")), "changed price used body");
        require(token.balanceOf(address(intake)) == 0, "changed price paid intake");
        require(token.allowance(address(research), address(intake)) == 0, "changed price approved intake");
    }

    function testOnlyAuthorizedResearcherCanSpendAndCanBeRevoked() public {
        vm.prank(ALICE);
        vm.expectRevert(GenesisResearch.Unauthorized.selector);
        research.orderResearch("first");
        research.setResearcher(ALICE, true);
        vm.prank(ALICE);
        bytes32 id = research.orderResearch("first");
        intake.success(research, id, OUTPUT);
        research.setResearcher(ALICE, false);
        vm.prank(ALICE);
        vm.expectRevert(GenesisResearch.Unauthorized.selector);
        research.orderResearch("second");
    }

    function testOnePendingRequestAndBodyReplayProtection() public {
        bytes32 id = research.orderResearch("same-body");
        vm.expectRevert(GenesisResearch.PendingResearch.selector);
        research.orderResearch("other");
        intake.success(research, id, OUTPUT);
        vm.expectRevert(GenesisResearch.DuplicateBody.selector);
        research.orderResearch("same-body");
    }

    function testRejectsForeignSpoofedAndDuplicateCallbacks() public {
        bytes32 id = research.orderResearch("first");
        vm.expectRevert(GenesisResearch.InvalidCallback.selector);
        research.onResult(id, OUTPUT, "ipfs://spoofed");
        vm.expectRevert(GenesisResearch.InvalidCallback.selector);
        intake.success(research, bytes32("foreign"), OUTPUT);
        intake.success(research, id, OUTPUT);
        vm.expectRevert(GenesisResearch.InvalidCallback.selector);
        intake.failure(research, id, 1);
        (, bytes32 resultHash, bytes32 uriHash,,, GenesisResearch.RequestState state) = research.requests(id);
        require(resultHash == OUTPUT && uriHash == keccak256("ipfs://research-result"), "result lost");
        require(state == GenesisResearch.RequestState.Succeeded, "wrong state");
    }

    function testRefusalUnlocksWithoutRefundOrBudgetReset() public {
        bytes32 id = research.orderResearch("first");
        uint256 beforeBalance = token.balanceOf(address(research));
        intake.failure(research, id, 1);
        require(research.spent() == PRICE && research.pendingRequestId() == 0, "failure accounting");
        require(token.balanceOf(address(research)) == beforeBalance, "fake refund");
        id = research.orderResearch("second");
        intake.failure(research, id, 2);
        vm.expectRevert(GenesisResearch.BudgetExceeded.selector);
        research.orderResearch("third");
    }

    function testBadFailureStatusCannotClearPending() public {
        bytes32 id = research.orderResearch("first");
        vm.expectRevert(GenesisResearch.InvalidCallback.selector);
        intake.failure(research, id, 0);
        require(research.pendingRequestId() == id, "pending was cleared");
    }

    function testRevertedPurchaseRollsBackBudgetBodyAndApproval() public {
        intake.setFailRequest(true);
        (bool ok,) = address(research).call(abi.encodeWithSignature("orderResearch(bytes)", bytes("first")));
        require(!ok && research.spent() == 0 && research.requestCount() == 0, "not atomic");
        require(!research.usedBodies(keccak256("first")), "body consumed");
        require(token.allowance(address(research), address(intake)) == 0, "approval retained");
        intake.setFailRequest(false);
        research.orderResearch("first");
    }

    function testDuplicateIntakeIdRevertsWholePurchase() public {
        bytes32 id = research.orderResearch("first");
        intake.success(research, id, OUTPUT);
        intake.setForcedId(id);
        vm.expectRevert(GenesisResearch.InvalidRequest.selector);
        research.orderResearch("second");
        require(research.spent() == PRICE && token.balanceOf(address(intake)) == PRICE, "duplicate paid");
        require(!research.usedBodies(keccak256("second")), "body burned");
    }

    function testSynchronousCallbackIsBlockedThenAsyncWorks() public {
        intake.setSynchronousCallback(true);
        bytes32 id = research.orderResearch("first");
        require(!intake.synchronousCallbackSucceeded(), "synchronous reentrancy");
        intake.success(research, id, OUTPUT);
        require(research.pendingRequestId() == 0, "async completion failed");
    }

    function testResultCallbackFitsIntakeGasBudget() public {
        bytes32 id = research.orderResearch("first");
        vm.prank(address(intake));
        (bool ok,) = address(research).call{gas: 200_000}(
            abi.encodeCall(research.onResult, (id, OUTPUT, "ipfs://bafy-result-document/result.json"))
        );
        require(ok && research.pendingRequestId() == 0, "callback exceeded gas budget");
    }

    function testPendingIntakeCannotChangeAndTimeoutDoesNotRefund() public {
        bytes32 id = research.orderResearch("first");
        MockIntake replacement = new MockIntake();
        vm.expectRevert(GenesisResearch.PendingResearch.selector);
        research.setIntake(address(replacement));
        vm.expectRevert(GenesisResearch.TooEarly.selector);
        research.abandonResearch(id);
        vm.warp(1000 + research.ABANDON_DELAY());
        research.abandonResearch(id);
        require(research.spent() == PRICE, "timeout refunded");
        research.setIntake(address(replacement));
        vm.expectRevert(GenesisResearch.InvalidCallback.selector);
        intake.success(research, id, OUTPUT);
        research.orderResearch("second");
    }

    function testRejectsEmptyOversizedBodiesAndFalseReturningToken() public {
        vm.expectRevert(GenesisResearch.InvalidBody.selector);
        research.orderResearch("");
        bytes memory tooLarge = new bytes(16 * 1024 + 1);
        vm.expectRevert(GenesisResearch.InvalidBody.selector);
        research.orderResearch(tooLarge);
        token.setReturnsFalse(true);
        vm.expectRevert(GenesisResearch.TokenCallFailed.selector);
        research.fund(1 ether);
    }

    function testWithdrawalRestrictedAndInsufficientFundingBlocksOrders() public {
        vm.prank(ALICE);
        vm.expectRevert(GenesisResearch.Unauthorized.selector);
        research.withdrawUnused(ALICE, PRICE);
        research.withdrawUnused(address(this), 3 * PRICE);
        vm.expectRevert(GenesisResearch.InsufficientFunds.selector);
        research.orderResearch("first");
    }

    function testCommitRevealIsTimeLockedAndCannotBeReplaced() public {
        uint256 epoch = research.openEpoch(keccak256("holdout-spec"), 1100, 1200);
        bytes32 commitment = research.predictionCommitment(epoch, ALICE, OUTPUT, SALT);
        vm.prank(ALICE);
        research.commitPrediction(epoch, commitment);
        vm.prank(ALICE);
        vm.expectRevert(GenesisResearch.InvalidPrediction.selector);
        research.commitPrediction(epoch, bytes32("replacement"));
        vm.prank(ALICE);
        vm.expectRevert(GenesisResearch.TooEarly.selector);
        research.revealPrediction(epoch, OUTPUT, SALT);
        vm.warp(1100);
        vm.prank(ALICE);
        vm.expectRevert(GenesisResearch.InvalidPrediction.selector);
        research.revealPrediction(epoch, OUTPUT, bytes32("wrong-salt"));
        vm.prank(ALICE);
        research.revealPrediction(epoch, OUTPUT, SALT);
        (, bytes32 revealed, bool done) = research.predictions(epoch, ALICE);
        require(done && revealed == OUTPUT, "not revealed");
        vm.prank(ALICE);
        vm.expectRevert(GenesisResearch.InvalidPrediction.selector);
        research.revealPrediction(epoch, OUTPUT, SALT);
    }

    function testCopiedCommitmentCannotBeRevealedByDifferentParticipant() public {
        uint256 epoch = research.openEpoch(keccak256("holdout"), 1100, 1200);
        bytes32 commitment = research.predictionCommitment(epoch, ALICE, OUTPUT, SALT);
        vm.prank(BOB);
        research.commitPrediction(epoch, commitment);
        vm.warp(1100);
        vm.prank(BOB);
        vm.expectRevert(GenesisResearch.InvalidPrediction.selector);
        research.revealPrediction(epoch, OUTPUT, SALT);
    }

    function testPredictionCannotCrossEpochOrContractAndRespectsDeadline() public {
        uint256 first = research.openEpoch(keccak256("holdout1"), 1100, 1200);
        uint256 second = research.openEpoch(keccak256("holdout2"), 1100, 1200);
        bytes32 commitment = research.predictionCommitment(first, ALICE, OUTPUT, SALT);
        require(commitment != research.predictionCommitment(second, ALICE, OUTPUT, SALT), "epoch replay");
        GenesisResearch other = new GenesisResearch(address(this), address(intake), address(token), WORLD, PRICE, PRICE);
        other.openEpoch(keccak256("holdout1"), 1100, 1200);
        require(commitment != other.predictionCommitment(first, ALICE, OUTPUT, SALT), "contract replay");
        vm.prank(ALICE);
        research.commitPrediction(first, commitment);
        vm.warp(1100);
        vm.prank(BOB);
        vm.expectRevert(GenesisResearch.CommitClosed.selector);
        research.commitPrediction(first, commitment);
        vm.warp(1200);
        vm.prank(ALICE);
        vm.expectRevert(GenesisResearch.RevealClosed.selector);
        research.revealPrediction(first, OUTPUT, SALT);
    }

    function testFuzzBudgetNeverOverspends(uint96 firstPrice, uint96 secondPrice) public {
        uint256 p1 = uint256(firstPrice) % (2 * PRICE) + 1;
        uint256 p2 = uint256(secondPrice) % (2 * PRICE) + 1;
        research.setPrice(p1);
        bytes32 id = research.orderResearch("first");
        intake.success(research, id, OUTPUT);
        research.setPrice(p2);
        if (p2 > 2 * PRICE - p1) {
            vm.expectRevert(GenesisResearch.BudgetExceeded.selector);
            research.orderResearch("second");
        } else {
            research.orderResearch("second");
        }
        require(research.spent() <= research.spendCap(), "cap violated");
    }
}
