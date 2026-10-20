// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GenesisResearch, IERC20Genesis, IIMDIntake} from "../../src/GenesisResearch.sol";

// Minimal local interfaces keep this suite runnable offline without a new dependency/remapping.
interface GenesisVm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function getBlockTimestamp() external view returns (uint256);
    function chainId(uint256) external;
    function deal(address, uint256) external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
    function etch(address, bytes calldata) external;
    function getNonce(address) external view returns (uint64);
}

abstract contract GenesisTestBase {
    GenesisVm internal constant vm = GenesisVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // Preserve already valid inputs (including endpoints), and map all other inputs into the range.
    function bound(uint256 value, uint256 low, uint256 high) internal pure returns (uint256) {
        require(low <= high, "invalid test bounds");
        if (value >= low && value <= high) return value;
        if (high == type(uint256).max && low == 0) return value;
        return low + value % (high - low + 1);
    }

    function assertError(bool ok, bytes memory data, bytes4 expected) internal pure {
        require(!ok, "call unexpectedly succeeded");
        require(data.length == 4 && bytes4(data) == expected, "unexpected revert");
    }

    function requestState(GenesisResearch research, bytes32 id)
        internal
        view
        returns (GenesisResearch.RequestState state)
    {
        (,,,,, state) = research.requests(id);
    }
}

/// @dev Local ERC-20 double. Failure modes act AFTER writes, so rollback assertions check atomicity.
contract GenesisTokenDouble is IERC20Genesis {
    enum ReturnMode {
        Standard,
        False,
        Revert,
        Empty,
        Short,
        Long,
        InvalidBool
    }

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(bytes4 => uint256) public calls;
    uint256 public totalSupply;
    bytes4 public faultSelector;
    uint256 public faultOccurrence;
    ReturnMode public returnMode;
    uint256 public fee;
    uint256 public surcharge;
    address public hookTarget;
    bytes4 public hookSelector;
    bytes public hookData;
    bool public hookSucceeded;
    bytes public hookResult;
    bool private inHook;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function configureReturn(bytes4 selector, uint256 occurrence, ReturnMode mode) external {
        faultSelector = selector;
        faultOccurrence = occurrence;
        returnMode = mode;
        calls[selector] = 0;
    }

    function configureFees(uint256 fee_, uint256 surcharge_) external {
        fee = fee_;
        surcharge = surcharge_;
    }

    function configureHook(address target, bytes4 selector, bytes calldata data) external {
        hookTarget = target;
        hookSelector = selector;
        hookData = data;
        hookSucceeded = false;
        delete hookResult;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return _finish(msg.sig);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return _finish(msg.sig);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "token allowance");
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return _finish(msg.sig);
    }

    function _move(address from, address to, uint256 amount) private {
        require(amount >= fee && balanceOf[from] >= amount + surcharge, "token balance");
        balanceOf[from] -= amount + surcharge;
        balanceOf[to] += amount - fee;
        totalSupply -= fee + surcharge;
    }

    function _finish(bytes4 selector) private returns (bool) {
        ++calls[selector];
        if (!inHook && hookTarget != address(0) && selector == hookSelector) {
            inHook = true;
            (hookSucceeded, hookResult) = hookTarget.call(hookData);
            inHook = false;
        }
        if (selector != faultSelector || (faultOccurrence != 0 && calls[selector] != faultOccurrence)) return true;
        ReturnMode mode = returnMode;
        if (mode == ReturnMode.False) return false;
        if (mode == ReturnMode.Revert) revert("token configured revert");
        if (mode == ReturnMode.Empty) {
            assembly {
                return(0, 0)
            }
        }
        if (mode == ReturnMode.Short) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (mode == ReturnMode.Long) {
            assembly {
                mstore(0, 1)
                mstore(32, 0)
                return(0, 64)
            }
        }
        if (mode == ReturnMode.InvalidBool) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return true;
    }
}

/// @dev Intake v2 model: exact raw body, payer, callbacks, treasury forwarding and writer-only,
/// one-shot delivery under 200,000 gas. Fault knobs are used only by adversarial unit tests.
contract GenesisIntakeDouble is IIMDIntake {
    struct Ask {
        address payer;
        address target;
        bytes4 selector;
        bytes4 failureSelector;
        bool completed;
        bool delivered;
    }

    address public immutable writer;
    address public immutable treasury;
    uint256 public quotedPrice;
    uint256 public nonce;
    bytes public lastBody;
    bytes32 public lastAction;
    address public lastAsset;
    uint256 public lastAmount;
    mapping(bytes32 => Ask) public asks;
    bool public overrideId;
    bytes32 public forcedId;
    bool public revertAfterPull;
    bool public overridePull;
    uint256 public forcedPull;
    address public hookTarget;
    bytes public hookData;
    bool public hookSucceeded;
    bytes public hookResult;

    constructor(address writer_, address treasury_, uint256 quote_) {
        writer = writer_;
        treasury = treasury_;
        quotedPrice = quote_;
    }

    function setQuote(uint256 next) external {
        quotedPrice = next;
    }

    function configureFault(bool useId, bytes32 id, bool revert_, bool usePull, uint256 pull) external {
        overrideId = useId;
        forcedId = id;
        revertAfterPull = revert_;
        overridePull = usePull;
        forcedPull = pull;
    }

    function configureHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32 id) {
        require(action == bytes32("job.open@job-1") && quotedPrice != 0, "action not sold");
        require(amount >= quotedPrice, "short payment");
        require(body.length != 0 && body.length <= 16 * 1024, "invalid intake body");
        uint256 pull = overridePull ? forcedPull : amount;
        if (pull != 0) {
            _token(asset, abi.encodeCall(IERC20Genesis.transferFrom, (msg.sender, address(this), pull)));
            _token(asset, abi.encodeCall(IERC20Genesis.transfer, (treasury, pull)));
        }
        require(!revertAfterPull, "intake configured revert");
        id = overrideId ? forcedId : keccak256(abi.encode(address(this), ++nonce));
        asks[id] = Ask(msg.sender, callback.target, callback.selector, onFailure, false, false);
        lastBody = body;
        lastAction = action;
        lastAsset = asset;
        lastAmount = amount;
        if (hookTarget != address(0)) (hookSucceeded, hookResult) = hookTarget.call(hookData);
    }

    function complete(bytes32 id, uint8 status, bytes calldata encodedArgs) external returns (bool delivered) {
        require(msg.sender == writer, "not writer");
        Ask storage ask = asks[id];
        require(ask.payer != address(0) && !ask.completed, "not open");
        require(status <= 2, "bad status");
        ask.completed = true;
        bytes4 selector = status == 0 ? ask.selector : ask.failureSelector;
        (delivered,) = ask.target.call{gas: 200_000}(abi.encodePacked(selector, encodedArgs));
        ask.delivered = delivered;
    }

    function _token(address token, bytes memory input) private {
        (bool ok, bytes memory result) = token.call(input);
        require(ok && (result.length == 0 || (result.length == 32 && abi.decode(result, (bool)))), "intake token");
    }
}

abstract contract GenesisFixture is GenesisTestBase {
    uint256 internal constant PRICE = 0.5 ether;
    uint256 internal constant CAP = 4 * PRICE;
    bytes32 internal constant WORLD = 0x190996ed4ed39d38bd9cf088077f0f9aa4afc5d926df034f0b4f792259599fac;
    address internal constant OWNER = 0x550011CAdCC758969391050241B2Fc43ED1a4B97;
    // Distinct local actors, not deployment arguments or live signers.
    address internal constant DONOR = address(uint160(uint256(keccak256("Genesis test donor"))));
    address internal constant RESEARCHER = address(uint160(uint256(keccak256("Genesis test researcher"))));
    address internal constant STRANGER = address(uint160(uint256(keccak256("Genesis test stranger"))));
    address internal constant WRITER = address(uint160(uint256(keccak256("Genesis test writer"))));
    address internal constant TREASURY = address(uint160(uint256(keccak256("Genesis test treasury"))));
    GenesisTokenDouble internal token;
    GenesisIntakeDouble internal intake;
    GenesisResearch internal research;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        token = new GenesisTokenDouble();
        intake = new GenesisIntakeDouble(WRITER, TREASURY, PRICE);
        research = new GenesisResearch(OWNER, address(intake), address(token), WORLD, CAP, PRICE);
        token.mint(DONOR, 10 ether);
        vm.startPrank(DONOR);
        token.approve(address(research), 10 ether);
        research.fund(3 ether);
        vm.stopPrank();
        vm.prank(OWNER);
        research.setResearcher(RESEARCHER, true);
    }

    function order(bytes memory body) internal returns (bytes32 id) {
        vm.prank(RESEARCHER);
        id = research.orderResearch(body, PRICE);
    }

    function succeed(bytes32 id) internal {
        vm.prank(WRITER);
        require(
            intake.complete(id, 0, abi.encode(id, keccak256("result bytes"), "ipfs://local-test/result.json")),
            "result not delivered"
        );
    }

    function fail(bytes32 id, uint8 status) internal {
        vm.prank(WRITER);
        require(
            intake.complete(
                id, status, abi.encode(id, status, bytes32("body_refused"), uint16(0), uint16(0), bytes(""))
            ),
            "failure not delivered"
        );
    }
}
