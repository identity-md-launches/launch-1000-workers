// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Workers} from "../src/Workers.sol";
import {WorkersFixture} from "./WorkersFixtures.sol";

contract WorkersHandler is Test {
    Workers internal immutable token;
    address internal immutable admin;
    address internal immutable factory;
    address internal immutable manager;
    address internal immutable distributor;
    address[] public accounts;

    constructor(Workers token_, address[] memory accounts_) {
        token = token_;
        admin = token_.owner();
        factory = token_.launchFactory();
        manager = token_.poolManager();
        distributor = token_.launchDistributor();
        accounts = accounts_;
    }

    function move(uint256 fromSeed, uint256 toSeed, uint256 amount, bool useAllowance) external {
        address from = accounts[fromSeed % accounts.length];
        address to = accounts[toSeed % accounts.length];
        amount = bound(amount, 0, token.balanceOf(from));
        address caller = useAllowance ? address(this) : from;

        // Independent balance model, including sender/receiver/fee-recipient aliasing.
        uint256[] memory expected = new uint256[](accounts.length);
        uint256 fee;
        bool exempt = caller == factory || caller == manager || from == manager || to == manager
            || caller == distributor || from == distributor || to == distributor;
        if (!exempt && (token.isTradeVenue(from) || token.isTradeVenue(to))) fee = amount / 50;
        for (uint256 i; i < accounts.length; ++i) {
            uint256 balance = token.balanceOf(accounts[i]);
            if (accounts[i] == from) balance -= amount;
            if (accounts[i] == to) balance += amount - fee;
            if (accounts[i] == token.feeRecipient()) balance += fee;
            expected[i] = balance;
        }

        if (useAllowance) {
            vm.prank(from);
            token.approve(address(this), amount);
            token.transferFrom(from, to, amount);
            assertEq(token.allowance(from, address(this)), 0);
        } else {
            vm.prank(from);
            token.transfer(to, amount);
        }
        for (uint256 i; i < accounts.length; ++i) {
            assertEq(token.balanceOf(accounts[i]), expected[i], "balance differs from model");
        }
    }

    function changeRecipient(uint256 seed) external {
        vm.prank(admin);
        token.setFeeRecipient(accounts[seed % accounts.length]);
    }

    function changeVenue(bool second, bool enabled) external {
        vm.prank(admin);
        token.setTradeVenue(accounts[second ? 3 : 2], enabled);
    }
}

contract WorkersInvariantTest is WorkersFixture {
    WorkersHandler internal handler;
    address[] internal accounts;

    function setUp() public override {
        super.setUp();
        _configure();
        factory.registerDistributor(LAUNCH_NUMBER, address(distributor));
        accounts.push(alice);
        accounts.push(bob);
        accounts.push(address(venue));
        accounts.push(address(secondVenue));
        accounts.push(treasury);
        accounts.push(address(factory));
        accounts.push(address(manager));
        accounts.push(address(distributor));
        accounts.push(admin);
        for (uint256 i; i < accounts.length; ++i) {
            if (accounts[i] != address(factory)) _fund(accounts[i], SUPPLY / 10);
        }
        handler = new WorkersHandler(token, accounts);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = WorkersHandler.move.selector;
        selectors[1] = WorkersHandler.changeRecipient.selector;
        selectors[2] = WorkersHandler.changeVenue.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_SupplyAndEveryTokenAreConserved() public view {
        uint256 balances;
        for (uint256 i; i < accounts.length; ++i) {
            balances += token.balanceOf(accounts[i]);
        }
        assertEq(balances, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }
}
