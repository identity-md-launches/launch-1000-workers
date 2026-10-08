// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Workers} from "../src/Workers.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {WorkersFixture, LaunchFactoryMock, TokenEndpoint} from "./WorkersFixtures.sol";

contract WorkersTest is WorkersFixture {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event FeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event TradeVenueUpdated(address indexed venue, bool enabled);
    event TradeFeePaid(address indexed from, address indexed to, address indexed recipient, uint256 fee);

    function test_ConstructorMintsExactlyOnceToDeployer() public view {
        assertEq(token.name(), "Workers");
        assertEq(token.symbol(), "WORK");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(admin), 0);
        assertEq(token.owner(), admin);
        assertEq(token.launchFactory(), address(factory));
        assertEq(token.poolManager(), address(manager));
        assertEq(token.launchNumber(), LAUNCH_NUMBER);
        assertEq(token.TRADE_FEE_BPS(), 200);
        assertEq(token.feeRecipient(), address(0));
        assertEq(token.launchDistributor(), address(0));
    }

    function test_ConstructorEmitsFullSupplyMint() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), address(factory), SUPPLY);
        factory.deploy(address(manager), LAUNCH_NUMBER, admin);
    }

    function test_ConstructorRejectsWrongFactory() public {
        vm.expectRevert(abi.encodeWithSelector(Workers.InvalidLaunchFactory.selector, address(factory)));
        new Workers(address(factory), address(manager), LAUNCH_NUMBER, admin);
    }

    function test_ConstructorRejectsFactoryWithoutRegistryContract() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Workers.InvalidLaunchFactory.selector, alice));
        new Workers(alice, address(manager), LAUNCH_NUMBER, admin);
    }

    function test_ConstructorRejectsUnsetAndNonContractPoolManager() public {
        vm.expectRevert(abi.encodeWithSelector(Workers.InvalidPoolManager.selector, address(0)));
        factory.deploy(address(0), LAUNCH_NUMBER, admin);
        vm.expectRevert(abi.encodeWithSelector(Workers.InvalidPoolManager.selector, alice));
        factory.deploy(alice, LAUNCH_NUMBER, admin);
        vm.expectRevert(abi.encodeWithSelector(Workers.InvalidPoolManager.selector, address(factory)));
        factory.deploy(address(factory), LAUNCH_NUMBER, admin);
    }

    function test_ConstructorRejectsUnsetOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        factory.deploy(address(manager), LAUNCH_NUMBER, address(0));
    }

    function test_UnconfiguredWalletTransfersWorkAndVenueActivationFailsClearly() public {
        _fund(alice, 100 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 100 ether));
        assertEq(token.balanceOf(bob), 100 ether);
        vm.prank(admin);
        vm.expectRevert(Workers.FeeRecipientNotConfigured.selector);
        token.setTradeVenue(address(venue), true);
        assertFalse(token.isTradeVenue(address(venue)));
    }

    function test_ConfigurationEmitsEventsAndCannotUnsetRecipient() public {
        vm.startPrank(admin);
        vm.expectEmit(true, true, false, true, address(token));
        emit FeeRecipientUpdated(address(0), treasury);
        token.setFeeRecipient(treasury);
        vm.expectEmit(true, false, false, true, address(token));
        emit TradeVenueUpdated(address(venue), true);
        token.setTradeVenue(address(venue), true);
        vm.expectRevert(abi.encodeWithSelector(Workers.InvalidFeeRecipient.selector, address(0)));
        token.setFeeRecipient(address(0));
        vm.expectRevert(abi.encodeWithSelector(Workers.InvalidFeeRecipient.selector, address(token)));
        token.setFeeRecipient(address(token));
        assertEq(token.feeRecipient(), treasury);
        vm.stopPrank();
    }

    function test_OnlyOwnerCanConfigureFeesAndVenues() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        token.setFeeRecipient(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        token.setTradeVenue(address(venue), true);
        vm.stopPrank();
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(factory)));
        token.setFeeRecipient(alice);
    }

    function test_ProtectedAndInvalidEndpointsCannotBecomeVenues() public {
        _configure();
        factory.registerDistributor(LAUNCH_NUMBER, address(distributor));
        address[6] memory invalid =
            [address(0), alice, address(token), address(factory), address(manager), address(distributor)];
        vm.startPrank(admin);
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(Workers.InvalidTradeVenue.selector, invalid[i]));
            token.setTradeVenue(invalid[i], true);
        }
        vm.stopPrank();
    }

    function test_BuyPaysTwoPercentAndEmitsNetAndFeeTransfers() public {
        _configure();
        _fund(address(venue), 100 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(venue), treasury, 2 ether);
        vm.expectEmit(true, true, true, true, address(token));
        emit TradeFeePaid(address(venue), alice, treasury, 2 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(venue), alice, 98 ether);
        venue.send(token, alice, 100 ether);
        assertEq(token.balanceOf(address(venue)), 0);
        assertEq(token.balanceOf(alice), 98 ether);
        assertEq(token.balanceOf(treasury), 2 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_SellPaysTwoPercent() public {
        _configure();
        _fund(alice, 100 ether);
        vm.prank(alice);
        assertTrue(token.transfer(address(venue), 100 ether));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(venue)), 98 ether);
        assertEq(token.balanceOf(treasury), 2 ether);
    }

    function test_VenueToVenuePaysOnlyOneFee() public {
        _configure();
        _fund(address(venue), 100 ether);
        venue.send(token, address(secondVenue), 100 ether);
        assertEq(token.balanceOf(address(venue)), 0);
        assertEq(token.balanceOf(address(secondVenue)), 98 ether);
        assertEq(token.balanceOf(treasury), 2 ether);
    }

    function test_WalletAndUnregisteredContractTransfersAreUntaxed() public {
        _configure();
        TokenEndpoint unregistered = new TokenEndpoint();
        _fund(alice, 100 ether);
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        vm.prank(bob);
        token.transfer(address(unregistered), 100 ether);
        assertEq(token.balanceOf(address(unregistered)), 100 ether);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_TransferFromChargesFeeAndSpendsGrossAllowance() public {
        _configure();
        _fund(alice, 100 ether);
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(alice, spender, 100 ether);
        token.approve(spender, 100 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, address(venue), 100 ether));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(venue)), 98 ether);
        assertEq(token.balanceOf(treasury), 2 ether);
    }

    function test_InfiniteAllowanceIsPreserved() public {
        _configure();
        _fund(alice, 100 ether);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(alice, address(venue), 100 ether);
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.balanceOf(address(venue)), 98 ether);
    }

    function test_InsufficientAllowanceRevertsAtomically() public {
        _configure();
        _fund(alice, 100 ether);
        vm.prank(alice);
        token.approve(spender, 98 ether);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 98 ether, 100 ether)
        );
        token.transferFrom(alice, address(venue), 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(address(venue)), 0);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.allowance(alice, spender), 98 ether);
    }

    function test_InsufficientBalanceRestoresAllowanceAndFees() public {
        _configure();
        _fund(alice, 99 ether);
        vm.prank(alice);
        token.approve(spender, 100 ether);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 99 ether, 100 ether)
        );
        token.transferFrom(alice, address(venue), 100 ether);
        assertEq(token.balanceOf(alice), 99 ether);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.balanceOf(address(venue)), 0);
        assertEq(token.allowance(alice, spender), 100 ether);
    }

    function test_ZeroAddressRevertsWithoutBurningOrChargingFee() public {
        _configure();
        _fund(address(venue), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        venue.send(token, address(0), 100 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), alice, 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.balanceOf(address(venue)), 100 ether);
    }

    function test_RoundingAtSmallestFeeUnitAndZeroTransfers() public {
        _configure();
        _fund(address(venue), 200);
        venue.send(token, alice, 0);
        assertEq(token.balanceOf(treasury), 0);
        venue.send(token, alice, 49);
        assertEq(token.balanceOf(alice), 49);
        assertEq(token.balanceOf(treasury), 0);
        venue.send(token, alice, 50);
        assertEq(token.balanceOf(alice), 98);
        assertEq(token.balanceOf(treasury), 1);
        venue.send(token, alice, 101);
        assertEq(token.balanceOf(alice), 197);
        assertEq(token.balanceOf(treasury), 3);
    }

    function test_SelfTransfersPreserveSupplyAndPayFeeOnlyForVenues() public {
        _configure();
        _fund(alice, 100 ether);
        _fund(address(venue), 100 ether);
        vm.prank(alice);
        token.transfer(alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        venue.send(token, address(venue), 100 ether);
        assertEq(token.balanceOf(address(venue)), 98 ether);
        assertEq(token.balanceOf(treasury), 2 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_FeeRecipientAsSenderStillRequiresFullGrossBalance() public {
        _configure();
        vm.prank(admin);
        token.setFeeRecipient(alice);
        _fund(alice, 98 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 98 ether, 100 ether)
        );
        token.transfer(address(venue), 100 ether);
        _fund(alice, 2 ether);
        vm.prank(alice);
        token.transfer(address(venue), 100 ether);
        assertEq(token.balanceOf(alice), 2 ether);
        assertEq(token.balanceOf(address(venue)), 98 ether);
    }

    function test_FeeRecipientAsReceiverReceivesFeeAndNetWithoutDoubleTax() public {
        _configure();
        vm.prank(admin);
        token.setFeeRecipient(alice);
        _fund(address(venue), 100 ether);
        venue.send(token, alice, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(address(venue)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ChangingRecipientAndRemovingVenueAffectsOnlyFutureTransfers() public {
        _configure();
        _fund(address(venue), 300 ether);
        venue.send(token, alice, 100 ether);
        vm.prank(admin);
        token.setFeeRecipient(bob);
        venue.send(token, alice, 100 ether);
        vm.prank(admin);
        token.setTradeVenue(address(venue), false);
        venue.send(token, alice, 100 ether);
        assertEq(token.balanceOf(treasury), 2 ether);
        assertEq(token.balanceOf(bob), 2 ether);
        assertEq(token.balanceOf(alice), 296 ether);
    }

    function test_OwnerTransfersInTwoStepsWithoutChangingBalancesOrExemptions() public {
        _configure();
        _fund(admin, 100 ether);
        vm.prank(admin);
        token.transferOwnership(alice);
        assertEq(token.owner(), admin);
        assertEq(token.pendingOwner(), alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        token.acceptOwnership();
        vm.prank(alice);
        token.acceptOwnership();
        assertEq(token.owner(), alice);
        assertEq(token.pendingOwner(), address(0));
        assertEq(token.balanceOf(admin), 100 ether);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        token.setFeeRecipient(bob);
        vm.prank(alice);
        token.setFeeRecipient(treasury);
        vm.prank(admin);
        token.transfer(address(venue), 100 ether);
        assertEq(token.balanceOf(address(venue)), 98 ether);
    }

    function test_RenunciationIsDisabledAndOwnershipTransferCanBeCancelled() public {
        vm.startPrank(admin);
        vm.expectRevert(Workers.OwnershipRenunciationDisabled.selector);
        token.renounceOwnership();
        token.transferOwnership(alice);
        token.transferOwnership(address(0));
        vm.stopPrank();
        assertEq(token.pendingOwner(), address(0));
        assertEq(token.owner(), admin);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        token.acceptOwnership();
    }

    function testFuzz_BuyConservesSupplyAndChargesExactlyTwoPercent(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        _configure();
        _fund(address(venue), amount);
        venue.send(token, alice, amount);
        uint256 expectedFee = amount / 50;
        assertEq(token.balanceOf(alice), amount - expectedFee);
        assertEq(token.balanceOf(treasury), expectedFee);
        assertEq(token.balanceOf(address(factory)), SUPPLY - amount);
        assertEq(token.balanceOf(address(venue)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_SellUsingAllowanceMatchesDirectFee(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        _configure();
        _fund(alice, amount);
        vm.prank(alice);
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(alice, address(venue), amount);
        assertEq(token.balanceOf(address(venue)), amount - amount / 50);
        assertEq(token.balanceOf(treasury), amount / 50);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
