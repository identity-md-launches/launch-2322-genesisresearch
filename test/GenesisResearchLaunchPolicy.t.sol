// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GenesisResearch, IERC20Genesis} from "../src/GenesisResearch.sol";
import {GenesisTestBase, GenesisTokenDouble, GenesisIntakeDouble} from "./helpers/GenesisHarness.sol";

contract GenesisLaunchProbe {
    // Review fixture for the six approved static words, in exact constructor declaration order.
    function initCode() public pure returns (bytes memory) {
        return abi.encodePacked(
            type(GenesisResearch).creationCode,
            abi.encode(
                0x550011CAdCC758969391050241B2Fc43ED1a4B97,
                0xa43e6F75ee006411F79Ac1C84120606C2330DE82,
                0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7,
                bytes32(0x190996ed4ed39d38bd9cf088077f0f9aa4afc5d926df034f0b4f792259599fac),
                uint256(500000000000000000),
                uint256(500000000000000000)
            )
        );
    }

    // One top-level call rehearses the factory transaction. No post-construction call is made.
    function deploy(bytes32 salt) external payable returns (address created) {
        bytes memory code = initCode();
        assembly ("memory-safe") {
            created := create2(callvalue(), add(code, 32), mload(code), salt)
        }
    }
}

contract GenesisResearchLaunchPolicyTest is GenesisTestBase {
    address private constant OWNER = 0x550011CAdCC758969391050241B2Fc43ED1a4B97;
    address private constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address private constant ASSET = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    bytes32 private constant WORLD = 0x190996ed4ed39d38bd9cf088077f0f9aa4afc5d926df034f0b4f792259599fac;
    uint256 private constant CAP = 500000000000000000;

    function testSingleFactoryConstructionUsesExactOwnerAndUnfundedArguments() public {
        vm.chainId(1);
        require(INTAKE.code.length == 0 && ASSET.code.length == 0, "requires empty rehearsal chain");
        GenesisLaunchProbe factory = new GenesisLaunchProbe();
        bytes32 salt = keccak256("public local deployment rehearsal");
        bytes memory code = factory.initCode();
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(code)))))
        );
        uint64 beforeNonce = vm.getNonce(address(factory));
        vm.recordLogs();
        address deployed = factory.deploy(salt);
        require(deployed != address(0) && deployed == predicted, "factory deployment failed");
        require(vm.getRecordedLogs().length == 0, "constructor performed an unexpected operation");
        require(vm.getNonce(address(factory)) == beforeNonce + 1, "factory did not create exactly one");
        require(vm.getNonce(deployed) == 1, "application constructor created another contract");
        GenesisResearch instance = GenesisResearch(deployed);
        require(instance.owner() == OWNER && OWNER != address(factory) && OWNER != tx.origin, "owner is deployer");
        require(instance.intake() == INTAKE && instance.asset() == ASSET, "dependencies changed");
        require(
            instance.worldCommitment() == WORLD && instance.spendCap() == CAP && instance.price() == CAP, "arguments"
        );
        require(instance.remainingBudget() == CAP && instance.spent() == 0, "budget not fresh");
        require(
            instance.requestCount() == 0 && instance.pendingRequestId() == 0 && instance.epochCount() == 0, "not idle"
        );
        require(!instance.researchers(address(factory)) && !instance.researchers(tx.origin), "deployer has a role");
        require(deployed.balance == 0 && address(factory).balance == 0, "native funding");
        assertRuntime(deployed.code);
    }

    function testConstructionWithLiveShapedDependenciesMakesNoApprovalOrRequest() public {
        GenesisTokenDouble token = new GenesisTokenDouble();
        GenesisIntakeDouble intake = new GenesisIntakeDouble(address(this), OWNER, CAP);
        vm.etch(ASSET, address(token).code);
        vm.etch(INTAKE, address(intake).code);
        GenesisLaunchProbe factory = new GenesisLaunchProbe();
        address deployed = factory.deploy(keccak256("dependencies present"));
        require(deployed != address(0), "construction failed");
        GenesisTokenDouble asset = GenesisTokenDouble(ASSET);
        require(asset.balanceOf(deployed) == 0 && asset.allowance(deployed, INTAKE) == 0, "initial funding or approval");
        require(
            asset.calls(IERC20Genesis.approve.selector) == 0 && asset.calls(IERC20Genesis.transfer.selector) == 0
                && asset.calls(IERC20Genesis.transferFrom.selector) == 0,
            "constructor moved or approved tokens"
        );
        require(GenesisIntakeDouble(INTAKE).nonce() == 0, "constructor opened a job");
    }

    function testConstructorAndRuntimeRejectNativeValue() public {
        GenesisLaunchProbe factory = new GenesisLaunchProbe();
        vm.deal(address(this), 2);
        address rejected = factory.deploy{value: 1}(keccak256("nonzero native launch"));
        require(rejected == address(0), "payable launch was accepted");
        address deployed = factory.deploy(keccak256("zero native launch"));
        require(deployed != address(0), "nonpayable launch failed");
        (bool ok,) = deployed.call{value: 1}("");
        require(!ok && deployed.balance == 0, "runtime accepted native funding");
    }

    function assertRuntime(bytes memory code) private pure {
        require(code.length > 0 && code.length <= 24_576, "runtime violates EIP-170");
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            require(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden runtime opcode");
        }
    }
}
