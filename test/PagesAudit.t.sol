// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {ClaimIntake} from "./Pages.t.sol";
import {MarginaliaPages, IMarginaliaHookPages} from "../src/MarginaliaPages.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Isolates market arithmetic from the pool's int128 deltas for amounts impossible with live IMD.
contract PagesAccountingHook {
    address public immutable imd;

    constructor(address imd_) {
        imd = imd_;
    }

    function fundPot(uint256 amount) external virtual {
        IERC20(imd).transferFrom(msg.sender, address(this), amount);
    }
}

contract PagesReentryHook is PagesAccountingHook {
    bytes public attempt;
    bytes public result;
    bool public succeeded;
    constructor(address imd_) PagesAccountingHook(imd_) {}

    function arm(bytes calldata data) external {
        attempt = data;
    }

    function fundPot(uint256 amount) external override {
        IERC20(imd).transferFrom(msg.sender, address(this), amount);
        (succeeded, result) = msg.sender.call(attempt);
    }
}

/// @dev Regressions for the four reproduced Pages audit findings, using the real local hook/pool.
contract PagesAuditTest is Fixture {
    MarginaliaPages pages;
    ClaimIntake intake;

    function setUp() public {
        _setup();
        intake = new ClaimIntake();
        pages = new MarginaliaPages(
            IMarginaliaHookPages(address(hook)), intake, bytes32("oracle.request@oracle-1"), vm.addr(0x5E7)
        );
        vm.prank(alice);
        imd.approve(address(pages), type(uint256).max);
        vm.prank(bob);
        imd.approve(address(pages), type(uint256).max);
    }

    function _buyPages(bytes32 subject, uint256 amount) internal {
        vm.prank(alice);
        pages.buy(subject, amount, type(uint256).max);
    }

    function testClaimInstructionRequiresThisDeploymentAndChain() public {
        vm.prank(bob);
        pages.requestClaim("BddNewsToday", 2109295512424009991);
        string memory body = string(intake.lastBody());
        string memory question = vm.parseJsonString(body, ".question");
        assertTrue(_contains(question, "is exactly bddnewstoday then"));
        assertTrue(_contains(question, "text is exactly this claim statement"));
        assertTrue(
            _contains(
                question,
                string.concat(
                    "I claim Marginalia pages on chain ",
                    Strings.toString(block.chainid),
                    " at ",
                    Strings.toHexString(address(pages)),
                    " for wallet <wallet>."
                )
            ),
            "a token/donation/scam-address tweet is not a claim"
        );
        assertTrue(_contains(question, "Return only that wallet, not the market address"));
        assertTrue(_contains(question, "no extra text"));
        assertTrue(_contains(question, "answer 0x0000000000000000000000000000000000000000"));
        assertLt(bytes(question).length, 2001, "oracle question length limit");
        assertEq(vm.parseJsonUint(body, ".chainId"), block.chainid);
        assertEq(vm.parseJsonString(body, ".answerType"), "address");
        assertEq(vm.parseJsonString(body, ".evidence"), "panel");
        assertEq(vm.parseJsonUint(body, ".head"), 1);
        assertEq(vm.parseJsonUint(body, ".panelSize"), 5);
        assertEq(vm.parseJsonUint(body, ".quorum"), 4);
        assertEq(vm.parseJsonAddress(body, ".consumer.verifyingContract"), address(pages));
        assertEq(vm.parseJsonStringArray(body, ".guards.sources")[0], "https://cdn.syndication.twimg.com/");
        assertEq(imd.allowance(address(pages), address(intake)), 0);
    }

    function testClaimInstructionChangesAcrossDeploymentsAndChains() public {
        string memory beforeBody = pages.questionBody("writer", 1);
        vm.chainId(block.chainid + 1);
        assertNotEq(pages.questionBody("writer", 1), beforeBody);
        MarginaliaPages other = new MarginaliaPages(
            IMarginaliaHookPages(address(hook)), intake, bytes32("oracle.request@oracle-1"), vm.addr(0x5E7)
        );
        assertNotEq(other.questionBody("writer", 1), pages.questionBody("writer", 1));
    }

    function testEveryHolderCanExitAfterAllLiquidityIsWithdrawn() public {
        bytes32 subject = pages.subjectOf(carol);
        _buyPages(subject, 5);
        vm.prank(bob);
        pages.buy(subject, 2, type(uint256).max);
        liquidity.add(key, -6000, 6000, -10_000_000 ether);
        _exit(subject, alice, 5);
        _exit(subject, bob, 2);
        assertEq(pages.reserveOf(subject), 0);
        (uint256 supply,,,) = pages.subjects(subject);
        assertEq(supply, 0);
        assertEq(imd.balanceOf(address(pages)), pages.pendingBurn());
        // Empty liquidity also does not prevent new page purchases.
        _buyPages(subject, 1);
        assertEq(pages.pagesOf(subject, alice), 1);
    }

    function _exit(bytes32 subject, address holder, uint256 amount) internal {
        (uint256 value, uint256 fee) = pages.sellPrice(subject, amount);
        uint256 before = imd.balanceOf(holder);
        vm.prank(holder);
        pages.sell(subject, amount, value - fee);
        assertEq(imd.balanceOf(holder) - before, value - fee);
        assertEq(pages.pagesOf(subject, holder), 0);
    }

    function testBurnFailureKeepsFundsAndCanResumeAfterLiquidityReturns() public {
        bytes32 subject = pages.subjectOfHandle("escrow");
        _buyPages(subject, 20);
        uint256 reserve = pages.reserveOf(subject);
        (,, uint256 escrow,) = pages.subjects(subject);
        uint256 burn = pages.pendingBurn();
        uint256 dead = token.balanceOf(pages.DEAD());
        liquidity.add(key, -6000, 6000, -10_000_000 ether);
        vm.expectRevert();
        pages.burnPending(burn);
        assertEq(pages.pendingBurn(), burn);
        assertEq(token.balanceOf(pages.DEAD()), dead);
        assertEq(imd.balanceOf(address(pages)), reserve + escrow + burn);
        liquidity.add(key, -6000, 6000, 10_000_000 ether);
        pages.burnPending(burn);
        assertEq(pages.pendingBurn(), 0);
        assertGe(token.balanceOf(pages.DEAD()) - dead, burn * 98 / 100);
        assertEq(imd.balanceOf(address(pages)), reserve + escrow);
        assertEq(pages.reserveOf(subject), reserve);
        (,, uint256 escrowAfter,) = pages.subjects(subject);
        assertEq(escrowAfter, escrow);
    }

    function testBurnAfterAManipulatedPriceStaysBoundedAndCannotBlockTrading() public {
        bytes32 subject = pages.subjectOf(carol);
        _buyPages(subject, 1000);
        uint256 burn = pages.pendingBurn();
        uint256 snap = vm.snapshotState();
        (uint256 spent, uint256 burned) = pages.burnPending(burn);
        assertEq(spent, burn, "at the fixture's depth the whole tranche fits the block's bound");
        assertGe(burned, burn * 98 / 100);
        vm.revertToState(snap);
        _buy(bob, 1_000_000 ether); // MARG now costs far more than the anchor of a later block
        uint256 reserve = pages.reserveOf(subject);
        uint256 before = imd.balanceOf(address(pages));
        (uint160 limit,, bool zeroForOne) = pages.burnLimit();
        (spent, burned) = pages.burnPending(burn);
        // The burn runs at the pushed price (there is no other MARG market) but moves it no further than
        // the bound, and what it did not spend stays pending.
        (, uint160 after_,) = pages.burnLimit();
        assertTrue(zeroForOne ? after_ >= limit : after_ <= limit);
        assertEq(pages.pendingBurn(), burn - spent);
        assertEq(imd.balanceOf(address(pages)), before - spent);
        assertEq(pages.reserveOf(subject), reserve);
        _exit(subject, alice, 1000);
    }

    function testOversizedTrancheFillsUpToTheBlockBoundAndResumesNextBlock() public {
        // Queue more IMD than one block's bound can absorb, without coupling the large page trade to a swap.
        bytes32 subject = pages.subjectOf(carol);
        (uint256 value, uint256 fee) = pages.buyPrice(subject, 200_000);
        imd.mint(alice, value + fee);
        _buyPages(subject, 200_000);
        uint256 burn = pages.pendingBurn();
        uint256 balance = imd.balanceOf(address(pages));
        (uint160 limit, uint160 start, bool zeroForOne) = pages.burnLimit();
        (uint256 spent,) = pages.burnPending(burn);
        assertLt(spent, burn, "the tranche is cut where the price bound is reached");
        assertGt(spent, 0);
        (, uint160 current,) = pages.burnLimit();
        assertEq(current, limit, "the pool stopped exactly at the block's limit");
        assertEq(pages.burnAnchorSqrtPrice(), start);
        assertEq(pages.burnAnchorBlock(), block.number);
        assertEq(pages.pendingBurn(), burn - spent);
        assertEq(imd.balanceOf(address(pages)), balance - spent);
        // The block's budget is spent: a second burn in it is refused by name and nothing moves.
        vm.expectRevert(MarginaliaPages.BurnBudgetSpent.selector);
        pages.burnPending(1 ether);
        (uint160 limit2,,) = pages.burnLimit();
        assertEq(limit2, limit, "the anchor holds for the rest of the block");
        // Next block, the bound is measured from the new price and burning resumes.
        vm.roll(block.number + 1);
        (uint160 limit3,,) = pages.burnLimit();
        assertTrue(zeroForOne ? limit3 < limit : limit3 > limit);
        (uint256 spent2,) = pages.burnPending(pages.pendingBurn());
        assertGt(spent2, 0);
        _exit(subject, alice, 200_000);
        assertEq(pages.reserveOf(subject), 0);
    }

    function testBurnCannotSpendReserveOrEscrow() public {
        _buyPages(pages.subjectOfHandle("writer"), 20);
        uint256 burn = pages.pendingBurn();
        vm.expectRevert(MarginaliaPages.ZeroAmount.selector);
        pages.burnPending(0);
        vm.expectRevert(MarginaliaPages.InsufficientBurn.selector);
        pages.burnPending(burn + 1);
        vm.expectRevert(MarginaliaPages.UnauthorizedCallback.selector);
        pages.unlockCallback(abi.encode(burn));
        vm.prank(address(manager));
        vm.expectRevert(MarginaliaPages.UnauthorizedCallback.selector);
        pages.unlockCallback(abi.encode(burn));
        pages.burnPending(burn);
        vm.expectRevert(MarginaliaPages.InsufficientBurn.selector);
        pages.burnPending(1);
    }

    function testSupplyAndBalancesDoNotTruncateAboveUint64() public {
        // Such prices exceed the live IMD supply and v4's per-operation delta range. Isolate the
        // market's accounting from those external limits, as in the original audit reproducer.
        PagesAccountingHook sink = new PagesAccountingHook(address(imd));
        pages = new MarginaliaPages(
            IMarginaliaHookPages(address(sink)), intake, bytes32("oracle.request@oracle-1"), vm.addr(0x5E7)
        );
        vm.prank(alice);
        imd.approve(address(pages), type(uint256).max);
        bytes32 subject = pages.subjectOf(carol);
        uint256 amount = (uint256(1) << 64) + 3;
        (uint256 value, uint256 fee) = pages.buyPrice(subject, amount);
        imd.mint(alice, value + fee);
        _buyPages(subject, amount);
        (uint256 supply,,,) = pages.subjects(subject);
        assertEq(supply, amount);
        assertEq(pages.pagesOf(subject, alice), amount);
        assertEq(pages.reserveOf(subject), value);
        _exit(subject, alice, amount);
        (supply,,,) = pages.subjects(subject);
        assertEq(supply, 0);
        assertEq(pages.reserveOf(subject), 0);
    }

    function testAbandonCannotReenterATrade() public {
        PagesReentryHook adversary = new PagesReentryHook(address(imd));
        pages = new MarginaliaPages(
            IMarginaliaHookPages(address(adversary)),
            intake,
            bytes32("oracle.request@oracle-1"),
            vm.addr(0x5E7)
        );
        vm.startPrank(alice);
        imd.approve(address(pages), type(uint256).max);
        bytes32 id = pages.requestClaim("waiting", 1);
        vm.stopPrank();
        bytes32 subject = pages.subjectOfHandle("waiting");
        vm.warp(block.timestamp + pages.ANSWER_DEADLINE());
        adversary.arm(abi.encodeCall(pages.abandonClaim, (subject)));
        _buyPages(subject, 1);
        assertFalse(adversary.succeeded());
        assertEq(adversary.result(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        (bytes32 pending,,,) = pages.claims(subject);
        assertEq(pending, id);
        pages.abandonClaim(subject); // The same operation works once the trade has completed.
        (pending,,,) = pages.claims(subject);
        assertEq(pending, bytes32(0));
    }

    function testFuzzReserveCoversAllHoldersWithQueuedBurns(uint16 n, uint16 m, uint16 sold) public {
        uint256 a = bound(n, 1, 1000);
        uint256 b = bound(m, 1, 1000);
        uint256 s = bound(sold, 0, a);
        bytes32 subject = pages.subjectOfHandle("fuzz_writer");
        _buyPages(subject, a);
        vm.prank(bob);
        pages.buy(subject, b, type(uint256).max);
        if (s > 0) {
            vm.prank(alice);
            pages.sell(subject, s, 0);
        }
        (uint256 supply,, uint256 escrow,) = pages.subjects(subject);
        assertEq(supply, a + b - s);
        assertEq(supply, pages.pagesOf(subject, alice) + pages.pagesOf(subject, bob));
        assertEq(pages.reserveOf(subject), pages.priceOf(0, supply));
        assertEq(imd.balanceOf(address(pages)), pages.reserveOf(subject) + escrow + pages.pendingBurn());
        if (a > s) _exit(subject, alice, a - s);
        _exit(subject, bob, b);
        (supply,, escrow,) = pages.subjects(subject);
        assertEq(supply, 0);
        assertEq(pages.reserveOf(subject), 0);
        assertEq(imd.balanceOf(address(pages)), escrow + pages.pendingBurn());
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        for (uint256 i; i + n.length <= h.length; ++i) {
            bool same = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    same = false;
                    break;
                }
            }
            if (same) return true;
        }
        return false;
    }
}
