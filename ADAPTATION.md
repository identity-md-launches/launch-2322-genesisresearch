# ADAPTATION

Launch: `evm_contracts`, Ethereum mainnet (chain id 1). Exactly one application contract,
`GenesisResearch`, deployed by the IMD project factory. No token, pool, distributor, proxy or
website is added. Compiler as configured in `foundry.toml`: Solidity 0.8.26, Paris, optimizer
200 runs, `bytecode_hash = "none"`. Build configuration, dependencies and layout are untouched.

## Changes

### 1. Constructor no longer requires `intake_` and `asset_` to have code

- File: `src/GenesisResearch.sol`, constructor.
- Required by: the launch reference ("a constructor that calls another contract, or requires an
  address to have code, reverts on the empty chain and parks the launch") and audit finding
  `30da7d7c677e187060353ffc441e32030f76ba830630216e0cd36dcd2d5a791d` (high), which reproduced:
  `new GenesisResearch(<manifest arguments>)` on a fresh forge chain reverted
  `InvalidConfiguration()` because the live Intake and IMD addresses have no code there
  (`test/scratch` reproduction failed before the change and passed after it).
- What changed: `intake_.code.length == 0` and `asset_.code.length == 0` became
  `intake_ == address(0)` and `asset_ == address(0)`. Every other constructor check (non-zero
  owner, non-zero world commitment, non-zero price, `spendCap >= price`) is unchanged.
- Test: `test/GenesisResearchLaunch.t.sol`
  `testConstructsWithManifestArgumentsOnEmptyChain` (exact brief arguments, chain id 1, no code at
  either address, all immutables and the unfunded/idle state asserted) and
  `testConstructorStillRejectsZeroAddressesAndBadBudget`.

### 2. The deferred code check runs at first use in `_orderResearch`

- File: `src/GenesisResearch.sol`, `_orderResearch`, one line before the balance read.
- Required by: the same reference ("take such values as arguments and check the live contract on
  first use instead"). It preserves the original intent of the removed constructor check: the
  contract never approves or pays an address that is not a live contract. It runs after the
  authorization, price, body, pending, duplicate and budget checks and before any state write or
  token call, so a refused order leaves nothing spent, approved or burned. `setIntake` keeps its
  own code check unchanged.
- Test: `test/GenesisResearchLaunch.t.sol`
  `testOrderRefusesCodelessIntakeBeforeAnyPaymentOrBookkeeping`,
  `testOrderRefusesCodelessAssetBeforeAnyPaymentOrBookkeeping`, `testSetIntakeStillRequiresCode`.

### 3. Documentation

- `README.md`: launch record (chain, constructor arguments, ownership, how the onchain address
  is published) replacing the "Not deployed" wording. No behaviour change.
- `ADAPTATION.md`: this file.

No other source line changed. All budget, authorization, callback authentication, replay,
reentrancy and commit/reveal logic is byte-for-byte the production source.

## Audit findings that were not changed

- `1dd09f3f…` (low, stored price instead of `Intake.priceOf`): the behaviour reproduces as
  described, but it is the project's design and the brief fixes `price` and `spendCap` as static
  constructor arguments and asks that production semantics be preserved. The price-bound overload
  `orderResearch(body, expectedPrice)` already stops an order at a price the caller did not review.
  Left unchanged; the requester accepts that a live price above the immutable cap means no further
  order can be placed from this registry.
- `f6250694…` (low, no generic ERC-20 rescue, immutable owner): reproduces as described and is a
  deliberate design choice recorded in the README. Adding ownership transfer or token rescue would
  be a redesign the launch rules do not ask for. Left unchanged and recorded as a trust assumption.
- `d87f413d…` (info, cap == price means one job for the contract's lifetime; abandoned bodies stay
  burned): reproduces and matches the stated "bounded" design and the brief's arguments. Left
  unchanged; the body must be preflighted with `POST /requests/check` before the single order.
- `286f4823…` (info, coverage): not a defect.

## Launch rules checked

- Nonpayable constructor, six static arguments (address, address, address, bytes32, uint256,
  uint256), no initializer, proxy, DELEGATECALL, CALLCODE or SELFDESTRUCT; runtime 8486 bytes,
  scanned with the floor's algorithm. Rehearsed in `test/scratch` by CREATE2 from an etched
  factory-like contract on chain id 1 with the exact arguments.
- Owner is the constructor's first argument (`$owner` = `0x550011cadcc758969391050241b2fc43ed1a4b97`),
  never `msg.sender` or `tx.origin`.
- Deployment sends zero ETH and makes no call after construction: the contract starts with zero
  IMD, zero allowance, `spent == 0`, no pending request and no epoch.
- No `launch.json` is written here; the manifest step writes it with the arguments listed in the
  README, in declaration order.

## Checks run

- `forge build` with the project's own `foundry.toml`.
- `forge test` with `FOUNDRY_FUZZ_SEED=0x8332f61ba498642a49c233984dd32e244f6c3e245b743f755929c41fb2f84a8a`:
  the 19 supplied tests (including `testResultCallbackFitsIntakeGasBudget` under a 200 000 gas
  call and `testFuzzBudgetNeverOverspends` with 256 runs) plus the 5 new launch tests, all passing.
- Callback selectors and action id re-derived with `cast`: `onResult(bytes32,bytes32,string)` =
  `0x4374622e`, `onFailure(bytes32,uint8,bytes32,uint16,uint16,bytes)` = `0x5a0df71e`,
  `bytes32("job.open@job-1")` = `0x6a6f622e6f70656e406a6f622d31…00`.
