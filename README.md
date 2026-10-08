# Workers (WORK)

Workers is a fixed-supply ERC-20 with a **2% fee on transfers involving owner-registered trading venues**. It mints **1,000,000,000 WORK with 18 decimals** once, entirely to the constructor's caller. Total supply in minor units is **1000000000000000000000000000**. There is no subsequent mint, burn, pause, blacklist, seizure, proxy, or upgrade function.

The launch's factory, ordinary PoolManager settlement, and distributor claims move exact amounts. **The native launch pool and other v4 pools using the same PoolManager do not collect the token's 2% fee on trades with unregistered accounts.** Other venues must be configured after deployment, as described below. Transfers between a registered venue and the PoolManager still pay the fee, so relaying a secondary venue trade through the manager does not bypass it. No trading venue or fee-recipient address has been guessed.

## Fee semantics and assumptions

“Trade” means a token transfer whose sender or receiver is a registered custody address (for example, a fee-aware AMM pair). The token cannot infer a swap's intent from an ERC-20 transfer. Transfers to/from a registered venue include liquidity deposits, withdrawals, donations and self-transfers; these also incur the fee unless exempt. Ordinary wallet transfers and transfers involving only unregistered contracts have no fee. Merely registering a router that never holds tokens will not tax its trades.

For gross amount `amount`, the fee in WORK is `floor(amount * 200 / 10000)`, and the destination receives `amount - fee`. A 100 WORK trade pays 2 WORK to the configured recipient and delivers 98 WORK. Rounding is down in the smallest token unit: amounts below 50 minor units pay no fee. Splitting transfers can reduce rounding fees. There is no automatic swap, reflection or burn.

`transfer` and `transferFrom` use identical fee rules. Allowances are spent on the **gross** amount, including the fee; OpenZeppelin's unlimited-allowance convention is retained. A transfer between two registered venues pays one fee. Zero transfers succeed and emit `Transfer`. Failed transfers roll back balances, fees, events, and allowances. The gross balance must be available even if the fee recipient is the sender. If the fee recipient is also the transfer destination, that address receives both fee and net amount.

Fees go directly to `feeRecipient` using internal ERC-20 accounting. It receives no callback and does not need to implement an interface. Each charged transfer emits a fee `Transfer`, `TradeFeePaid`, and a net `Transfer`. The rate is an immutable code constant; administrators cannot increase it.

## Deployment parameters

Build target: `src/Workers.sol:Workers`. Constructor arguments are static, in this order:

| Argument | Source | Meaning |
| --- | --- | --- |
| `address factory_` | `$factory` | Actual deploying launch factory; must equal `msg.sender` and have code. |
| `address poolManager_` | `$poolManager` | Verified launch PoolManager contract on the target chain; must have code and differ from the factory. |
| `uint64 launchNumber_` | `$launchNumber` | Actual launch key used by the factory's `distributorOf(uint64)` registry. |
| `address initialOwner_` | Literal static address | Actual requester administration address, normally the launch's requester/remainder recipient; must be nonzero and differ from the factory and PoolManager. |

The first three `$…` entries are the launch guidance's symbolic deployment parameters, **not literal addresses or substitute values**. Resolve them from the actual launch configuration. The fourth argument must contain the requester's actual administration address as a literal static address; the token constructor's manifest arguments do not resolve `$requester`. The constructor rejects the factory and PoolManager as owner because these launch endpoints cannot administer the token.

The entire supply goes to `msg.sender` (the factory), even when the initial owner differs. The factory subsequently performs its distribution, pool seed, and requester transfer. The constructor does not move any of the initial mint. No initialization call is needed for those launch flows.

The factory must already be deployed and expose `distributorOf(uint64) returns (address)`. Direct EOA deployment and deploying from inside a factory's own constructor are intentionally unsupported. The factory must record the correct distributor for this launch before claims begin. That distributor is resolved at transfer time because its address depends on the token deployment. A zero registry result means no distributor has been registered; it is never treated as an exemption. A reverting lookup produces `DistributorLookupFailed` on a fee-eligible transfer, venue registration, or fee-recipient update, while transfers with no registered venue remain usable, including ordinary PoolManager settlement.

Launch exemptions take precedence over venue settings:

- The caller is the immutable launch factory.
- The caller, sender, or recipient is this launch's current registered distributor.

The PoolManager cannot be registered as a venue. Transfers between it and unregistered accounts are untaxed under the ordinary transfer rule. It has no caller or endpoint exemption when a registered venue is involved: venue-to-manager and manager-to-venue transfers pay 2%, as does `transferFrom` called by the manager when either endpoint is a venue. Routers must settle the actual amount received and account for fees on these routes.

Exemptions do not grant spending authority: `transferFrom` still requires the holder's allowance, including for the factory, manager, distributor and owner. Protected endpoint addresses and the current fee recipient cannot be enabled as venues; a distributor registered later also takes precedence over an existing venue flag. The owner is not automatically fee-exempt.

No chain, launch number, paired currency, pool economics, or production addresses were supplied with this assignment. This project contains no fabricated launch manifest and performs no deployment, broadcasting, bridging, or key access. The launch operator supplies these deployment values separately. Solidity is pinned to **0.8.26**, with optimizer runs **200**, EVM target **Cancun**, and `bytecode_hash = "none"`. Use a chain that supports this EVM target; a different compiler environment such as zkSync Era is not covered by this build.

## After launch

The token starts with an **unset fee recipient and no registered venues**. Transfers are available, but the trade fee does not activate until the owner configures a venue. Configure fees before opening a secondary taxable market:

1. The owner calls `setFeeRecipient(address)` with the actual fee treasury supplied by the requester. Zero, the token, factory, PoolManager, current registered distributor and registered venues are rejected to avoid stranded or publicly claimable fees. This emits `FeeRecipientUpdated`. Replacing it affects future fees only. A treasury cannot subsequently be registered as a venue while it remains the fee recipient.
2. The owner obtains each intended custody/pair address from that venue's verified deployment or factory registry, checks it on the correct chain, then calls `setTradeVenue(address, true)`. Contract code is required, but code existence alone does not prove that it is an AMM. This emits `TradeVenueUpdated`. Calling this before setting the recipient reverts with `FeeRecipientNotConfigured`.
3. Verify both trade directions and liquidity operations with the venue's actual router. It must account for fee-on-transfer balances, including routes through the PoolManager to/from registered venues. Ordinary launch-pool trades with unregistered accounts remain untaxed; fee-on-transfer support is not assumed for any additional venue. Disable an obsolete venue using `setTradeVenue(address, false)`.
4. If administration should move to another account or multisig, the current owner calls `transferOwnership(newOwner)` and that account calls `acceptOwnership()`. A pending transfer can be cancelled with `transferOwnership(address(0))`. Renunciation is disabled so configuration remains recoverable.

Operational responsibilities: the owner controls treasury routing and venue classification, so holders trust it to label actual trading venues accurately. It can apply the fixed 2% fee to a contract wallet by registering that wallet, or remove fees by disabling venues. It cannot freeze balances or debit another holder without allowance. The launch operator is responsible for verifying factory and PoolManager code, the distributor registry entry, constructor arguments, supply, and deployed bytecode. The factory's registry is a trusted dependency for taxable transfers and distributor exemptions; it must not later register the treasury as the distributor. The recipient checks exclude known unsafe endpoints but cannot prove custody of an arbitrary treasury, so the requester must verify its control and withdrawal ability. Keep ownership keys secure and monitor configuration events. Run independent adversarial review and verify source before a production release; the local checks are not a security audit.

## Build and verification

```sh
forge build
forge test
forge fmt --check
```

Foundry and the pinned compiler are the only toolchain prerequisites. All Solidity dependencies are included as ordinary source files under `lib/`; there are no submodules, package downloads during builds, RPC dependencies, FFI, or filesystem cheatcode permissions. Tests use no environment variables and are isolated for concurrent execution.

The tests cover constructor mint/metadata, invalid deployment parameters, unsafe owner/treasury rejection, unconfigured/set fee states, owner permissions and two-step transfer, buys/sells, rounding, self-transfers, overlapping sender/recipient/treasury addresses, gross allowances, atomic failures, launch distribution, exact ordinary manager settlement, taxed manager relays to/from venues, late distributor registration and lookup failures, absent mint/freeze/upgrade powers, and forbidden runtime opcodes. Two amount fuzz tests each run 512 cases. A stateful balance model exercises random direct/delegated transfers and configuration changes; the invariant checks conservation over 128 sequences of 64 calls.

Launch endpoint fixtures model exact token movements; they **do not implement Uniswap pricing or prove live AMM integration**. The supplied protected admission harness requires the network's factory/PoolManager infrastructure, generated creation code and launch environment. It is an input, not copied into the delivered test tree or claimed as a locally executed admission test. That independent integration check remains the launch operator's responsibility. Slither and Mythril were not run.

Dependency provenance and licenses: [DEPENDENCIES.md](DEPENDENCIES.md).
