# GenesisResearch

Contract-only source package for the Genesis experiment-discovery app at https://imdgenesis.xyz. Not deployed. No token or liquidity pool.

Pins one public world commitment, bounds future IMD research spending, authenticates Intake callbacks and records prediction commitments/reveals. Scientific correctness and prediction scoring remain offchain. No automatic prize payment.

Expected owner and proposed external prize recipient: 0x550011cadcc758969391050241b2fc43ed1a4b97. The creator of an IMD factory deployment is the factory, distinct from this owner. Organizer prize attribution remains unresolved.

Deployment must start unfunded, with 0.5 IMD lifetime cap and 0.5 IMD job price. It makes no approval or research purchase. Future funding/order needs separate authorization. No private keys or hidden world parameters belong in this package.

Solidity 0.8.26, Paris EVM, optimizer 200, metadata bytecode_hash none for IMD source import. Unit tests use mocks and are not proof of a live registry job.
