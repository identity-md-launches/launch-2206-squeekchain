# SqueekChain (SQK)

An immutable, fixed-supply ERC-20 token. The constructor mints the entire supply
once to its caller. Ordinary transfers and approved transfers move the exact
requested amount.

## Contract and deployment parameters

| Parameter | Value |
| --- | --- |
| Source / Solidity identifier | `src/SqueekChain.sol:SqueekChain` |
| Token name | `SqueekChain` |
| Symbol | `SQK` |
| Decimals | `18` |
| Supply in whole tokens | `1,000,000,000` |
| Supply in base units | `1000000000000000000000000000` (`10^27`) |
| Named supply constant | `INITIAL_SUPPLY` |
| Constructor arguments | None (`[]`) |
| Constructor transaction value | `0` |
| Initial recipient | `msg.sender`, the immediate constructor caller |
| Intended launch chain | Ethereum, chain ID `1` |
| Administration / initialization | None |

Deploy the compiled creation bytecode directly. A direct wallet deployment
credits that wallet; a factory deployment credits the factory. The transaction
origin and the caller of the factory do not receive tokens automatically. The
constructor makes no external calls and needs no pre-existing contracts,
addresses, keys, or configuration. The deployment artifact is
`out/SqueekChain.sol/SqueekChain.json`; no library linking is required.

For the IdentityMD launch, the launch service deploys this token through its
factory. The factory then handles the specified distribution: 10% to the swarm
distributor, 80% for pool seeding, and the remaining 10% to the requester. These
allocations are external launch operations, not constructor transfers. This
project contains only the token; the separate launch step supplies the manifest,
pool settings, and deployment transaction. No launch manifest or signing script
is needed here.

## Behavior and assumptions

- No minting is exposed after construction. There is no burn interface, transfer
  tax, rebase, pause, blacklist, seizure, owner, or upgrade mechanism.
- `transfer`, `approve`, and `transferFrom` return `true` on success and revert
  with ERC-20 custom errors on failure. Transfers emit `Transfer`; explicit
  approvals emit `Approval`. Allowance spending does not emit `Approval`.
- Zero-value transfers between valid addresses are allowed and emit `Transfer`.
  Self-transfers preserve the balance. Transfers to the zero address and
  approvals to a zero spender revert.
- Approvals replace the existing allowance. Finite allowances decrease when
  spent; `type(uint256).max` is an unlimited allowance and does not decrease.
  Holders choose their spenders and allowance amounts. Changing an existing
  allowance can race with spending: revoke to zero and confirm before setting a
  replacement when this matters.
- No recipient callback occurs during a transfer. Native currency payments and
  unknown function calls revert. Tokens sent to this token contract or another
  address without a way to transfer them back cannot be rescued by an admin.

## Build and test

Install Foundry and Solidity `0.8.26` in the build environment. All Solidity
dependencies are included as ordinary files under `lib/`; no dependency download
or submodule initialization is needed. The verifier provides the pinned compiler
offline. `foundry.toml` pins Cancun, optimization at 200 runs, and
`bytecode_hash = "none"`. FFI is disabled and no filesystem permissions are
granted to tests.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x4c0e975694cbf102ce29e295e5db11d1fae0ffa88b6667f7cb9bc9e2e941421c forge test
forge fmt --check
sha256sum -c dependencies.sha256
```

The tests do not read or change environment variables, require an RPC, or rely
on persistent state from other tests. The environment assignment above sets
Foundry's fuzz seed, not contract configuration. There is no seed pinned in the
project configuration. Fuzz tests run 512 cases each; stateful invariants run 128
sequences of 64 actions each.

`test/SqueekChain.t.sol` covers metadata, the single mint event, exact transfers,
allowance accounting and revocation, zero and maximum amounts, rejected inputs,
rollback of failed operations, unsupported administrative calls, and runtime
size/opcodes. `test/SqueekChainLaunch.t.sol` covers CREATE2 factory ownership of
the initial supply and exact distribution, claim, and trading transfer routes.
The trading test exercises token transfers only, not Uniswap pricing or actual
pool settlement. `test/SqueekChainInvariant.t.sol` checks supply, balances, and
allowances against an independent model across randomized action sequences.

The supplied protected launch checks reference additional launch infrastructure
and environment values that are not part of this repository. They are run by
the separate launch verifier; the local suite does not claim to execute them.

## Dependencies

Production code inherits the unmodified ERC-20 implementation from
[OpenZeppelin Contracts v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2).
Only its five required Solidity files and MIT license are vendored.
[forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7)
is vendored for testing with its MIT and Apache-2.0 licenses. Source tags and
archive hashes are recorded in `dependencies.json`; individual vendored file
hashes are in `dependencies.sha256`. Formatting excludes these upstream files.

## After launch

There are no owner settings, initialization calls, keepers, or administrative
keys for SQK. The launch operator is responsible for using the correct creation
bytecode and chain, ensuring that the deploying factory can distribute the
supply, completing the launch distribution and pool setup, and verifying source
and deployed bytecode. Confirm the name, symbol, decimals, total supply, and
distribution from on-chain state and events.

Holders are responsible for recipient selection and spender approvals. Losing
access to a holder account or sending tokens to an inaccessible address cannot
be reversed. The fixed supply does not give any party special recovery powers.

The implementation was reviewed locally for constructor allocation, externally
reachable mint/burn paths, allowance authorization, rollback, external calls,
and upgrade or balance-control powers. Foundry unit, fuzz, and invariant tests
provide automated checks. Slither and Mythril were not run. This work is not an
independent security audit; the launch's separate review and deployment checks
remain the launch operator's responsibility.
