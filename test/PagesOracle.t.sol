// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ClaimIntake} from "./Pages.t.sol";
import {PagesAccountingHook} from "./PagesAudit.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MarginaliaPages, IMarginaliaHookPages} from "../src/MarginaliaPages.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

/// @dev The protocol vector has a bytes32[] answer. Exercise its signature separately from Pages'
/// application-specific address decoder, retaining the exact domain, message and signature.
contract PagesSignatureHarness is MarginaliaPages {
    constructor(IMarginaliaHookPages h, IIntake i, bytes32 a, address s) MarginaliaPages(h, i, a, s) {}

    function verify(OracleAttestation.Attestation calldata a, bytes calldata sig) external view {
        _verifyAttestation(a, sig);
    }
}

contract PagesOracleTest is Test {
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;
    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";
    bytes32 constant ACTION = bytes32("oracle.request@oracle-1");

    MockERC20 imd;
    PagesAccountingHook hook;
    ClaimIntake intake;
    MarginaliaPages pages;
    address asker = makeAddr("asker");
    address wallet = makeAddr("wallet");
    bytes32 subject;
    bytes32 requestId;
    bytes signature;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        imd = new MockERC20("IMD", "IMD", 100 ether);
        hook = new PagesAccountingHook(address(imd));
        intake = new ClaimIntake();
        deployCodeTo(
            "MarginaliaPages.sol:MarginaliaPages", abi.encode(hook, intake, ACTION, SIGNER), VECTOR_CONSUMER
        );
        pages = MarginaliaPages(VECTOR_CONSUMER);
        subject = pages.subjectOfHandle("writer");
        imd.approve(address(pages), type(uint256).max);
        pages.buy(subject, 20, type(uint256).max);
        // Both recipients start the callback with zero IMD balances, the expensive SSTORE case.
        imd.transfer(asker, 0.5 ether);
        vm.startPrank(asker);
        imd.approve(address(pages), 0.5 ether);
        requestId = pages.requestClaim("writer", 123);
        vm.stopPrank();
        signature = _sign(_answer());
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function _answer() internal view returns (OracleAttestation.Attestation memory a) {
        a = vector();
        a.chainId = VECTOR_CHAIN;
        a.answerType = OracleAttestation.ANSWER_ADDRESS;
        a.answer = abi.encode(wallet);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, pages.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function testDigestMatchesProtocolVector() public view {
        assertEq(pages.attestationDigest(vector()), VECTOR_DIGEST);
        assertEq(pages.onOracleResult.selector, bytes4(keccak256(bytes(CALLBACK))));
    }

    function testProtocolSignatureVerifiesUnchanged() public {
        deployCodeTo(
            "PagesOracle.t.sol:PagesSignatureHarness",
            abi.encode(hook, intake, ACTION, SIGNER),
            VECTOR_CONSUMER
        );
        PagesSignatureHarness(VECTOR_CONSUMER).verify(vector(), VECTOR_SIGNATURE);
    }

    function testColdCallbackPaysTwoFreshBalancesUnderStipendWithDistinctIds() public {
        OracleAttestation.Attestation memory a = _answer();
        assertNotEq(a.requestId, requestId, "oracle UUID and Intake id intentionally differ");
        uint256 before = gasleft();
        bool ok = intake.deliver(address(pages), requestId, a, signature);
        emit log_named_uint("delivery gas including mock Intake overhead", before - gasleft());
        assertTrue(ok, "200,000 gas callback stipend");
        assertEq(pages.payeeOf(subject), wallet);
        assertEq(imd.balanceOf(asker), 0.5 ether);
        assertEq(imd.balanceOf(wallet), 1.39 ether);
        assertTrue(pages.consumed(a.requestId));
        assertFalse(intake.deliver(address(pages), requestId, a, signature));
    }

    function testSignedUuidCannotReplayAgainstAnotherPendingIntakeId() public {
        OracleAttestation.Attestation memory a = _answer();
        assertTrue(intake.deliver(address(pages), requestId, a, signature));
        bytes32 other = pages.requestClaim("other_writer", 124);
        assertFalse(intake.deliver(address(pages), other, a, signature));
        assertEq(pages.payeeOf(pages.subjectOfHandle("other_writer")), address(0));
        (bytes32 pending,,,) = pages.claims(pages.subjectOfHandle("other_writer"));
        assertEq(pending, other);
    }

    function testAnswersForUnrequestedIdsAndOtherConsumersAreRefused() public {
        OracleAttestation.Attestation memory a = _answer();
        assertFalse(intake.deliver(address(pages), keccak256("unsolicited"), a, signature));
        MarginaliaPages other =
            new MarginaliaPages(IMarginaliaHookPages(address(hook)), intake, ACTION, SIGNER);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, other.attestationDigest(a));
        assertFalse(intake.deliver(address(pages), requestId, a, abi.encodePacked(r, s, v)));
        assertTrue(intake.deliver(address(pages), requestId, a, signature));
    }

    function testAbandonBoundaryInvalidatesOldRoutingAndAllowsRetry() public {
        vm.warp(ISSUED_AT + 3 days - 1);
        vm.expectRevert(MarginaliaPages.TooEarly.selector);
        pages.abandonClaim(subject);
        vm.warp(ISSUED_AT + 3 days);
        pages.abandonClaim(subject);
        bytes32 fresh = pages.requestClaim("writer", 125);
        OracleAttestation.Attestation memory a = _answer();
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
        assertFalse(intake.deliver(address(pages), requestId, a, _sign(a)));
        (bytes32 pending,,,) = pages.claims(subject);
        assertEq(pending, fresh);
        a.requestId = keccak256("new oracle UUID");
        assertTrue(intake.deliver(address(pages), fresh, a, _sign(a)));
    }
}
