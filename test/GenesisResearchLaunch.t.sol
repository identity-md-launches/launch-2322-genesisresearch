// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GenesisResearch} from "../src/GenesisResearch.sol";
import {MockToken, MockIntake} from "./GenesisResearch.t.sol";

interface VmLaunch {
    function chainId(uint256) external;
    function expectRevert(bytes4) external;
}

/// @notice Launch-floor behaviour: the factory constructs GenesisResearch on an empty rehearsal chain
/// with the brief's exact static arguments, and the code checks the constructor used to make are
/// enforced at first use instead. Mirrors the imported audit finding 30da7d7c677e.
contract GenesisResearchLaunchTest {
    VmLaunch private constant vm = VmLaunch(address(uint160(uint256(keccak256("hevm cheat code")))));

    // Exact manifest arguments, in constructor declaration order.
    address private constant OWNER = 0x550011CAdCC758969391050241B2Fc43ED1a4B97;
    address private constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address private constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    bytes32 private constant WORLD = 0x190996ed4ed39d38bd9cf088077f0f9aa4afc5d926df034f0b4f792259599fac;
    uint256 private constant CAP = 500000000000000000;
    uint256 private constant PRICE = 500000000000000000;

    function testConstructsWithManifestArgumentsOnEmptyChain() public {
        vm.chainId(1);
        require(INTAKE.code.length == 0 && IMD.code.length == 0, "precondition: empty chain");
        GenesisResearch research = new GenesisResearch(OWNER, INTAKE, IMD, WORLD, CAP, PRICE);
        require(research.owner() == OWNER, "owner");
        require(research.intake() == INTAKE, "intake");
        require(research.asset() == IMD, "asset");
        require(research.worldCommitment() == WORLD, "world commitment");
        require(research.spendCap() == CAP && research.price() == PRICE, "cap or price");
        require(research.remainingBudget() == CAP, "budget");
        // Starts unfunded and idle: nothing spent, ordered, approved or pending.
        require(research.spent() == 0 && research.requestCount() == 0, "not idle");
        require(research.pendingRequestId() == bytes32(0) && research.epochCount() == 0, "not idle");
        require(address(research).balance == 0, "native value");
    }

    function testConstructorStillRejectsZeroAddressesAndBadBudget() public {
        vm.expectRevert(GenesisResearch.InvalidConfiguration.selector);
        new GenesisResearch(address(0), INTAKE, IMD, WORLD, CAP, PRICE);
        vm.expectRevert(GenesisResearch.InvalidConfiguration.selector);
        new GenesisResearch(OWNER, address(0), IMD, WORLD, CAP, PRICE);
        vm.expectRevert(GenesisResearch.InvalidConfiguration.selector);
        new GenesisResearch(OWNER, INTAKE, address(0), WORLD, CAP, PRICE);
        vm.expectRevert(GenesisResearch.InvalidConfiguration.selector);
        new GenesisResearch(OWNER, INTAKE, IMD, bytes32(0), CAP, PRICE);
        vm.expectRevert(GenesisResearch.InvalidConfiguration.selector);
        new GenesisResearch(OWNER, INTAKE, IMD, WORLD, CAP, 0);
        vm.expectRevert(GenesisResearch.InvalidConfiguration.selector);
        new GenesisResearch(OWNER, INTAKE, IMD, WORLD, PRICE - 1, PRICE);
    }

    function testOrderRefusesCodelessIntakeBeforeAnyPaymentOrBookkeeping() public {
        MockToken token = new MockToken();
        GenesisResearch research = new GenesisResearch(address(this), INTAKE, address(token), WORLD, CAP, PRICE);
        token.mint(address(this), PRICE);
        token.approve(address(research), PRICE);
        research.fund(PRICE);
        require(INTAKE.code.length == 0, "precondition: intake has no code");

        vm.expectRevert(GenesisResearch.InvalidConfiguration.selector);
        research.orderResearch(bytes("first"), PRICE);
        require(research.spent() == 0 && research.requestCount() == 0, "spent against no contract");
        require(research.pendingRequestId() == bytes32(0), "pending against no contract");
        require(!research.usedBodies(keccak256("first")), "body burned");
        require(token.balanceOf(address(research)) == PRICE, "funds moved");
        require(token.allowance(address(research), INTAKE) == 0, "approval left for a non-contract");

        // Once a live intake is configured the same order proceeds unchanged.
        MockIntake live = new MockIntake();
        research.setIntake(address(live));
        bytes32 id = research.orderResearch(bytes("first"), PRICE);
        require(research.pendingRequestId() == id && research.spent() == PRICE, "live order");
    }

    function testOrderRefusesCodelessAssetBeforeAnyPaymentOrBookkeeping() public {
        MockIntake live = new MockIntake();
        GenesisResearch research = new GenesisResearch(address(this), address(live), IMD, WORLD, CAP, PRICE);
        require(IMD.code.length == 0, "precondition: asset has no code");
        vm.expectRevert(GenesisResearch.InvalidConfiguration.selector);
        research.orderResearch(bytes("first"), PRICE);
        require(research.spent() == 0 && research.requestCount() == 0, "spent against no contract");
        require(!research.usedBodies(keccak256("first")), "body burned");
    }

    function testSetIntakeStillRequiresCode() public {
        MockToken token = new MockToken();
        MockIntake live = new MockIntake();
        GenesisResearch research = new GenesisResearch(address(this), address(live), address(token), WORLD, CAP, PRICE);
        vm.expectRevert(GenesisResearch.InvalidConfiguration.selector);
        research.setIntake(INTAKE);
        require(research.intake() == address(live), "intake replaced by a non-contract");
    }
}
