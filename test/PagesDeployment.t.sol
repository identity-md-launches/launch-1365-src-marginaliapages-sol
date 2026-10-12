// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarginaliaPages} from "../src/MarginaliaPages.sol";

contract PagesDeploymentFactory {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
        require(deployed != address(0), "constructor failed");
    }
}

contract PagesDeploymentTest is Test {
    address constant HOOK = 0xf0457dD0Cf526686190e4f057Ba19dB14D34a0cc;
    address constant INTAKE = 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56;
    address constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    bytes32 constant ACTION = 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000;

    function testFactoryDeploysOnlyPagesWithoutExistingChainState() public {
        vm.chainId(1);
        assertEq(HOOK.code.length, 0);
        assertEq(INTAKE.code.length, 0);
        assertEq(SIGNER.code.length, 0);
        PagesDeploymentFactory factory = new PagesDeploymentFactory();
        bytes memory code =
            abi.encodePacked(type(MarginaliaPages).creationCode, abi.encode(HOOK, INTAKE, ACTION, SIGNER));
        assertLe(code.length, 49_152);
        bytes32 salt = keccak256("Pages deployment rehearsal");
        address predicted = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(code))))
            )
        );
        address deployed = factory.deploy(code, salt);
        assertEq(deployed, predicted);
        MarginaliaPages pages = MarginaliaPages(deployed);
        assertEq(address(pages.hook()), HOOK);
        assertEq(address(pages.intake()), INTAKE);
        assertEq(pages.action(), ACTION);
        assertEq(pages.oracleSigner(), SIGNER);
        assertEq(pages.BASE(), 0.1 ether);
        assertEq(pages.FEE_BPS(), 1000);
        assertEq(pages.ISSUER_BPS(), 9000);
        assertEq(pages.BURN_BPS(), 500);
        assertEq(pages.MAX_PRICE(), 1 ether);
        assertEq(pages.ANSWER_DEADLINE(), 3 days);
        assertEq(pages.CLAIM_WINDOW(), 90 days);
        bytes memory runtime = deployed.code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
