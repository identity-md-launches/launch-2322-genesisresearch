# GenesisResearch test review

The original 19 behavior tests and five launch tests are retained unchanged. Added tests use
the existing production contract directly. All helper contracts are local test doubles; they
are not additional launch applications. No production source, configuration, dependency,
manifest, or broadcast script is changed.

## Added coverage

| File | Properties checked |
| --- | --- |
| `GenesisResearchAdversarial.t.sol` | Every owner permission; donor versus researcher authority; exact action, body, payer and callback ABI; body length endpoints; atomic rollback after payment, invalid request IDs, partial pulls, all three approval failures and malformed ERC-20 returns; token and intake reentrancy; writer-only one-shot delivery; both failure statuses and result callbacks under 200,000 gas; emitted provenance; unknown/foreign/replayed callbacks; intake migration; abandonment at the seven-day boundary. |
| `GenesisResearchBudgetEdges.t.sol` | Full-width uint256 fuzzing; one wei; maximum cap and price; exact final budget consumption; one wei above remaining budget; funding and withdrawals cannot restore spent lifetime budget. |
| `GenesisResearchPrediction.t.sol` | Missing/invalid epochs; empty commitments and predictions; incorrect salts and hashes; early, expired and duplicate reveals; exact one-second windows; participant, chain, contract, epoch, target and world binding; uint64 deadline boundary; predictions do not settle prizes. |
| `GenesisResearchLaunchPolicy.t.sol` | One factory CREATE2 transaction using the exact approved static words; explicit requester ownership; no child application creation; empty-chain construction; zero funding, approvals, orders and epochs; nonpayable deployment; runtime size and forbidden opcodes. |
| `GenesisResearchInvariant.t.sol` | Independent custody accounting, lifetime budget, authorization and immutable request history across random call sequences. |
| `GenesisResearchPredictionInvariant.t.sol` | Immutable targets and commitments, one reveal per participant/epoch, and commit/reveal timing across random call sequences. |

## Stateful models

Both campaigns run 256 sequences of depth 128 with `fail-on-revert = true`, configured in the
test files. Only the handlers are targeted. Mock minting and fault configuration cannot be
randomly called behind the model's back.

The budget handler has an owner, a persistent researcher, a revocable researcher, an
unprivileged donor, two intakes, and a separate writer and treasury. It interleaves funding,
direct token donations, withdrawals, both order overloads, price changes, researcher changes,
intake migration, success/failure callbacks, time advancement, abandonment, and unauthorized
or replayed calls. Ghost balances are derived from successful operation inputs, not copied
from the contract's reported totals.

After every call:

- Registry custody equals funding plus direct donations minus withdrawals minus paid prices.
- Treasury receipts equal the sum of prices actually ordered, which equals `spent`.
- Actor balances and total token supply conserve value; neither intake retains funds or an
  allowance from the registry.
- Spending never exceeds the immutable cap, including after failures and abandonment.
- Every recorded request keeps its original body, intake and time; terminal states and
  result hashes never change. The pending pointer identifies exactly zero or one request.
- Owner, researchers, price and intake match authorized model changes.

The prediction handler interleaves opening epochs, committing, revealing valid and incorrect
preimages, moving time forward to random times and exact deadlines, and unauthorized epoch
creation. It retains every epoch and participant record and checks them after every call.
Accepted commits precede their deadline; accepted reveals fall inside their reveal window.

Each handler also has a deterministic test proving it reaches successful transitions and
rejections. Expected failures verify the revert selector; unexpected failures are not swallowed.
The campaigns use bounded inputs and no `vm.assume`, `vm.setEnv`, forks, FFI, or skipped tests.

## Launch argument fixture

The launch probe encodes these six words in declaration order:

| Argument | Approved value |
| --- | --- |
| owner | `$owner` resolves to `0x550011cadcc758969391050241b2fc43ed1a4b97` |
| intake | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| asset | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| worldCommitment | `0x190996ed4ed39d38bd9cf088077f0f9aa4afc5d926df034f0b4f792259599fac` |
| spendCap | `500000000000000000` |
| price | `500000000000000000` |

The deployment under review is one `GenesisResearch` on Ethereum mainnet, with zero native
value, zero IMD and no post-deployment calls. Local CREATE2 addresses are test results, not a
mainnet deployment address. The confirmed address belongs in the deployment handoff after
launch. Ownership is the immutable requester address above.

Job `62c73a84-26cf-4378-962e-c72e55ceb81d` is a separate direct Intake request; none of these
tests claims prior registry use or retroactive commitment timing. Scientific scoring and
prize-recipient rules remain external.

## Verification and limits

Run from the repository root, using the pinned compiler settings already in `foundry.toml`
(Solidity 0.8.26, Paris, optimizer 200, bytecode hash none):

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge build --offline
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache FOUNDRY_FUZZ_SEED=0x8332f61ba498642a49c233984dd32e244f6c3e245b743f755929c41fb2f84a8a forge test --offline
```

Artifact paths keep generated files inside disposable scratch space; delivered tests do not
import or depend on it. The suite needs no additional libraries or network access.

The full suite passed on Foundry 1.8.3: 73 reported tests, including three invariant functions
(the two accounting invariants share one campaign). The two campaigns completed 65,536
randomized handler calls in total with zero unexpected reverts. Stateless fuzz tests each
run 256 cases, including the original budget fuzz test.

An additional `forge coverage --offline` run passed the same suite and reported 127/127
production lines, 21/21 functions and 32/33 branches. The uncovered branch is attributed to
the shared `nonReentrant` modifier; nested token and intake callback tests separately assert
the exact `ReentrantCall()` error. Coverage percentages are not a substitute for those checks.

The intake double follows the supplied Intake v2 interface and delivery rules; it does not
claim to verify live mainnet code, paid-body admission, future oracle delivery, or scientific
correctness. GenesisResearch uses unsigned job-result callbacks, not oracle attestations.
No confirmed production defect requiring a finding was reproduced by this suite.
