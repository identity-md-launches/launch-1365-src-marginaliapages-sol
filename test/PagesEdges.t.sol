// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdError} from "forge-std/StdError.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {ClaimIntake} from "./Pages.t.sol";
import {MarginaliaPages, IMarginaliaHookPages} from "../src/MarginaliaPages.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";

/// @dev The inputs the page market did not obviously consider: zero, one wei off, the boundary of every
/// threshold, the same call twice, and callers who are not who the code assumed. Runs against the real local
/// hook and pool, the ClaimIntake stand-in and an EOA signer.
contract PagesEdgesTest is Fixture {
    uint256 constant SIGNER_KEY = 0x5E7;
    bytes32 constant ACTION = bytes32("oracle.request@oracle-1");
    uint256 constant PRICE = 0.5 ether;

    MarginaliaPages pages;
    ClaimIntake intake;
    address dave = makeAddr("dave");

    function setUp() public {
        _setup();
        _fundCarol();
        intake = new ClaimIntake();
        pages = new MarginaliaPages(IMarginaliaHookPages(address(hook)), intake, ACTION, vm.addr(SIGNER_KEY));
        address[3] memory traders = [alice, bob, carol];
        for (uint256 i; i < traders.length; ++i) {
            vm.prank(traders[i]);
            imd.approve(address(pages), type(uint256).max);
        }
    }

    function _pools() internal view returns (uint256) {
        return _claims(address(hook), address(imd));
    }

    function _att(bytes32 uuid, address wallet)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        a.requestId = uuid;
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
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, pages.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _deliver(bytes32 requestId, OracleAttestation.Attestation memory a) internal returns (bool) {
        return intake.deliver(address(pages), requestId, a, _sign(a));
    }

    // ------------------------------------------------------------------ construction

    function testConstructorRefusesEveryZeroInput() public {
        address h = address(hook);
        address s = vm.addr(SIGNER_KEY);
        vm.expectRevert(MarginaliaPages.BadClaim.selector);
        new MarginaliaPages(IMarginaliaHookPages(address(0)), intake, ACTION, s);
        vm.expectRevert(MarginaliaPages.BadClaim.selector);
        new MarginaliaPages(IMarginaliaHookPages(h), IIntake(address(0)), ACTION, s);
        vm.expectRevert(MarginaliaPages.BadClaim.selector);
        new MarginaliaPages(IMarginaliaHookPages(h), intake, bytes32(0), s);
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        new MarginaliaPages(IMarginaliaHookPages(h), intake, ACTION, address(0));
        // the live arguments are stored verbatim and nothing on chain is read
        assertEq(address(pages.hook()), h);
        assertEq(address(pages.intake()), address(intake));
        assertEq(pages.action(), ACTION);
        assertEq(pages.oracleSigner(), s);
    }

    // ------------------------------------------------------------------ trades at the edges

    function testZeroAmountsAndOneWeiOfSlippageAreRefused() public {
        bytes32 subject = pages.subjectOf(carol);
        vm.startPrank(alice);
        vm.expectRevert(MarginaliaPages.ZeroAmount.selector);
        pages.buy(subject, 0, type(uint256).max);
        vm.expectRevert(MarginaliaPages.ZeroAmount.selector);
        pages.sell(subject, 0, 0);
        // nothing held: refused before any price is computed
        vm.expectRevert(MarginaliaPages.InsufficientPages.selector);
        pages.sell(subject, 1, 0);
        pages.buy(subject, 3, type(uint256).max);
        (uint256 value, uint256 fee) = pages.sellPrice(subject, 3);
        vm.expectRevert(MarginaliaPages.Slippage.selector);
        pages.sell(subject, 3, value - fee + 1);
        // one more page than held, even though the supply would cover it after someone else buys
        vm.stopPrank();
        vm.prank(bob);
        pages.buy(subject, 1, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(MarginaliaPages.InsufficientPages.selector);
        pages.sell(subject, 4, 0);
        // the public quote refuses more than the supply
        vm.expectRevert(MarginaliaPages.InsufficientPages.selector);
        pages.sellPrice(subject, 5);
    }

    function testSellFeeIsSplitExactlyLikeABuyFee() public {
        bytes32 subject = pages.subjectOf(carol);
        vm.prank(alice);
        pages.buy(subject, 10, type(uint256).max);
        (uint256 value, uint256 fee) = pages.sellPrice(subject, 4);
        assertEq(value, 0.1 ether * (10 + 9 + 8 + 7));
        assertEq(fee, value / 10);
        uint256 carolBefore = imd.balanceOf(carol);
        uint256 poolsBefore = _pools();
        uint256 burnBefore = pages.pendingBurn();
        uint256 aliceBefore = imd.balanceOf(alice);
        vm.prank(alice);
        pages.sell(subject, 4, value - fee);
        assertEq(imd.balanceOf(alice) - aliceBefore, value - fee);
        assertEq(imd.balanceOf(carol) - carolBefore, fee * 9000 / 10_000, "90% of a sell fee to the issuer");
        assertEq(pages.pendingBurn() - burnBefore, fee * 500 / 10_000, "5% queued for the burn");
        assertEq(
            _pools() - poolsBefore, fee - fee * 9000 / 10_000 - fee * 500 / 10_000, "the rest to the pools"
        );
        assertEq(pages.reserveOf(subject), pages.priceOf(0, 6));
    }

    function testSellingOutEmptiesTheCurveAndTheNextPageCostsBaseAgain() public {
        bytes32 subject = pages.subjectOf(carol);
        vm.prank(alice);
        pages.buy(subject, 7, type(uint256).max);
        (uint256 value, uint256 fee) = pages.sellPrice(subject, 7);
        vm.prank(alice);
        pages.sell(subject, 7, value - fee);
        (uint256 supply,,,) = pages.subjects(subject);
        assertEq(supply, 0);
        assertEq(pages.reserveOf(subject), 0);
        assertEq(imd.balanceOf(address(pages)), pages.pendingBurn(), "only the burn queue is left");
        (uint256 next,) = pages.buyPrice(subject, 1);
        assertEq(next, pages.BASE());
        vm.prank(bob);
        pages.buy(subject, 1, type(uint256).max);
        assertEq(pages.reserveOf(subject), pages.BASE());
    }

    function testSubjectsAreIndependentCurves() public {
        bytes32 a = pages.subjectOf(carol);
        bytes32 b = pages.subjectOfHandle("other");
        vm.startPrank(alice);
        pages.buy(a, 5, type(uint256).max);
        pages.buy(b, 2, type(uint256).max);
        uint256 reserveB = pages.reserveOf(b);
        (,, uint256 escrowB,) = pages.subjects(b);
        pages.buy(a, 20, type(uint256).max);
        pages.sell(a, 25, 0);
        vm.stopPrank();
        assertEq(pages.reserveOf(b), reserveB, "trades on one curve never touch another");
        (uint256 supplyB,, uint256 escrowAfter,) = pages.subjects(b);
        assertEq(supplyB, 2);
        assertEq(escrowAfter, escrowB);
        assertEq(pages.reserveOf(a), 0);
        // and selling pages of b with a's balance is refused
        vm.prank(alice);
        vm.expectRevert(MarginaliaPages.InsufficientPages.selector);
        pages.sell(b, 3, 0);
    }

    function testPriceOverflowRevertsInsteadOfWrapping() public {
        bytes32 subject = pages.subjectOf(carol);
        vm.expectRevert(stdError.arithmeticError);
        pages.priceOf(0, type(uint128).max);
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        pages.buy(subject, type(uint128).max, type(uint256).max);
        assertEq(pages.reserveOf(subject), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzCurveIsAdditiveAndEachPageCostsBaseTimesItsIndex(uint64 supply, uint32 a, uint32 b)
        public
        view
    {
        uint256 s = bound(supply, 0, 1 << 40);
        uint256 x = bound(a, 0, 1 << 20);
        uint256 y = bound(b, 0, 1 << 20);
        assertEq(
            pages.priceOf(s, x) + pages.priceOf(s + x, y),
            pages.priceOf(s, x + y),
            "buying in two steps costs the same"
        );
        assertEq(pages.priceOf(s, 1), pages.BASE() * (s + 1), "the n-th page costs BASE x n");
        assertEq(pages.priceOf(s, 0), 0);
        assertEq(pages.BASE() * x * (2 * s + x + 1) % 2, 0, "the curve integral is exact, no rounding");
    }

    /// forge-config: default.fuzz.runs = 300
    function testFuzzRoundTripAloneAlwaysLosesExactlyTheFees(uint16 n, uint16 before) public {
        uint256 amount = bound(n, 1, 300);
        uint256 depth = bound(before, 0, 300);
        bytes32 subject = pages.subjectOfHandle("writer");
        if (depth > 0) {
            vm.prank(bob);
            pages.buy(subject, depth, type(uint256).max);
        }
        (uint256 buyValue, uint256 buyFee) = pages.buyPrice(subject, amount);
        uint256 start = imd.balanceOf(alice);
        vm.startPrank(alice);
        pages.buy(subject, amount, buyValue + buyFee);
        (uint256 sellValue, uint256 sellFee) = pages.sellPrice(subject, amount);
        pages.sell(subject, amount, sellValue - sellFee);
        vm.stopPrank();
        assertEq(sellValue, buyValue, "the same pages sell back at the price they were bought at");
        assertEq(start - imd.balanceOf(alice), buyFee + sellFee, "a round trip costs exactly the two fees");
        assertEq(pages.reserveOf(subject), pages.priceOf(0, depth));
    }

    // ------------------------------------------------------------------ the zero subject

    function testZeroAddressIssuerEscrowsAndCanOnlyBeRecycled() public {
        bytes32 subject = pages.subjectOf(address(0));
        assertEq(subject, bytes32(0));
        assertEq(pages.payeeOf(subject), address(0), "nobody is paid for the zero address");
        vm.prank(alice);
        pages.buy(subject, 2, type(uint256).max);
        (,, uint256 escrow, uint64 since) = pages.subjects(subject);
        assertEq(escrow, pages.priceOf(0, 2) / 10 * 9000 / 10_000);
        assertEq(since, vm.getBlockTimestamp());
        // no handle hashes to it, so it can never be claimed, and nothing is pending to abandon
        vm.expectRevert(MarginaliaPages.UnknownRequest.selector);
        pages.abandonClaim(subject);
        vm.expectRevert(MarginaliaPages.TooEarly.selector);
        pages.recycle(subject);
        vm.warp(vm.getBlockTimestamp() + pages.CLAIM_WINDOW());
        uint256 poolsBefore = _pools();
        pages.recycle(subject);
        assertEq(_pools() - poolsBefore, escrow);
        // the curve itself still works for its holders
        (uint256 value, uint256 fee) = pages.sellPrice(subject, 2);
        vm.prank(alice);
        pages.sell(subject, 2, value - fee);
        assertEq(pages.reserveOf(subject), 0);
    }

    // ------------------------------------------------------------------ claims at the edges

    function testClaimWithoutAnyEscrowSetsThePayeeAndLaterFeesGoDirect() public {
        bytes32 subject = pages.subjectOfHandle("fresh");
        vm.prank(bob);
        bytes32 id = pages.requestClaim("fresh", 1);
        uint256 bobBefore = imd.balanceOf(bob);
        uint256 carolBefore = imd.balanceOf(carol);
        assertTrue(_deliver(id, _att(keccak256("u1"), carol)));
        assertEq(pages.payeeOf(subject), carol);
        assertEq(imd.balanceOf(bob), bobBefore, "nothing to reimburse from");
        assertEq(imd.balanceOf(carol), carolBefore, "nothing to pay yet");
        (,, uint256 escrow, uint64 since) = pages.subjects(subject);
        assertEq(escrow, 0);
        assertEq(since, 0, "no escrow clock was ever started");
        // the payout record names the asker with nothing to give back, and there is nothing to settle
        (address owedTo, uint96 owedBack) = pages.settlements(subject);
        assertEq(owedTo, bob);
        assertEq(owedBack, 0);
        vm.expectRevert(MarginaliaPages.NothingToSettle.selector);
        pages.settleClaim(subject);
        (, uint256 fee) = pages.buyPrice(subject, 1);
        vm.prank(alice);
        pages.buy(subject, 1, type(uint256).max);
        assertEq(
            imd.balanceOf(carol) - carolBefore, fee * 9000 / 10_000, "paid directly from the first trade"
        );
        (,, escrow, since) = pages.subjects(subject);
        assertEq(escrow, 0);
        assertEq(since, 0);
        vm.warp(vm.getBlockTimestamp() + pages.CLAIM_WINDOW());
        vm.expectRevert(MarginaliaPages.NothingToRecycle.selector);
        pages.recycle(subject);
    }

    function testEscrowExactlyThePriceReimbursesAndPaysTheOwnerNothing() public {
        bytes32 subject = pages.subjectOfHandle("exact");
        vm.prank(alice);
        pages.buy(subject, 1, type(uint256).max);
        (,, uint256 escrow,) = pages.subjects(subject);
        assertEq(escrow, 0.009 ether);
        intake.setPrice(escrow);
        vm.prank(bob);
        bytes32 id = pages.requestClaim("exact", 1);
        uint256 bobBefore = imd.balanceOf(bob);
        uint256 carolBefore = imd.balanceOf(carol);
        assertTrue(_deliver(id, _att(keccak256("u1"), carol)));
        (address owedTo, uint96 owedBack) = pages.settlements(subject);
        assertEq(owedTo, bob);
        assertEq(owedBack, escrow, "the whole escrow is the reimbursement");
        vm.prank(dave); // anyone settles
        pages.settleClaim(subject);
        assertEq(imd.balanceOf(bob) - bobBefore, escrow, "the asker is made whole");
        assertEq(imd.balanceOf(carol), carolBefore, "the owner gets what is left: nothing");
        assertEq(pages.payeeOf(subject), carol);
        (,, escrow,) = pages.subjects(subject);
        assertEq(escrow, 0);
    }

    function testEscrowOneWeiShortOfThePriceGoesWhollyToTheOwner() public {
        bytes32 subject = pages.subjectOfHandle("short");
        vm.prank(alice);
        pages.buy(subject, 1, type(uint256).max);
        (,, uint256 escrow,) = pages.subjects(subject);
        intake.setPrice(escrow + 1);
        vm.prank(bob);
        bytes32 id = pages.requestClaim("short", 1);
        uint256 bobBefore = imd.balanceOf(bob);
        uint256 carolBefore = imd.balanceOf(carol);
        assertTrue(_deliver(id, _att(keccak256("u1"), carol)));
        (, uint96 owedBack) = pages.settlements(subject);
        assertEq(owedBack, 0, "no partial reimbursement is recorded");
        pages.settleClaim(subject);
        assertEq(imd.balanceOf(bob), bobBefore, "no partial reimbursement");
        assertEq(imd.balanceOf(carol) - carolBefore, escrow);
    }

    function testPriceBoundaryAcceptsExactlyOneImdAndRefusesOneWeiMore() public {
        intake.setPrice(pages.MAX_PRICE() + 1);
        vm.prank(bob);
        vm.expectRevert(MarginaliaPages.PriceMismatch.selector);
        pages.requestClaim("cap", 1);
        intake.setPrice(pages.MAX_PRICE());
        uint256 before = imd.balanceOf(bob);
        vm.prank(bob);
        pages.requestClaim("cap", 1);
        assertEq(before - imd.balanceOf(bob), 1 ether);
        (,, uint256 price,) = pages.claims(pages.subjectOfHandle("cap"));
        assertEq(price, 1 ether, "the price paid is the one remembered for reimbursement");
    }

    function testPanelThresholdsAtTheirBoundaries() public {
        bytes32 subject = pages.subjectOfHandle("panel");
        vm.prank(alice);
        pages.buy(subject, 2, type(uint256).max);
        vm.prank(carol);
        bytes32 id = pages.requestClaim("panel", 1);
        OracleAttestation.Attestation memory a = _att(keccak256("u"), carol);
        // refused: quorum below four even when everyone agrees
        a.quorum = 3;
        a.agreed = 5;
        assertFalse(_deliver(id, a));
        // refused: a panel of four with a quorum of four
        a.panelSize = 4;
        a.quorum = 4;
        a.agreed = 4;
        assertFalse(_deliver(id, a));
        // refused: agreement one short of the quorum
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 3;
        assertFalse(_deliver(id, a));
        // refused: zero agreement
        a.agreed = 0;
        assertFalse(_deliver(id, a));
        // refused: issued too far in the future
        a.agreed = 5;
        a.issuedAt = uint64(vm.getBlockTimestamp() + 5 minutes + 1);
        assertFalse(_deliver(id, a));
        a.issuedAt = uint64(vm.getBlockTimestamp());
        // refused: a list answer carrying the right address
        a.answerType = OracleAttestation.ANSWER_ADDRESS_LIST;
        address[] memory list = new address[](1);
        list[0] = carol;
        a.answer = abi.encode(list);
        assertFalse(_deliver(id, a));
        a.answerType = OracleAttestation.ANSWER_ADDRESS;
        a.answer = abi.encode(carol);
        // none of those consumed anything or closed the claim
        assertFalse(pages.consumed(a.requestId));
        (bytes32 pending,,,) = pages.claims(subject);
        assertEq(pending, id);
        // accepted: exactly the minimum, four of five agreeing on a quorum of four
        a.agreed = 4;
        assertTrue(_deliver(id, a));
        assertEq(pages.payeeOf(subject), carol);
    }

    function testLargerPanelsAndQuorumsAreAccepted() public {
        vm.prank(carol);
        bytes32 id = pages.requestClaim("bigpanel", 1);
        OracleAttestation.Attestation memory a = _att(keccak256("u"), carol);
        a.panelSize = 9;
        a.quorum = 7;
        a.agreed = 7;
        assertTrue(_deliver(id, a));
        assertEq(pages.payeeOf(pages.subjectOfHandle("bigpanel")), carol);
    }

    function testUpperCaseRequestClaimsTheLowerCaseSubjectAndAsksAboutTheLowerCaseHandle() public {
        bytes32 subject = pages.subjectOfHandle("mixedcase");
        vm.prank(alice);
        pages.buy(subject, 1, type(uint256).max);
        vm.prank(carol);
        bytes32 id = pages.requestClaim("MixedCase", 77);
        (bytes32 pending,,,) = pages.claims(subject);
        assertEq(pending, id, "the request lands on the lower-cased subject");
        string memory body = string(intake.lastBody());
        assertTrue(vm.contains(body, "is exactly mixedcase then"));
        assertFalse(vm.contains(body, "MixedCase"));
        assertTrue(_deliver(id, _att(keccak256("u"), carol)));
        assertEq(pages.payeeOf(subject), carol);
        assertEq(pages.payeeOf(pages.subjectOfHandle("MIXEDCASE")), carol);
    }

    function testHandleLengthAndCharacterBoundaries() public {
        bytes32 fifteen = pages.subjectOfHandle("abcdefghijklmno");
        assertEq(fifteen, keccak256(abi.encodePacked("x:", "abcdefghijklmno")));
        assertEq(pages.subjectOfHandle("_"), keccak256(abi.encodePacked("x:", "_")));
        assertEq(pages.subjectOfHandle("0"), keccak256(abi.encodePacked("x:", "0")));
        assertEq(pages.subjectOfHandle("ABCDEFGHIJKLMNO"), fifteen);
        vm.expectRevert(MarginaliaPages.BadHandle.selector);
        pages.subjectOfHandle("abcdefghijklmnop");
        vm.expectRevert(MarginaliaPages.BadHandle.selector);
        pages.subjectOfHandle("a-b");
        vm.expectRevert(MarginaliaPages.BadHandle.selector);
        pages.subjectOfHandle("a.b");
        vm.expectRevert(MarginaliaPages.BadHandle.selector);
        pages.subjectOfHandle(unicode"é");
        vm.expectRevert(MarginaliaPages.BadHandle.selector);
        pages.subjectOfHandle("a b");
        vm.prank(carol);
        vm.expectRevert(MarginaliaPages.BadHandle.selector);
        pages.requestClaim("@handle", 1);
    }

    function testEscrowClockSurvivesAFailedClaimAndRecyclingTakesLaterFeesToo() public {
        bytes32 subject = pages.subjectOfHandle("clock");
        uint256 t0 = vm.getBlockTimestamp();
        vm.prank(alice);
        pages.buy(subject, 1, type(uint256).max);
        vm.warp(t0 + 10 days);
        vm.prank(bob);
        bytes32 id = pages.requestClaim("clock", 1);
        assertTrue(_deliver(id, _att(keccak256("u"), address(0))));
        (,, uint256 escrow1, uint64 since) = pages.subjects(subject);
        assertEq(since, t0, "a failed claim does not restart the window");
        vm.warp(t0 + 89 days);
        vm.prank(alice);
        pages.buy(subject, 1, type(uint256).max);
        (,, uint256 escrow2, uint64 since2) = pages.subjects(subject);
        assertEq(since2, t0, "a later buy does not restart it either");
        assertGt(escrow2, escrow1);
        vm.warp(t0 + pages.CLAIM_WINDOW() - 1);
        vm.expectRevert(MarginaliaPages.TooEarly.selector);
        pages.recycle(subject);
        vm.warp(t0 + pages.CLAIM_WINDOW());
        uint256 poolsBefore = _pools();
        pages.recycle(subject);
        assertEq(_pools() - poolsBefore, escrow2, "the fee from a day-old buy is recycled with the rest");
        // the clock restarts with the next escrowed fee
        vm.prank(alice);
        pages.buy(subject, 1, type(uint256).max);
        (,, uint256 escrow3, uint64 since3) = pages.subjects(subject);
        assertGt(escrow3, 0);
        assertEq(since3, vm.getBlockTimestamp());
    }

    function testClaimedHandleIsClosedToEveryLaterClaimPath() public {
        bytes32 subject = pages.subjectOfHandle("done");
        vm.prank(alice);
        pages.buy(subject, 3, type(uint256).max);
        vm.prank(carol);
        bytes32 id = pages.requestClaim("done", 1);
        assertTrue(_deliver(id, _att(keccak256("u"), carol)));
        vm.warp(vm.getBlockTimestamp() + pages.CLAIM_WINDOW() + pages.ANSWER_DEADLINE());
        vm.expectRevert(MarginaliaPages.NothingToRecycle.selector);
        pages.recycle(subject);
        vm.expectRevert(MarginaliaPages.UnknownRequest.selector);
        pages.abandonClaim(subject);
        vm.prank(bob);
        vm.expectRevert(MarginaliaPages.AlreadyClaimed.selector);
        pages.requestClaim("DONE", 2);
        // a fresh signed answer naming someone else is refused too: there is no request to answer
        assertFalse(_deliver(id, _att(keccak256("u2"), bob)));
        assertEq(pages.payeeOf(subject), carol);
    }

    function testAnyoneMayAbandonExactlyAtTheDeadlineAndTheAskerIsNotRefunded() public {
        bytes32 subject = pages.subjectOfHandle("late");
        uint256 t0 = vm.getBlockTimestamp();
        vm.prank(bob);
        pages.requestClaim("late", 1);
        uint256 bobAfterAsking = imd.balanceOf(bob);
        vm.warp(t0 + pages.ANSWER_DEADLINE() - 1);
        vm.prank(dave);
        vm.expectRevert(MarginaliaPages.TooEarly.selector);
        pages.abandonClaim(subject);
        vm.warp(t0 + pages.ANSWER_DEADLINE());
        vm.prank(dave);
        pages.abandonClaim(subject);
        assertEq(imd.balanceOf(bob), bobAfterAsking, "the price stays with the Intake");
        vm.prank(dave);
        vm.expectRevert(MarginaliaPages.UnknownRequest.selector);
        pages.abandonClaim(subject);
    }

    function testCallbackFromTheIntakeForAnotherConsumersRequestIsRefused() public {
        // a second market shares the Intake and the signer; its request id must not route into this one
        MarginaliaPages other =
            new MarginaliaPages(IMarginaliaHookPages(address(hook)), intake, ACTION, vm.addr(SIGNER_KEY));
        vm.startPrank(carol);
        imd.approve(address(other), type(uint256).max);
        bytes32 foreign = other.requestClaim("shared", 1);
        bytes32 ours = pages.requestClaim("shared", 1);
        vm.stopPrank();
        OracleAttestation.Attestation memory a = _att(keccak256("u"), carol);
        assertFalse(intake.deliver(address(pages), foreign, a, _sign(a)), "an id this market never issued");
        // and an answer signed in the other market's domain does not verify here
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, other.attestationDigest(a));
        assertFalse(intake.deliver(address(pages), ours, a, abi.encodePacked(r, s, v)));
        assertEq(pages.payeeOf(pages.subjectOfHandle("shared")), address(0));
        assertTrue(_deliver(ours, a));
        assertEq(pages.payeeOf(pages.subjectOfHandle("shared")), carol);
    }

    function testColdClaimAgainstTheRealHookFitsTheStipend() public {
        // both recipients start with zero IMD, the first escrow payout and the first reimbursement
        address owner = makeAddr("owner");
        bytes32 subject = pages.subjectOfHandle("cold");
        vm.prank(alice);
        pages.buy(subject, 20, type(uint256).max);
        imd.transfer(dave, PRICE);
        vm.startPrank(dave);
        imd.approve(address(pages), PRICE);
        bytes32 id = pages.requestClaim("cold", 1);
        vm.stopPrank();
        assertEq(imd.balanceOf(dave), 0);
        assertEq(imd.balanceOf(owner), 0);
        (,, uint256 escrow,) = pages.subjects(subject);
        assertTrue(_deliver(id, _att(keccak256("u"), owner)), "200k stipend with the live hook's imd() read");
        assertEq(imd.balanceOf(dave), 0, "the callback pays nobody");
        assertEq(imd.balanceOf(owner), 0);
        // settlement by a stranger pays both cold balances
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        pages.settleClaim(subject);
        assertEq(imd.balanceOf(dave), PRICE);
        assertEq(imd.balanceOf(owner), escrow - PRICE);
        assertEq(imd.balanceOf(stranger), 0, "the settler earns nothing");
    }

    // ------------------------------------------------------------------ settlement

    function testOwnerWhoAskedCollectsEscrowAndReimbursementInOneSettlement() public {
        bytes32 subject = pages.subjectOfHandle("selfask");
        vm.prank(alice);
        pages.buy(subject, 20, type(uint256).max);
        (,, uint256 escrow,) = pages.subjects(subject);
        assertGt(escrow, PRICE);
        uint256 carolBefore = imd.balanceOf(carol);
        vm.prank(carol);
        bytes32 id = pages.requestClaim("selfask", 1);
        assertTrue(_deliver(id, _att(keccak256("u"), carol)));
        assertEq(imd.balanceOf(carol), carolBefore - PRICE, "the callback moves nothing");
        pages.settleClaim(subject);
        assertEq(
            imd.balanceOf(carol), carolBefore - PRICE + escrow, "the price back plus the rest: all of it"
        );
        vm.expectRevert(MarginaliaPages.NothingToSettle.selector);
        pages.settleClaim(subject);
    }

    function testClaimedButUnsettledHandleIsClosedToEveryOtherPathAndFrozen() public {
        bytes32 subject = pages.subjectOfHandle("frozen");
        vm.prank(alice);
        pages.buy(subject, 20, type(uint256).max);
        (,, uint256 escrow, uint64 since) = pages.subjects(subject);
        vm.prank(bob);
        bytes32 id = pages.requestClaim("frozen", 1);
        assertTrue(_deliver(id, _att(keccak256("u"), carol)));
        // between the callback and the settlement nothing else can touch the claim or its escrow
        vm.prank(bob);
        vm.expectRevert(MarginaliaPages.AlreadyClaimed.selector);
        pages.requestClaim("frozen", 2);
        vm.expectRevert(MarginaliaPages.UnknownRequest.selector);
        pages.abandonClaim(subject);
        vm.warp(vm.getBlockTimestamp() + pages.CLAIM_WINDOW() + 1);
        vm.expectRevert(MarginaliaPages.NothingToRecycle.selector);
        pages.recycle(subject);
        // trades pay carol directly and the escrow keeps its clock and amount
        uint256 carolBefore = imd.balanceOf(carol);
        (, uint256 fee) = pages.sellPrice(subject, 5);
        vm.prank(alice);
        pages.sell(subject, 5, 0);
        assertEq(imd.balanceOf(carol) - carolBefore, fee * 9000 / 10_000);
        (,, uint256 held, uint64 stillSince) = pages.subjects(subject);
        assertEq(held, escrow);
        assertEq(stillSince, since);
        // the settlement pays exactly what the claim found: the later trade did not change it
        uint256 bobBefore = imd.balanceOf(bob);
        carolBefore = imd.balanceOf(carol);
        pages.settleClaim(subject);
        assertEq(imd.balanceOf(bob) - bobBefore, PRICE);
        assertEq(imd.balanceOf(carol) - carolBefore, escrow - PRICE);
        (,, held, stillSince) = pages.subjects(subject);
        assertEq(held, 0);
        assertEq(stillSince, 0);
        assertEq(imd.balanceOf(address(pages)), pages.reserveOf(subject) + pages.pendingBurn());
    }

    // ------------------------------------------------------------------ the escrow window's edge

    function testAccrualOneSecondBeforeTheWindowEndsKeepsTheClockAndAtItRestartsIt() public {
        bytes32 keeps = pages.subjectOfHandle("keeps");
        bytes32 restarts = pages.subjectOfHandle("restarts");
        uint256 t0 = vm.getBlockTimestamp();
        vm.startPrank(alice);
        pages.buy(keeps, 1, type(uint256).max);
        pages.buy(restarts, 1, type(uint256).max);
        (,, uint256 dust,) = pages.subjects(keeps);
        vm.warp(t0 + pages.CLAIM_WINDOW() - 1);
        pages.buy(keeps, 10, type(uint256).max);
        (,, uint256 escrowKeeps, uint64 sinceKeeps) = pages.subjects(keeps);
        assertEq(sinceKeeps, t0, "inside the window the first buy's clock stands");
        vm.warp(t0 + pages.CLAIM_WINDOW());
        pages.buy(restarts, 10, type(uint256).max);
        (,, uint256 escrowRestarts, uint64 sinceRestarts) = pages.subjects(restarts);
        assertEq(sinceRestarts, t0 + pages.CLAIM_WINDOW(), "at the window's end a new accrual restarts it");
        assertEq(escrowRestarts, escrowKeeps, "the same accruals in both");
        assertGt(escrowRestarts, dust);
        vm.stopPrank();
        // the one that kept its clock is recyclable now, the whole amount; the restarted one waits a window
        uint256 poolsBefore = _pools();
        pages.recycle(keeps);
        assertEq(_pools() - poolsBefore, escrowKeeps);
        vm.expectRevert(MarginaliaPages.TooEarly.selector);
        pages.recycle(restarts);
        vm.warp(t0 + 2 * pages.CLAIM_WINDOW() - 1);
        vm.expectRevert(MarginaliaPages.TooEarly.selector);
        pages.recycle(restarts);
        vm.warp(t0 + 2 * pages.CLAIM_WINDOW());
        poolsBefore = _pools();
        pages.recycle(restarts);
        assertEq(_pools() - poolsBefore, escrowRestarts, "the old dust is recycled with the new accrual");
    }

    // ------------------------------------------------------------------ the burn's block budget

    /// @dev A block burns once: the tranche anchors at the price it finds, the limit is that anchor moved by
    /// the bound, and a second tranche in the block is refused by name although the price is still inside the
    /// bound. The next block anchors afresh at the moved price and burns the rest.
    function testBurnLimitIsTheAnchorMovedByTheBoundAndABlockBurnsOnce() public {
        bytes32 subject = pages.subjectOf(carol);
        vm.prank(alice);
        pages.buy(subject, 100, type(uint256).max);
        (uint160 limit, uint160 current, bool zeroForOne) = pages.burnLimit();
        assertTrue(pages.burnAnchorBlock() != block.number, "no anchor before the block's burn");
        uint256 expected = zeroForOne
            ? uint256(current) * (10_000 - pages.BURN_SQRT_BPS()) / 10_000
            : uint256(current) * (10_000 + pages.BURN_SQRT_BPS()) / 10_000;
        assertEq(limit, expected, "a fresh block measures from the current price");
        uint256 half = pages.pendingBurn() / 2;
        (uint256 spent,) = pages.burnPending(half);
        assertEq(spent, half);
        assertEq(pages.burnAnchorBlock(), block.number);
        assertEq(pages.burnAnchorSqrtPrice(), current, "the anchor is the price the burn found");
        (uint160 limit2, uint160 moved,) = pages.burnLimit();
        assertEq(limit2, limit, "the limit holds for the rest of the block");
        assertTrue(zeroForOne ? moved < current : moved > current, "the burn moved the price");
        assertTrue(zeroForOne ? moved > limit : moved < limit, "but not past the bound");
        uint256 rest = pages.pendingBurn();
        assertGt(rest, 0);
        // the price is inside the bound, yet the block has burned: every further tranche is refused by name
        vm.expectRevert(MarginaliaPages.BurnBudgetSpent.selector);
        pages.burnPending(rest);
        vm.expectRevert(MarginaliaPages.BurnBudgetSpent.selector);
        pages.burnPending(1);
        assertEq(pages.pendingBurn(), rest, "a refused tranche stays queued");
        assertEq(pages.burnAnchorSqrtPrice(), current, "a refusal does not move the anchor");
        // the next block anchors at the moved price and the rest fits its bound
        vm.roll(block.number + 1);
        (uint160 limit3, uint160 current3,) = pages.burnLimit();
        assertEq(current3, moved, "a new block measures from where the last burn left the price");
        assertTrue(zeroForOne ? limit3 < limit : limit3 > limit, "so its limit is past the old one");
        (spent,) = pages.burnPending(rest);
        assertEq(spent, rest);
        assertEq(pages.pendingBurn(), 0);
        assertEq(pages.burnAnchorBlock(), block.number);
        assertEq(pages.burnAnchorSqrtPrice(), moved);
    }

    function testABlockThatBurnedRefusesAgainAfterAnExternalPushAndTheNextBlockAnchorsAtThePushedPrice()
        public
    {
        bytes32 subject = pages.subjectOf(carol);
        vm.prank(alice);
        pages.buy(subject, 100, type(uint256).max);
        uint256 pending = pages.pendingBurn();
        (uint256 spent,) = pages.burnPending(pending / 4);
        assertEq(spent, pending / 4);
        (uint160 limit,, bool zeroForOne) = pages.burnLimit();
        // somebody else buys MARG hard in the same block: the price passes the burn's bound on its own
        _buy(bob, 1_000_000 ether);
        (, uint160 pushed,) = pages.burnLimit();
        assertTrue(zeroForOne ? pushed < limit : pushed > limit);
        uint256 left = pages.pendingBurn();
        vm.expectRevert(MarginaliaPages.BurnBudgetSpent.selector);
        pages.burnPending(left);
        vm.expectRevert(MarginaliaPages.BurnBudgetSpent.selector);
        pages.burnPending(1);
        assertEq(pages.pendingBurn(), left, "nothing left the queue");
        // the next block anchors at the pushed price and burns again, at that price
        vm.roll(block.number + 1);
        (uint160 limit2, uint160 current2,) = pages.burnLimit();
        assertEq(current2, pushed);
        assertTrue(zeroForOne ? limit2 < pushed : limit2 > pushed);
        (spent,) = pages.burnPending(left);
        assertEq(spent, left, "a small tranche fits the new block's bound");
        assertEq(pages.pendingBurn(), 0);
    }

    function testBurnPendingRefusesZeroAndOneWeiOverTheQueue() public {
        vm.expectRevert(MarginaliaPages.InsufficientBurn.selector);
        pages.burnPending(1); // an empty queue
        bytes32 subject = pages.subjectOf(carol);
        vm.prank(alice);
        pages.buy(subject, 1, type(uint256).max);
        uint256 pending = pages.pendingBurn();
        assertEq(pending, 0.1 ether / 10 * 500 / 10_000);
        vm.expectRevert(MarginaliaPages.ZeroAmount.selector);
        pages.burnPending(0);
        vm.expectRevert(MarginaliaPages.InsufficientBurn.selector);
        pages.burnPending(pending + 1);
        vm.expectRevert(MarginaliaPages.InsufficientBurn.selector);
        pages.burnPending(type(uint256).max);
        (uint256 spent, uint256 burned) = pages.burnPending(pending);
        assertEq(spent, pending);
        assertGt(burned, 0);
        vm.expectRevert(MarginaliaPages.InsufficientBurn.selector);
        pages.burnPending(1);
    }

    function testStrangersCannotCallTheCallbacksOrMoveValue() public {
        bytes32 subject = pages.subjectOfHandle("guarded");
        vm.prank(alice);
        pages.buy(subject, 1, type(uint256).max);
        vm.prank(carol);
        bytes32 id = pages.requestClaim("guarded", 1);
        OracleAttestation.Attestation memory a = _att(keccak256("u"), carol);
        bytes memory sig = _sign(a);
        // a perfectly good answer from anyone but the Intake
        vm.prank(carol);
        vm.expectRevert(MarginaliaPages.OnlyIntake.selector);
        pages.onOracleResult(id, a, sig);
        vm.prank(vm.addr(SIGNER_KEY));
        vm.expectRevert(MarginaliaPages.OnlyIntake.selector);
        pages.onOracleResult(id, a, sig);
        // the pool manager's callback outside a burn, from the manager itself and from anyone else
        bytes memory tranche = abi.encode(pages.pendingBurn());
        vm.prank(address(manager));
        vm.expectRevert(MarginaliaPages.UnauthorizedCallback.selector);
        pages.unlockCallback(tranche);
        vm.prank(address(hook));
        vm.expectRevert(MarginaliaPages.UnauthorizedCallback.selector);
        pages.unlockCallback(tranche);
        // the market has no privileged surface at all: nothing to pause, own or upgrade
        (bool ok,) = address(pages).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(pages).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok);
        (ok,) = address(pages).call(abi.encodeWithSignature("setOracleSigner(address)", carol));
        assertFalse(ok);
        assertEq(pages.oracleSigner(), vm.addr(SIGNER_KEY));
    }
}
