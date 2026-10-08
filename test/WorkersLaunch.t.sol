// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Workers, ILaunchFactory} from "../src/Workers.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {WorkersFixture} from "./WorkersFixtures.sol";

contract WorkersLaunchTest is WorkersFixture {
    function test_LaunchDistributionWorksBeforeFeeConfiguration() public {
        factory.registerDistributor(LAUNCH_NUMBER, address(distributor));
        uint256 swarm = SUPPLY / 10;
        uint256 liquidity = SUPPLY / 2;
        _fund(address(distributor), swarm);
        _fund(address(manager), liquidity);
        _fund(admin, SUPPLY - swarm - liquidity);
        distributor.send(token, alice, swarm);
        assertEq(token.balanceOf(alice), swarm);
        assertEq(token.balanceOf(address(distributor)), 0);
        assertEq(token.balanceOf(address(manager)), liquidity);
        assertEq(token.balanceOf(admin), SUPPLY - swarm - liquidity);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_FactoryTransfersAreExactEvenToRegisteredVenues() public {
        _configure();
        _fund(address(venue), 100 ether);
        assertEq(token.balanceOf(address(venue)), 100 ether);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_SeedAndPoolManagerBuySellSettlementAreExactWithFeesActive() public {
        _configure();
        _fund(address(manager), SUPPLY / 2);
        manager.send(token, alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        vm.prank(alice);
        token.transfer(address(manager), 100 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(manager)), SUPPLY / 2);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_PoolManagerTransfersToAndFromRegisteredVenuesPayFee() public {
        _configure();
        _fund(address(manager), 100 ether);
        manager.send(token, address(venue), 100 ether);
        assertEq(token.balanceOf(address(venue)), 98 ether);
        assertEq(token.balanceOf(treasury), 2 ether);
        venue.send(token, address(manager), 98 ether);
        assertEq(token.balanceOf(address(venue)), 0);
        assertEq(token.balanceOf(address(manager)), 96.04 ether);
        assertEq(token.balanceOf(treasury), 3.96 ether);
    }

    function test_PoolManagerTransferFromSpendsGrossAllowanceAndPaysVenueFee() public {
        _configure();
        _fund(alice, 100 ether);
        vm.prank(alice);
        token.approve(address(manager), 100 ether);
        vm.prank(address(manager));
        token.transferFrom(alice, address(venue), 100 ether);
        assertEq(token.balanceOf(address(venue)), 98 ether);
        assertEq(token.allowance(alice, address(manager)), 0);
        assertEq(token.balanceOf(treasury), 2 ether);
    }

    function test_DistributorResolvedAfterDeploymentAndClaimsStayExact() public {
        _configure();
        assertEq(token.launchDistributor(), address(0));
        factory.registerDistributor(LAUNCH_NUMBER, address(distributor));
        uint256 swarm = SUPPLY / 10;
        _fund(address(distributor), swarm);
        assertEq(token.launchDistributor(), address(distributor));
        // Claim directly into a taxable contract wallet/venue.
        distributor.send(token, address(venue), swarm);
        assertEq(token.balanceOf(address(venue)), swarm);
        assertEq(token.balanceOf(address(distributor)), 0);
        venue.send(token, address(distributor), swarm);
        assertEq(token.balanceOf(address(distributor)), swarm);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_LateDistributorRegistrationOverridesEarlierVenueClassification() public {
        _configure();
        _fund(address(venue), 100 ether);
        factory.registerDistributor(LAUNCH_NUMBER, address(venue));
        venue.send(token, alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_OtherLaunchDistributorIsNotExempt() public {
        _configure();
        factory.registerDistributor(LAUNCH_NUMBER + 1, address(venue));
        _fund(address(venue), 100 ether);
        venue.send(token, alice, 100 ether);
        assertEq(token.balanceOf(alice), 98 ether);
        assertEq(token.balanceOf(treasury), 2 ether);
    }

    function test_RegistryFailureRevertsVenueTransfersButAllowsPlainSettlement() public {
        _configure();
        _fund(alice, 100 ether);
        _fund(address(venue), 100 ether);
        vm.mockCallRevert(
            address(factory), abi.encodeCall(ILaunchFactory.distributorOf, (LAUNCH_NUMBER)), "registry unavailable"
        );
        vm.expectRevert(Workers.DistributorLookupFailed.selector);
        venue.send(token, alice, 100 ether);
        assertEq(token.balanceOf(address(venue)), 100 ether);
        assertEq(token.balanceOf(treasury), 0);
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
        vm.expectRevert(Workers.DistributorLookupFailed.selector);
        venue.send(token, address(manager), 100 ether);
        assertEq(token.balanceOf(address(venue)), 100 ether);
        vm.prank(bob);
        token.transfer(address(manager), 100 ether);
        assertEq(token.balanceOf(address(manager)), 100 ether);
        manager.send(token, alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_ExemptAndPrivilegedCallersStillNeedHolderAllowance() public {
        _configure();
        _fund(alice, 100 ether);
        factory.registerDistributor(LAUNCH_NUMBER, address(distributor));
        address[4] memory callers = [address(factory), address(manager), address(distributor), admin];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, callers[i], 0, 1));
            token.transferFrom(alice, callers[i], 1);
        }
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function test_NoExternalMintBurnFreezeSeizureOrUpgradePowers() public {
        _configure();
        _fund(alice, 100 ether);
        bytes[12] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", alice, 1 ether),
            abi.encodeWithSignature("mint(uint256)", 1 ether),
            abi.encodeWithSignature("mint()"),
            abi.encodeWithSignature("burn(uint256)", 1 ether),
            abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1 ether),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("freeze(address)", alice),
            abi.encodeWithSignature("blacklist(address)", alice),
            abi.encodeWithSignature("seize(address)", alice),
            abi.encodeWithSignature("upgradeTo(address)", alice),
            abi.encodeWithSignature("initialize(address)", alice),
            abi.encodeWithSignature("setFee(uint256)", 10_000)
        ];
        address[3] memory callers = [admin, address(factory), bob];
        for (uint256 i; i < callers.length; ++i) {
            for (uint256 j; j < calls.length; ++j) {
                vm.prank(callers[i]);
                (bool ok,) = address(token).call(calls[j]);
                assertFalse(ok);
                assertEq(token.totalSupply(), SUPPLY);
                assertEq(token.balanceOf(alice), 100 ether);
            }
        }
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
    }

    function test_RuntimeContainsNoForbiddenOpcodesAndFitsDeploymentLimit() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden runtime opcode");
        }
    }
}
