// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Workers, ILaunchFactory} from "../src/Workers.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {WorkersFixture} from "./WorkersFixtures.sol";

contract WorkersConfigurationTest is WorkersFixture {
    function test_ConstructorRejectsFactoryAsOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(factory)));
        factory.deploy(address(manager), LAUNCH_NUMBER, address(factory));
    }

    function test_ConstructorRejectsPoolManagerAsOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(manager)));
        factory.deploy(address(manager), LAUNCH_NUMBER, address(manager));
    }

    function test_FeeRecipientRejectsFactory() public {
        _assertInvalidRecipient(address(factory));
    }

    function test_FeeRecipientRejectsPoolManager() public {
        _assertInvalidRecipient(address(manager));
    }

    function test_FeeRecipientRejectsDistributor() public {
        factory.registerDistributor(LAUNCH_NUMBER, address(distributor));
        _assertInvalidRecipient(address(distributor));
    }

    function test_FeeRecipientRejectsRegisteredVenue() public {
        _configure();
        _assertInvalidRecipient(address(venue));
    }

    function test_ExistingFeeRecipientCannotBecomeVenue() public {
        vm.startPrank(admin);
        token.setFeeRecipient(address(venue));
        vm.expectRevert(abi.encodeWithSelector(Workers.InvalidTradeVenue.selector, address(venue)));
        token.setTradeVenue(address(venue), true);
        vm.stopPrank();
    }

    function test_RecipientUpdateRequiresWorkingRegistryAndPreservesPreviousSettingOnFailure() public {
        _configure();
        vm.mockCallRevert(
            address(factory), abi.encodeCall(ILaunchFactory.distributorOf, (LAUNCH_NUMBER)), "registry unavailable"
        );
        vm.prank(admin);
        vm.expectRevert(Workers.DistributorLookupFailed.selector);
        token.setFeeRecipient(bob);
        assertEq(token.feeRecipient(), treasury);
        vm.clearMockedCalls();
        vm.prank(admin);
        token.setFeeRecipient(bob);
        assertEq(token.feeRecipient(), bob);
    }

    function test_FormerRecipientCanBecomeVenueAfterTreasuryChanges() public {
        vm.startPrank(admin);
        token.setFeeRecipient(address(venue));
        token.setFeeRecipient(treasury);
        token.setTradeVenue(address(venue), true);
        vm.stopPrank();
        _fund(alice, 100 ether);
        vm.prank(alice);
        token.transfer(address(venue), 100 ether);
        assertEq(token.balanceOf(treasury), 2 ether);
        assertEq(token.balanceOf(address(venue)), 98 ether);
    }

    function _assertInvalidRecipient(address recipient) internal {
        address previous = token.feeRecipient();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Workers.InvalidFeeRecipient.selector, recipient));
        token.setFeeRecipient(recipient);
        assertEq(token.feeRecipient(), previous);
    }
}
