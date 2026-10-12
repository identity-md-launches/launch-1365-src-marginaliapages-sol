// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {MarginaliaPages, IMarginaliaHookPages} from "../src/MarginaliaPages.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Stands in for the Intake: takes the price, records the body, and delivers an attestation back to the
/// consumer under the protocol's 200k callback stipend, reporting whether the callback succeeded.
contract ClaimIntake is IIntake {
    uint256 public price = 0.5 ether;
    uint256 public requests;
    bytes public lastBody;
    bytes32 public lastRequestId;

    function setPrice(uint256 p) external {
        price = p;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId)
    {
        require(amount >= price, "PriceNotMet");
        require(callback.target == msg.sender, "callback target");
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        requests += 1;
        lastBody = body;
        requestId = keccak256(abi.encode(requests, body));
        lastRequestId = requestId;
    }

    function deliver(
        address target,
        bytes32 requestId,
        OracleAttestation.Attestation calldata a,
        bytes calldata sig
    ) external returns (bool ok) {
        (ok,) = target.call{gas: 200_000}(abi.encodeCall(MarginaliaPages.onOracleResult, (requestId, a, sig)));
    }
}

/// @dev The page market against the local hook: curve math, fee split (issuer / MARG burn / pools), no cap,
/// handle escrow, oracle-attested claims, abandonment, recycling, and that pages never move.
contract PagesTest is Fixture {
    MarginaliaPages pages;
    ClaimIntake intake;
    uint256 constant SIGNER_KEY = 0x5E7;
    bytes32 constant ACTION = bytes32("oracle.request@oracle-1");
    address signerAddr;

    function setUp() public {
        _setup();
        signerAddr = vm.addr(SIGNER_KEY);
        intake = new ClaimIntake();
        pages = new MarginaliaPages(IMarginaliaHookPages(address(hook)), intake, ACTION, signerAddr);
        vm.prank(alice);
        imd.approve(address(pages), type(uint256).max);
        vm.prank(bob);
        imd.approve(address(pages), type(uint256).max);
        _fundCarol();
        vm.prank(carol);
        imd.approve(address(pages), type(uint256).max);
    }

    function _pools() internal view returns (uint256) {
        return hook.refundPool(hook.today()) + hook.thesisPool(hook.week());
    }

    // ------------------------------------------------------------------ curve and fees (unchanged)

    function testCurveIsLinear() public view {
        assertEq(pages.priceOf(0, 1), 0.1 ether);
        assertEq(pages.priceOf(1, 1), 0.2 ether);
        assertEq(pages.priceOf(0, 3), 0.6 ether); // 0.1 + 0.2 + 0.3
        assertEq(pages.priceOf(99, 1), 10 ether); // the 100th key
        assertEq(pages.priceOf(0, 200), 0.1 ether * 200 * 201 / 2); // two hundred pages
    }

    function testBuyPaysTheIssuerQueuesBoundedBurnAndFundsThePools() public {
        bytes32 subject = pages.subjectOf(carol);
        (uint256 value, uint256 fee) = pages.buyPrice(subject, 3);
        assertEq(value, 0.6 ether);
        assertEq(fee, 0.06 ether);
        uint256 carolBefore = imd.balanceOf(carol);
        uint256 poolsBefore = _pools();
        uint256 deadBefore = token.balanceOf(pages.DEAD());
        uint256 aliceBefore = imd.balanceOf(alice);
        vm.prank(alice);
        pages.buy(subject, 3, value + fee);
        assertEq(aliceBefore - imd.balanceOf(alice), value + fee);
        assertEq(pages.pagesOf(subject, alice), 3);
        assertEq(pages.reserveOf(subject), value, "the curve reserve holds the value, never the fee");
        assertEq(imd.balanceOf(carol) - carolBefore, fee * 9000 / 10_000, "90% of the fee to the issuer");
        assertEq(_pools() - poolsBefore, fee * 500 / 10_000, "5% of the fee to the pools");
        uint256 burn = fee * 500 / 10_000;
        assertEq(pages.pendingBurn(), burn, "5% of the fee is reserved for burning");
        assertEq(token.balanceOf(pages.DEAD()), deadBefore, "trades do not depend on a swap");
        assertEq(imd.balanceOf(address(pages)), value + burn, "reserve plus segregated burn funds");
        // At the fixture's 1:1 price and depth the tranche fills whole, losing only the pool's 1.25% LP fee.
        (uint256 spent, uint256 burned) = pages.burnPending(burn);
        assertEq(spent, burn);
        assertEq(token.balanceOf(pages.DEAD()) - deadBefore, burned);
        assertGe(burned, burn * 98 / 100);
        assertEq(pages.pendingBurn(), 0);
        assertEq(imd.balanceOf(address(pages)), value, "a burn never spends the reserve");
    }

    function testSellReturnsTheCurveLessFeeAndPagesAreNotTransferable() public {
        bytes32 subject = pages.subjectOf(carol);
        vm.prank(alice);
        pages.buy(subject, 5, type(uint256).max);
        vm.prank(bob);
        pages.buy(subject, 2, type(uint256).max);
        (uint256 value, uint256 fee) = pages.sellPrice(subject, 2);
        assertEq(value, 1.3 ether); // the top two prices, 0.7 + 0.6
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        pages.sell(subject, 2, value - fee);
        assertEq(imd.balanceOf(alice) - before, value - fee);
        assertEq(pages.pagesOf(subject, alice), 3);
        (uint256 supply,,,) = pages.subjects(subject);
        assertEq(supply, 5);
        vm.prank(bob);
        vm.expectRevert(MarginaliaPages.InsufficientPages.selector);
        pages.sell(subject, 3, 0);
        (uint256 all,) = pages.sellPrice(subject, 5);
        assertEq(pages.reserveOf(subject), all, "the reserve always covers every holder selling out");
    }

    function testSlippageAndNoCap() public {
        bytes32 subject = pages.subjectOf(carol);
        (uint256 value, uint256 fee) = pages.buyPrice(subject, 1);
        uint256 shy = value + fee - 1;
        vm.prank(alice);
        vm.expectRevert(MarginaliaPages.Slippage.selector);
        pages.buy(subject, 1, shy);
        // there is no cap: a deep run is just a higher price (the 1000th page costs 100 IMD)
        imd.mint(alice, 100_000 ether);
        vm.prank(alice);
        pages.buy(subject, 1000, type(uint256).max);
        assertEq(pages.pagesOf(subject, alice), 1000);
        assertEq(pages.priceOf(999, 1), 100 ether);
        (uint256 all,) = pages.sellPrice(subject, 1000);
        assertEq(pages.reserveOf(subject), all, "the reserve covers every holder selling out at any depth");
        vm.prank(bob);
        pages.buy(subject, 1, type(uint256).max); // the 1001st page is open to the next buyer
        assertEq(pages.pagesOf(subject, bob), 1);
    }

    // ------------------------------------------------------------------ handles

    function testHandleIsLowerCasedAndValidated() public {
        assertEq(pages.subjectOfHandle("BlkNoiz06"), pages.subjectOfHandle("blknoiz06"));
        assertEq(pages.subjectOfHandle("a_B9"), keccak256(abi.encodePacked("x:", "a_b9")));
        vm.expectRevert(MarginaliaPages.BadHandle.selector);
        pages.subjectOfHandle("@blknoiz06");
        vm.expectRevert(MarginaliaPages.BadHandle.selector);
        pages.subjectOfHandle("");
        vm.expectRevert(MarginaliaPages.BadHandle.selector);
        pages.subjectOfHandle("sixteen_chars_xx");
        vm.expectRevert(MarginaliaPages.BadHandle.selector);
        pages.subjectOfHandle("no spaces");
    }

    function _att(bytes32 requestId, address wallet)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        a.requestId = requestId;
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

    /// @dev Pages of an unclaimed handle escrow the issuer's share; the panel's answer names the wallet, which
    /// collects the escrow less the oracle price reimbursed to whoever asked, and is paid from then on.
    function testEscrowThenOracleAttestedClaim() public {
        bytes32 subject = pages.subjectOfHandle("blknoiz06");
        assertEq(pages.payeeOf(subject), address(0));
        vm.prank(alice);
        pages.buy(subject, 20, type(uint256).max); // 21 IMD of pages → 2.1 fee → 1.89 escrow, above the oracle price
        (uint256 supply, address payee, uint256 escrow, uint64 since) = pages.subjects(subject);
        assertEq(supply, 20);
        assertEq(payee, address(0));
        assertEq(escrow, pages.priceOf(0, 20) * 1000 / 10_000 * 9000 / 10_000);
        assertGt(escrow, 0.5 ether);
        assertEq(since, vm.getBlockTimestamp());
        // carol (the handle's owner) asks, paying the price up front
        uint256 carolBefore = imd.balanceOf(carol);
        vm.prank(carol);
        bytes32 requestId = pages.requestClaim("BlkNoiz06", 2109295512424009991);
        assertEq(carolBefore - imd.balanceOf(carol), 0.5 ether, "the claimant fronts the oracle price");
        assertEq(intake.requests(), 1);
        string memory body = string(intake.lastBody());
        assertTrue(_contains(body, "tweet-result?id=2109295512424009991&token=a"), "the body names the tweet");
        assertTrue(_contains(body, "is exactly blknoiz06 then"), "the body names the normalized handle");
        assertTrue(_contains(body, '"answerType":"address"'));
        assertTrue(_contains(body, '"guards":{"sources":["https://cdn.syndication.twimg.com/"]}'));
        (bytes32 rid, address claimant, uint256 price, uint64 at) = pages.claims(subject);
        assertEq(rid, requestId);
        assertEq(claimant, carol);
        assertEq(price, 0.5 ether);
        assertEq(at, vm.getBlockTimestamp());
        // a second request for the same subject waits for the first
        vm.prank(bob);
        vm.expectRevert(MarginaliaPages.ClaimPending.selector);
        pages.requestClaim("blknoiz06", 1);
        // the panel answers carol's wallet
        OracleAttestation.Attestation memory a = _att(requestId, carol);
        bool ok = intake.deliver(address(pages), requestId, a, _sign(a));
        assertTrue(ok, "the callback fits the Intake's 200k stipend");
        assertEq(pages.payeeOf(subject), carol);
        // the callback only verified and stored; anyone settles the payout in a later call
        (address owedTo, uint256 reimbursed) = pages.settlements(subject);
        assertEq(owedTo, carol);
        assertEq(reimbursed, 0.5 ether);
        assertEq(imd.balanceOf(carol), carolBefore - 0.5 ether, "nothing is paid inside the callback");
        vm.prank(bob);
        pages.settleClaim(subject);
        assertEq(
            imd.balanceOf(carol) - carolBefore,
            escrow - 0.5 ether,
            "the owner nets the escrow less the oracle price, which the escrow paid"
        );
        (,, uint256 escrowLeft,) = pages.subjects(subject);
        assertEq(escrowLeft, 0);
        vm.expectRevert(MarginaliaPages.NothingToSettle.selector);
        pages.settleClaim(subject);
        (rid,,,) = pages.claims(subject);
        assertEq(rid, bytes32(0), "the claim is closed");
        assertTrue(pages.consumed(a.requestId));
        // replaying the same signed answer is refused
        ok = intake.deliver(address(pages), requestId, a, _sign(a));
        assertFalse(ok, "callback replay");
        // the next trade pays carol directly
        (, uint256 fee2) = pages.buyPrice(subject, 1);
        uint256 before = imd.balanceOf(carol);
        vm.prank(bob);
        pages.buy(subject, 1, type(uint256).max);
        assertEq(imd.balanceOf(carol) - before, fee2 * 9000 / 10_000);
        // and a claimed handle cannot be asked about again
        vm.prank(bob);
        vm.expectRevert(MarginaliaPages.AlreadyClaimed.selector);
        pages.requestClaim("blknoiz06", 1);
    }

    /// @dev A stranger's bogus claim costs the stranger: the panel answers zero, the escrow is untouched, the
    /// handle can be asked about again at once, and a third party who asks correctly is reimbursed from escrow.
    function testBogusClaimCostsOnlyTheClaimantAndIsRetriable() public {
        bytes32 subject = pages.subjectOfHandle("ghost");
        vm.prank(alice);
        pages.buy(subject, 20, type(uint256).max); // escrow 1.89 IMD, above the oracle price
        (,, uint256 escrow,) = pages.subjects(subject);
        uint256 bobBefore = imd.balanceOf(bob);
        vm.prank(bob);
        bytes32 requestId = pages.requestClaim("ghost", 42);
        OracleAttestation.Attestation memory a = _att(requestId, address(0));
        assertTrue(intake.deliver(address(pages), requestId, a, _sign(a)));
        assertEq(pages.payeeOf(subject), address(0));
        (,, uint256 escrowAfter,) = pages.subjects(subject);
        assertEq(escrowAfter, escrow, "a failed claim never touches the escrow");
        assertEq(bobBefore - imd.balanceOf(bob), 0.5 ether, "the bogus claimant paid the oracle");
        // retry at once, by a third party on the owner's behalf: the third party is reimbursed, carol is paid
        bobBefore = imd.balanceOf(bob);
        uint256 carolBefore = imd.balanceOf(carol);
        vm.prank(bob);
        requestId = pages.requestClaim("ghost", 43);
        a = _att(requestId, carol);
        assertTrue(intake.deliver(address(pages), requestId, a, _sign(a)));
        assertEq(pages.payeeOf(subject), carol);
        pages.settleClaim(subject);
        assertEq(imd.balanceOf(bob), bobBefore, "the asker got the price back from the escrow");
        assertEq(
            imd.balanceOf(carol) - carolBefore, escrow - 0.5 ether, "the owner nets the escrow less the price"
        );
    }

    /// @dev Tiny escrow: the price is not reimbursed and the owner gets what is there.
    function testSmallEscrowIsPaidWithoutReimbursement() public {
        bytes32 subject = pages.subjectOfHandle("tiny");
        vm.prank(alice);
        pages.buy(subject, 1, type(uint256).max); // 0.1 IMD value → 0.01 fee → 0.009 escrow
        (,, uint256 escrow,) = pages.subjects(subject);
        assertLt(escrow, 0.5 ether);
        uint256 carolBefore = imd.balanceOf(carol);
        vm.prank(carol);
        bytes32 requestId = pages.requestClaim("tiny", 7);
        OracleAttestation.Attestation memory a = _att(requestId, carol);
        assertTrue(intake.deliver(address(pages), requestId, a, _sign(a)));
        pages.settleClaim(subject);
        assertEq(imd.balanceOf(carol), carolBefore - 0.5 ether + escrow);
    }

    /// @dev Bad answers are refused without closing the claim: wrong signer, wrong chain, thin panel, wrong type,
    /// an unknown request, a caller that is not the Intake, and an expired attestation.
    function testRejectedAnswersDoNotCloseTheClaim() public {
        bytes32 subject = pages.subjectOfHandle("strict");
        vm.prank(alice);
        pages.buy(subject, 2, type(uint256).max);
        vm.prank(carol);
        bytes32 requestId = pages.requestClaim("strict", 9);
        OracleAttestation.Attestation memory a = _att(requestId, carol);
        bytes memory sig = _sign(a);
        // not the intake
        vm.expectRevert(MarginaliaPages.OnlyIntake.selector);
        pages.onOracleResult(requestId, a, sig);
        // tampered after signing
        a.figure = 1;
        assertFalse(intake.deliver(address(pages), requestId, a, sig));
        a.figure = 0;
        // wrong chain
        a.chainId = 999;
        assertFalse(intake.deliver(address(pages), requestId, a, _sign(a)));
        a.chainId = block.chainid;
        // thin panel / no agreement
        a.panelSize = 2;
        a.quorum = 2;
        a.agreed = 2;
        assertFalse(intake.deliver(address(pages), requestId, a, _sign(a)));
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 3;
        assertFalse(intake.deliver(address(pages), requestId, a, _sign(a)));
        a.agreed = 5;
        // wrong answer type
        a.answerType = OracleAttestation.ANSWER_BYTES32;
        a.answer = abi.encode(bytes32(uint256(uint160(carol))));
        assertFalse(intake.deliver(address(pages), requestId, a, _sign(a)));
        a.answerType = OracleAttestation.ANSWER_ADDRESS;
        a.answer = abi.encode(carol);
        // unknown request id
        assertFalse(intake.deliver(address(pages), keccak256("other"), a, _sign(a)));
        // expired
        a.expiresAt = uint64(vm.getBlockTimestamp() - 1);
        assertFalse(intake.deliver(address(pages), requestId, a, _sign(a)));
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
        // the claim is still open and a good answer still lands
        (bytes32 rid,,,) = pages.claims(subject);
        assertEq(rid, requestId);
        assertTrue(intake.deliver(address(pages), requestId, a, _sign(a)));
        assertEq(pages.payeeOf(subject), carol);
    }

    /// @dev An unanswered claim is abandoned after the deadline, a late delivery is then refused, and the
    /// subject can be asked about again. Recycling waits for a pending claim.
    function testAbandonAfterDeadlineAndRecycleWaitsForPendingClaims() public {
        bytes32 subject = pages.subjectOfHandle("quiet");
        vm.prank(alice);
        pages.buy(subject, 4, type(uint256).max);
        (,, uint256 escrow,) = pages.subjects(subject);
        vm.prank(carol);
        bytes32 requestId = pages.requestClaim("quiet", 5);
        vm.expectRevert(MarginaliaPages.TooEarly.selector);
        pages.abandonClaim(subject);
        // 90 days pass with the claim still open: no recycling over a live claim
        vm.warp(vm.getBlockTimestamp() + pages.CLAIM_WINDOW());
        vm.expectRevert(MarginaliaPages.ClaimPending.selector);
        pages.recycle(subject);
        pages.abandonClaim(subject);
        OracleAttestation.Attestation memory a = _att(requestId, carol);
        assertFalse(intake.deliver(address(pages), requestId, a, _sign(a)), "a late delivery is refused");
        assertEq(pages.payeeOf(subject), address(0));
        // now recycling works, and a later claim still works, it just has no escrow left
        uint256 poolsBefore = _pools();
        pages.recycle(subject);
        assertEq(_pools() - poolsBefore, escrow);
        vm.expectRevert(MarginaliaPages.NothingToRecycle.selector);
        pages.recycle(subject);
        vm.prank(carol);
        requestId = pages.requestClaim("quiet", 6);
        a = _att(requestId, carol);
        assertTrue(intake.deliver(address(pages), requestId, a, _sign(a)));
        assertEq(pages.payeeOf(subject), carol);
    }

    function testPriceGuardAndAddressSubjectsNeedNoClaim() public {
        intake.setPrice(2 ether);
        vm.prank(carol);
        vm.expectRevert(MarginaliaPages.PriceMismatch.selector);
        pages.requestClaim("pricey", 1);
        intake.setPrice(0);
        vm.prank(carol);
        vm.expectRevert(MarginaliaPages.PriceMismatch.selector);
        pages.requestClaim("pricey", 1);
        assertEq(pages.payeeOf(pages.subjectOf(carol)), carol);
    }

    function testOnlyThePoolManagerMayCallBack() public {
        vm.expectRevert(MarginaliaPages.UnauthorizedCallback.selector);
        pages.unlockCallback(abi.encode(uint256(1)));
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i + n.length <= h.length; ++i) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
