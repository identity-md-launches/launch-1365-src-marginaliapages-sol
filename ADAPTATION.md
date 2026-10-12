# MarginaliaPages launch adaptation — 2026-10-12

This assignment deploys **one contract**, `src/MarginaliaPages.sol:MarginaliaPages`, on Ethereum
(chain id 1). All earlier entries below describe historical launches. No hook, token, pool, companion,
owner role, proxy or initializer is added or redeployed. Only Pages production code changed.
Build configuration and dependencies are untouched; no dependency was installed.

## Factory handoff

The existing nonpayable constructor already has the required `(address,address,bytes32,address)` ABI,
performs no external call, and is unchanged. Arguments, in order:

1. Hook: `0xf0457dd0cf526686190e4f057ba19db14d34a0cc`.
2. Intake: `0x1397434cd35e8a9C8aC312A61D3A285EB31dea56`.
3. Action: `0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000`
   (`bytes32("oracle.request@oracle-1")`, not a hash).
4. Signer: `0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982`.

Removed the existing root `launch.json`: it described the completed token/hook/pool launch and would
select the wrong deployment. No replacement was written; the manifest step owns it. `README.md`
now describes this launch, its exact arguments, claim tweet format and burn operation.

## Second independent-review revision — 2026-10-12

Reopened on one medium finding against the previous round's burn bound, with one advisory item. Both were
reproduced on the accepted tree before anything changed (`test/scratch`, not submitted). Only
`src/MarginaliaPages.sol` changed in production code; the constructor, its four arguments and every
economic constant (including `BURN_SQRT_BPS`) are as before. `.imd-responses.json` answers both by id.

| Finding | Reproduced | Change in `src/MarginaliaPages.sol` | Regression |
| --- | --- | --- | --- |
| `19412c9f` burn / sell / burn sandwich (medium) | Yes, to the reviewer's figures: with the bound only comparing the current price with the block's limit, bob's push + {burn tranche, sell back exactly the MARG it burned} loop + final sale drained the whole 601.0125 IMD budget in one block (17 to 20 tranches) for +37.44 / +66.43 / +96.61 / +127.94 IMD at pushes of 700 / 1000 / 1400 / 2000 IMD, burning 474.6 / 435.2 / 389.9 / 334.1 MARG instead of 540.1. | A block burns once. `unlockCallback` refuses with `BurnBudgetSpent` when `burnAnchorBlock` is already this block, before reading the limit; otherwise it records the anchor and bounds the one tranche at `BURN_SQRT_BPS` from the price it found, as before. The bound now caps the block's volume, not only the level the price may reach: bringing the price back under the limit re-opens nothing. The stale `current` vs `limit` check is kept as a guard at the price extremes. NatSpec and README no longer claim an absolute guarantee; they state what the bound does (the sandwich against the pool's resting liquidity loses at every size) and what it does not (the reference is the pool's spot; a pusher who also supplies the tranche's MARG as liquidity at the pushed price captures at most the slippage their push paid, bounded by the ~30 IMD a block's tranche is at the live depth). | `test/PagesRevision.t.sol` `testBurnSellBurnSandwichIsRefusedAndLosesMoneyAtEverySize`: the reviewer's loop at the four push sizes gets exactly one tranche, the second burn reverts `BurnBudgetSpent`, more than 90% of the budget stays pending and bob ends down 30.71 / 43.59 / 60.57 / 85.65 IMD; `testASecondBurnInABlockIsRefusedEvenAfterThePriceCameBack`: after a tranche reaches the bound and a sale brings the price back under the limit, both a full and a 1 IMD burn are refused, the anchor holds, and the next block burns again. `test/PagesAudit.t.sol` `testOversizedTranche...` now expects the named error. The existing across-blocks test still burns the whole budget and 540.077 MARG, one tranche per block. |
| `681b03fb` window restart carries the older escrow (info) | Yes: dust escrow at t0, 1 page bought at t0 + 90 days in the block before `recycle`, which then reverts `TooEarly`; repeated every 90 days it defers recycling indefinitely while the owner can still claim everything. | No code change: this is the trade-off of the single clock per subject the previous round chose over the recycle race (`0680ae89`), and the finding offers stating it as a resolution. `README.md` now says the restarted window carries the whole escrow, that trades at or after day 90 can defer recycling indefinitely, and why that is accepted (the escrow stays claimable by the owner, nobody is paid wrongly, the deferring party's fees land 90% in that escrow, only the pools' recycled income is delayed). Separate clocks per accrual would need a second escrow bucket in the subject, the claim settlement and the recycle path for an income delay with no victim. | Behaviour unchanged; `testAccrualAfterTheWindowOpensANewWindow...` still covers the restart. |

Validation of this round: `forge build` passes (warnings only); `forge test` passes every test (the fork suite
skips without `MAINNET_RPC_URL`); the reviewer's loop rebuilt in `test/scratch/BurnBoundCycle.t.sol` failed on
the accepted tree with the figures above and passes now.

## Independent-review revision — 2026-10-12

The accepted Pages launch was reopened on one medium finding; five advisory items came with it. Each
was reproduced on the accepted tree before anything changed (`test/scratch`, not submitted). Only
`src/MarginaliaPages.sol` changed in production code; the constructor, its four arguments and every
economic constant are as before. `.imd-responses.json` answers every item by id.

| Finding | Reproduced | Change in `src/MarginaliaPages.sol` | Regression |
| --- | --- | --- | --- |
| `b28cbca9` burn sandwich (medium) | Yes: at ~6k IMD depth, bob's push + `burnPending(601 IMD, 1)` + sell-back netted +49.65 / +78.76 / +102.29 / +126.62 IMD for 400 / 700 / 1000 / 1400 IMD pushes, exactly the reported figures; the MARG burned fell from 540 to 363. | The floor is now the chain's. `burnPending(imdIn)` (no caller floor) swaps with a `sqrtPriceLimitX96` set `BURN_SQRT_BPS` = 0.5% (about 1% in price) from the pool's sqrt price when the block's first burn began (`burnAnchorSqrtPrice` / `burnAnchorBlock`; `burnLimit()` exposes it). A tranche past the bound fills partially and only what the pool took leaves `pendingBurn`; a block whose budget is spent refuses with `BurnBudgetSpent`. The hook has no TWAP of the launch pool and the spot is what the attacker moves, so the bound is relative to the anchor the attacker may have pushed: that still caps what a sandwich can gain at ~1% of the attacker's position, below the 1.25% + 1.25% LP fees plus the hook's 3% quiet-sell fee the round trip pays. Every number of the brief is unchanged; the only new constant is the tolerance the finding asked for. | `test/PagesRevision.t.sol`: the reviewer's sandwich loses money at all four sizes; bounded tranches over successive blocks burn the whole 601 IMD budget and 540.077 MARG, the same as one unbounded swap; one block moves the price at most (1.005)². `test/PagesAudit.t.sol`: an oversized tranche fills up to the bound, is refused for the rest of the block and resumes next block; a burn after a 1,000,000-IMD push stays within the bound and cannot block trading. |
| `0680ae89` recycle race (low) | Yes: dust escrow at t0, 100 pages at t0 + 91 days, `recycle` sweeps 46.359 IMD in the same block, the owner's claim then pays 0.5 IMD for nothing. | A share landing in escrow after the window has already elapsed restarts `escrowSince`; inside a window the first buy's clock stands, keeping the brief's "90 days after the first buy" for escrow that is being accumulated. | `test/PagesRevision.t.sol` `testAccrualAfterTheWindowOpensANewWindow...`: recycle refuses, the owner's claim takes the 45.9 IMD; an accrual inside a window does not restart it and recycling works at day 90. |
| `f2228aa4` callback headroom (low) | Yes: the accepted callback made two transfers; 182,782 gas delivery (mock Intake overhead included) on the local token, 194,116 reported on the live one. | `onOracleResult` verifies and stores only: it sets the payee and records `settlements[subject]` (claimant, reimbursement; one slot). Permissionless `settleClaim(subject)` pays the escrow less the reimbursement; trades meanwhile pay the payee directly and the escrow is frozen (recycle refuses claimed subjects). `Claimed` is emitted by the callback, `ClaimSettled` by the settlement. | Delivery now measures 153,153 / 160,691 gas with the mock overhead (asserted < 160k in `testCallbackOnlyVerifiesAndStores...`); `test/Pages.t.sol` and `test/PagesOracle.t.sol` settle before checking balances and check nothing is paid inside the callback. |
| `8a9e9350` self subjects (low) | Yes: `subjectOf(pages)` stranded 0.009 IMD per page bought; `subjectOf(hook)` paid the hook's raw balance. | `buy` refuses an address subject equal to this market or the hook with `BadSubject`. | `testMarketAndHookCannotBeSubjects`. |
| `e209caca` dust tranche (info) | Yes: `burnPending(1 wei)` reverted `UnauthorizedCallback`. | A swap that returns no MARG reverts `NothingBurned`; the wei stay pending. | `testDustTrancheIsRefusedByName`. |
| `8681a890` immutable oracle terms (info) | Not a defect; the brief orders no owner and the stored constants. | No code change. README now records the trust assumption and its consequences (claims stop; escrow recycles to the pools; ERC-1271 signer rotation remains possible). | — |

The earlier `8ecf51b2` entry below (a caller-quoted floor) is superseded by the on-chain bound above.
`test/fork/PagesMainnet.t.sol` follows the new signature and asserts the whole small tranche is spent.

## Imported audit findings and changes

- **`1dcd97a5dd38` — reproduced.** The unchanged supplied claim-binding proof fails against the
  original question. `questionBody` in `src/MarginaliaPages.sol` now requires the tweet's entire
  text to be the deliberate claim statement naming this market address, this chain, and a single
  recipient wallet. It returns that wallet rather than the market address; unrelated address
  tweets and extra text require zero. The old `bddnewstoday` token-address probe is therefore not
  an acceptable claim. `test/PagesAudit.t.sol` checks the instruction itself (not just consumer
  metadata), JSON validity, body limits, normalized handle, source guard and deployment/chain
  binding. Unit tests verify the question supplied to the panel, not off-chain panel reasoning.

- **`5bf6cd36fb4e` — reproduced.** Withdrawing all fixture liquidity makes the original supplied
  sell-out proof revert through the hook's `PartialFill`. `_distributeFee` now adds the unchanged
  burn share to `pendingBurn` instead of swapping during a trade. The separate nonReentrant
  `burnPending(imdIn,minMargOut)` executes permissionless tranches and cannot spend reserves or
  escrow. A revert rolls back its pending-balance debit. `test/PagesAudit.t.sol` tests multiple
  holders exiting with no liquidity, buys in that state, pool restoration and retry, partial-fill
  refusal, smaller successful tranches, and complete large exits. Pool funding remains immediate
  through the live hook's `fundPot`, which settles claims without requiring swap liquidity.

- **`8ecf51b296b80` — output loss reproduced; the stated profit did not reproduce.** The original
  fixture burns 247.115768228801323318 MARG for a 1,000-page buy. Preceding it with the stated
  1,000,000-IMD buy reduces the burn to 204.693308948730789744 MARG. The searcher's specified
  round trip loses 52,993.877966197089670555 IMD after LP/hook fees, so that example is not a
  profitable sandwich. The missing minimum was real. The audit's deferred, caller-quoted burn
  option is implemented: each burn requires a nonzero minimum output and a whole input fill,
  with all MARG sent directly to DEAD. Tests show a floor feasible before the price move rejects
  the manipulated output without consuming the pending tranche, while a page holder still exits.
  This is caller-selected execution protection, not a global fair-price guarantee: a malicious
  permissionless caller can choose a low floor. No new price feed, authority or slippage constant
  is introduced. Meaningful independent quotes and burn execution are caller responsibilities.

- **`550f1f4d8493` — reproduced as isolated arithmetic, not a feasible live-token exploit.** With
  a mintable IMD and inert pool swap / fee sink, the original credits `2**64` pages but reports
  supply zero. The initial attempt to bypass only PoolManager failed the hook's unlock-context
  check; the independent arithmetic fixture isolates both external limits. `Subject.supply`
  is now `uint256`, and buy/sell no longer narrow the amount. This preserves the no-cap rule
  instead of imposing a new uint64 ceiling. `test/PagesAudit.t.sol` buys and sells above `2**64`
  with an accounting-only fee sink, and fuzzes real-pool reserve/holder/escrow/burn accounting.
  The `subjects` getter's first return type changes from uint64 to uint256; Pages is not deployed
  yet, and there is no existing Pages storage to migrate. Ordinary arithmetic overflow and
  external token/pool representational limits still revert atomically.

- **`8af79412047b` — not an exploit against an honest Intake; no protocol change.** The supplied
  oracle reference explicitly states that the callback's Intake id and attestation UUID differ,
  and that the relative window prevents precomputing `questionHash`. Requiring equal ids would
  break live delivery. The Intake remains trusted to pair the signed answer with the request
  purchased by Pages. `test/PagesOracle.t.sol` verifies distinct ids, UUID replay refusal across
  pending requests, refusal of unsolicited ids, and signatures for another consumer. No claim
  is made that these checks protect against a malicious trusted Intake misrouting a valid answer.

- **`053844bddb7b` — informational, no defect.** Rechecked the live hook and Intake through the
  contributor endpoint `http://127.0.0.1:36699/rpc/1`: IMD, MARG, PoolManager, INTAKE, ACTION,
  ORACLE_SIGNER, initialization and pool key match the brief. `priceOf` is 0.5 IMD, below the
  unchanged 1 IMD ceiling. `test/fork/PagesMainnet.t.sol` rehearses Pages against those live
  dependencies on a local fork; it skips without `MAINNET_RPC_URL`. No live transaction is sent.

## Other changes required by the brief

- `src/MarginaliaPages.sol`: `abandonClaim` now also uses `nonReentrant`, matching the requirement
  for claims. A reentering fee sink test in `test/PagesAudit.t.sol` confirms cancellation cannot
  occur during a trade, then succeeds normally outside it. `unlockCallback` still accepts only
  the hook's PoolManager and now also requires an active guarded operation. Burn input is
  bounded by v4's signed delta range, and output is checked before settlement. The flow remains
  `sync → transfer from Pages' own funds → settle`, then `take(MARG, DEAD, output)`.
- `test/Pages.t.sol`: retains all 12 scenarios; the original immediate-burn assertion now checks
  fee reservation and an explicit bounded burn, and supply variables follow the uint256 getter.
- `test/PagesDeployment.t.sol`: CREATE2 deployment with the exact four live arguments on an
  empty chain, constructor ABI/configuration, runtime size, constants and forbidden-opcode scan.
- `test/PagesOracle.t.sol`: the protocol's unchanged digest/signature/selector vector plus a
  fresh address answer under the 200,000-gas stipend, with distinct zero-balance reimbursement
  and payee recipients. Also tests request routing, domain binding, replay and abandonment.
  `src/OracleAttestation.sol` is unchanged: its existing memory SignatureChecker entry point is
  compatible with the vendored OpenZeppelin version and the canonical vector.

All economic constants remain unchanged: BASE 0.1 IMD, 10% trade fee, 90/5/5 split of that fee,
70/30 split inside `fundPot`, 5-member/4-quorum oracle, MAX_PRICE 1 IMD, three-day abandonment,
90-day recycling, and the fixed dead address. Pages remain nontransferable, ownerless and
non-upgradeable. The live hook and other project contracts retain their behavior.

## Validation for this assignment

Revision of 2026-10-12 (the independent-review round above): `forge build` passes with the unchanged
configuration; `forge test --match-path 'test/Pages*.t.sol'` is **36 passed, 0 failed** (12 in
`test/Pages.t.sol`, 10 audit, 6 oracle, 1 deployment, 7 revision); the full `forge test` is
**287 passed, 0 failed, 2 skipped** (the two optional fork setups without an RPC). The reviewer's
sandwich, rerun against the fixed code in scratch, loses 17.7 / 30.7 / 43.6 / 60.6 IMD for the four
push sizes. Callback delivery with the mock Intake's overhead: 153,153 and 160,691 gas. The figures
below are the earlier round's and are kept as its record.

- Original Pages baseline: **12 passed**. Both unchanged supplied proofs failed on the original
  code and passed after the fixes. The isolated original-code truncation reproducer also passed,
  confirming the bad state described above. Scratch reproducers are not part of the submission.
- `forge build`: **passed**, using the existing Solidity 0.8.26 / Cancun / via-IR / optimizer-200
  configuration. Compiler and lint warnings remain in pre-existing project code; no build errors.
- `forge test --match-path 'test/Pages*.t.sol'`: **29 passed, 0 failed**, including all 12 original
  Pages scenarios and the new 256-case accounting fuzz test.
- Final plain `forge test`, after retiring scratch-only reproducers: **278 passed, 0 failed,
  2 skipped**. The skipped entries are the two optional fork suite setups with no RPC environment.
  The preceding full run including the three scratch proofs was 281 passed, 0 failed, 2 skipped.
- The **unchanged supplied `Contracts.protected.t.sol`** passed against Pages' compiled creation
  bytecode and exact four constructor arguments on empty chain id 1. It rehearsed factory CREATE2
  deployment, address prediction, the EIP-170 bound and the forbidden-opcode scan. Its artifacts
  were isolated in scratch; no build configuration file changed.
- `MAINNET_RPC_URL=http://127.0.0.1:36699/rpc/1 forge test --match-path test/fork/PagesMainnet.t.sol`
  (with separate scratch output/cache paths): **2 passed**. This exercised live dependency
  constants, page buy/sell, fee distribution, MARG burn and Intake payment on a local mainnet fork.
- Pages runtime: **15,834 bytes**; creation bytecode: **17,280 bytes**, or **17,408** with the four
  ABI-encoded arguments. No unresolved library links. No forbidden escape opcodes.
- The fresh-recipient callback completed under the mock Intake's **200,000-gas stipend**;
  the trace records **155,416 gas** for the callback frame. The broader test wrapper's 203,394-gas
  measurement includes Intake/encoding/storage overhead outside that frame. The original local
  hook/Intake callback tests pass as well.
- `git diff --check` passed; protected configuration/dependency paths have no diff.
- No Slither, Mythril, paid off-chain oracle panel, explorer verification or mainnet broadcast
  was performed. No network is needed for the delivered unit tests; optional fork tests skip.

The prior launch results following this section are historical and are not claims about this assignment.

---

# Historical adaptation records

# Independent-review revision — 2026-10-11

This is a revision of the accepted hook launch, not a new implementation. The only executable
production source changed is `src/MarginaliaHook.sol`. The launch token, constructor arguments,
permission flags `0x20cc`, implementation addresses, companion sources/ABIs, dependencies and build
configuration are unchanged. `.imd-responses.json` answers all 22 reported items individually.

## Reproductions and changes

The starting tree's 186 existing local tests passed. The supplied late-child proof was copied
unchanged to `test/scratch/Proof_7ee86ab40f33.t.sol`; it failed with `NotOpen()` before the fix.
The new `test/HookReview.t.sol` regressions were run before changing production code. They reproduced
all six reopened findings and the v2/v3 alias advisory. The paired-price tests use real router/pricer
code with controlled PoolManager price/liquidity slots; observation-monopoly and hostile-reading
tests use actual swaps on the local PoolManager.

| Finding | Change in `src/MarginaliaHook.sol` | Regression / reason |
| --- | --- | --- |
| `6bbdcb1e` | `_checkCallVenue` rejects calls or seals on the bound IMD, and a subject identical to the venue quote. | IMD denominated in IMD is an identity price, not a falsifiable 10% move. BUY, SELL and seal refusal are atomic; target-zero theses can still discuss IMD. |
| `7ee86ab4` | An own-thesis child must be posted no later than `parent.postedAt + THESIS_GRACE`. | An overdue parent cannot be rescued before its keeper settles it. The supplied proof passes; tests cover the exact inclusive deadline, late refusal, exact returned bond, forfeiture split and 10% bounty. |
| `27af4563` | A slot replacement retains its opening block for the append gap, while updating its actual timestamp, price/accumulator and balance. The final slot is reserved until the actual first-to-last timestamps span one hour. | Dust swaps every 19 blocks previously prevented every honest append. The attack now resolves Wrong and pays the keeper. Testing the first fix also reproduced a capped series shorter than one hour after a first-slot replacement; reserving the final slot closes that related refundable-void path. Neither a timestamp nor an accumulator is backdated. |
| `5acec328` | Adds `MAX_AUTHOR_THESES = 3` and `thesesPerAuthor[week][author]`; the count applies to every thesis, including rebuttals. | Three is the existing ranked-head size. One wallet can no longer consume all 120 slots; the regression admits 3 of 120 attempts, another author can enter, and the allowance resets next week. No stamp, bond or prize amount changes. This is an address occupancy cap, not Sybil resistance. |
| `c6e68a4f` | The first `drawForJudging` is gated until `(week + 1) * 7 days + THESIS_GRACE`. | A week-boundary request can no longer freeze out late theses' timely children. Tests verify atomic refusal before the deadline, success at the exact deadline, both eligible ids in the question, the 0.5 IMD draw and unchanged retry behavior. |
| `5869aec9` | `_settlementPrice` prices each complete v4 observation separately through the pinned pricer, then chooses the minimum product for BUY or maximum for SELL. | BUY/SELL series whose complete prices were all 4 IMD previously settled on synthetic 1/16 IMD component products and forfeited. Both now settle Right and return exactly 0.65 IMD. V3/v2 continue passing their whole series to the live pricer for first-to-last TWAP and adverse hub leg; canonical accumulator settlement is checked too. Unpriceable calls remain VoidNoData. |
| `607bc1b0` | `_checkCallVenue` rejects nonzero high 12 bytes of a v3/v2 ref at both posting and sealing. | The live router still admits alias checkpoints, but none can price an accepted note/seal. Four regressions reproduce different window start times, reject the alias without payment, and post/settle successfully using the same pool's canonical address encoding. |
| `0def2ef9` | Documentation only: fixes `observe`/span comments and the current README/SPEC claims. | A dump-observe-unwind regression confirms one hostile adverse reading survives price recovery and can decide settlement. Honest readings defeat favourable pumps, not adverse attacks. The requested settlement rule is preserved. |

`_settlementPrice` makes at most 16 read-only calls for v4 (the existing observation cap), or one
for an accumulator venue. It introduces no new stateful external call, payment, permission or
privileged role. The live pricer's own multi-observation method remains unchanged. Its posting
window also remains unchanged: the immutable router stores separate component extrema, so an
ETH-quoted baseline is a conservative bound, not necessarily a price seen at one instant. Recovering
historical paired samples from that window is impossible; changing the posting scheme or deploying
a replacement companion is outside this revision. The settlement error is repaired at the hook.

## Tests and documentation adjusted

- `test/HookReview.t.sol`: 18 regressions covering the changes above and the documented adverse
  reading / liquidity-exit limits. The additional full-series span regression failed against the
  first spacing fix before its cause was repaired.
- `test/RevisionFindings.t.sol`: the existing global 120-entry cap test now uses distinct authors;
  its purpose remains refusal of entry 121 without taking payment. The judging setup waits for
  the full grace.
- `test/AuditFindings.t.sol`, `test/Lifecycle.t.sol`: judging setups wait until week-end plus grace;
  callback, payout, retry and sweep assertions are retained.
- `test/fork/MainnetLaunch.t.sol`: both historical calls about IMD now assert refusal and no loss
  of IMD/ETH; the optional X trade rolls back too. A valid thesis activates the initially one-sided
  launch liquidity before the retained wrong-subject check. Other live-venue tests are unchanged.
- `README.md`, `SPEC.md`: document the current hook launch, admission/weekly limits and judging
  timing, paired v4 settlement, conservative posting bound, observation limitations, and advisories.
  The historical SPEC row advertising a successful IMD/IMD call is marked superseded.
- `.imd-responses.json`: complete machine-readable findings, verdicts and reproduction details.

## Preserved decisions and advisory findings

- The imported seal-binding, supply-read, lapsed-seal, refund-denominator, manifest and gas-test
  findings were already fixed in the accepted tree. Their existing regressions pass; those fixes
  were retained, not rewritten. There is no root `launch.json` to repair or submit.
- The immutable Judge does not check `questionHash`. Its own pending request plus the trusted
  Intake routes the answer. In particular, `keccak256(questionBody(week))` is **not** the protocol's
  canonical question hash: the supplied oracle-consumer reference includes the resolved block
  window and definitions, and this judge uses a relative 168-hour window. The hook never sees the
  attestation and cannot add this check. No replacement Judge, signer or Intake was introduced.
- Observation incentives are unchanged: observations are unpaid, only a forfeiting settlement pays
  10%, and insufficient data returns the bond with a negative score. Paying observers or treating
  no-data calls as forfeits would change the brief's explicit amounts or resolution rule.
- Refund eligibility is checked when claimed after the posting day. Retraction prevents an unpaid
  refund, forfeits the full bond and decrements the count only once; it does not recover a refund
  already paid. This accepted behavior is reproduced by
  `testARetractionAfterTheRefundClaimDoesNotDoubleCount` and now stated without the misleading
  “never gets a refund” comment. A deferred 90-day claim conflicts with the 28-day sweep schedule.
- Fees remain swap fees. The single-sided-liquidity regression confirms a MARG range can become
  IMD through buyers and be withdrawn without a hook fee. Adding liquidity callbacks would change
  the mandatory `0x20cc` flags and the factory liquidity policy.
- The accepted initialization boundary remains: only the supplied factory through PoolManager can
  bind the first pool, with fee 12500; pair and spacing are supplied by that factory. The mainnet
  rehearsal uses IMD and spacing 60. No chain-specific restriction was added to local deployments.
- EIP-1167 companions and constructor initialization are expressly required by the brief. Third-party
  nonempty hookData remains refused; integrators must use empty data for quiet swaps.

## Validation of this revision

- `forge build` and `forge build --sizes`: passed with the existing configuration (compiler/lint warnings only).
  Hook runtime **23,916 bytes**, creation bytecode **25,454 bytes**; runtime margin **660 bytes**.
- `forge test --no-match-path 'test/fork/*'`: **205 passed, 0 failed** with the unchanged supplied proof in
  scratch. This is **204 deliverable tests** (186 existing + 18 new) plus that one proof.
- Plain `forge test` with no `MAINNET_RPC_URL`: **205 passed, 0 failed, 1 skipped suite setup**. The skip
  explicitly reports the unavailable fork environment; it is not counted as a fork pass.
- `MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-path 'test/fork/*' -vv`:
  **5 passed, 0 failed** against the live implementations. The real factory's deployment portion used
  **8,306,882 gas**, below 16,777,216; test-side salt mining is outside that deployment measurement.
- Both supplied protected floors were copied unchanged under `test/scratch/univ4_hook/` and run against
  the built creation code with local constructor probes, flags 0x20cc, mainnet IMD pairing, fee 12500,
  spacing 60, price 2^96, supply 10^27 and decimals 18: **11 passed, 0 failed**. This included the
  empty-companion-EVM constructor rehearsal, factory initialization and runtime opcode/size checks.
  The temporary floor copies were then removed so an ordinary test run needs no probe environment.
- `git diff --check` and parsing/validating all 22 response records: passed.
- No Slither, Mythril, broadcast or explorer verification is claimed.

The live-code comparison at Ethereum block **26169085** found Router, Treasury and Pricer byte-for-byte
identical to the compiled artifacts; Judge matched after masking only its compiler-declared EIP-712
immutable ranges. The pair reports symbol `IMD` and 18 decimals. No companion code was changed.

No dependency was installed; no build configuration, dependency, `.git`, `.github`, environment file
or `node_modules` path was modified. No mainnet transaction was broadcast: the deployment transaction
is the subsequent launch service's step, and the fork impersonates the real factory's launch wallet.

---

# Previously accepted hook-launch adaptation (retained history)

# Marginalia hook launch (univ4_hook, Ethereum mainnet): adaptation

This round makes the tree as delivered (commit 8075b3e, v0.8) the hook launch: the `Marginalia` token and
`MarginaliaHook(IPoolManager, token, factory)`, which clones the live launch #1240 companions. The launch shape
already held, and nothing about it changed:

- `Marginalia` (`src/Marginalia.sol`): no constructor arguments, 18 decimals, 1,000,000,000 MARG minted once to
  `msg.sender` (the factory). It has no mint, owner, pause, fee or upgrade path.
- `MarginaliaHook`: a nonpayable constructor `(IPoolManager $poolManager, address $token, address $factory)`. It
  validates its permissions (beforeInitialize, beforeSwap, afterSwap, beforeSwapReturnDelta,
  afterSwapReturnDelta = flags 0x20cc), clones Router/Judge/Treasury from the `src/MarginaliaImpls.sol`
  constants, and initialises each clone once. The constructor reads no chain state. `beforeInitialize` is
  callable only by the PoolManager. It requires the factory as sender and fee 12500, binds the first pool and
  refuses any later one. The hook has no owner, admin, pause, upgrade or setter. Its runtime has no
  DELEGATECALL, CALLCODE or SELFDESTRUCT and is 22,770 bytes (EIP-170 limit 24,576).
- The companion sources (`MarginaliaRouter`, `MarginaliaJudge`, `MarginaliaTreasury`, `MarginaliaPricer`,
  `MarginaliaTypes`) are **unchanged** in this round. The live implementations are what the clones run, and the
  brief forbids redeploying them.

## Changes, by finding

Each finding in the imported audit was checked against the unchanged tree first.

1. **`f31a482c` (high): `seal()` bound neither the sealer, nor X, nor the venue. Reproduced.** On the
   unchanged code, `seals` was keyed by `hash` alone, and `_postNote` used whichever seal sat at
   `sealHash(author, p)`. A stranger could therefore occupy that slot. The victim's note then reverted
   `TooEarly`, and once it did post, it was priced from the stranger's venue. An author could also seal one
   venue's baselines and reveal on another. Fix in `src/MarginaliaHook.sol`:
   - Seals are stored at `sealKey(sealer, hash) = keccak256(abi.encode(sealer, hash))`, a new public pure helper.
   - `Seal` gains `subject = keccak256(abi.encode(x, venue))`.
   - A reveal uses only the author's own seal whose subject is the note's own `p.x` and `p.venue`. Any other
     seal counts as no seal, so it can neither block nor price the note.

   The seal still pays its stamp, prices both baselines and snapshots the sealer's own X balance, as before.
   Tests in `test/LaunchAuditFindings.t.sol`:
   - `testAStrangersSealNeitherBlocksNorPricesTheAuthorsNote`
   - `testAnAuthorsSealOnAnotherVenueDoesNotPriceTheNote`

   The existing seal tests in `test/Lifecycle.t.sol` read the record at its new key.
2. **`43fe5339` (medium): an unguarded `totalSupply()` could block `settle` and `retract`. Reproduced.**
   `_difficulty` called `IERC20(x).totalSupply()` with all remaining gas and then `FullMath.mulDiv`. A reverting
   supply, or one whose market cap overflows, therefore made `settle` and `retract` revert forever. Fix:
   - The supply is read by staticcall bounded by the existing `BALANCE_READ_GAS`, the same way balances are.
   - A failed read, or a `postPrice * supply` that would overflow, books market cap 0, which is tier 1. SPEC's
     rule for an unreadable supply is also tier 1.
   - The score formula is otherwise unchanged.

   Tests:
   - `testARevertingTotalSupplyStillSettlesWrongAndPaysTheKeeper`
   - `testARevertingTotalSupplyDoesNotBlockARetraction`
   - `testAHugeSupplyBooksTierOneInsteadOfOverflowing`
3. **`559dc581` (low): the writer refund counted retracted notes. Reproduced.** `retract` left the note in
   `notesPerDay`, so the day's other notes were underpaid. Fix: `retract` decrements `notesPerDay[n.day]` unless
   the note already claimed its refund, in which case the claim already decremented it. Tests:
   - `testARetractedNoteLeavesTheDaysRefundSplit`: the sole non-retracted note takes `min(pool, STAMP)`.
   - `testARetractionAfterTheRefundClaimDoesNotDoubleCount`
4. **`d492eadc` (low): a lapsed seal was never cleared. Reproduced.** Fix:
   - `seal()` refuses only a seal that is still live (`age <= SEAL_MAX`). A lapsed seal may be replaced.
   - Posting the note now deletes the author's seal whether it was timely or lapsed.

   Tests:
   - `testALapsedSealCanBeSealedAgain`
   - `testUnrevealedSealIsNotAFreeOptionAndLapses` (Lifecycle) previously asserted that "the lapsed seal
     record stays". It now asserts the record is spent, because that rule is the one this finding changed.
5. **`b88581da` (low): `launch.json` was mixed-case and had no `initialPrice`. Reproduced.** `launch.json` is
   **removed**. The manifest belongs to the step after this one, and a partial manifest in the tree is checked
   and rejected. `README.md` now says the manifest step writes it. The launch values the code relies on are
   unchanged:
   - constructor args `$poolManager, $token, $factory`
   - flags 0x20cc
   - fee 12500 and tick spacing 60
   - IMD `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`
6. **`cceb58e5` (info): one test asserted a gas measurement that this toolchain no longer gives. Reproduced:**
   177 passed and 1 failed, out of 178. `test/AuditFindings.t.sol`
   `testHeadOfThreeFitsIntakeStipendAndAFullRankingIsRetried` asserted that a 120-id answer does *not* fit the
   200k callback. It now asserts the property itself, on either outcome:
   - if the answer fits, the week is judged and the head is the thesis;
   - if it does not, the week stays unjudged and the head-of-three retry fits.

   No contract changed for this finding.

## Findings left alone, and why

- **`e20484511` (low): the judge never compares `a.questionHash` with `questionBody(week)`. Reproduces.** By
  reading the code, `onOracleResult` has no such check. The existing tests also deliver attestations with
  `questionHash = keccak256("q")`, and the judge accepts them. **Not fixed:** the check belongs in
  `MarginaliaJudge`, and the hook runs a clone of the live implementation `0xC934…72b4`. The brief forbids
  redeploying the companions. Editing the source here would make the tests run code that mainnet does not run,
  and the hook has no way to see the question hash, because the judge passes it only the head of three. The
  impact is unchanged from the audit: the Intake must route answers to the right `requestId`, and a misrouted
  answer most often leaves an empty head, which rolls the week's pool forward. Fixing this needs a new judge
  implementation, which is a decision for the requester.
- **`3d919d39` (info): the companions are EIP-1167 clones with initialisers.** The brief mandates this. The
  hook's own runtime has no DELEGATECALL, which the protected floor checks.
- **`9e449bc8` (info): `beforeInitialize` does not pin tick spacing 60 or the IMD address.** Left as is. The
  factory supplies both from the manifest, the brief asks only for the factory and fee 12500, and pinning IMD
  would make the hook unusable on any test or other manager.
- **`447e57be` (info): third-party non-empty `hookData` reverts.** This is documented behaviour and unchanged.
- **`9d389a94` (info): coverage statement.** It needs no action.

## Validation (this round)

- `forge build`: passed, with lint warnings only.
- `forge test --no-match-path 'test/fork/*'`: **186 passed, 0 failed**. That is the 178 tests as delivered
  plus 8 new ones in `test/LaunchAuditFindings.t.sol`. The brief's 179 does not match the delivered tree, which
  had 178.
- The supplied protected floors (`Hook.protected.t.sol`, `Token.protected.t.sol`) were run unchanged from
  `test/scratch/` and all **11 passed**. They ran against the built creation code with the manager, token
  probe and factory probe at their own addresses, IMD as the paired currency, fee 12500, tick spacing 60,
  sqrtPrice 2^96, flags 0x20cc, expected supply 10^27 and decimals 18. The hook's constructor ran in an EVM
  where the implementation addresses have no code.
- **Not run:** the mainnet fork suite `test/fork/MainnetLaunch.t.sol`, because no `MAINNET_RPC_URL` was
  available on this machine. The imported audit reports 5 fork tests passing against the live companions on
  the unchanged tree. This round changed only the hook, so the companions' byte-identity it reported is not
  affected.
- No dependency, build configuration, submodule or CI file was changed.

---

# Earlier rounds: companion implementations (launch #1240)


This is the Ethereum mainnet contracts-only launch. Deploy exactly these existing application
contracts, each with an empty constructor argument list:

| Contract | Constructor behavior | Runtime / creation bytecode (bytes) |
| --- | --- | --- |
| `MarginaliaRouter` | Locks its own `hook` to `address(1)` | 17,616 / 17,667 |
| `MarginaliaJudge` | Locks its own `hook` and initializes its EIP-712 implementation domain | 11,194 / 12,362 |
| `MarginaliaTreasury` | Locks its own `hook` to `address(1)` | 1,449 / 1,493 |
| `MarginaliaPricer` | Implicit nonpayable, zero-argument constructor; stateless | 7,748 / 7,774 |

These constructors were already suitable for an empty-chain factory deployment and required no
argument changes. They make no external calls. All library calls are internally linked. There is
no owner, pause, upgrade, action fee, token deployment, pool creation or deployment-time initializer
in this launch. Router, Judge and Treasury are implementations, not operational instances: the
later hook creates immutable EIP-1167 clones and initializes them atomically. The implementation
lock is the explicitly requested sentinel, not an invented recipient or dependency address.

The worker prepared and rehearsed the deployment bytecodes; it did not broadcast transactions or
read wallet keys. The manifest/deployment service supplies confirmed addresses. The existing
`MarginaliaImpls.sol` rehearsal constants belong to the later hook launch and must be replaced with
those confirmed addresses at that step. None is used by the four implementation constructors.

## Reproduced imported findings and changes

All six imported findings reproduced. None was dismissed.

1. **`a4534c56…`: posting used a manipulable same-block spot.** On the original code, selling
   2,000,000 MARG, posting a BUY +10% call and buying back caused a falling market to settle RIGHT.
   The mirror SELL attack also settled RIGHT. `test/AuditFindings.t.sol` reproduces both with real
   local v4 swaps and checks that both now settle WRONG. Changes:
   - `src/MarginaliaTypes.sol` adds `PriceWindow`, holding a first accumulator reading and sampled
     price extremes.
   - `src/MarginaliaRouter.sol` adds permissionless `checkpointVenue`, using the existing canonical
     venue validation and deriving orientation/quote before storing history. The mapping is keyed
     by the derived venue, not caller-supplied orientation. `postPrice` passes that history to the
     stateless pricer. A live checkpoint cannot be replaced or have its start reset.
   - `src/MarginaliaPricer.sol` replaces the spot-only posting API with one that requires a prior
     window: at least one hour, an earlier block, and at most six hours since its start. V3/v2 use
     the accumulator TWAP from that start through posting. V4 and the hub use the maximum sampled
     price for a BUY baseline, minimum for SELL, including the current price. The baseline's
     conservative direction is opposite settlement's because it multiplies the target.
   - `src/MarginaliaHook.sol` reads the baseline through its router and exposes its existing pricer
     reference so the router also makes stateless price calls. Settlement and score formulas stay
     unchanged. Hook runtime remains below EIP-170 at 23,864 bytes; creation code is 25,469 bytes.
   - `test/PriceHistory.t.sol` covers accumulator timing, both price orientations, hub manipulation,
     fresh/missing/expired history, window preservation and fuzzed conservative v4 baselines.

2. **`c697391d…`: a fully ineligible ranking permanently trapped a thesis pool.** The original
   `payJudged` reverted `BadAnswer` for a signed ranking containing only id 999. In
   `src/MarginaliaJudge.sol`, an empty filtered head now reaches the hook's existing unranked-slot
   rollover instead of reverting. Signed empty arrays are also accepted as a no-winner result.
   Payment remains one-shot. `test/AuditFindings.t.sol` verifies the entire remaining IMD pool
   rolls to the current week, the old pool is zero, and a second payment fails.

3. **`e454c18b…`: the root manifest described the wrong launch.** The supplied `launch.json`
   contained `kind: univ4_hook`, token/pool entries and no contracts array. It was removed. No
   replacement manifest was written: that is the next launch step's responsibility. `README.md`
   now distinguishes these four implementations from the later token/hook launch.

4. **`58380615…`: unbounded callback storage exhausted the Intake stipend.** The original clone
   ran out of the 200,000-gas stipend when storing a full 120-id ranking. In
   `src/MarginaliaJudge.sol`, only the requested first three ids are stored. Filtering and
   deduplication still occur at payment; entries after the requested head are ignored, including
   when the head contains ineligible ids. Tests cover 5 and 120 ids, EOA and ERC-1271 signatures,
   no-winner answers, duplicate/invalid ids, replay, sender checks, signature tampering, validity
   windows, quorum and retry. `test/JudgeOracle.t.sol` also pins the supplied protocol digest,
   signature and callback selector on a clone. The vector's 5/4 panel is verified by a test-only
   signature harness and is correctly rejected by the application's unchanged 7/5 quorum.

5. **`9129914f…`: v4 reads accepted a pool with no active liquidity.** Removing all fixture
   liquidity still allowed an observation on the original code. `src/MarginaliaPricer.sol` now
   rejects empty v4 venues and the v4 ETH/IMD hub with `EmptyPool`, including observation,
   checkpoint and posting reads. The integration regression verifies the failed observation
   leaves the call to resolve `VoidNoData`; unit tests cover an empty hub too.

6. **`71bebb06…`: forfeiture conversion used a floor derived from the caller's manipulated spot.**
   The original conversion succeeded immediately after a 2,000,000-MARG dump. In
   `src/MarginaliaHook.sol`, the pot sale's 97% floor now uses the router's mature MARG/IMD window
   and its conservative maximum, including the current price. The dump now reverts without
   consuming the pot. Full-fill accounting and the 97% factor remain unchanged. Tests also
   demonstrate conversion resumes after a genuine price decline once a fresh window matures,
   and verify the IMD claims received. The author's optional deposit conversion is unchanged.

## Other launch adaptation

- `src/MarginaliaRouter.sol`, `src/MarginaliaJudge.sol`, `src/MarginaliaTreasury.sol`: each one-shot
  initializer additionally checks `msg.sender == hook_`, matching the explicit requirement that
  the hook initializes its clones. The constructor locks and nonzero configuration checks remain.
  `test/Implementations.t.sol` checks all implementation locks, refusal of another caller, one
  successful initialization and refusal of every repeat.
- `test/helpers/Fixture.sol` seeds a real checkpoint and advances the EVM clock by an hour before
  price-call tests. Existing economic assertions are preserved. `test/fork/MainnetLaunch.t.sol`
  does the same for the selected live venue and explicitly skips when `MAINNET_RPC_URL` is absent,
  allowing the whole suite to run with an empty environment. A skip is not a fork pass.
- `README.md` documents the launch scope, changed posting/conversion preparation, no-winner
  rollover, head-of-three semantics and oracle limitations. This file records every adaptation.
- No build configuration, dependency, environment file, submodule, repository metadata or CI file
  was changed. No dependencies were installed. All delivered regression tests are outside scratch.

## Operational consequences and preserved behavior

Anyone may checkpoint a canonical venue. Price calls and pot conversions need a window between
one and six hours old; an expired window must be restarted and mature again. Theses need no price
history. A stale baseline causes an atomic revert, with the user's funds unchanged. The six-hour
expiry prevents indefinitely stale references; preserving live extrema prevents an attacker from
erasing an honest checkpoint immediately before posting. This is a deliberate, tested behavior
change required by the two reproduced spot-price findings. Tests use `vm.warp` and `vm.roll`, not
real-time waiting.

V4 and hub histories remain sampled price extremes, not accumulators. They rely on honest
permissionless observations, as does the pre-existing settlement design. Spacing alone cannot
prove a price was held at unobserved times; hostile extreme readings can defer conversion or make
a call harder to win until expiry. V3/v2 averages use elapsed accumulator time. The existing
18-decimal assumption, oracle signer trust and canonical venue policy are unchanged.

The judge threshold remains 2 IMD, the configured oracle price 0.5 IMD, the prize split 50/30/20,
and the treasury drip 2% per UTC day. No 0.25% action fee was added. Canonical venue validation,
fee-on-transfer pulls, weekly pools, retry deadlines, sweep accounting, full-fill sales and the
one-hour settlement observation span remain in place.

## Validation

- Original baseline: 33 tests passed before changes. Added regressions failed against the original
  source for the findings described above, then passed against the fixes.
- `forge build --sizes`: passed with the repository's existing Solidity 0.8.26 / Cancun / via-IR /
  optimizer settings. All four implementations and the later hook fit runtime/initcode limits.
- The **unchanged** supplied `Contracts.protected.t.sol` was copied to scratch and run against all
  four compiled creation bytecodes with no constructor arguments on chain id 1. It passed factory
  CREATE2 deployment, predicted-address checks, runtime limits and forbidden-opcode scanning.
- `test/Implementations.t.sol` independently rehearses all four deployments without dependencies
  present on chain, checks linked bytecode behavior, and exercises clone initialization.
- Final `forge build`: passed (compiler/lint warnings, no errors).
- Final `forge test --no-match-path 'test/fork/*'`: **59 passed, 0 failed**; the fuzz test ran the
  configured 256 cases.
- Final plain `forge test`: **59 passed, 0 failed, 1 skipped suite setup**. The mainnet fork suite
  explicitly skipped because no RPC URL was supplied.
- The four local CREATE2 implementation deployments used **8,694,125 gas**, excluding the test's
  opcode-scanning loop and any production factory overhead.
- No live mainnet fork, Slither, Mythril, explorer verification or broadcast is claimed.

## Revision round 2 (2026-10-11): reviewer findings

Each finding was reproduced before anything changed (the two supplied proofs failed on the starting tree
and pass now; `.imd-responses.json` carries the verdicts). Changes, by file:

- `src/MarginaliaPricer.sol` (finding `4772e72b`, zero prices; `272fbe0d`): `fromSqrt` reverts `EmptyPool`
  when a price rounds to zero in either orientation; the v2 spot and v2 TWAP, `postPrice` and `settlePrice`
  reject a zero result. `sqrt` seeds with `x / 2 + 1` so `type(uint256).max` no longer overflows.
- `src/MarginaliaJudge.sol` (`70ce87bf`, stranded pot): `convertForfeits` tries the whole pot, then halves
  down to 1/256 (`CONVERT_HALVINGS`), through the unchanged judge-only `sellPotMarg` and its unchanged 97%
  floor, and re-raises the hook's reason only if no tranche sells. (`f0aea555`): `weekClosed` stays false
  while a request is still deliverable; new permissionless `abandonRequest(week)` invalidates an unanswered
  request after `ANSWER_DEADLINE`, after which the week can be swept and a late delivery is refused.
  (`b5fc440f`): `onOracleResult` requires `a.chainId == block.chainid`.
- `src/MarginaliaHook.sol` (`ce3d30ae`, dust voids a SELL): the hold rule is `_broken`; a SELL call breaks
  only when the balance grows by more than `SELL_HOLD_TOLERANCE_BPS` (10%) of the post balance and the
  deposit's worth of X. (`7fa6bcfb`, slot squatting): `observe` keeps the slot spacing and cap, but a reading
  more adverse to the call than the latest entry replaces it (`_moreAdverse`). (`542fd714`, switchable
  `balanceOf`): the balance is read by bounded-gas staticcall (`_balanceOf`); a failed read is the
  unverifiable sentinel and counts as not held. (`0a0c1d10`, free option): `VoidNoData` books `-difficulty`
  while the deposit remains claimable. (`7539406d`): `MAX_WEEK_THESES = 120` replaces the silent 256 cut;
  a 121st thesis reverts before its stamp and deposit are taken. (`4772e72b`): a zero baseline is refused
  and a series the pricer cannot price settles `VoidNoData` instead of reverting forever. Hook runtime is
  24,442 bytes (limit 24,576).
- `src/MarginaliaRouter.sol` (`6948a02b`, v3 branch): a canonical v3 pool with zero liquidity is refused.
- Tests: `test/RevisionFindings.t.sol` (one test per change above), `test/PotTranche.t.sol` (the reviewer's
  proof kept as the regression, plus the pot draining across fresh windows), `test/Lifecycle.t.sol`
  `testNoDataRefunds` updated for the negative score. The supplied proofs were run from `test/scratch/`.

Disputed, with reasons in `.imd-responses.json`: `6948a02b` (venue admission is the project's design and
has no owner-settable policy; the free variants are closed and the limit is documented), `ec6beba1` (the
adverse-extreme rule is the one the brief specifies; its cost is a paid round trip), `86e81b29` (concerns
the later hook launch, recorded as its first work item). The four implementation constructors are
unchanged: still empty, still locking `hook = address(1)`, still making no external calls.

Validation after this round: `forge build` passes (warnings only); `forge test --no-match-path 'test/fork/*'`
passes every test; the two reviewer proofs pass from `test/scratch/`.

## Revision round 3 (2026-10-10): reviewer findings

Each finding was reproduced on the unchanged tree before anything changed (the reviewer's recipes, rebuilt in
`test/scratch/Round3Repro.t.sol`, failed exactly as reported: leaderboard share 50.005 IMD for the self-priced
venue, VoidSold with score -20,538 for the gifted SELL call, `sqrt(2) == 2`). `.imd-responses.json` carries the
verdicts. Changes, by file:

- `src/MarginaliaHook.sol` (`c7331916`, self-priced venue farms the leaderboard): `_difficulty` returns 0 for a
  call whose venue is not the launch pool (v4, `ref == poolId`), so `settle` and `retract` book no score and no
  `weekScore` for it, in either direction. The call still returns or forfeits its own deposit on price, still
  counts in `right` / `wrong` / `broken` / `retracted`, and still takes the writer refund. Of the reviewer's three
  options this is the only one that bounds the draw to zero: a capped multiple or a depth-derived tier still
  leaves a RIGHT on a pool the author alone provisions free, and free rights dilute honest scores pro-rata
  across any number of wallets. A venue policy that would let other canonical pools score again is the
  requester's decision; there is no owner to set one.
- `src/MarginaliaHook.sol` (`80c42ce7`, a gift voids a SELL call): the SELL hold rule is removed; `_broken` is
  false for SELL calls, which settle on price alone. `balanceOf` cannot distinguish a buy-back from a stranger's
  transfer, so every tolerance is a griefing price, not a guarantee. The BUY hold rule and its unverifiable-read
  sentinel are unchanged. `SELL_HOLD_TOLERANCE_BPS` is gone. Hook runtime is 24,411 bytes, initcode 26,016.
- `src/MarginaliaPricer.sol` (`4e3977e5`, advisory): `sqrt` returns 1 for inputs 1..3 before the loop; the
  overflow-safe seed stays for the rest. One of the four deployed contracts, so fixed here.
- Tests: `test/Round3Findings.t.sol` (the reviewer's two scenarios as regressions, plus: a wrong call and a
  retraction on another venue book no score, a launch-pool call still scores and pays, a gift of any size does
  not void a SELL call, a wrong SELL call still forfeits, a BUY call still breaks on a sale, `sqrt` exhaustive
  over 0..1023 and fuzzed over `uint256`). `test/RevisionFindings.t.sol`: `testARealBuyBackStillVoidsASellCall`
  encoded the removed rule and is now `testABuyBackNoLongerVoidsASellCallItSettlesOnPrice`;
  `testARevertingBalanceOfVoidsTheCallAsSoldNotAsNoData` asserts score 0 (its venue is not the launch pool).
- Docs: `SPEC.md` 4.3 (hold rule, score eligibility), 4.4 and section 10 rows; `README.md` leaderboard row,
  audit history and known limits now state both rules as implemented.

The four implementation constructors are unchanged: empty, locking `hook = address(1)`, no external calls.
Validation after this round: `forge build --sizes` passes (warnings only); `forge test --no-match-path
'test/fork/*'` passes every test (the fork suite still skips without `MAINNET_RPC_URL`); the unchanged supplied
`Contracts.protected.t.sol` was run again from `test/scratch/` against the four rebuilt creation bytecodes with
no constructor arguments on chain id 1 and passed.
