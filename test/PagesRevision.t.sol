// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {ClaimIntake} from "./Pages.t.sol";
import {MarginaliaPages, IMarginaliaHookPages} from "../src/MarginaliaPages.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

/// @dev Regressions for the independent review of the accepted Pages launch: the burn's on-chain price bound
/// against a sandwich, the escrow window restart, the verify-and-store callback with a separate settlement,
/// the refused self subjects and the dust-tranche error. The pool is re-seeded at the live pool's depth.
contract PagesRevisionTest is Fixture {
    MarginaliaPages pages;
    ClaimIntake intake;
    uint256 constant SIGNER_KEY = 0x5E7;

    function setUp() public {
        _setup();
        intake = new ClaimIntake();
        pages = new MarginaliaPages(
            IMarginaliaHookPages(address(hook)),
            intake,
            bytes32("oracle.request@oracle-1"),
            vm.addr(SIGNER_KEY)
        );
        vm.prank(alice);
        imd.approve(address(pages), type(uint256).max);
        vm.prank(bob);
        imd.approve(address(pages), type(uint256).max);
        _fundCarol();
        vm.prank(carol);
        imd.approve(address(pages), type(uint256).max);
        // About 6k IMD of depth in range, the order of the live launch pool.
        liquidity.add(key, -6000, 6000, -10_000_000 ether);
        liquidity.add(key, -6000, 6000, 6_000 ether);
    }

    function _att(bytes32 requestId, address wallet)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        a.requestId = keccak256(abi.encode("uuid", requestId));
        a.chainId = block.chainid;
        a.questionHash = keccak256("q");
        a.answerType = OracleAttestation.ANSWER_ADDRESS;
        a.answer = abi.encode(wallet);
        a.fromBlock = uint64(block.number - 10);
        a.toBlock = uint64(block.number);
        a.blockHash = blockhash(block.number - 1);
        a.panelJobId = keccak256("job");
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, pages.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Burn everything pending within the current block: tranches until the block's bound refuses.
    function _burnThisBlock() internal returns (uint256 burned) {
        for (uint256 i; i < 50 && pages.pendingBurn() > 0; ++i) {
            (uint160 limit, uint160 current, bool z) = pages.burnLimit();
            if (z ? current <= limit : current >= limit) break;
            (, uint256 b) = pages.burnPending(pages.pendingBurn());
            burned += b;
        }
    }

    // ------------------------------------------------------------------ the burn's on-chain floor

    /// @dev The reviewer's sandwich: push the price, burn the whole pending budget at the pushed price, sell back.
    /// With the per-block bound the burn moves the price at most ~1%, below the attacker's round-trip fees, so
    /// every size of the attack loses money and the burn budget stays in the pool.
    function testSandwichingTheBurnLosesMoneyAtEverySize() public {
        bytes32 subject = pages.subjectOf(carol);
        vm.prank(alice);
        pages.buy(subject, 1550, type(uint256).max);
        uint256 pending = pages.pendingBurn();
        assertEq(pending, 601.0125 ether);
        uint256[4] memory sizes = [uint256(400 ether), 700 ether, 1000 ether, 1400 ether];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 bobBefore = imd.balanceOf(bob);
            uint256 marg = _buy(bob, sizes[i]);
            uint256 burned = _burnThisBlock();
            _sell(bob, marg);
            assertLt(imd.balanceOf(bob), bobBefore, "the sandwich loses after LP and hook fees");
            assertGt(burned, 0);
            assertGt(pages.pendingBurn(), 0, "the bound cut the tranche; the rest waits for later blocks");
            vm.revertToState(snap);
        }
    }

    /// @dev Honest burning across blocks spends the whole budget at the market's price: splitting an exact-input
    /// swap over blocks yields the same MARG as one unbounded swap would have.
    function testBoundedBurnsAcrossBlocksBurnTheWholeBudgetAtMarket() public {
        bytes32 subject = pages.subjectOf(carol);
        vm.prank(alice);
        pages.buy(subject, 1550, type(uint256).max);
        uint256 pending = pages.pendingBurn();
        uint256 deadBefore = token.balanceOf(pages.DEAD());
        (uint160 limit0, uint160 start0, bool z) = pages.burnLimit();
        uint256 blocks;
        uint256 start = block.number;
        while (pages.pendingBurn() > 0) {
            _burnThisBlock();
            ++blocks;
            vm.roll(start + blocks);
            assertLt(blocks, 60, "the budget drains in a bounded number of blocks");
        }
        assertEq(imd.balanceOf(address(pages)), pages.reserveOf(subject));
        uint256 burned = token.balanceOf(pages.DEAD()) - deadBefore;
        // One unbounded exact-input swap of the same budget burns 540.077 MARG at this depth (the reviewer's
        // honest baseline); the bounded tranches burn the same within rounding.
        assertApproxEqRel(burned, 540.077219517261780476 ether, 0.0001e18);
        assertGt(blocks, 1, "a budget of this size spans several blocks");
        // Each block moved the price at most the bound from its anchor.
        assertTrue(z ? limit0 < start0 : limit0 > start0);
        assertEq(pending, 601.0125 ether);
    }

    /// @dev A burn cannot be used as a free lever on MARG's spot price: one block moves it at most ~1%.
    function testOneBlockOfBurningMovesThePriceAtMostTheBound() public {
        bytes32 subject = pages.subjectOf(carol);
        vm.prank(alice);
        pages.buy(subject, 1550, type(uint256).max);
        uint256 priceBefore = hook.margPriceInImd();
        _burnThisBlock();
        uint256 priceAfter = hook.margPriceInImd();
        assertGt(priceAfter, priceBefore);
        assertLe(priceAfter, priceBefore * 1_010_025 / 1_000_000 + 1); // (1 + 0.5%)^2 on the sqrt price
        (uint160 limit, uint160 current,) = pages.burnLimit();
        assertEq(current, limit);
    }

    /// @dev A tranche the pool's fee rounds away is refused by name, and the wei stay pending.
    function testDustTrancheIsRefusedByName() public {
        bytes32 subject = pages.subjectOf(carol);
        vm.prank(alice);
        pages.buy(subject, 1, type(uint256).max);
        uint256 pending = pages.pendingBurn();
        (bool ok, bytes memory data) = address(pages).call(abi.encodeCall(pages.burnPending, (1)));
        assertFalse(ok);
        assertTrue(_has(data, MarginaliaPages.NothingBurned.selector), "named, not UnauthorizedCallback");
        assertFalse(_has(data, MarginaliaPages.UnauthorizedCallback.selector));
        assertEq(pages.pendingBurn(), pending);
        (uint256 spent,) = pages.burnPending(pending);
        assertEq(spent, pending);
    }

    // ------------------------------------------------------------------ escrow window

    /// @dev Escrow landing after the window has elapsed opens a new window: a recycler cannot sweep a fresh
    /// accrual the moment it lands, so the owner's claim still finds it (and pays the oracle from it).
    function testAccrualAfterTheWindowOpensANewWindowInsteadOfBeingRecyclableAtOnce() public {
        bytes32 subject = pages.subjectOfHandle("writer");
        vm.prank(alice);
        pages.buy(subject, 1, type(uint256).max);
        (,, uint256 dust, uint64 since) = pages.subjects(subject);
        assertEq(since, block.timestamp);
        vm.warp(block.timestamp + 91 days);
        // The dust alone is recyclable now, but a new accrual restarts the window for the whole escrow.
        vm.prank(bob);
        pages.buy(subject, 100, type(uint256).max);
        (,, uint256 escrow, uint64 since2) = pages.subjects(subject);
        assertGt(escrow, dust + 45 ether);
        assertEq(since2, block.timestamp, "the window restarted at the first accrual after it elapsed");
        vm.expectRevert(MarginaliaPages.TooEarly.selector);
        pages.recycle(subject);
        // The owner claims and the escrow pays for it.
        uint256 carolBefore = imd.balanceOf(carol);
        vm.prank(carol);
        bytes32 requestId = pages.requestClaim("writer", 1);
        OracleAttestation.Attestation memory a = _att(requestId, carol);
        assertTrue(intake.deliver(address(pages), requestId, a, _sign(a)));
        pages.settleClaim(subject);
        assertEq(imd.balanceOf(carol) - carolBefore, escrow - 0.5 ether);
        // Within a window, an accrual does not restart it: 90 days after the restart the escrow is recyclable.
        bytes32 other = pages.subjectOfHandle("other");
        vm.prank(alice);
        pages.buy(other, 1, type(uint256).max);
        (,,, uint64 s0) = pages.subjects(other);
        vm.warp(block.timestamp + 89 days);
        vm.prank(bob);
        pages.buy(other, 100, type(uint256).max);
        (,,, uint64 s1) = pages.subjects(other);
        assertEq(s1, s0, "an accrual inside the window keeps the first buy's window");
        vm.warp(uint256(s0) + 90 days);
        pages.recycle(other);
    }

    // ------------------------------------------------------------------ verify-and-store callback

    /// @dev The callback stores the payout instead of making two live-token transfers inside the Intake's
    /// 200k stipend; settlement is a separate permissionless call, and the escrow is frozen in between.
    function testCallbackOnlyVerifiesAndStoresThenAnyoneSettles() public {
        bytes32 subject = pages.subjectOfHandle("writer");
        vm.prank(alice);
        pages.buy(subject, 20, type(uint256).max);
        (,, uint256 escrow,) = pages.subjects(subject);
        address asker = makeAddr("asker");
        imd.transfer(asker, 0.5 ether);
        vm.startPrank(asker);
        imd.approve(address(pages), 0.5 ether);
        bytes32 requestId = pages.requestClaim("writer", 1);
        vm.stopPrank();
        address wallet = makeAddr("fresh wallet");
        OracleAttestation.Attestation memory a = _att(requestId, wallet);
        bytes memory sig = _sign(a);
        uint256 before = gasleft();
        bool ok = intake.deliver(address(pages), requestId, a, sig);
        uint256 used = before - gasleft();
        assertTrue(ok);
        emit log_named_uint("delivery gas including the mock Intake's overhead", used);
        assertLt(
            used, 160_000, "no token transfer inside the stipend: well under 200k even on a dearer token"
        );
        assertEq(imd.balanceOf(asker), 0);
        assertEq(imd.balanceOf(wallet), 0);
        assertEq(pages.payeeOf(subject), wallet);
        (,, uint256 held,) = pages.subjects(subject);
        assertEq(held, escrow, "the escrow waits for settlement");
        // Trades in between pay the payee directly and never touch the frozen escrow; recycling refuses it.
        vm.prank(bob);
        pages.buy(subject, 1, type(uint256).max);
        (,, held,) = pages.subjects(subject);
        assertEq(held, escrow);
        assertGt(imd.balanceOf(wallet), 0);
        vm.expectRevert(MarginaliaPages.NothingToRecycle.selector);
        pages.recycle(subject);
        uint256 walletBefore = imd.balanceOf(wallet);
        vm.prank(carol);
        pages.settleClaim(subject);
        assertEq(imd.balanceOf(asker), 0.5 ether, "the asker is reimbursed from the escrow");
        assertEq(imd.balanceOf(wallet) - walletBefore, escrow - 0.5 ether, "the owner takes the rest");
        (,, held,) = pages.subjects(subject);
        assertEq(held, 0);
        vm.expectRevert(MarginaliaPages.NothingToSettle.selector);
        pages.settleClaim(subject);
        // Unclaimed and address subjects have nothing to settle.
        bytes32 nobody = pages.subjectOfHandle("nobody");
        bytes32 carolSubject = pages.subjectOf(carol);
        vm.expectRevert(MarginaliaPages.NothingToSettle.selector);
        pages.settleClaim(nobody);
        vm.expectRevert(MarginaliaPages.NothingToSettle.selector);
        pages.settleClaim(carolSubject);
    }

    // ------------------------------------------------------------------ self subjects

    /// @dev Neither this market nor the hook can be an issuer: their share would strand outside every balance.
    function testMarketAndHookCannotBeSubjects() public {
        bytes32 self = pages.subjectOf(address(pages));
        bytes32 hookSubject = pages.subjectOf(address(hook));
        bytes32 carolSubject = pages.subjectOf(carol);
        assertEq(pages.payeeOf(self), address(pages));
        vm.startPrank(alice);
        vm.expectRevert(MarginaliaPages.BadSubject.selector);
        pages.buy(self, 1, type(uint256).max);
        vm.expectRevert(MarginaliaPages.BadSubject.selector);
        pages.buy(hookSubject, 1, type(uint256).max);
        pages.buy(carolSubject, 1, type(uint256).max); // any other address still works
        vm.stopPrank();
        assertEq(imd.balanceOf(address(pages)), pages.reserveOf(carolSubject) + pages.pendingBurn());
    }

    function _has(bytes memory data, bytes4 sel) internal pure returns (bool) {
        for (uint256 i; i + 4 <= data.length; ++i) {
            if (bytes4(bytes.concat(data[i], data[i + 1], data[i + 2], data[i + 3])) == sel) return true;
        }
        return false;
    }
}
