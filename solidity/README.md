# Oracle Consumer Contracts - Solidity

Oracle consumer contract integrating Chainlink price feeds with fallback logic for resilience.

## Contracts

### OrangePriceOracle.sol
Chainlink price feed consumer with automatic fallback support.
- Primary and fallback feed configuration
- Staleness checks with configurable heartbeat
- Price deviation monitoring between feeds
- Custom errors for gas efficiency

## Setup

```bash
npm install
```

## Test

```bash
npx hardhat test
```

## Key Features

- **Fallback Logic**: Automatically uses fallback feed when primary fails
- **Staleness Checks**: Rejects outdated price data based on heartbeat
- **Deviation Monitoring**: Detects excessive price differences between feeds
- **Gas Efficient**: Custom errors, optimized storage layout

## Test Coverage

- 42 tests covering constructor, price fetching, fallback behavior, staleness, deviation, and admin functions
