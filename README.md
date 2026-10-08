# Basket Protocol

Basket is an index vault for Stock Tokens on Robinhood Chain (chain ID **4663**). `BaskVault` is also the ERC-20 share: **Basket / BASK / 18 decimals**. Its initial supply is zero; deposits mint shares and redemptions burn shares. There is no supply cap.

## Build and deployment

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins solc 0.8.26, optimization at 200 runs, via IR, Cancun, and no bytecode metadata hash. FFI and filesystem permissions are disabled. Dependencies are vendored as ordinary files; see `DEPENDENCIES.md`. Tests use local Token, Feed and v3-style Pool mocks, with no forks, RPCs or environment variables. Test time reads use Foundry's `getBlockTimestamp()` to prevent the optimizer caching timestamps across test-only time warps.

`launch.json` deploys only `BaskVault(address owner_, address guardian_)`:

| Parameter | Literal |
|---|---|
| owner_ | `0x30B57ECf51D19ABcED7F6f70974e6fBb6f3b9Da3` |
| guardian_ | `0x5ed39AF86f2C00ad99913B5d727bD68f2A904B68` |

The constructor rejects zero or identical roles and makes no external calls. Ownership comes from the argument, including when a factory deploys the contract. No transactions are broadcast by this project. No separate lens is needed while runtime remains below 24,000 bytes.

## After launch

The owner obtains and verifies the actual Stock Token, USD feed, pool and quote-feed addresses on chain 4663. No external deployment addresses are guessed or embedded here.

1. Call `genesisList(token, feed, pool, quoteFeed, minLiquidity)` for each initial asset. Listing validates token/feed decimals, feed freshness and positive answer, exclusive use of the feed among unretired assets, and pool pair/quote decimals. The initial centre is the feed answer. Pause-interface support is detected once at listing, even if its returned boolean is true.
2. Pool configuration is atomic with listing. A missing pool is explicitly represented by `pool = 0`, `quoteFeed = 0`, `minLiquidity = 0` and activates the tighter feed-age fallback. These zeros represent the specified optional configuration, not a deployment stand-in. A configured pool identifies the quote token through its pair. The owner is responsible for choosing the true pool and quote USD feed, adequate observation history, and the minimum harmonic liquidity threshold.
3. Call `finalizeGenesis()` once at least three assets are listed. Deposits remain closed until this call. Listing is immediate only during genesis; later listings require proposals.
4. Fees start disabled. To enable the fixed 50 bps fees, propose `FeeRecipient` with the actual recipient in `target`, wait two days, then execute. The recipient cannot be zero or the vault. Once configured, it cannot be cleared; the fee rate cannot change.
5. Monitor feed ages, pool observations, optional token pause interfaces, managed backing, and outstanding debts. Close deposits or pause them when necessary. Anyone may flag and recognize losses; the owner need not cooperate.

## Accounting and user operations

Only `managed[token]` enters valuation. Direct token transfers are ignored until the owner executes a timed `Resync`. Resync adds only positive balance surplus after both managed assets and redemption debts; it does not reduce managed amounts.

Values are dollars times 1e18, rounded down as `amount * answer * 1e18 / 10^(tokenDecimals + feedDecimals)`. Full-precision multiplication avoids intermediate overflow where the final quotient fits. Decimals are cached at listing/feed/pool configuration, with every supported decimal count at most 18.

`deposit(tokens, amounts, receiver, minSharesOut, deadline)` validates global deposit state, weekday hours, unique open assets, exact positive input amounts, all unretired assets' readable backing, and valid prices for every funded or deposited asset. Closed but unretired funded assets still require valid prices. Retired assets contribute zero NAV, so **deposits are unavailable while any retired asset has nonzero managed backing** (`RetiredBacking`). This prevents new shares from acquiring redeemable backing excluded from their purchase price. Retired assets with zero managed backing are skipped, including their feed, balance and debt checks. Freshness counts unretired listed assets with successful positive feed reads within both the maximum age and `freshHours`.

Every pull must increase the vault's token balance by exactly the requested amount. NAV is computed from managed amounts before the pulls. First-deposit gross shares equal deposited USD value; later gross shares are `floor(value * totalSupply / NAV)`, requiring nonzero NAV. When enabled, the deposit fee is `ceil(gross / 200)` newly minted to the recipient. On the first deposit, 1e15 of the remaining shares is permanently sent to `address(0xdEaD)`, exactly as specified. The receiver gets the remainder, which must be positive and satisfy `minSharesOut`. A zero receiver or the vault itself is rejected. Successful deposits clear unretired deficit records.

`redeem(shares, receiver, minAmountsOut, deadline)` needs positive owned shares and a receiver that is neither zero nor the vault itself. It never reads prices or checks deposit pauses, hours, openness or retirement. The fee, if enabled, transfers `ceil(shares / 200)` existing shares to the recipient; only the net shares burn. Each leg uses total supply **before** burning and `min(managed, max(balance - totalOwed, 0))`. An unreadable balance uses managed as the available amount. Managed is reduced only by the resulting leg, not by any other observed shortfall.

If the number of positive-managed assets is at most `directLimit`, every nonzero leg attempts payment through the vault-only external `pay` function with `payGas`. A failed token call, wrong return value, excessive gas consumption, unreadable balance, or incorrect vault balance decrease rolls back that whole payment subcall and creates debt instead. Above the direct limit, all legs become debt. Balances used to determine legs have `balanceGas` limits and copy at most 32 output bytes. Payment subcalls copy no revert data. A bitmap tracks positive managed balances so zero-managed entries cannot exhaust the gas margin.

`minAmountsOut` uses the **current `assets` order**, includes retired entries, and checks the leg whether paid directly or owed. Missing entries are zero; extra entries must be zero or the call reverts `Slippage`. Removal swaps the final asset into the removed position. A nonzero minimum at that former trailing index therefore cannot silently disappear when the registry shrinks. Refresh this order when preparing a redemption. Minimums remain positional, not bound to token addresses: removal followed by an owner-executed listing can reuse an index, so a previously read order is not an execution-time identity guarantee. As with any transaction, the caller must supply sufficient gas; user-selected minimums and expired deadlines can intentionally revert redemption.

`claim(tokens, to)` pays `min(caller's owed, current vault balance)` to a nonzero address. It uses the same exact-decrease payment function, with no configured gas cap on either balance reads or the payment. This keeps low `balanceGas` or `payGas` settings from preventing recovery. Failed claims revert their selected batch and preserve debts; claim working tokens separately while another token is blocked. Claims have no share fee and ignore all vault deposit restrictions. Underlying tokens can still refuse or confiscate transfers; the vault cannot compel them to pay. Claims can consume remaining backing in a deficit, exactly as specified.

`Redeem` logs the share amount, net burn and fee. Return values give the legs in registry order. A successful direct leg also emits `Payment`; other nonzero legs become debt visible through `owed` and `totalOwed`. `Claimed` identifies subsequent debt payments. All public state-changing entry points are guarded against reentrancy; `pay` is callable only by the vault from inside a guarded operation.

## Price checks

A primary feed must return a positive answer, no future timestamp, and an age at most `maxAge`. Its answer must be within `[floor(centre / band), centre * band]`. If the token had a boolean `oraclePaused()` interface at listing, a later call must succeed and return false.

For configured pools, the vault uses v3's arithmetic mean tick (rounding negative values toward negative infinity) and harmonic mean liquidity across `poolWindow`. Accumulator wrap semantics match v3. A successful observation with sufficient liquidity requires a positive, fresh quote-feed answer and a USD price within `poolDeviation` of the primary USD feed. A bad quote feed or divergent sufficient-liquidity pool does **not** fall back to age-only validation. Failed/malformed observations, low liquidity or no pool instead require age at most `noPoolAge` as well as `maxAge`. Tick quotes carry 18 extra decimal places before quote-USD conversion to handle mixed token decimals.

## Proposals and roles

Use `propose(ProposalData)`; the owner alone may execute from `readyAt = proposedAt + 2 days` through `readyAt + 7 days`, inclusive. After that it expires. Validation runs again at execution. Owner or guardian may cancel a live proposal, except the guardian cannot cancel its own replacement.

| Action | Relevant `ProposalData` fields |
|---|---|
| `List` | `token`, `target` = feed, `pool`, `quoteFeed`, `value` = minimum liquidity |
| `Feed` | `token`, `target` = new feed; centre becomes execution-time answer |
| `Recentre` | `token`; centre becomes current feed's execution-time answer |
| `Reopen` | `token`; any later close permanently voids the proposal |
| `Retire` | `token`, closed at proposal and execution |
| `Pool` | `token`, `pool`, `quoteFeed`, `value` = minimum liquidity; all three zero removes the pool |
| `Resync` | `token` |
| `Guardian` | `target` = replacement guardian, nonzero and different from both owner and pending owner at proposal and execution |
| `RaiseCap` | `value` = new USD NAV cap, above the current cap and at most 10,000,000,000e18 |
| `FeeRecipient` | `target` = actual recipient |
| `SettingChange` | `setting` = enum key, `value` = new value |

Irrelevant struct fields are ignored. `action`/`setting` are Solidity enums in source order, starting at zero. `List` is available through proposals during genesis too. Unretired assets cannot share their primary feed; retired feeds may be reused. Retiring an asset permanently closes it and voids all its pending proposals. Anyone may `removeAsset` only after retirement and both managed and total owed are zero; the token may then be listed anew. Removal/relisting cannot revive stale proposals.

Retirement of a funded asset stops new deposits even after all circulating shares redeem: the required permanent 1e15 shares and round-down redemptions leave positive backing. That residual cannot be swept, discarded or removed from accounting. Removal remains possible for never-funded assets and assets whose actual losses were fully recognized, once their debts are also zero. Retiring a funded asset is therefore not a way to resume deposits after a feed failure; a timed `Feed` replacement is available before retirement. Retirement never blocks redemption or claims. Donations and `Resync` of another asset cannot bypass `RetiredBacking`.

Owner-only immediate actions: genesis operations, `transferOwnership(next)` (accepted by `acceptOwnership()`), unpausing deposits, and `lowerNAVCap(cap)`. Transfer cannot target the guardian, including at acceptance. There is no ownership renunciation. Owner and guardian can immediately pause deposits and close individual assets. Every lowering of the NAV cap voids pending raises; lowering below current NAV is permitted and only restricts deposits.

No role can upgrade, sweep, rescue, change fees, mint outside deposit, freeze BASK transfers, or add a restriction to redeem/claim. The only asset movements are exact deposit pulls and payments to the receiver/claim destination selected by the share holder or creditor.

## Settings

`settings()` returns the following 16 values in order. `setting(Setting)` reads one.

| Enum / index | Initial value | Bounds / units |
|---|---:|---|
| Band / 0 | 4 | 2–100, integer multiplier |
| MaxAge / 1 | 288000 | 1 hour–30 days, seconds |
| NoPoolAge / 2 | 93600 | 1 hour–30 days, seconds |
| FreshCount / 3 | 0 | 0–10 |
| FreshHours / 4 | 4 | 1–48, hours |
| HoursFrom / 5 | 0 | Seconds of UTC day, 0–86399 |
| HoursTo / 6 | 0 | Seconds of UTC day, 0–86400 |
| PoolWindow / 7 | 1800 | 300–86400 seconds |
| PoolDeviation / 8 | 300 | 50–2000 bps |
| FeedGas / 9 | 100000 | 20000–500000 |
| PauseGas / 10 | 100000 | 20000–500000 |
| PoolGas / 11 | 150000 | 20000–500000 |
| BalanceGas / 12 | 50000 | 20000–500000 |
| PayGas / 13 | 250000 | 20000–500000 |
| MaxAssets / 14 | 250 | At least current asset count; coupled gas bound below |
| DirectLimit / 15 | 25 | Coupled gas bound below; zero always defers |

Hours `0–0` means always open, including weekends. Otherwise the interval is Monday–Friday, inclusive `from`, exclusive `to`, with `from < to`. Configure `HoursTo` before raising `HoursFrom`; reset `HoursFrom` to zero before resetting `HoursTo` to zero. There are no holidays or overnight intervals.

Every setting proposal and execution must preserve:

```
maxAssets * (balanceGas + 60000) <= 28000000
directLimit * (balanceGas + payGas + 60000) <= 28000000
maxAssets >= current asset count
```

Consequently the largest configurable registry is 350 assets at the minimum balance gas. Settings may make deposits unavailable (for example, too few fresh feeds); they are absent from withdrawal eligibility.

## Losses and views

`flagDeficit(token)` records a positive shortfall only when larger than the previously recorded amount, restarting its clock. It requires a readable balance. `recognizeLoss(token)` is permissionless at least seven days later, writes off `min(recorded, current shortfall)`, and clears the record, even if recovery made the actual loss zero. Neither redemption nor an oracle failure automatically writes off managed balances. Loss functions also work on retired assets.

If all priced backing is lost, nonzero share supply still makes deposits revert `ZeroNAV`, including when only the permanent shares remain. There is no share reset or automatic recapitalization. An actual donation to an unretired asset followed by a timed `Resync` can restore positive NAV; it benefits the existing supply and does not bypass any other deposit check.

Views include `allAssets()` (configuration, answer/time, band, pool USD price, open/retired flags, managed, short/unreadable flags, total owed and price status), individual `asset`, `assetPrice`, balances/debts, settings, `previewDeposit`, `previewRedeem`, `depositStatus`, `proposal` and paginated `pendingProposals(start, count)`. The latter scans consecutive IDs starting at 1 and returns only waiting/ready proposals; it does not scan the entire history implicitly.

`previewDeposit` enforces deposit pricing/state/input/cap checks and returns `(receiverShares, fee, value, beforeNAV)`; it does not simulate token pulls or receiver/deadline arguments. `previewRedeem` returns current legs and the share fee, without testing transfers. `depositStatus(tokens)` reports checks that do not require amounts, a receiver or a deadline; it cannot report slippage, amount-dependent cap failures, or future transfer failures.

Reason codes, in order: `0 OK`, `1 Genesis`, `2 Paused`, `3 Hours`, `4 Unlisted`, `5 Closed`, `6 Duplicate`, `7 Unreadable`, `8 Deficit`, `9 Feed`, `10 Band`, `11 OraclePaused`, `12 QuoteFeed`, `13 PoolDeviation`, `14 NoPoolAge`, `15 Freshness`, `16 RetiredBacking`. The accompanying fault address is the affected asset, or zero for a global reason. `Feed` includes failed/malformed, nonpositive, future and stale readings. Asset views return raw feed answers even when invalid where readable.

## Accepted assumptions and review

The owner must pair each asset with its true feed and pool. Feed-lag profit within pool deviation is accepted. There is no per-asset concentration limit. Manipulating a thin pool may stop deposits. The protocol adds no sequencer feed, holiday service, swap, rebalance, price circuit breaker, emergency withdrawal role or fee control beyond the requested checks.

External Stock Tokens can pause, block accounts, change implementation or confiscate balances. Debts preserve accounting when payment fails; they are not a guarantee of later recoverability. Extremely large or dishonest oracle values can make deposit arithmetic/views revert; redemption and claims read no oracle. The immutable share and vault cannot repair a broken underlying token.

Tests exercise success and failure paths, decimal and conservation fuzzing, proposal replay/invalidation, exact time boundaries, pool direction and decimal conversion, loss delays, callback reentrancy and hostile token behavior. The gas tests use cold account/storage state, exhaust balance/payment stipends, configure the allowed gas extremes, and count intrinsic calldata gas. Their setup gas includes deploying hundreds of independent mocks; only the explicitly measured redemption is compared with 28,000,000. See `REVIEW.md` for measured results and review limits. Independent review by another contributor is an operational responsibility before release; local testing is not an independent audit.
