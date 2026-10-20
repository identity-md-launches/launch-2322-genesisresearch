# GenesisResearch

Contract-only source package for the Genesis experiment-discovery app at https://imdgenesis.xyz. No token or liquidity pool.

Pins one public world commitment, bounds future IMD research spending, authenticates Intake callbacks and records prediction commitments/reveals. Scientific correctness and prediction scoring remain offchain. No automatic prize payment; prize-recipient rules are external to this contract.

## Launch record (Ethereum mainnet, chain id 1)

One `GenesisResearch` is deployed through the IMD project factory as an `evm_contracts` launch. The factory constructs it in one transaction with these static arguments, in constructor declaration order:

| Argument | Value |
| --- | --- |
| `owner` | `$owner` = `0x550011cadcc758969391050241b2fc43ed1a4b97` (the requester wallet) |
| `intake` | `0xa43e6f75ee006411f79ac1c84120606c2330de82` (IMD Intake v2) |
| `asset` | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (IMD) |
| `worldCommitment` | `0x190996ed4ed39d38bd9cf088077f0f9aa4afc5d926df034f0b4f792259599fac` |
| `spendCap` | `500000000000000000` (0.5 IMD lifetime cap) |
| `price` | `500000000000000000` (0.5 IMD per job) |

Ownership: `owner` is immutable and is the requester wallet above. The factory that creates the contract and IMD's launch wallet hold no role in it. Only the owner can set researchers, replace the intake while idle, set the price up to the cap, open epochs, abandon a stale request after 7 days and withdraw unused IMD. There is no ownership transfer and no rescue for tokens other than the configured asset.

Onchain address: assigned by the launch and published on the IMD launch page and in the deployment handoff once the launch transaction confirms. It is not recorded in this repository, and no address should be invented for it.

The deployment starts unfunded: zero native value, zero IMD, zero allowance, nothing spent, no pending request and no epoch. The launch makes no approval, transfer, research order or any other post-deployment call. Future funding or orders need separate authorization from the owner. The earlier paid research job `62c73a84-26cf-4378-962e-c72e55ceb81d` was a separate direct Intake request and is not a prior use of this registry; this launch claims no retroactive commitment timing.

No private keys, secret seeds, environment files or hidden world parameters belong in this package.

## Build and test

Solidity 0.8.26, Paris EVM, optimizer 200, metadata `bytecode_hash = "none"` (see `foundry.toml`). `forge build` and `forge test` run with the project's own configuration. Unit tests use mocks and are not proof of a live registry job; `test/GenesisResearchLaunch.t.sol` rehearses the launch floor's empty-chain construction with the exact arguments above. See `ADAPTATION.md` for what changed for the launch.
