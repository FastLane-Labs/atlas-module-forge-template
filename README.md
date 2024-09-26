# Atlas Module Forge Template

This project is a template for developing Atlas modules using the Foundry framework.

## Foundry

Foundry is a blazing fast, portable, and modular toolkit for Ethereum application development written in Rust.

Foundry consists of:

- **Forge**: Ethereum testing framework (similar to Truffle, Hardhat, and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions, and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache or Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose Solidity REPL.

## Getting Started

1. Install Foundry by following the [official installation guide](https://book.getfoundry.sh/getting-started/installation).
2. Clone this repository.
3. Run `forge install` to install dependencies.
4. Copy `.env.example` to `.env` and fill in your environment variables.

## Usage

### Build

Compile the smart contracts:

```shell
forge build
```

### Test

Run the test suite:

```shell
forge test
```

For more verbose output, use:

```shell
forge test -vv
```

### Format

Format your Solidity code:

```shell
forge fmt
```

### Gas Snapshots

Generate gas snapshots:

```shell
forge snapshot
```

### Anvil (Local Ethereum Node)

Start a local Ethereum node:

```shell
anvil
```

### Deploy

Deploy your contracts to a network:

```shell
forge script script/Deploy.s.sol:DeployScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

Replace `<your_rpc_url>` and `<your_private_key>` with your actual RPC URL and private key.

### Interact with Contracts (Cast)

Use Cast to interact with deployed contracts:

```shell
cast <subcommand>
```

## Documentation

For more detailed information on using Foundry, refer to the [Foundry Book](https://book.getfoundry.sh/).

## Project Structure

- `src/`: Smart contract source files
- `test/`: Test files
- `script/`: Deployment and other scripts
- `lib/`: Dependencies (installed via Forge)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the [MIT License](LICENSE).
