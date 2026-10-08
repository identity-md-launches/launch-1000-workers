// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Workers} from "src/Workers.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {WorkersFixture} from "./WorkersFixtures.sol";

/// @dev Actors are two wallets, two venues, and a treasury. Launch endpoints stay outside this
/// model: WorkersInvariantTest already exercises their exemptions. Balances and allowances are
/// retained in ghost storage, never resynchronized to the token after an action.
contract WorkersAllowanceHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    Workers internal immutable token;
    address internal immutable admin;
    address internal immutable factory;
    uint256 internal immutable factoryReserve;
    address[5] internal actors;

    mapping(address => uint256) internal balances;
    mapping(address => mapping(address => uint256)) internal approvals;
    mapping(address => bool) internal venues;
    address internal recipient;

    constructor(Workers token_, address admin_, address[5] memory actors_, uint256 allocation) {
        token = token_;
        admin = admin_;
        factory = token_.launchFactory();
        actors = actors_;
        factoryReserve = SUPPLY - actors_.length * allocation;
        for (uint256 i; i < actors_.length; ++i) {
            balances[actors_[i]] = allocation;
        }
        venues[actors_[2]] = true;
        venues[actors_[3]] = true;
        recipient = actors_[4];
    }

    /// @dev Approval changes are independent actions. Spending never grants a fresh allowance.
    function approve(uint256 holderSeed, uint256 spenderSeed, uint256 amount, uint8 mode) external {
        address holder = _actor(holderSeed);
        address spender = _actor(spenderSeed);
        mode %= 4;
        if (mode == 0) amount = bound(amount, 0, SUPPLY);
        else if (mode == 1) amount = 0;
        else if (mode == 2) amount = type(uint256).max;
        else amount = balances[holder];
        vm.prank(holder);
        assertTrue(token.approve(spender, amount));
        approvals[holder][spender] = amount;
    }

    function move(uint256 fromSeed, uint256 toSeed, uint256 amount, bool fullBalance) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = fullBalance ? balances[from] : bound(amount, 0, balances[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _recordTransfer(from, to, amount);
    }

    function spend(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount, bool fullBudget) external {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowance = approvals[from][spender];
        uint256 available = allowance < balances[from] ? allowance : balances[from];
        amount = fullBudget ? available : bound(amount, 0, available);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        if (allowance != type(uint256).max) approvals[from][spender] -= amount;
        _recordTransfer(from, to, amount);
    }

    /// @dev Invalid inputs must revert with the expected error and leave the entire ghost model
    /// intact. The invariant subsequently compares every allowance and balance, including fees.
    function rejectTransfer(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, bool delegated, bool maximum)
        external
    {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 amount = maximum ? type(uint256).max : balances[from] + 1;
        uint256 allowance = approvals[from][spender];
        bytes memory errorData;
        if (delegated && allowance < amount) {
            errorData =
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, amount);
        } else {
            errorData =
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balances[from], amount);
        }
        vm.prank(delegated ? spender : from);
        vm.expectRevert(errorData);
        if (delegated) token.transferFrom(from, to, amount);
        else token.transfer(to, amount);
    }

    function configure(uint256 recipientSeed, bool secondVenue, bool enabled) external {
        address nextRecipient = _actor(recipientSeed);
        address venue = actors[secondVenue ? 3 : 2];
        vm.startPrank(admin);
        token.setFeeRecipient(nextRecipient);
        token.setTradeVenue(venue, enabled);
        vm.stopPrank();
        recipient = nextRecipient;
        venues[venue] = enabled;
    }

    function unauthorizedConfiguration(uint256 callerSeed, uint8 action) external {
        address caller = _actor(callerSeed);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        action %= 4;
        if (action == 0) token.setFeeRecipient(caller);
        else if (action == 1) token.setTradeVenue(actors[2], false);
        else if (action == 2) token.transferOwnership(caller);
        else token.renounceOwnership();
    }

    function assertState() external view {
        uint256 sum = token.balanceOf(factory);
        assertEq(sum, factoryReserve, "a transfer or fee escaped the actor set");
        for (uint256 i; i < actors.length; ++i) {
            address account = actors[i];
            uint256 actual = token.balanceOf(account);
            assertEq(actual, balances[account], "balance differs from cumulative accounting");
            sum += actual;
            assertEq(token.isTradeVenue(account), venues[account], "venue changed without owner authorization");
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(account, actors[j]),
                    approvals[account][actors[j]],
                    "gross allowance consumed incorrectly or changed on failure"
                );
            }
        }
        assertEq(sum, SUPPLY, "value was minted, burned, or sent outside tracked accounts");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.owner(), admin);
        assertEq(token.pendingOwner(), address(0));
        assertEq(token.feeRecipient(), recipient);
    }

    function _recordTransfer(address from, address to, uint256 amount) internal {
        uint256 fee = (venues[from] || venues[to]) ? amount / 50 : 0;
        // Sequential updates support every alias, including from == to == recipient.
        balances[from] -= amount;
        balances[to] += amount - fee;
        balances[recipient] += fee;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract WorkersAllowanceInvariantTest is WorkersFixture {
    WorkersAllowanceHandler internal handler;

    function setUp() public override {
        super.setUp();
        _configure();
        address[5] memory actors = [alice, bob, address(venue), address(secondVenue), treasury];
        for (uint256 i; i < actors.length; ++i) {
            _fund(actors[i], SUPPLY / 10);
        }
        handler = new WorkersAllowanceHandler(token, admin, actors, SUPPLY / 10);
        // Seed some spending authority so early calls can spend without requiring approval first.
        for (uint256 i; i < actors.length; ++i) {
            handler.approve(i, (i + 1) % actors.length, SUPPLY / 20, 0);
        }
        handler.assertState();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = WorkersAllowanceHandler.approve.selector;
        selectors[1] = WorkersAllowanceHandler.move.selector;
        selectors[2] = WorkersAllowanceHandler.spend.selector;
        selectors[3] = WorkersAllowanceHandler.rejectTransfer.selector;
        selectors[4] = WorkersAllowanceHandler.configure.selector;
        selectors[5] = WorkersAllowanceHandler.unauthorizedConfiguration.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_BalancesAllowancesAndAuthorityMatchCumulativeAccounting() public view {
        handler.assertState();
    }

    /// @dev Pin meaningful handler transitions as well as random exploration: partial spend,
    /// revocation, insufficient allowance, unlimited approval, insufficient balance, exhaustion,
    /// venue/treasury aliasing, and every unauthorized administration entry point.
    function test_HandlerSequenceExercisesApprovalAndFailureTransitions() public {
        handler.move(0, 2, 50, false);
        handler.spend(0, 1, 2, 100, false);
        handler.assertState();
        handler.approve(0, 1, 0, 1);
        handler.rejectTransfer(0, 1, 2, true, false);
        handler.assertState();
        handler.approve(0, 1, 0, 2);
        handler.rejectTransfer(0, 1, 2, true, true);
        handler.spend(0, 1, 2, 0, true);
        handler.assertState();
        handler.configure(2, false, true);
        handler.approve(2, 1, 0, 3);
        handler.spend(2, 1, 2, 0, true);
        handler.rejectTransfer(2, 1, 2, true, false);
        handler.assertState();
        handler.configure(4, false, false);
        handler.move(2, 0, 0, true);
        handler.rejectTransfer(2, 1, 0, false, true);
        for (uint8 action; action < 4; ++action) {
            handler.unauthorizedConfiguration(0, action);
        }
        handler.assertState();
    }
}
