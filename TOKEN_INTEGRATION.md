# $SWPL token integration

Swapline **deploys no token**. $SWPL launches separately on a launchpad. Until its address is wired in, every token
feature is disabled and the protocol works in full without it.

## What the token unlocks
All token logic lives in one contract, `ProjectTokenHooks`:

1. **Fee sharing.** `FeeCollector.distribute()` (permissionless) splits protocol fees as follows:
   - 20% to the insurance fund
   - 50% to stakers, paid in USDG and claimed with `claim()`
   - the rest to the treasury
   
   Before the token is set, or while nobody is staking, the staker share goes to the treasury.
2. **Advisory governance.** Stakers holding at least `proposalThreshold` can `propose(kind, payloadHash, description)`
   new rate sources or maturities, and every staker can `vote`. A proposal `passed()` when it reaches a 10% quorum of
   the stake at its start and has more votes for than against.
   
   Results are **advisory**: execution is a separate Timelock proposal (e.g. `MarketFactory.createMarket`). That
   proposal's calldata hash should match the vote's `payloadHash`.
3. **Staking rules.** `stake` / `requestUnstake` (7-day cooldown) / `withdraw`. Staking is fee-on-transfer safe.
   Because the cooldown (7d) is longer than the voting period (5d), tokens used in a vote cannot move to another
   address and vote again before that vote closes.

## Wiring the token (one time, through the 48h Timelock)
`ProjectTokenHooks.setProjectToken(address)`:
- can only be called by `DEFAULT_ADMIN_ROLE`, which is held by the Timelock;
- can be called **once** (`TokenAlreadySet` afterwards);
- rejects the zero address, EOAs and the reward token.

The exact `schedule` and `execute` commands are in DEPLOY.md §5.

## Frontend
- `NEXT_PUBLIC_PROJECT_TOKEN` empty: staking and voting UI hidden.
- `NEXT_PUBLIC_PROJECT_TOKEN` set to the token address: UI shown.

Set it only after the Timelock operation has executed.

## Testing
Unit tests use a mock ERC-20 (`test/utils/Mocks.sol`, `MockERC20`) that exists only in tests. The behaviour tested in
`test/unit/TokenAndFees.t.sol`:
- token unset: everything reverts with `TokenNotSet` and fees go to insurance and treasury;
- setter rules: one-shot and Timelock-only;
- staking: pro-rata fee sharing and cooldowns;
- advisory voting: double-vote resistance and quorum.
