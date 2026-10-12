// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {ClaimIntake} from "./Pages.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MarginaliaPages, IMarginaliaHookPages} from "../src/MarginaliaPages.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Drives MarginaliaPages against the real local PoolManager, hook and pool with bounded inputs and four
/// actors: buys and sells on six subjects (two address issuers, the zero subject, three handles), oracle claims
/// (good, zero, tampered, thin, stale, wrong signer), settlement, abandonment, recycling, bounded MARG burns
/// and time. Every call the handler makes either succeeds and is checked, or is a deliberate refusal whose
/// reason is asserted, so the suite runs with fail-on-revert. A separate ledger (the ghosts) records what the
/// market should hold.
contract PagesHandler is Test {
    MarginaliaPages public immutable pages;
    ClaimIntake public immutable intake;
    MockERC20 public immutable imd;
    IERC20 public immutable marg;
    address public immutable manager;
    uint256 internal immutable signerKey;

    address[4] public actors;
    bytes32[] public subjects;
    string[3] internal handles;
    uint256 public constant HANDLE_OFFSET = 3;
    /// @dev The smallest burn tranche the handler asks for: the smallest fee share is 5e14 wei, and a wei or
    /// two is eaten whole by the pool's LP fee and returns no MARG.
    uint256 public constant MIN_TRANCHE = 1e12;

    // ------------------------------------------------------------------ ghosts
    mapping(bytes32 => uint256) public ghostSupply;
    mapping(bytes32 => mapping(address => uint256)) public ghostPages;
    mapping(bytes32 => uint256) public ghostEscrow;
    mapping(bytes32 => uint256) public ghostEscrowSince;
    mapping(bytes32 => address) public ghostPayee; // handle subjects only
    mapping(bytes32 => bytes32) public ghostPending; // the Intake id of the claim in flight
    mapping(bytes32 => address) public ghostClaimant;
    mapping(bytes32 => uint256) public ghostPrice;
    mapping(bytes32 => uint256) public ghostRequestedAt;
    /// @dev A successful claim's payout waiting for settleClaim: who asked and what the escrow owes them back.
    mapping(bytes32 => address) public ghostSettleTo;
    mapping(bytes32 => uint256) public ghostReimbursed;
    mapping(bytes32 => bool) public ghostUnsettled;
    uint256 public ghostPendingBurn;
    uint256 public ghostIn; // IMD the market took from traders
    uint256 public ghostOut; // IMD the market paid out: sellers, issuers, pools, claims, recycling, burns
    uint256 public ghostPools; // IMD handed to the hook's pools (fees and recycling)
    uint256 public ghostMargBurned;
    uint256 public ghostImdBurned;
    bytes32[] public consumedUuids;
    uint256 internal uuidNonce;

    // ------------------------------------------------------------------ counters
    uint256 public buys;
    uint256 public sells;
    uint256 public refusals;
    uint256 public requests;
    uint256 public claimsSucceeded;
    uint256 public claimsFailed;
    uint256 public settlements;
    uint256 public answersRefused;
    uint256 public abandons;
    uint256 public recycles;
    uint256 public burns;
    uint256 public partialFills;
    uint256 public budgetRefusals;

    constructor(
        MarginaliaPages pages_,
        ClaimIntake intake_,
        MockERC20 imd_,
        IERC20 marg_,
        uint256 signerKey_,
        address[4] memory actors_,
        address fixedIssuer
    ) {
        pages = pages_;
        intake = intake_;
        imd = imd_;
        marg = marg_;
        manager = address(pages_.hook().poolManager());
        signerKey = signerKey_;
        actors = actors_;
        handles[0] = "writer_one";
        handles[1] = "Writer_Two"; // upper case on purpose: the market lower-cases it
        handles[2] = "x";
        subjects.push(pages_.subjectOf(actors_[0])); // a trader who is their own issuer
        subjects.push(pages_.subjectOf(fixedIssuer));
        subjects.push(bytes32(0)); // the zero address as an issuer: nobody is paid, the share escrows
        for (uint256 i; i < 3; ++i) {
            subjects.push(pages_.subjectOfHandle(handles[i]));
        }
    }

    function subjectCount() external view returns (uint256) {
        return subjects.length;
    }

    function consumedCount() external view returns (uint256) {
        return consumedUuids.length;
    }

    // ------------------------------------------------------------------ helpers

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _fund(address who, uint256 amount) internal {
        if (imd.balanceOf(who) < amount) imd.mint(who, amount);
    }

    /// @dev A call that must be refused with exactly `selector`.
    function _refused(address from, bytes memory data, bytes4 selector) internal {
        vm.prank(from);
        (bool ok, bytes memory ret) = address(pages).call(data);
        assertFalse(ok, "call should have been refused");
        assertGe(ret.length, 4, "refusal carries an error");
        assertEq(bytes4(ret), selector, "refused for the wrong reason");
        refusals++;
    }

    function _feeGhost(bytes32 subject, uint256 fee, address payee) internal {
        uint256 toIssuer = fee * pages.ISSUER_BPS() / 10_000;
        uint256 toBurn = fee * pages.BURN_BPS() / 10_000;
        uint256 toPools = fee - toIssuer - toBurn;
        if (payee != address(0)) {
            ghostOut += toIssuer;
        } else {
            // the window runs from the first buy of the escrow being accumulated; a share landing after it
            // elapsed opens a new one
            if (ghostEscrowSince[subject] == 0 || _now() >= ghostEscrowSince[subject] + pages.CLAIM_WINDOW())
            {
                ghostEscrowSince[subject] = _now();
            }
            ghostEscrow[subject] += toIssuer;
        }
        ghostPendingBurn += toBurn;
        ghostPools += toPools;
        ghostOut += toPools;
    }

    function _att(address wallet) internal returns (OracleAttestation.Attestation memory a) {
        uuidNonce++;
        a.requestId = keccak256(abi.encode("oracle uuid", uuidNonce));
        a.chainId = block.chainid;
        a.questionHash = keccak256("question");
        a.answerType = OracleAttestation.ANSWER_ADDRESS;
        a.answer = abi.encode(wallet);
        a.fromBlock = 1;
        a.toBlock = 2;
        a.blockHash = keccak256("block");
        a.panelJobId = keccak256("job");
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(_now());
        a.expiresAt = uint64(_now() + 1 days);
    }

    function _sign(OracleAttestation.Attestation memory a, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, pages.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------------------------ actions

    function buy(uint256 actorSeed, uint256 subjectSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        bytes32 subject = subjects[subjectSeed % subjects.length];
        amount = bound(amount, 1, 40);
        (uint256 value, uint256 fee) = pages.buyPrice(subject, amount);
        assertEq(value, pages.priceOf(ghostSupply[subject], amount));
        _fund(actor, value + fee);
        // one wei short is refused before anything moves
        _refused(
            actor,
            abi.encodeCall(MarginaliaPages.buy, (subject, amount, value + fee - 1)),
            MarginaliaPages.Slippage.selector
        );
        address payee = pages.payeeOf(subject);
        uint256 before = imd.balanceOf(actor);
        uint256 escrowBefore = ghostEscrow[subject];
        vm.prank(actor);
        pages.buy(subject, amount, value + fee);
        uint256 paid = before - imd.balanceOf(actor);
        uint256 toIssuer = fee * pages.ISSUER_BPS() / 10_000;
        assertEq(paid, payee == actor ? value + fee - toIssuer : value + fee, "a buyer pays value plus fee");
        ghostIn += value + fee;
        ghostSupply[subject] += amount;
        ghostPages[subject][actor] += amount;
        _feeGhost(subject, fee, payee);
        if (payee != address(0)) {
            assertEq(ghostEscrow[subject], escrowBefore, "a paid subject escrows nothing");
        }
        buys++;
    }

    function sell(uint256 actorSeed, uint256 subjectSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        bytes32 subject = subjects[subjectSeed % subjects.length];
        uint256 held = pages.pagesOf(subject, actor);
        if (held == 0) {
            // nothing to sell: the curve refuses, whatever the supply held by others
            _refused(
                actor,
                abi.encodeCall(MarginaliaPages.sell, (subject, 1, 0)),
                MarginaliaPages.InsufficientPages.selector
            );
            return;
        }
        amount = bound(amount, 1, held);
        (uint256 value, uint256 fee) = pages.sellPrice(subject, amount);
        assertEq(value, pages.priceOf(ghostSupply[subject] - amount, amount));
        _refused(
            actor,
            abi.encodeCall(MarginaliaPages.sell, (subject, held + 1, 0)),
            MarginaliaPages.InsufficientPages.selector
        );
        _refused(
            actor,
            abi.encodeCall(MarginaliaPages.sell, (subject, amount, value - fee + 1)),
            MarginaliaPages.Slippage.selector
        );
        address payee = pages.payeeOf(subject);
        uint256 before = imd.balanceOf(actor);
        vm.prank(actor);
        pages.sell(subject, amount, value - fee);
        uint256 got = imd.balanceOf(actor) - before;
        uint256 toIssuer = fee * pages.ISSUER_BPS() / 10_000;
        assertEq(got, payee == actor ? value - fee + toIssuer : value - fee, "a seller gets value less fee");
        ghostOut += value - fee;
        ghostSupply[subject] -= amount;
        ghostPages[subject][actor] -= amount;
        _feeGhost(subject, fee, payee);
        sells++;
    }

    function requestClaim(uint256 actorSeed, uint256 handleSeed, uint256 tweetId) external {
        address actor = actors[actorSeed % actors.length];
        uint256 idx = handleSeed % handles.length;
        bytes32 subject = subjects[HANDLE_OFFSET + idx];
        string memory handle = handles[idx];
        uint256 price = intake.price();
        _fund(actor, price);
        bytes memory data = abi.encodeCall(MarginaliaPages.requestClaim, (handle, tweetId));
        if (ghostPayee[subject] != address(0)) {
            _refused(actor, data, MarginaliaPages.AlreadyClaimed.selector);
            return;
        }
        if (ghostPending[subject] != bytes32(0)) {
            _refused(actor, data, MarginaliaPages.ClaimPending.selector);
            return;
        }
        uint256 actorBefore = imd.balanceOf(actor);
        uint256 intakeBefore = imd.balanceOf(address(intake));
        uint256 pagesBefore = imd.balanceOf(address(pages));
        vm.prank(actor);
        bytes32 id = pages.requestClaim(handle, tweetId);
        assertTrue(id != bytes32(0));
        assertEq(actorBefore - imd.balanceOf(actor), price, "the asker fronts the oracle price");
        assertEq(imd.balanceOf(address(intake)) - intakeBefore, price, "the price goes to the Intake");
        assertEq(imd.balanceOf(address(pages)), pagesBefore, "the market keeps none of it");
        assertEq(imd.allowance(address(pages), address(intake)), 0, "no allowance is left behind");
        ghostPending[subject] = id;
        ghostClaimant[subject] = actor;
        ghostPrice[subject] = price;
        ghostRequestedAt[subject] = _now();
        requests++;
    }

    /// @param mode 0 names a wallet, 1 answers zero, the rest are refused answers of one kind each.
    function answer(uint256 handleSeed, uint256 walletSeed, uint256 mode) external {
        uint256 idx = handleSeed % handles.length;
        bytes32 subject = subjects[HANDLE_OFFSET + idx];
        address wallet = actors[walletSeed % actors.length];
        bytes32 id = ghostPending[subject];
        if (id == bytes32(0)) {
            // nothing pending: a signed answer for an id the market never issued is refused
            OracleAttestation.Attestation memory stray = _att(wallet);
            bytes32 unknown = keccak256(abi.encode("unknown intake id", uuidNonce));
            assertFalse(intake.deliver(address(pages), unknown, stray, _sign(stray, signerKey)));
            assertFalse(pages.consumed(stray.requestId));
            answersRefused++;
            return;
        }
        mode = mode % 7;
        if (mode >= 2) {
            _refusedAnswer(subject, id, wallet, mode);
            return;
        }
        if (mode == 1) wallet = address(0);
        OracleAttestation.Attestation memory a = _att(wallet);
        bytes memory sig = _sign(a, signerKey);
        address claimant = ghostClaimant[subject];
        uint256 escrow = ghostEscrow[subject];
        uint256 reimbursed = escrow >= ghostPrice[subject] ? ghostPrice[subject] : 0;
        uint256 claimantBefore = imd.balanceOf(claimant);
        uint256 walletBefore = wallet == address(0) ? 0 : imd.balanceOf(wallet);
        uint256 pagesBefore = imd.balanceOf(address(pages));
        bool ok = intake.deliver(address(pages), id, a, sig);
        assertTrue(ok, "the callback fits the Intake's 200k stipend");
        assertTrue(pages.consumed(a.requestId), "the oracle UUID is consumed");
        assertFalse(intake.deliver(address(pages), id, a, sig), "a replay is refused");
        (bytes32 pending,,,) = pages.claims(subject);
        assertEq(pending, bytes32(0), "the claim is closed either way");
        assertEq(imd.balanceOf(address(pages)), pagesBefore, "the callback only verifies and stores");
        assertEq(imd.balanceOf(claimant), claimantBefore, "nothing is paid inside the callback");
        consumedUuids.push(a.requestId);
        delete ghostPending[subject];
        delete ghostClaimant[subject];
        delete ghostPrice[subject];
        delete ghostRequestedAt[subject];
        if (wallet == address(0)) {
            assertEq(pages.payeeOf(subject), address(0), "a zero answer names nobody");
            (address nobody, uint96 nothing) = pages.settlements(subject);
            assertEq(nobody, address(0), "a failed claim records no payout");
            assertEq(nothing, 0);
            claimsFailed++;
            return;
        }
        assertEq(pages.payeeOf(subject), wallet, "the answer is the payee");
        assertEq(imd.balanceOf(wallet), walletBefore, "the owner is paid by settlement, not the callback");
        (,, uint256 frozen,) = pages.subjects(subject);
        assertEq(frozen, escrow, "the escrow waits for settlement");
        (address owedTo, uint96 owedBack) = pages.settlements(subject);
        assertEq(owedTo, claimant, "the asker is remembered");
        assertEq(owedBack, reimbursed, "the price comes back only if the escrow covers it");
        ghostPayee[subject] = wallet;
        ghostSettleTo[subject] = claimant;
        ghostReimbursed[subject] = reimbursed;
        ghostUnsettled[subject] = true;
        claimsSucceeded++;
        // one successful claim per subject, ever
        string memory handle = handles[idx];
        _refused(
            actors[0],
            abi.encodeCall(MarginaliaPages.requestClaim, (handle, 1)),
            MarginaliaPages.AlreadyClaimed.selector
        );
    }

    function _refusedAnswer(bytes32 subject, bytes32 id, address wallet, uint256 mode) internal {
        OracleAttestation.Attestation memory a = _att(wallet);
        bytes memory sig;
        if (mode == 2) {
            sig = _sign(a, signerKey);
            a.figure = 1; // tampered after signing
        } else if (mode == 3) {
            a.agreed = 3; // below the quorum
            sig = _sign(a, signerKey);
        } else if (mode == 4) {
            a.chainId = block.chainid + 1; // about another chain
            sig = _sign(a, signerKey);
        } else if (mode == 5) {
            a.expiresAt = uint64(_now() - 1); // stale
            sig = _sign(a, signerKey);
        } else {
            sig = _sign(a, signerKey + 1); // another key
        }
        uint256 pagesBefore = imd.balanceOf(address(pages));
        assertFalse(intake.deliver(address(pages), id, a, sig), "a bad answer is refused");
        assertFalse(pages.consumed(a.requestId), "a refused answer consumes nothing");
        assertEq(imd.balanceOf(address(pages)), pagesBefore);
        (bytes32 pending, address claimant, uint256 price, uint64 at) = pages.claims(subject);
        assertEq(pending, id, "the claim stays open");
        assertEq(claimant, ghostClaimant[subject]);
        assertEq(price, ghostPrice[subject]);
        assertEq(at, ghostRequestedAt[subject]);
        assertEq(pages.payeeOf(subject), ghostPayee[subject]);
        answersRefused++;
    }

    /// @dev Anyone pays out a successful claim, once: the escrow to the owner less the price back to the asker.
    function settle(uint256 subjectSeed) external {
        bytes32 subject = subjects[subjectSeed % subjects.length];
        bytes memory data = abi.encodeCall(MarginaliaPages.settleClaim, (subject));
        if (!ghostUnsettled[subject] || (ghostEscrow[subject] == 0 && ghostReimbursed[subject] == 0)) {
            // address subjects, unclaimed handles, settled claims and a claim that found an empty escrow
            _refused(actors[2], data, MarginaliaPages.NothingToSettle.selector);
            return;
        }
        address wallet = ghostPayee[subject];
        address asker = ghostSettleTo[subject];
        uint256 escrow = ghostEscrow[subject];
        uint256 back = ghostReimbursed[subject];
        uint256 walletBefore = imd.balanceOf(wallet);
        uint256 askerBefore = imd.balanceOf(asker);
        uint256 pagesBefore = imd.balanceOf(address(pages));
        vm.prank(actors[2]); // anyone
        pages.settleClaim(subject);
        assertEq(pagesBefore - imd.balanceOf(address(pages)), escrow, "exactly the escrow leaves");
        if (wallet == asker) {
            assertEq(imd.balanceOf(wallet) - walletBefore, escrow, "an owner who asked gets it all");
        } else {
            assertEq(imd.balanceOf(asker) - askerBefore, back, "the asker gets the price back");
            assertEq(imd.balanceOf(wallet) - walletBefore, escrow - back, "the owner gets the rest");
        }
        (,, uint256 left, uint64 since) = pages.subjects(subject);
        assertEq(left, 0);
        assertEq(since, 0, "a settled escrow has no clock");
        (address cleared,) = pages.settlements(subject);
        assertEq(cleared, address(0), "the payout record is cleared");
        _refused(actors[2], data, MarginaliaPages.NothingToSettle.selector); // never twice
        ghostEscrow[subject] = 0;
        ghostEscrowSince[subject] = 0;
        ghostUnsettled[subject] = false;
        ghostOut += escrow;
        settlements++;
    }

    function abandon(uint256 handleSeed) external {
        uint256 idx = handleSeed % handles.length;
        bytes32 subject = subjects[HANDLE_OFFSET + idx];
        bytes32 id = ghostPending[subject];
        bytes memory data = abi.encodeCall(MarginaliaPages.abandonClaim, (subject));
        if (id == bytes32(0)) {
            _refused(actors[1], data, MarginaliaPages.UnknownRequest.selector);
            return;
        }
        if (_now() < ghostRequestedAt[subject] + pages.ANSWER_DEADLINE()) {
            _refused(actors[1], data, MarginaliaPages.TooEarly.selector);
            return;
        }
        uint256 pagesBefore = imd.balanceOf(address(pages));
        vm.prank(actors[1]); // anyone
        pages.abandonClaim(subject);
        assertEq(imd.balanceOf(address(pages)), pagesBefore, "abandoning moves nothing");
        (bytes32 pending,,,) = pages.claims(subject);
        assertEq(pending, bytes32(0));
        // a late delivery under the abandoned request is refused
        OracleAttestation.Attestation memory late = _att(actors[2]);
        assertFalse(intake.deliver(address(pages), id, late, _sign(late, signerKey)), "late delivery");
        assertEq(pages.payeeOf(subject), ghostPayee[subject]);
        delete ghostPending[subject];
        delete ghostClaimant[subject];
        delete ghostPrice[subject];
        delete ghostRequestedAt[subject];
        abandons++;
    }

    function recycle(uint256 subjectSeed) external {
        bytes32 subject = subjects[subjectSeed % subjects.length];
        bytes memory data = abi.encodeCall(MarginaliaPages.recycle, (subject));
        uint256 escrow = ghostEscrow[subject];
        if (pages.payeeOf(subject) != address(0) || escrow == 0) {
            // a claimed handle's frozen escrow is the owner's, never the pools'
            _refused(actors[2], data, MarginaliaPages.NothingToRecycle.selector);
            return;
        }
        if (ghostPending[subject] != bytes32(0)) {
            _refused(actors[2], data, MarginaliaPages.ClaimPending.selector);
            return;
        }
        if (_now() < ghostEscrowSince[subject] + pages.CLAIM_WINDOW()) {
            _refused(actors[2], data, MarginaliaPages.TooEarly.selector);
            return;
        }
        uint256 pagesBefore = imd.balanceOf(address(pages));
        vm.prank(actors[2]); // anyone
        pages.recycle(subject);
        assertEq(pagesBefore - imd.balanceOf(address(pages)), escrow, "exactly the escrow is recycled");
        (,, uint256 left, uint64 since) = pages.subjects(subject);
        assertEq(left, 0);
        assertEq(since, 0);
        ghostEscrow[subject] = 0;
        ghostEscrowSince[subject] = 0;
        ghostPools += escrow;
        ghostOut += escrow;
        recycles++;
    }

    /// @dev A burn tranche: a quiet buy of MARG bounded by the block's price budget. The pool takes what fits
    /// under the bound, the rest stays queued; a block whose budget is spent refuses by name.
    function burn(uint256 amountSeed) external {
        uint256 pending = pages.pendingBurn();
        if (pending == 0) {
            _refused(
                actors[3],
                abi.encodeCall(MarginaliaPages.burnPending, (1)),
                MarginaliaPages.InsufficientBurn.selector
            );
            return;
        }
        _refused(
            actors[3],
            abi.encodeCall(MarginaliaPages.burnPending, (pending + 1)),
            MarginaliaPages.InsufficientBurn.selector
        );
        (uint160 limit, uint160 current, bool zeroForOne) = pages.burnLimit();
        if (zeroForOne ? current <= limit : current >= limit) {
            _refused(
                actors[3],
                abi.encodeCall(MarginaliaPages.burnPending, (pending)),
                MarginaliaPages.BurnBudgetSpent.selector
            );
            assertEq(pages.pendingBurn(), pending, "a refused tranche stays queued");
            budgetRefusals++;
            return;
        }
        // one wei is eaten whole by the pool's LP fee: refused by name, and nothing is anchored by a refusal
        uint64 anchorBlockBefore = pages.burnAnchorBlock();
        _refused(
            actors[3],
            abi.encodeCall(MarginaliaPages.burnPending, (1)),
            MarginaliaPages.NothingBurned.selector
        );
        assertEq(pages.burnAnchorBlock(), anchorBlockBefore);
        if (pending < MIN_TRANCHE) return;
        uint256 amount = bound(amountSeed, MIN_TRANCHE, pending);
        uint256 deadBefore = marg.balanceOf(pages.DEAD());
        uint256 pagesBefore = imd.balanceOf(address(pages));
        uint256 poolBefore = imd.balanceOf(manager);
        uint256 poolMargBefore = marg.balanceOf(manager);
        vm.prank(actors[3]); // anyone
        (uint256 spent, uint256 burned) = pages.burnPending(amount);
        assertGt(spent, 0, "something was spent");
        assertLe(spent, amount, "never more than the tranche");
        assertGt(burned, 0, "something was burned");
        assertEq(marg.balanceOf(pages.DEAD()) - deadBefore, burned, "the MARG went to the dead address");
        assertEq(poolMargBefore - marg.balanceOf(manager), burned, "and came out of the pool");
        assertEq(pagesBefore - imd.balanceOf(address(pages)), spent, "exactly what the pool took left");
        assertEq(imd.balanceOf(manager) - poolBefore, spent, "and the pool got it");
        assertEq(pages.pendingBurn(), pending - spent, "the unspent rest stays queued");
        assertEq(pages.burnAnchorBlock(), block.number, "the block is anchored");
        (uint160 limitAfter, uint160 after_,) = pages.burnLimit();
        assertEq(limitAfter, limit, "the bound holds for the whole block");
        assertTrue(zeroForOne ? after_ >= limit : after_ <= limit, "the price never passes the bound");
        if (spent < amount) {
            assertEq(after_, limit, "a partial fill stops exactly at the bound");
            partialFills++;
        }
        ghostPendingBurn -= spent;
        ghostOut += spent;
        ghostImdBurned += spent;
        ghostMargBurned += burned;
        burns++;
    }

    function warp(uint256 secondsSeed) external {
        uint256 d = bound(secondsSeed, 1 hours, 31 days);
        vm.warp(_now() + d);
        vm.roll(vm.getBlockNumber() + d / 12);
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract PagesInvariantTest is Fixture {
    uint256 constant SIGNER_KEY = 0x5E7;
    bytes32 constant ACTION = bytes32("oracle.request@oracle-1");

    MarginaliaPages pages;
    ClaimIntake intake;
    PagesHandler handler;
    address dave = makeAddr("dave");
    address issuer = makeAddr("issuer");
    uint256 poolsBaseline;
    uint256 deadBaseline;

    function setUp() public {
        _setup();
        _fundCarol();
        // Shallow in-range liquidity, the order of the live launch pool, so the per-block burn bound is hit
        // within a run: tranches fill partially and a block's budget runs out.
        liquidity.add(key, -6000, 6000, -10_000_000 ether);
        liquidity.add(key, -6000, 6000, 2_000 ether);
        intake = new ClaimIntake();
        pages = new MarginaliaPages(IMarginaliaHookPages(address(hook)), intake, ACTION, vm.addr(SIGNER_KEY));
        address[4] memory actors = [alice, bob, carol, dave];
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            imd.approve(address(pages), type(uint256).max);
        }
        handler = new PagesHandler(pages, intake, imd, IERC20(address(token)), SIGNER_KEY, actors, issuer);
        poolsBaseline = _claims(address(hook), address(imd));
        deadBaseline = token.balanceOf(pages.DEAD());
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = PagesHandler.buy.selector;
        selectors[1] = PagesHandler.sell.selector;
        selectors[2] = PagesHandler.requestClaim.selector;
        selectors[3] = PagesHandler.answer.selector;
        selectors[4] = PagesHandler.settle.selector;
        selectors[5] = PagesHandler.abandon.selector;
        selectors[6] = PagesHandler.recycle.selector;
        selectors[7] = PagesHandler.burn.selector;
        selectors[8] = PagesHandler.warp.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _subject(uint256 i) internal view returns (bytes32) {
        return handler.subjects(i);
    }

    /// @dev What the market holds is exactly the curve reserves, the handle escrow (frozen or not) and the
    /// burn queue.
    function invariant_marketHoldsExactlyWhatItOwes() public view {
        uint256 owed = pages.pendingBurn();
        uint256 n = handler.subjectCount();
        for (uint256 i; i < n; ++i) {
            bytes32 s = _subject(i);
            (,, uint256 escrow,) = pages.subjects(s);
            owed += pages.reserveOf(s) + escrow;
        }
        assertEq(imd.balanceOf(address(pages)), owed, "balance == reserves + escrow + pending burn");
    }

    /// @dev Nothing leaks in or out: the balance is what traders paid less everything the market paid away.
    function invariant_conservation() public view {
        assertEq(imd.balanceOf(address(pages)), handler.ghostIn() - handler.ghostOut(), "in - out");
        assertEq(pages.pendingBurn(), handler.ghostPendingBurn(), "burn queue");
    }

    /// @dev Every subject's reserve is the integral of the curve under its supply, so every holder can sell
    /// out at any depth, and every page is held by a trader: pages never move.
    function invariant_reserveCoversEveryHolder() public view {
        uint256 n = handler.subjectCount();
        for (uint256 i; i < n; ++i) {
            bytes32 s = _subject(i);
            (uint256 supply,,,) = pages.subjects(s);
            assertEq(supply, handler.ghostSupply(s), "supply");
            assertEq(pages.reserveOf(s), pages.priceOf(0, supply), "reserve is the curve's integral");
            if (supply > 0) {
                (uint256 all,) = pages.sellPrice(s, supply);
                assertEq(all, pages.reserveOf(s), "everyone can sell out");
            }
            uint256 held;
            for (uint256 j; j < 4; ++j) {
                address actor = handler.actors(j);
                assertEq(pages.pagesOf(s, actor), handler.ghostPages(s, actor), "holder balance");
                held += pages.pagesOf(s, actor);
            }
            assertEq(held, supply, "every page has a holder");
            assertEq(pages.pagesOf(s, issuer), 0, "an issuer who never bought holds nothing");
        }
    }

    /// @dev Escrow, payee, the claim in flight and the payout awaiting settlement match the ledger; a claim
    /// never reopens; a claimed subject is paid directly, so its escrow is frozen at what the claim found
    /// until it is settled, and then empty.
    function invariant_claimsAreFinal() public view {
        uint256 n = handler.subjectCount();
        for (uint256 i; i < n; ++i) {
            bytes32 s = _subject(i);
            (, address storedPayee, uint256 escrow, uint64 since) = pages.subjects(s);
            assertEq(escrow, handler.ghostEscrow(s), "escrow");
            (bytes32 pending, address claimant, uint256 price, uint64 at) = pages.claims(s);
            assertEq(pending, handler.ghostPending(s), "pending claim");
            assertEq(claimant, handler.ghostClaimant(s));
            assertEq(price, handler.ghostPrice(s));
            assertEq(at, handler.ghostRequestedAt(s));
            (address owedTo, uint96 owedBack) = pages.settlements(s);
            if (i < handler.HANDLE_OFFSET()) {
                assertEq(storedPayee, address(0), "address subjects never store a payee");
                address expected = s == bytes32(0) ? address(0) : address(uint160(uint256(s)));
                assertEq(pages.payeeOf(s), expected);
                assertEq(owedTo, address(0), "address subjects never settle");
                assertEq(owedBack, 0);
            } else {
                assertEq(storedPayee, handler.ghostPayee(s), "payee never changes once set");
                assertEq(pages.payeeOf(s), handler.ghostPayee(s));
                if (storedPayee != address(0)) {
                    assertEq(pending, bytes32(0), "no claim can be pending on a claimed handle");
                    if (handler.ghostUnsettled(s)) {
                        assertEq(owedTo, handler.ghostSettleTo(s), "the payout waits for settlement");
                        assertEq(owedBack, handler.ghostReimbursed(s));
                        assertLe(owedBack, escrow, "the reimbursement never exceeds the escrow");
                        assertLe(owedBack, pages.MAX_PRICE());
                    } else {
                        assertEq(escrow, 0, "a settled handle holds no escrow");
                        assertEq(owedTo, address(0));
                        assertEq(owedBack, 0);
                    }
                } else {
                    assertEq(owedTo, address(0), "nothing to settle before a claim");
                    assertEq(owedBack, 0);
                }
            }
            if (escrow > 0) assertGt(since, 0, "escrow always has a clock");
        }
        uint256 m = handler.consumedCount();
        for (uint256 i; i < m; ++i) {
            assertTrue(pages.consumed(handler.consumedUuids(i)), "a consumed answer stays consumed");
        }
    }

    /// @dev Fees reach where they are meant to: the pools' 5% (and recycled escrow) sit in the hook's IMD
    /// claims; every wei of burned IMD became MARG at the dead address.
    function invariant_feesReachPoolsAndDead() public view {
        assertEq(_claims(address(hook), address(imd)) - poolsBaseline, handler.ghostPools(), "pools funded");
        uint256 dead = token.balanceOf(pages.DEAD()) - deadBaseline;
        assertEq(dead, handler.ghostMargBurned(), "MARG at dead");
        if (handler.ghostImdBurned() == 0) assertEq(dead, 0, "no burn without a tranche");
        else assertGt(dead, 0, "no tranche without a burn");
    }

    /// @dev Nothing but burns trades on the pool here, so within a block the price never sits past the bound
    /// measured from the block's anchor, and the bound is exactly BURN_SQRT_BPS of the anchor's sqrt price.
    function invariant_burnsNeverPassTheBlocksBound() public view {
        (uint160 limit, uint160 current, bool zeroForOne) = pages.burnLimit();
        uint256 anchor = pages.burnAnchorBlock() == block.number ? pages.burnAnchorSqrtPrice() : current;
        uint256 expected = zeroForOne
            ? anchor * (10_000 - pages.BURN_SQRT_BPS()) / 10_000
            : anchor * (10_000 + pages.BURN_SQRT_BPS()) / 10_000;
        assertEq(limit, expected, "the limit is the anchor moved by the bound");
        assertTrue(zeroForOne ? current >= limit : current <= limit, "the price is inside the bound");
    }
}
