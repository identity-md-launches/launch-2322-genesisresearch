// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20Genesis {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev IMD Intake v2's documented same-chain job request interface.
interface IIMDIntake {
    struct Callback { address target; bytes4 selector; }
    function requestWithFailure(
        bytes32 action, bytes calldata body, Callback calldata callback,
        bytes4 onFailure, address asset, uint256 amount
    ) external returns (bytes32 requestId);
}

/// @notice A bounded research budget and prediction registry for one committed GENESIS world.
/// @dev Job callbacks establish provenance, NOT scientific correctness. No prediction prize settlement.
contract GenesisResearch {
    enum RequestState { Unknown, Pending, Succeeded, Failed, Abandoned }

    struct ResearchRequest {
        bytes32 bodyHash;
        bytes32 resultHash;
        bytes32 uriHash;
        address intake;
        uint64 requestedAt;
        RequestState state;
    }

    struct Epoch {
        bytes32 targetHash;
        uint64 commitDeadline;
        uint64 revealDeadline;
    }

    struct Prediction {
        bytes32 commitment;
        bytes32 predictionHash;
        bool revealed;
    }

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidBody();
    error DuplicateBody();
    error PendingResearch();
    error BudgetExceeded();
    error UnexpectedPrice();
    error InsufficientFunds();
    error TokenCallFailed();
    error UnsupportedToken();
    error InvalidRequest();
    error InvalidCallback();
    error ReentrantCall();
    error TooEarly();
    error InvalidEpoch();
    error CommitClosed();
    error RevealClosed();
    error InvalidPrediction();

    bytes32 public constant RESEARCH_ACTION = "job.open@job-1";
    uint256 public constant MAX_BODY_BYTES = 16 * 1024;
    uint256 public constant ABANDON_DELAY = 7 days;
    bytes32 public constant PREDICTION_DOMAIN = keccak256("GENESIS_PREDICTION_V1");

    address public immutable owner;
    address public immutable asset;
    bytes32 public immutable worldCommitment;
    uint256 public immutable spendCap;
    address public intake;
    uint256 public price;
    uint256 public spent;
    uint256 public requestCount;
    bytes32 public pendingRequestId;
    uint256 public epochCount;
    uint256 private entered;

    mapping(address => bool) public researchers;
    mapping(bytes32 => bool) public usedBodies;
    mapping(bytes32 => ResearchRequest) public requests;
    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(address => Prediction)) public predictions;

    event Funded(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event ResearcherSet(address indexed researcher, bool allowed);
    event IntakeSet(address indexed intake);
    event PriceSet(uint256 price);
    event ResearchOrdered(bytes32 indexed requestId, bytes32 indexed bodyHash, uint256 amount);
    event ResearchResult(bytes32 indexed requestId, bytes32 resultHash, string uri);
    event ResearchFailed(bytes32 indexed requestId, uint8 status, bytes32 reason);
    event ResearchAbandoned(bytes32 indexed requestId);
    event EpochOpened(uint256 indexed epoch, bytes32 targetHash, uint64 commitDeadline, uint64 revealDeadline);
    event PredictionCommitted(uint256 indexed epoch, address indexed participant, bytes32 commitment);
    event PredictionRevealed(uint256 indexed epoch, address indexed participant, bytes32 predictionHash);

    constructor(
        address owner_, address intake_, address asset_, bytes32 worldCommitment_, uint256 spendCap_, uint256 price_
    ) {
        if (owner_ == address(0) || intake_.code.length == 0 || asset_.code.length == 0
            || worldCommitment_ == bytes32(0) || price_ == 0 || spendCap_ < price_) {
            revert InvalidConfiguration();
        }
        owner = owner_;
        intake = intake_;
        asset = asset_;
        worldCommitment = worldCommitment_;
        spendCap = spendCap_;
        price = price_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        if (entered != 0) revert ReentrantCall();
        entered = 1;
        _;
        entered = 0;
    }

    /// @notice Donations fund the owner's expedition; they create no claim or yield for the donor.
    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidConfiguration();
        uint256 beforeBalance = IERC20Genesis(asset).balanceOf(address(this));
        _tokenCall(abi.encodeCall(IERC20Genesis.transferFrom, (msg.sender, address(this), amount)));
        if (IERC20Genesis(asset).balanceOf(address(this)) != beforeBalance + amount) revert UnsupportedToken();
        emit Funded(msg.sender, amount);
    }

    function setResearcher(address researcher, bool allowed) external onlyOwner {
        if (researcher == address(0)) revert InvalidConfiguration();
        researchers[researcher] = allowed;
        emit ResearcherSet(researcher, allowed);
    }

    /// @dev The asset and lifetime cap are immutable so a cap cannot silently change denomination.
    function setIntake(address next) external onlyOwner nonReentrant {
        if (pendingRequestId != bytes32(0)) revert PendingResearch();
        if (next.code.length == 0) revert InvalidConfiguration();
        intake = next;
        emit IntakeSet(next);
    }

    function setPrice(uint256 next) external onlyOwner {
        if (next == 0 || next > spendCap) revert InvalidConfiguration();
        price = next;
        emit PriceSet(next);
    }

    /// @notice Pays for one IMD research job; preflight the public JSON body with /requests/check first.
    /// @dev Refused/failed jobs still cost IMD. An identical body is never purchased twice.
    /// @dev Legacy entry point: accepts the owner's current price. Prefer the price-bound overload.
    function orderResearch(bytes calldata body) external nonReentrant returns (bytes32 requestId) {
        return _orderResearch(body, price);
    }

    /// @notice Buys only at the reviewed price, including when an owner changes price while the tx is pending.
    function orderResearch(bytes calldata body, uint256 expectedPrice) external nonReentrant returns (bytes32 requestId) {
        return _orderResearch(body, expectedPrice);
    }

    function _orderResearch(bytes calldata body, uint256 expectedPrice) private returns (bytes32 requestId) {
        if (msg.sender != owner && !researchers[msg.sender]) revert Unauthorized();
        if (price != expectedPrice) revert UnexpectedPrice();
        if (body.length == 0 || body.length > MAX_BODY_BYTES) revert InvalidBody();
        if (pendingRequestId != bytes32(0)) revert PendingResearch();
        bytes32 bodyHash = keccak256(body);
        if (usedBodies[bodyHash]) revert DuplicateBody();
        uint256 cost = price;
        if (cost > spendCap - spent) revert BudgetExceeded();
        uint256 beforeBalance = IERC20Genesis(asset).balanceOf(address(this));
        if (beforeBalance < cost) revert InsufficientFunds();

        // Lock budget/body before interacting. Synchronous callbacks are deliberately rejected.
        spent += cost;
        usedBodies[bodyHash] = true;
        requestCount += 1;
        _tokenCall(abi.encodeCall(IERC20Genesis.approve, (intake, 0)));
        _tokenCall(abi.encodeCall(IERC20Genesis.approve, (intake, cost)));
        requestId = IIMDIntake(intake).requestWithFailure(
            RESEARCH_ACTION, body, IIMDIntake.Callback(address(this), this.onResult.selector),
            this.onFailure.selector, asset, cost
        );
        _tokenCall(abi.encodeCall(IERC20Genesis.approve, (intake, 0)));
        if (IERC20Genesis(asset).balanceOf(address(this)) != beforeBalance - cost) revert UnsupportedToken();
        if (requestId == bytes32(0) || requests[requestId].state != RequestState.Unknown) revert InvalidRequest();
        requests[requestId] = ResearchRequest(bodyHash, 0, 0, intake, uint64(block.timestamp), RequestState.Pending);
        pendingRequestId = requestId;
        emit ResearchOrdered(requestId, bodyHash, cost);
    }

    /// @dev Only records the writer's result. URI is emitted, hashed in storage to fit callback gas.
    function onResult(bytes32 requestId, bytes32 resultHash, string calldata uri) external nonReentrant {
        ResearchRequest storage research = _pending(requestId);
        research.state = RequestState.Succeeded;
        research.resultHash = resultHash;
        research.uriHash = keccak256(bytes(uri));
        pendingRequestId = bytes32(0);
        emit ResearchResult(requestId, resultHash, uri);
    }

    /// @dev Fixed Intake v2 signature. An unsigned failure changes status, never refunds or pays value.
    function onFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16, uint16, bytes calldata)
        external nonReentrant
    {
        if (status != 1 && status != 2) revert InvalidCallback();
        ResearchRequest storage research = _pending(requestId);
        research.state = RequestState.Failed;
        pendingRequestId = bytes32(0);
        emit ResearchFailed(requestId, status, reason);
    }

    /// @notice Unblocks this registry after a missing callback; does NOT cancel or refund the IMD job.
    function abandonResearch(bytes32 requestId) external onlyOwner nonReentrant {
        ResearchRequest storage research = requests[requestId];
        if (research.state != RequestState.Pending || pendingRequestId != requestId) revert InvalidRequest();
        if (block.timestamp < uint256(research.requestedAt) + ABANDON_DELAY) revert TooEarly();
        research.state = RequestState.Abandoned;
        pendingRequestId = bytes32(0);
        emit ResearchAbandoned(requestId);
    }

    function withdrawUnused(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidConfiguration();
        _tokenCall(abi.encodeCall(IERC20Genesis.transfer, (to, amount)));
        emit Withdrawn(to, amount);
    }

    /// @notice Pins the holdout specification before participants commit. Targets cannot be replaced.
    function openEpoch(bytes32 targetHash, uint64 commitDeadline, uint64 revealDeadline)
        external onlyOwner returns (uint256 epoch)
    {
        if (targetHash == bytes32(0) || commitDeadline <= block.timestamp || revealDeadline <= commitDeadline) {
            revert InvalidEpoch();
        }
        epoch = ++epochCount;
        epochs[epoch] = Epoch(targetHash, commitDeadline, revealDeadline);
        emit EpochOpened(epoch, targetHash, commitDeadline, revealDeadline);
    }

    function predictionCommitment(uint256 epoch, address participant, bytes32 predictionHash, bytes32 salt)
        public view returns (bytes32)
    {
        return keccak256(abi.encode(
            PREDICTION_DOMAIN, block.chainid, address(this), worldCommitment,
            epoch, epochs[epoch].targetHash, participant, predictionHash, salt
        ));
    }

    function commitPrediction(uint256 epoch, bytes32 commitment) external {
        Epoch storage target = epochs[epoch];
        if (target.targetHash == bytes32(0)) revert InvalidEpoch();
        if (block.timestamp >= target.commitDeadline) revert CommitClosed();
        if (commitment == bytes32(0) || predictions[epoch][msg.sender].commitment != bytes32(0)) {
            revert InvalidPrediction();
        }
        predictions[epoch][msg.sender].commitment = commitment;
        emit PredictionCommitted(epoch, msg.sender, commitment);
    }

    /// @notice Reveals a prediction document's hash. Correctness is evaluated by the offchain lab.
    function revealPrediction(uint256 epoch, bytes32 predictionHash, bytes32 salt) external {
        Epoch storage target = epochs[epoch];
        if (target.targetHash == bytes32(0)) revert InvalidEpoch();
        if (block.timestamp < target.commitDeadline) revert TooEarly();
        if (block.timestamp >= target.revealDeadline) revert RevealClosed();
        Prediction storage prediction = predictions[epoch][msg.sender];
        if (prediction.revealed || prediction.commitment == bytes32(0) || predictionHash == bytes32(0)
            || prediction.commitment != predictionCommitment(epoch, msg.sender, predictionHash, salt)) {
            revert InvalidPrediction();
        }
        prediction.predictionHash = predictionHash;
        prediction.revealed = true;
        emit PredictionRevealed(epoch, msg.sender, predictionHash);
    }

    function remainingBudget() external view returns (uint256) { return spendCap - spent; }

    function _pending(bytes32 requestId) private view returns (ResearchRequest storage research) {
        research = requests[requestId];
        if (research.state != RequestState.Pending || pendingRequestId != requestId
            || msg.sender != research.intake) revert InvalidCallback();
    }

    function _tokenCall(bytes memory data) private {
        (bool ok, bytes memory result) = asset.call(data);
        if (!ok || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))) {
            revert TokenCallFailed();
        }
    }
}
