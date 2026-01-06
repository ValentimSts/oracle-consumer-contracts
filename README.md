# Oracle Consumer Contracts

Chainlink price feed consumer with fallback logic for resilient off-chain data retrieval.

## Features

- Primary and fallback oracle support
- Staleness checks with configurable heartbeat
- Price deviation monitoring between feeds
- Custom errors for gas efficiency

## Structure

```
solidity/   - Solidity implementation
vyper/      - Vyper implementation
```

## Quick Start

```bash
cd solidity && npm install && npx hardhat test
cd vyper && pip install -r requirements.txt && npx hardhat test
```
