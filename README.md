# Marginalia — notes in the margin of every trade

**What it is:** a bonded feed. Anyone who buys MARG can attach a note: a falsifiable call on any token (up or
down, by how much, by when), or a long-form thesis. The author puts an IMD bond behind it, the chain settles
whether it was right, and the record follows the wallet. **Not a perp DEX, not a prediction market.** There is
no leverage, no counterparty and no payout for being right: a right call only gets its own bond back, a wrong
one forfeits it to the writers' pools. The only money that moves is the author's own. Key holders read an
author's sealed notes before the crowd does; nobody trades against anyone.

This contracts-only launch deploys **MarginaliaPages only** on Ethereum mainnet, using the existing launch-1283 hook. The token, hook, pool and companion implementations are already live. The hook clones the live launch-1240 Router, Judge and Treasury and calls the live Pricer; none of those implementations is redeployed. Buying MARG through the
router with a note attached posts a falsifiable call on an ERC-20 other than IMD itself, backed by a flat 0.1 IMD stamp and an
IMD bond the author sizes between 0.25 and 10 IMD (every note also buys 0.25 IMD of MARG). Calls resolve against a manipulation-resistant settlement price built from permissionless
on-chain observations (v3/v2 TWAPs, the adverse extreme on v4); right calls get their deposit back,
everything else feeds the weekly pools, including thesis prizes ranked by the IMD oracle panel.
No owner, no pause, no upgrade. Spec: `SPEC.md`.

## Contracts

| Contract | Role |
|---|---|
| `Marginalia` | The launch ERC-20: 1,000,000,000 × 1e18 minted once to its deployer (the launch factory). |
| `MarginaliaHook` | The hook (flags `0x20cc`): binds the launch pool, takes the stamp and the IMD bond on noted buys and the 1%/3% fee on sells, holds notes, observations, records and the three pools, and pays out. Its constructor clones the three companions (EIP-1167) from the live launch-1240 implementations and initialises each once. Notes can be counters: a thesis may rebut another author's open thesis, a call may take the other side of another author's open call on the same token (`parentId` pointing at that note). |
| `MarginaliaRouter` | The only path that can attach a note; optionally trades X on Uniswap v4, v3 or v2 in the same transaction so the position is proven, and refuses a note about a token other than the one traded. Plain MARG buys and sells go through any v4 router. |
| `MarginaliaJudge` | The oracle consumer: once a week buys the panel's ranking of the week's long-form theses through the IMD Intake, verifies the EIP-712 attestation, tells the hook whom to pay. Short-form calls are never judged. |
| `MarginaliaTreasury` | Receives prizes and gifts in IMD; drips 2% of its IMD into the pools daily. No withdraw; refuses ETH. |
| `MarginaliaPages` | The page market (this launch): pages of an author on a linear IMD curve (0.1 IMD × n, no cap, never transferable); 10% fee per trade, 90% of it to the issuer, 5% is reserved for permissionless MARG burns whose price impact is bounded on chain per block, 5% to the pools; pages of an unclaimed X handle escrow the issuer share until the owner claims it through the IdentityMD oracle: they tweet the exact claim statement naming this market, chain and wallet, anyone pays the Intake's price to verify it (X's public embed JSON, no login), and the signed answer sets the payee, the price reimbursed from the escrow. No attester, no server of ours. Unclaimed escrow recycles into the pools after 90 days. Page holders get sealed notes first. |
| `MarginaliaPricer` | Stateless, ownerless helper the hook calls by staticcall (kept out of the hook for code size): score arithmetic (log2, sqrt, difficulty), price reads and the settlement rule: a prior-window baseline (v3/v2 accumulator TWAP, conservative v4/hub extreme); observation reads (v3 tick cumulative, v2 price cumulative, v4 spot, the ETH→IMD hub spot); settle price = TWAP first→last on v3/v2, the observation least favourable to the call on v4 and on the hub leg. An honest observation pins the extreme; the series must span at least one hour. |

## Deployed (Ethereum mainnet, 2026-10-11)

IMD launch **#1283** (`univ4_hook`, job `9060a248-29ce-4683-b5d1-54fbc83cd49d`, deploy tx
`0x6ba7149c648529bdc043dae985611f827fbbe18e47b5dfd9add56a5e17a74e48`, block 26169583). All six audits,
the adapt step, the manifest and the Foundry tests were accepted; nothing parked.

| Contract | Address |
|---|---|
| `Marginalia` (MARG, 1,000,000,000 fixed) | `0xfa0efea559bde229031c2b0a219472316647759c` |
| `MarginaliaHook` (flags `0x20cc`, 23,916 B runtime) | `0xf0457dd0cf526686190e4f057ba19db14d34a0cc` |
| `MerkleDistributor` (swarm share) | `0x2d637b51f531fc408a079170832e91349c1eae18` |
| Router / Judge / Treasury / Pricer (launch #1240) | see `src/MarginaliaImpls.sol` |

Pool: MARG / IMD (`0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`), fee 12500, tick spacing 60, on the canonical
v4 PoolManager. Launch record: `https://explorer.imd.fun/launches/01771823-5250-4aaa-a55e-da5c1afe1146`.

## How the pot pays

Every IMD accrual (stamps, sell fees, forfeits, treasury drips) splits at accrual time:

| Share | Pool | Paid to |
|---|---|---|
| 70% | the week's thesis prize | the panel's top three long-form theses, 50/30/20, after the week and its seven-day child grace, through `requestJudging(week)` and `payJudged(week)` |
| 30% | the day's writer refund | every non-retracted note of the day, equal split, capped at one stamp; `claimRefund(id)` after the day ends |

The score (difficulty-weighted, netted across right, wrong, broken, unproven and retracted calls, on every venue)
is reputation: no pool pays for it. That is deliberate. On any canonical pool an author can be the only LP and
trader and manufacture a right call for a stamp; a pool that paid by score would pay them (review finding
c7331916). With no such pool the number can be inflated but never cashed, and the venue is on every note for the
reader and the site to judge. A paid leaderboard, if one is ever run, is a campaign funded from the paying wallet's
retained MARG with published rules, outside the hook.

Unclaimed pools roll forward after 28 days (`sweep`). No pool pays for a price outcome or reputation score.
A week admits at most 120 theses and at most three per author (the size of the ranked head), including rebuttals.
A child call must arrive by its parent's seven-day deadline, even if nobody has settled the parent yet.
Judging can first draw its fee at `(week + 1) * 7 days + 7 days`, so every thesis gets its full grace.
The per-author cap limits one wallet's occupancy; it is not Sybil resistance.

## Deployment order

1. ✅ Contracts-only launch **#1240** (Ethereum mainnet, tx `0x93a1b0cce64e04d4bd7edd7b5fb6e6268b1fd5ab68fb5b990e66c56e972d71a3`,
   block 26163341): `MarginaliaRouter` `0x365CcB3cfBC430600485234F56FD5ECb23fd70D1`, `MarginaliaJudge`
   `0xC93460730a79a22282f063A0c6BA5E340Ac372b4`, `MarginaliaTreasury` `0xe2086012f5F9CC7cAECDBC70dE392e263aAe8481`
   (ownerless implementations that lock themselves in their constructors so only clones can be initialised, once,
   by the hook) plus the stateless `MarginaliaPricer` `0xEaff9B262341A0cB05579227e662BFE768A71cfb`. The on-chain
   runtime bytecode matches this tree's build (the judge differs only in its EIP-712 immutables).
2. ✅ The four addresses are pinned in `src/MarginaliaImpls.sol`.
3. ✅ Hook launch **#1283** (historical `univ4_hook` launch): the factory deploys the token and the hook; the hook's constructor
   clones the three implementations and initialises each with itself in the same transaction. The constructor is
   chain-state-free (the launcher rehearses constructors in an empty EVM): it reads no code at any address, and a
   codeless companion would revert on first use because every companion call expects return data.

Because the router is deployed, the `NoteParams` ABI it accepts is fixed; that is why a counter rides the existing
`parentId` field instead of a new one. `forge build --sizes` is the gate for the hook's runtime (EIP-170, 24,576) and
initcode (EIP-3860, 49,152) sizes; the mainnet-fork rehearsal (`test/fork`) runs against the live implementations
without etching.

## Build and test

Solidity 0.8.26, Cancun, via-IR, optimizer 200 runs, `bytecode_hash = "none"`. All dependencies are
vendored under `lib/` (versions in `dependencies.json`); no network is needed to build or run the unit tests.

```sh
forge build --sizes
forge test --no-match-path 'test/fork/*'
```

Without `MAINNET_RPC_URL`, the fork tests explicitly skip, including under plain `forge test`.
The fork rehearsal deploys through the real IMD LaunchFactory on an Ethereum mainnet fork, impersonating
the protocol's launch wallet, and then posts a note through the router:

```sh
MAINNET_RPC_URL=https://... forge test --match-path test/fork/MainnetLaunch.t.sol -vvv
```

## Launch

Deploy only `src/MarginaliaPages.sol:MarginaliaPages`, with the four constructor arguments below, in order.
The constructor makes no external calls and assigns no owner. The next launch step writes `launch.json`;
the old hook-launch manifest has been removed. See `ADAPTATION.md` for findings and validation.

| Argument | Value |
|---|---|
| hook | `0xf0457dd0cf526686190e4f057ba19db14d34a0cc` |
| intake | `0x1397434cd35e8a9C8aC312A61D3A285EB31dea56` |
| action | `0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000` |
| signer | `0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982` |

An X handle owner must publish exactly this text, replacing both bracketed values with the actual addresses
and using the market address in lowercase (no brackets in the tweet):

```text
I claim Marginalia pages on chain 1 at <deployed Pages address> for wallet <owner wallet>.
```

The final period is part of the statement. `questionBody(normalizedHandle, tweetId)` gives the full
verification rule for the deployed market. Ordinary token-address tweets, claims for another market/chain,
and extra text are refused by that rule. Anyone may call `requestClaim`; only the authenticated oracle
answer delivered by the Intake sets the permanent payee. The paid request has a three-day abandonment
path. The Intake routes answers; the oracle UUID is distinct from the Intake request id, and the relative
question window prevents precomputing `questionHash`.

Every page trade still allocates 90% of its 10% fee to the issuer (or escrow), 5% to `pendingBurn`, and
5% immediately through `hook.fundPot` (70% thesis / 30% refund). Anyone executes `burnPending(imdIn)`
for any tranche no larger than the accumulated burn balance; it returns what was spent and burned. The
floor is the chain's, not the caller's: within one block the burns may move the pool's sqrt price by at
most `BURN_SQRT_BPS` (0.5%, about 1% in price) from the price the block's first burn found (`burnLimit()`
shows the limit). A tranche that reaches the bound fills partially and the rest stays pending for a later
block; a block whose budget is spent refuses with `BurnBudgetSpent`, and a tranche the pool's fee rounds
to nothing with `NothingBurned`. A sandwich of the burn therefore gains at most ~1% on the attacker's
position while the round trip pays the pool's 1.25% LP fee twice plus the hook's 3% quiet-sell fee, so
the burn budget cannot be turned into an attacker's profit, and a burn cannot be used as a free lever on
MARG's spot price. At the live pool's depth one block absorbs roughly 30 IMD of burn, so a large budget
drains over a few minutes of blocks; the total MARG burned equals what one unbounded swap would have
bought. The quiet buy pays the pool's LP fee, no hook fee, and sends all MARG directly to the fixed dead
address. Failed swaps and missing liquidity leave the tranche available for retry and cannot block
buying or selling pages. Curve reserves and handle escrow cannot fund burns. The supply getter returns
`uint256`.

The claim callback only verifies and stores (the Intake attempts it once, with a 200,000-gas stipend):
it records the payee and the asker's reimbursement, and anyone then calls `settleClaim(subject)` to pay
the escrow to the payee less the oracle price to the asker. Trades in between pay the payee directly;
the escrow is frozen until settled. An issuer share landing in escrow after the 90-day window has
already elapsed opens a new window, so a fresh accrual is never recyclable the moment it lands; inside a
window the first buy's clock stands. This market and the hook are refused as address subjects.

Trust assumption: the Intake, action and oracle signer are immutable, as the brief orders (no owner).
If the oracle signer key rotates, the action's price leaves (0, 1 IMD], or Intake v1 stops answering,
handle claims stop working (deliveries fail or are abandoned after 3 days, the asker's price lost) and
unclaimed handle escrow recycles to the hook's pools after 90 days instead of reaching the authors.
Address subjects, page holders and curve exits are unaffected. The signer may be an ERC-1271 contract
the oracle operator rotates behind, which the attestation check already supports.

The focused suite is `forge test --match-path 'test/Pages*.t.sol'`. An optional integration rehearsal is
`MAINNET_RPC_URL=http://127.0.0.1:36699/rpc/1 forge test --match-path test/fork/PagesMainnet.t.sol` on the
contributor machine. It deploys only on a local fork and spends no live funds. Offline runs skip it.

Sealed notes: `seal(x, venue, hash)` commits to a note before it is posted. The seal pays one stamp up front
(non-refundable, so a seal is never a free option), prices the venue's BUY and SELL baselines at that moment, and
snapshots the author's X balance. The note is then posted through the router as usual, no sooner than 30 minutes
and no later than 6 hours after the seal (`SEAL_MIN`, `SEAL_MAX`); it settles against the sealed baseline, and a
sealed BUY call is refused if the author's X balance fell since the seal (position first, then seal). Between seal
and reveal, the author's key holders may read what was sealed off-chain; everyone else sees only the `Sealed`
event (author, X, venue). The hash is `sealHash(author, params)` over the router-derived venue, which is what the
hook receives (`router.validateVenue` gives it). A seal is stored per sealer, at `seals(sealKey(sealer, hash))`, and
records the X and venue it priced: a reveal uses only the author's own seal of the note's own X and venue, so nobody
else's seal can delay or price a note. A seal that lapses leaves its stamp in the pools and may be replaced by a fresh
seal of the same note; posting the note spends the seal, timely or lapsed.

Counters and duels: a thesis whose `parentId` is another author's open thesis is a rebuttal; it needs its own child
call like any thesis and then competes in the same weekly judged set. A call whose `parentId` is another author's
open call on the same token, from the opposite side, is a counter-call. No deposit moves between the two: each
settles on its own price and keeps or forfeits its own deposit, their scores move in opposite directions, and the
duel's outcome is the pair of `Settled` events (the link is in `NotePosted.parentId`), read off-chain. The keeper who
settles a wrong or broken call earns 10% of the forfeited deposit (`KEEPER_BPS`).

Before posting a price call, anyone calls `router.checkpointVenue(noteParams, venueKey)` for its
canonical venue. V3/v2 references must be the pool address zero-padded to 32 bytes; the hook refuses
high-byte aliases on both posts and seals. Its first checkpoint must be at least one hour old, from an earlier block, and at
most six hours old. Further checkpoints preserve the start and accumulate conservative extremes;
they cannot erase an honest reading. After expiry, checkpoint again and allow a new hour to elapse.
Theses (`targetBps == 0`) do not need price history. This warm-up uses on-chain timestamps; tests
advance the EVM clock and never wait in real time.

For v3/v2, the post baseline is the accumulator TWAP from the checkpoint to posting. For v4 and
the ETH/IMD hub leg, a BUY baseline uses the maximum of the window's readings and the current
price, and SELL uses the minimum. The immutable router/pricer store independent component extrema, so
a multi-leg baseline is a conservative bound and need not be a price observed at one instant.
At settlement the hook prices each complete v4 observation through the live pricer and takes the minimum
product for BUY or maximum product for SELL; it never combines legs from different observations.
V3/v2 still use the first-to-last accumulator TWAP multiplied by the adverse hub observation.
The one-hour minimum span is unchanged. Calls and checkpoint reads reject a v4 venue or hub with no active liquidity.

The oracle callback stores only the requested head of three ids, then filters and deduplicates them
when paid. A signed empty or entirely ineligible head pays no winners and rolls the whole remaining
thesis pool forward. Extra ranking entries beyond the requested head are ignored.

## Audit history

The swarm's four-specialist panel reviewed the whole repository during the first implementations launch
(job `0c08497a`, 2026-10-10) and merged 14 reproduced findings, led by a self-priced venue (any contract
answering `slot0()` could set a note's price) and a leaderboard sweep that paid twice. All are fixed in
commit `1e6388a`: every price venue and trade venue is now checked against the canonical Uniswap factories
(v3/v2) or recomputed from the full key with liquidity (v4) in the router, sweeps zero their pools, an
unanswered judging request can be retried after three days, quiet weeks' thesis pools sweep once the judge
confirms nothing is pending, implementations lock themselves against stray `init` calls, sells of pot MARG
require a whole fill with a slippage floor, and the Attested class can no longer be self-declared.

The relaunch of those fixes (launch 1217) was then parked by the audit judge on the one finding the first
round had not closed: `observe()` read spot, so a two-block pump → observe → unwind bought a settlement
for swap fees. v0.5 moved settlement into `MarginaliaPricer`: Uniswap v3 and v2 venues settle on the
time-weighted average between the first and last observation (their on-chain accumulators), v4 venues
and the ETH→IMD hub leg settle on the observation least favourable to the call, and the observations
must span at least an hour. Accumulator prices weight the elapsed time, and an honest observer can
pin the v4/hub extreme; sampled extremes do not measure prices between observations. Tests: `testTwoBlockPumpObserveUnwindSettlesWrong` (local),
`testTradeAndNoteOnUniswapV3` settles LINK on the live v3 accumulator (fork), `test/Pricer.t.sol`.

The second implementations review (2026-10-11) reopened the launch on eight reproduced findings; all are
answered in `.imd-responses.json` and listed in `ADAPTATION.md`. In short: a price that rounds to zero is
refused everywhere; forfeited MARG converts in tranches (`convertForfeits` sells the largest halving of the
pot the pool absorbs); a stranger's dust cannot void a SELL call (a tolerance rule, since replaced by no SELL
hold rule at all: see the third review below); an observation slot is never owned (a more adverse reading replaces the
latest entry; a favourable pump can be overwritten, while an adverse hostile reading remains); a note token whose `balanceOf` fails is "not
held" (VoidSold, never a refundable void); an unobserved call scores as wrong though its deposit returns;
a week holds at most 120 theses and refuses the 121st before taking anything; `abandonRequest` invalidates
an unanswered judging request after its deadline so a thesis pool is never swept from under a deliverable
answer; and an attestation must be about this chain. Two findings are disputed as design: any canonical
Uniswap pool is a venue (an author can be its only participant: see the limits below), and the adverse
extreme can be moved against a call by a paid round trip, which is the cost of the rule the launch asks for.

The third review (2026-10-10) reopened the launch on the self-priced venue, now reproduced as a loss path
(a wallet that is the only LP and trader of a hookless X/IMD pool settled a 100x call RIGHT at tier 3 and took
the capped 10% of the week's leaderboard pool for one stamp), and on the residual of the SELL hold rule (a
stranger's gift of the deposit's worth of X still voided a correct SELL call). Both are fixed: only a call
priced on the launch pool books a score (a call on any other venue still returns or forfeits its own deposit
and takes the writer refund, but books nothing and draws nothing from the leaderboard), and SELL calls have no
hold rule at all (any balance-growth rule is a stranger's transfer away from voiding a correct call; the BUY
hold rule is unchanged). The advisory `sqrt(2) == 2` is also fixed. See `ADAPTATION.md` and `.imd-responses.json`.

## v1 scope and known limits

- Price reads assume 18-decimal assets on both sides. Quotes other than IMD, ETH or WETH are refused.
  Calls and seals on IMD itself are refused: every price is denominated in IMD, so an IMD/IMD target is
  not falsifiable. Theses about IMD remain possible because they have no price target.
- v4 venues have no on-chain accumulator, so their baseline and settlement rely on sampled extremes rather than a TWAP. These require honest permissionless observations; time spacing alone cannot prove an unobserved price was held continuously. A
  single hostile observation can push a genuine call to WRONG by moving the pool against it, observing,
  and unwinding in one transaction. Later favourable readings do not remove it. On a thin pool, the
  swap cost may be below the keeper bounty. Replacements retain the slot's opening block, so they cannot
  continually postpone another observer's next slot; timestamps still record the actual reading time.
- Sells of MARG pay 3% through any router, or 1% plus the stamp through `sellWithNote` with a note and deposit attached.
  These are swap fees: single-sided liquidity that converts MARG into IMD as others buy is untaxed by
  the hook. Flags `0x20cc` deliberately have no liquidity callbacks. Third-party routers must send empty
  `hookData`; non-empty data is reserved for the Marginalia router's authenticated note format.
- Bonds are IMD, held as ERC-6909 claims: a noted buy sends `imdIn`, of which 0.1 is the stamp, 0.25 buys MARG and the
  rest (0.25 to 10 IMD) is the bond; a noted sell bonds the minimum off its IMD output. A right bond comes back as
  exactly that IMD; forfeits accrue to the pools at once (10% to the settling keeper). The hook never holds MARG
  claims and there is no pot sale: the deployed judge's `convertForfeits` finds `potMarg() == 0` and returns.
- The X trade leg supports v4 pools (including native-ETH pairs), v3 pools and v2 pairs; exact-input only.
- Quiet (un-noted) MARG sells are exact-input only: an exact-output sell through any router reverts
  (`NoteNeedsExactInput`). Exact-output buys are unaffected.
- `noteOf` returns a slim `NoteView`; the venue, text and timestamps are in the `NotePosted` event, which carries
  the ids, class, side, target, horizon, parent and text (price and deposit are read from `noteOf`).
- The implementation addresses in `MarginaliaImpls.sol` are the live launch-1240 deployments; the local tests etch
  rehearsal code at those same addresses, the fork tests use the live code.
- The action fee on follow trades, treasury conversion of ETH/USDC/USDT to IMD, the on-chain ERC-8004 agent
  badge (contract wallets are marked Agent), and attestation re-delivery are specified but not yet built.
- The judge binds an answer to the Intake request it paid for and to this chain id. The oracle's canonical
  question hash includes the resolved relative block window and is not `keccak256(questionBody(week))`;
  the immutable judge relies on the Intake to route the signed answer under the request it was bought for.
- Observations pay no reward. Only settling a forfeited bond earns 10%; absent sufficient observations,
  `VoidNoData` returns the bond and scores it as wrong. Mainnet gas can exceed that bounty.
- Refund eligibility is checked when claimed after the posting day. Retraction forfeits the entire bond
  and prevents a future refund claim, but does not claw back a refund already paid. Waiting until a
  90-day horizon to allow refunds would conflict with the daily refund and 28-day sweep schedule.
- Venue admission is "any canonical Uniswap pool with liquidity", and an author can be the only LP and trader
  of such a pool. A call priced there is a bonded claim that returns or forfeits the author's own deposit on
  price and moves a reputation score that no pool pays for. The site labels venues where the author is the
  dominant liquidity; the contract cannot see that and does not pretend to.
- SELL calls have no hold rule: they settle on price alone. BUY calls must keep their post balance.
- The hook's constructor reads no chain state (the launcher rehearses constructors in an empty EVM); the pinned
  implementation addresses are exercised by the mainnet-fork rehearsal instead.
