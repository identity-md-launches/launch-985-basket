# Basket contributor tests

Run `forge build` and `forge test` from the repository root. All external contracts are local mocks; no RPC, environment variables, forks, FFI, new dependencies, or production storage writes are needed. The existing tests remain intact.

`BasketInvariant.t.sol` runs 256 sequences of 64 calls using four actors and three Stock Tokens. Only the handler's 13 selected operations are targeted. Unexpected handler reverts fail the campaign; anticipated failures assert the precise custom error. A deterministic handler test also demonstrates successful deposits, deferred redemption, claims, loss recognition and resync.

The handler tracks independent token flows and checks these identities after every call, including while balances are unreadable or backing is short:

- Physical custody + payouts + confiscations = deposits + donations.
- Managed + total owed + payouts + recognized losses = deposits + resynced donations.
- Total owed = the sum of each actor's debt.
- Total share supply = all actors' balances + the permanent first-deposit lock.

Additional assertions check payment versus deferred-debt conservation, preview agreement, exact claim amounts, allowance transfers and delayed loss recognition. Every completed sequence attempts full redemption by all actors, including the current and former fee recipients. Payout ghosts come from recipients' actual mock balances, independently of the vault's return values.

`BasketEdges.t.sol` adds atomic rollback tests for late deposit, redemption and claim failures; duplicate and unauthorized claims; feed-uniqueness races; retirement execution checks; role restrictions; fee-recipient self-transfers; execution-time resync; and a reentrant redemption whose caller and payload demonstrably succeed outside a callback. Three properties each run 1,000 fuzz cases: repeated round trips, donation isolation and partial-loss recovery.

`RegistryExit.t.sol` exercises removal, loss, resync and relisting across registry indices 255/256. It also removes the code of all 250 funded Stock Tokens and requires a cold redemption within 28 million gas, preserving each claim and allowing payment after code recovery. The existing gas suite additionally attacks gas-exhausting and paused tokens at extreme permitted settings.

`Settings.t.sol` checks both endpoints of all 16 settings, values immediately outside their bounds, and the maximum integer. Accepted changes must respect the timelock, leave unrelated settings unchanged, and reject replay. Both endpoints and 1,000 generated valid settings are followed by redemption with paused Stock Tokens and broken feeds, then claims after token recovery while deposits remain paused. Separate races verify execution-time revalidation when another proposal changes the payment budget, asset count, or trading-hours endpoint; a failed gas-setting proposal can be retried after its constraints are restored.

The sequence campaign uses fixed $1 feeds and 18-decimal Stock Tokens so its conservation properties are unambiguous. Oracle pricing, pool observations, other decimal combinations, larger registries and retirement are exercised separately by the existing and added unit/fuzz tests. This offline suite does not verify real Stock Token/feed/pool pairings on Robinhood Chain or claim exhaustive coverage of arbitrary upgraded code.
