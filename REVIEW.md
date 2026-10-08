# Local adversarial review

This is the implementer's review, not an independent contributor audit. No deployment, wallet access or external transaction was performed.

## Validation

- Solidity 0.8.26, optimizer 200, via IR, Cancun, `bytecode_hash = "none"`.
- `forge build --sizes`: BaskVault runtime **22,881 bytes**, initcode **23,469 bytes**. No lens required. The constructor performs no external calls and uses explicit owner/guardian arguments.
- `forge test -j 4 -vv`: **74 tests**, including seven fuzz tests with 256 runs each. Fixtures are independent and make no environment or fork calls.
- `forge fmt --check`: passes.
- The deployed-bytecode test repeats the supplied floor's PUSH-aware scan and rejects DELEGATECALL, CALLCODE and SELFDESTRUCT, including the data section. The fixed ERC-20 Transfer topic is a private immutable so the compiler encodes it as PUSH data; standard event topics/data are tested. This immutable is not configurable.
- All imports are present as ordinary files. FFI and filesystem permissions are disabled. The compiler binary is supplied by the check environment, not vendored or path-pinned.

The revision first reproduced all six reports on the accepted tree. The supplied retirement proof failed with a 360e18 payout for a 300e18 deposit, then passed unchanged after the fix. `test/Revision.t.sol` adds twelve regression tests. Decisions and remaining scope limitations for every report are in `.imd-responses.json`; the permanent-share residual and zero-NAV rejection are retained because the brief explicitly requires their accounting rules.

## Redemption gas attacks

Measurements below include a cold call, all-zero minimum arrays with one entry per listed asset, and transaction intrinsic calldata gas, before refunds. Each redemption is supplied **27,925,000 execution gas**, leaving room beneath 28 million for intrinsic gas. Tests additionally assert total measured gas is below 28 million. Setup cost is excluded: it includes deploying up to 350 independent mocked tokens and feeds.

| Scenario | Gas |
|---|---:|
| 250 funded assets, all balance reads exhaust their 50,000 gas | 26,604,927 |
| 250 funded assets, all tokens paused | 15,447,429 |
| 254 funded assets, 50,000 balance gas | 27,029,340 |
| 350 funded assets, 20,000 balance gas | 26,717,673 |
| 50 funded assets, 500,000 balance gas, new fee recipient, 512-bit arithmetic | 27,924,736 |
| 250 listed / 77 funded, direct limit 77, slow reads and gas-exhausting payments | 27,611,179 |
| 350 listed / 48 funded, 20,000 balance gas, 500,000 pay gas, new fee recipient, 512-bit arithmetic | 27,978,671 |

The two 512-bit scenarios first perform three real confiscation, delayed loss-recognition and deposit cycles. These create a very large share supply without storage injection, forcing full-precision redemption multiplication. The sparse-registry test also covers zero-managed entries and a previously unused fee-recipient balance.

Gas attacks during development found that scanning unfunded storage twice and emitting an event per deferred leg consumed the allowed margin. The implementation now tracks funded indices with an internal bitmap, caches registry length, uses fixed-size balance reads, and emits the required transaction-level redemption event. It preserves every required balance/minimum/payment check and the specified gas stipends. The bitmap is maintained through deposit, resync, loss recognition, redemption and registry swap-removal.

## Other concrete attacks

- **Paused, blocked and changed tokens:** redemption pays healthy legs while preserving failed legs as debts. Removing a token's code after deposit cannot stop redemption.
- **False/malformed/huge transfer results and incorrect debits:** the isolated payment reverts, restoring the token transfer before recording debt. Empty successful return data is accepted. Inbound short-credit tokens are rejected. Outbound acceptance measures the specified exact vault debit, not receiver credit.
- **Hostile balance reads:** short/reverting/gas-exhausting reads use managed for redemption; large return buffers copy only the first word. Deposits reject unreadable backing. Loss recognition requires a readable current shortfall.
- **Callback reentrancy:** deposit, redeem, claim, and registry mutation callbacks fail, including a token that is itself the owner. The payment entry point rejects callers other than the vault.
- **Withdrawal restrictions:** invalid prices, stale feeds, every deposit pause/close, cap zero, tight freshness/hours, low oracle gas and restrictive price settings cannot veto redeem or claim. Low balance/pay settings do not cap claim calls.
- **Losses and debt priority:** available backing subtracts total owed; resync excludes debts. Deficits are not silently written off. Larger recorded deficits restart the seven-day clock; partial recovery limits recognition. Partial claims retain unpaid debt.
- **Oracle failures:** price/time/band bounds, optional pause detection, negative tick rounding, accumulator wrap, quote decimals/direction, adequate-liquidity deviation, low-liquidity fallback and malformed observations are tested.
- **Governance races:** execution revalidates listing and settings; closes void reopen proposals; retirement voids asset proposals; removal/relisting cannot revive them; lowering the cap voids raises. Timelock/expiry boundaries, guardian cancellation restrictions and two-step ownership are tested.
- **Share accounting:** first-deposit lock, fixed fees rounded upward, round-down valuation/redemption, donation isolation, zero NAV, slippage, deadlines, allowance semantics and ERC-20 logs are tested. Fuzzing covers conservation, decimal combinations, transfer/read failure modes and reciprocal tick quotes.
- **Revision regressions:** retired managed backing prevents new shares from acquiring unpriced holdings, including with broken reads and configured fees; fully recognized losses and empty retired entries allow deposits subject to the other checks. Existing holders still redeem or claim. Redemptions to the vault revert atomically. Nonzero trailing minimums survive one or multiple registry removals by reverting. Guardian proposals recheck pending ownership at execution.

## Release responsibilities and limits

The owner must verify real Stock Token/feed/pool pairings, decimals and pool observations on Robinhood Chain and configure the basket through the documented genesis/proposal paths. This assignment provides no unverified external addresses. Fee-recipient selection remains an owner proposal, as specified.

The accepted risks remain: feed-lag profit within deviation, owner-selected pairings, concentration without per-asset caps, and thin-pool interference with deposits. Deferred debt cannot force a blocked or broken token to transfer. Retired positions have zero deposit NAV and remain redeemable, so nonzero retired managed backing now prevents deposits. Permanent-share residuals can keep that restriction in place. Redemption minimums remain positional; checking trailing minimums fixes the reported removal-only omission but does not bind token identities across subsequent owner listings. Claimants can consume remaining liquidity in a deficit under the specified first-claim accounting.

These are local EVM measurements and tests, not live-chain execution or an exhaustive proof over malicious token implementations. No Slither/Mythril run or independent reviewer sign-off is claimed. A separate contributor review and verification of actual launch dependencies remain release responsibilities.
