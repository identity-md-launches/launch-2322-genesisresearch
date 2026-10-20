// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GenesisResearch} from "../src/GenesisResearch.sol";
import {GenesisTestBase, GenesisTokenDouble, GenesisIntakeDouble} from "./helpers/GenesisHarness.sol";

contract GenesisResearchBudgetEdgesTest is GenesisTestBase {
    address internal constant TREASURY = address(uint160(uint256(keccak256("budget edge treasury"))));
    GenesisTokenDouble private token;
    GenesisIntakeDouble private intake;
    GenesisResearch private research;

    /// forge-config: default.fuzz.runs = 256
    function testFuzzFullWidthBudgetConservesValue(uint256 capSeed, uint256 firstSeed, uint256 secondSeed) public {
        uint256 cap = bound(capSeed, 1, type(uint256).max);
        checkBudget(cap, bound(firstSeed, 1, cap), bound(secondSeed, 1, cap));
    }

    function testOneWeiCapCannotBuyTwoJobs() public {
        checkBudget(1, 1, 1);
    }

    function testMaximumUint256CapAndPriceDoNotOverflow() public {
        checkBudget(type(uint256).max, type(uint256).max, 1);
    }

    function testLastWeiOfMaximumBudgetCanBeSpentExactlyOnce() public {
        checkBudget(type(uint256).max, type(uint256).max - 1, 1);
    }

    function testPriceOneWeiAboveRemainingBudgetIsRejected() public {
        checkBudget(type(uint256).max, type(uint256).max - 1, 2);
    }

    function testFundingAfterExhaustionCannotRestoreLifetimeCap() public {
        deploy(0.5 ether, 0.5 ether);
        bytes32 id = research.orderResearch("single authorized budget", 0.5 ether);
        finish(id);
        token.mint(address(this), 0.5 ether);
        token.approve(address(research), 0.5 ether);
        research.fund(0.5 ether);
        research.setPrice(1);
        intake.setQuote(1);
        vm.expectRevert(GenesisResearch.BudgetExceeded.selector);
        research.orderResearch("additional job", 1);
        require(research.spent() == 0.5 ether && research.remainingBudget() == 0, "budget replenished");
        require(token.balanceOf(address(research)) == 0.5 ether, "new donation spent");
        research.withdrawUnused(address(this), 0.5 ether);
        require(research.spent() == 0.5 ether && research.requestCount() == 1, "withdrawal reset history");
    }

    function testOneWeiUnderfundingLeavesBodyReusable() public {
        deploy(0.5 ether, 0.5 ether);
        research.withdrawUnused(address(this), 1);
        vm.expectRevert(GenesisResearch.InsufficientFunds.selector);
        research.orderResearch("one wei short", 0.5 ether);
        require(!research.usedBodies(keccak256("one wei short")) && research.spent() == 0, "failed attempt recorded");
        token.approve(address(research), 1);
        research.fund(1);
        bytes32 id = research.orderResearch("one wei short", 0.5 ether);
        require(research.pendingRequestId() == id && token.balanceOf(TREASURY) == 0.5 ether, "retry failed");
    }

    function checkBudget(uint256 cap, uint256 first, uint256 second) private {
        deploy(cap, first);
        bytes32 id = research.orderResearch("first", first);
        finish(id); // A refusal spends the same budget as a successful result.
        research.setPrice(second);
        intake.setQuote(second);
        uint256 expectedSpent = first;
        if (second > cap - first) {
            vm.expectRevert(GenesisResearch.BudgetExceeded.selector);
            research.orderResearch("second", second);
            require(!research.usedBodies(keccak256("second")) && research.requestCount() == 1, "failed order recorded");
        } else {
            id = research.orderResearch("second", second);
            expectedSpent += second;
            require(research.requestCount() == 2 && research.pendingRequestId() == id, "second order missing");
        }
        require(research.spent() == expectedSpent && research.remainingBudget() == cap - expectedSpent, "budget drift");
        require(token.balanceOf(TREASURY) == expectedSpent, "treasury mismatch");
        require(token.balanceOf(address(research)) == cap - expectedSpent, "custody mismatch");
        require(token.balanceOf(address(intake)) == 0, "unexpected escrow");
        require(token.allowance(address(research), address(intake)) == 0, "residual approval");
    }

    function deploy(uint256 cap, uint256 price) private {
        token = new GenesisTokenDouble();
        intake = new GenesisIntakeDouble(address(this), TREASURY, price);
        research = new GenesisResearch(
            address(this), address(intake), address(token), keccak256("public arithmetic test world"), cap, price
        );
        token.mint(address(this), cap);
        token.approve(address(research), cap);
        research.fund(cap);
    }

    function finish(bytes32 id) private {
        require(
            intake.complete(id, 1, abi.encode(id, uint8(1), bytes32("body_refused"), uint16(0), uint16(0), bytes(""))),
            "failure callback rejected"
        );
    }
}
