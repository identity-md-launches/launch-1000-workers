// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Workers, ILaunchFactory} from "src/Workers.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {WorkersFixture, TokenEndpoint} from "./WorkersFixtures.sol";

/// @dev Complements the launch and basic ERC-20 tests with boundary inputs and multi-call failures.
/// forge-config: default.fuzz.runs = 1000
contract WorkersAdversarialTest is WorkersFixture {
    function setUp() public override {
        super.setUp();
        _configure();
    }

    function test_FullSupplyCanBeSoldInOneTransfer() public {
        _fund(alice, SUPPLY);
        vm.prank(alice);
        assertTrue(token.transfer(address(venue), SUPPLY));
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(venue)), 980_000_000 ether);
        assertEq(token.balanceOf(treasury), 20_000_000 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_FullSupplyCanBeBoughtWithFiniteAllowance() public {
        _fund(address(venue), SUPPLY);
        vm.prank(address(venue));
        token.approve(spender, SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(venue), alice, SUPPLY));
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(address(venue)), 0);
        assertEq(token.balanceOf(alice), 980_000_000 ether);
        assertEq(token.balanceOf(treasury), 20_000_000 ether);
        assertEq(token.allowance(address(venue), spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_OneMinorUnitTradeSucceedsWithoutRoundingUpTheFee() public {
        _fund(address(venue), 1);
        venue.send(token, alice, 1);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(venue)), 0);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_MaximumGrossAmountRevertsBeforeFeeArithmetic() public {
        _fund(alice, SUPPLY);
        bytes memory expected =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, SUPPLY, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(expected);
        token.transfer(address(venue), type(uint256).max);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        vm.expectRevert(expected);
        token.transferFrom(alice, address(venue), type(uint256).max);
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(address(venue)), 0);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_DelegatedTreasurySelfTransferStillConsumesGrossAllowance() public {
        address account = treasury;
        _fund(account, 100 ether);
        vm.prank(account);
        token.approve(spender, 100 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(account, account, 100 ether));
        assertEq(token.balanceOf(account), 100 ether);
        assertEq(token.allowance(account, spender), 0);
        // The unchanged balance is not permission for a second delegated spend.
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(account, account, 1);
        assertEq(token.balanceOf(account), 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RejectedVenueRecipientUpdatePreservesFeeOnDelegatedSelfTransfer() public {
        address account = address(venue);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Workers.InvalidFeeRecipient.selector, account));
        token.setFeeRecipient(account);
        assertEq(token.feeRecipient(), treasury);
        assertTrue(token.isTradeVenue(account));
        _fund(account, 100 ether);
        vm.prank(account);
        token.approve(spender, 100 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(account, account, 100 ether));
        assertEq(token.balanceOf(account), 98 ether);
        assertEq(token.balanceOf(treasury), 2 ether);
        assertEq(token.allowance(account, spender), 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(account, account, 1);
        assertEq(token.balanceOf(account), 98 ether);
        assertEq(token.balanceOf(treasury), 2 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_InvalidTransferFromDestinationRestoresSpentAllowance() public {
        _fund(address(venue), 100 ether);
        vm.prank(address(venue));
        token.approve(spender, 100 ether);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(address(venue), address(0), 100 ether);
        assertEq(token.allowance(address(venue), spender), 100 ether);
        assertEq(token.balanceOf(address(venue)), 100 ether);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroDelegatedTradeNeedsNoAllowanceAndMovesNoValue() public {
        _fund(address(venue), 100 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(venue), alice, 0));
        assertEq(token.allowance(address(venue), spender), 0);
        assertEq(token.balanceOf(address(venue)), 100 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_RegistryFailureRestoresFiniteAllowanceAndRetrySucceeds() public {
        _fund(alice, 100 ether);
        vm.prank(alice);
        token.approve(spender, 100 ether);
        vm.mockCallRevert(
            address(factory), abi.encodeCall(ILaunchFactory.distributorOf, (LAUNCH_NUMBER)), "registry unavailable"
        );
        vm.prank(spender);
        vm.expectRevert(Workers.DistributorLookupFailed.selector);
        token.transferFrom(alice, address(venue), 100 ether);
        assertEq(token.allowance(alice, spender), 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(address(venue)), 0);
        assertEq(token.balanceOf(treasury), 0);

        vm.clearMockedCalls();
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, address(venue), 100 ether));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(venue)), 98 ether);
        assertEq(token.balanceOf(treasury), 2 ether);
    }

    function test_RegistryFailureCannotPartiallyEnableVenueAndOwnerCanDisableExistingOne() public {
        TokenEndpoint candidate = new TokenEndpoint();
        _fund(alice, 100 ether);
        vm.mockCallRevert(
            address(factory), abi.encodeCall(ILaunchFactory.distributorOf, (LAUNCH_NUMBER)), "registry unavailable"
        );
        vm.prank(admin);
        vm.expectRevert(Workers.DistributorLookupFailed.selector);
        token.setTradeVenue(address(candidate), true);
        assertFalse(token.isTradeVenue(address(candidate)));

        vm.prank(admin);
        token.setTradeVenue(address(venue), false);
        vm.prank(alice);
        assertTrue(token.transfer(address(venue), 100 ether));
        assertEq(token.balanceOf(address(venue)), 100 ether);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.feeRecipient(), treasury);
        assertTrue(token.isTradeVenue(address(secondVenue)));
    }

    function test_ReplacedPendingOwnerCannotAcceptOrConfigure() public {
        vm.prank(admin);
        token.transferOwnership(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        token.setFeeRecipient(alice);
        vm.prank(admin);
        token.transferOwnership(bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        token.acceptOwnership();
        assertEq(token.owner(), admin);
        assertEq(token.pendingOwner(), bob);
        assertEq(token.feeRecipient(), treasury);
        vm.prank(bob);
        token.acceptOwnership();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        token.setTradeVenue(address(venue), false);
        vm.prank(bob);
        token.setTradeVenue(address(venue), false);
        assertEq(token.owner(), bob);
        assertEq(token.pendingOwner(), address(0));
        assertFalse(token.isTradeVenue(address(venue)));
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_FactoryAndDistributorDelegatedExemptionsDeliverGrossAndExhaustApproval() public {
        factory.registerDistributor(LAUNCH_NUMBER, address(distributor));
        _fund(alice, 200 ether);
        address[2] memory callers = [address(factory), address(distributor)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(alice);
            token.approve(callers[i], 100 ether);
            vm.prank(callers[i]);
            assertTrue(token.transferFrom(alice, address(venue), 100 ether));
            assertEq(token.allowance(alice, callers[i]), 0);
            assertEq(token.balanceOf(address(venue)), (i + 1) * 100 ether);
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, callers[i], 0, 1));
            token.transferFrom(alice, address(venue), 1);
        }
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(treasury), 0);
    }

    function testFuzz_FeeHasLessThanOneMinorUnitRoundingError(uint256 gross) public {
        gross = bound(gross, 0, SUPPLY);
        _fund(address(venue), gross);
        venue.send(token, alice, gross);
        uint256 fee = token.balanceOf(treasury);
        // An inequality oracle checks rounding without copying the implementation's division.
        assertLe(50 * fee, gross);
        assertLt(gross, 50 * (fee + 1));
        assertEq(token.balanceOf(alice) + fee, gross);
        assertEq(token.balanceOf(address(venue)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_ApprovalRevocationAndReuseCannotExceedGrossBudget(uint256 budget, uint256 first) public {
        budget = bound(budget, 1, SUPPLY);
        first = bound(first, 0, budget - 1);
        _fund(alice, budget);
        vm.prank(alice);
        token.approve(spender, budget);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, address(venue), first));
        assertEq(token.allowance(alice, spender), budget - first);
        vm.prank(alice);
        token.approve(spender, 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(alice, address(venue), 1);
        assertEq(token.balanceOf(alice), budget - first);
        vm.prank(alice);
        token.approve(spender, budget - first);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, address(venue), budget - first));
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(alice, address(venue), 1);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        uint256 fee = token.balanceOf(treasury);
        assertEq(token.balanceOf(address(venue)) + fee, budget);
        // Two independently rounded fees lose strictly less than two minor units in total.
        assertLe(fee * 50, budget);
        assertLt(budget, (fee + 2) * 50);
    }

    function testFuzz_RepeatedRoundTripsOnlyLoseTheFeesPaid(uint256 initial, uint256 cycles) public {
        initial = bound(initial, 1, SUPPLY);
        cycles = bound(cycles, 1, 8);
        _fund(alice, initial);
        for (uint256 i; i < cycles; ++i) {
            uint256 before = token.balanceOf(alice);
            vm.prank(alice);
            assertTrue(token.transfer(address(venue), before));
            venue.send(token, alice, token.balanceOf(address(venue)));
            assertLe(token.balanceOf(alice), before, "round trip created tokens for trader");
            assertEq(token.balanceOf(alice) + token.balanceOf(treasury), initial);
            assertEq(token.balanceOf(address(venue)), 0);
            assertEq(token.totalSupply(), SUPPLY);
        }
    }
}
