// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarginaliaPages, IMarginaliaHookPages} from "../../src/MarginaliaPages.sol";
import {MarginaliaHook} from "../../src/MarginaliaHook.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Optional integration rehearsal against the existing launch, never a broadcast.
contract PagesMainnetTest is Test {
    MarginaliaHook constant HOOK = MarginaliaHook(0xf0457dD0Cf526686190e4f057Ba19dB14D34a0cc);
    IIntake constant INTAKE = IIntake(0x1397434cd35e8a9C8aC312A61D3A285EB31dea56);
    IERC20 constant IMD = IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    address constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    bytes32 constant ACTION = bytes32("oracle.request@oracle-1");
    MarginaliaPages pages;
    address trader = makeAddr("Pages launch rehearsal trader");
    address author = makeAddr("Pages launch rehearsal author");

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        pages = new MarginaliaPages(IMarginaliaHookPages(address(HOOK)), INTAKE, ACTION, SIGNER);
        deal(address(IMD), trader, 100 ether);
        vm.prank(trader);
        IMD.approve(address(pages), type(uint256).max);
    }

    function testLiveConstantsTradeBurnAndSell() public {
        assertEq(block.chainid, 1);
        assertEq(HOOK.imd(), address(IMD));
        assertEq(HOOK.INTAKE(), address(INTAKE));
        assertEq(HOOK.ACTION(), ACTION);
        assertEq(HOOK.ORACLE_SIGNER(), SIGNER);
        assertTrue(HOOK.initialized());
        uint256 pools = HOOK.thesisPool(HOOK.week()) + HOOK.refundPool(HOOK.today());
        bytes32 subject = pages.subjectOf(author);
        vm.prank(trader);
        pages.buy(subject, 3, 0.66 ether);
        assertEq(pages.reserveOf(subject), 0.6 ether);
        assertEq(IMD.balanceOf(author), 0.054 ether);
        assertEq(HOOK.thesisPool(HOOK.week()) + HOOK.refundPool(HOOK.today()) - pools, 0.003 ether);
        uint256 burn = pages.pendingBurn();
        uint256 deadBefore = IERC20(HOOK.token()).balanceOf(pages.DEAD());
        // Fork quote is fixed within this test; production callers should quote independently.
        uint256 minMarg = burn * 1e18 / HOOK.margPriceInImd() * 98 / 100;
        assertGt(minMarg, 0);
        pages.burnPending(burn, minMarg);
        assertGe(IERC20(HOOK.token()).balanceOf(pages.DEAD()) - deadBefore, minMarg);
        assertEq(IMD.balanceOf(address(pages)), 0.6 ether);
        vm.prank(trader);
        pages.sell(subject, 3, 0.54 ether);
        assertEq(pages.reserveOf(subject), 0);
        assertEq(pages.pagesOf(subject, trader), 0);
        assertEq(IMD.balanceOf(address(pages)), pages.pendingBurn());
    }

    function testLiveIntakeBuysRequestAtExactPrice() public {
        uint256 price = INTAKE.priceOf(ACTION, address(IMD));
        assertGt(price, 0);
        assertLe(price, pages.MAX_PRICE());
        uint256 before = IMD.balanceOf(trader);
        vm.prank(trader);
        bytes32 id = pages.requestClaim("bddnewstoday", 2109295512424009991);
        assertNotEq(id, bytes32(0));
        assertEq(before - IMD.balanceOf(trader), price);
        (bytes32 pending, address claimant, uint256 paid,) =
            pages.claims(pages.subjectOfHandle("bddnewstoday"));
        assertEq(pending, id);
        assertEq(claimant, trader);
        assertEq(paid, price);
        assertEq(IMD.allowance(address(pages), address(INTAKE)), 0);
    }
}
