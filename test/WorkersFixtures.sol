// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Workers} from "../src/Workers.sol";

/// @dev Models the factory's deployment, transfer and late distributor registration interfaces.
contract LaunchFactoryMock {
    mapping(uint64 => address) public distributorOf;

    function deploy(address manager, uint64 number, address owner) external returns (Workers) {
        return new Workers(address(this), manager, number, owner);
    }

    function registerDistributor(uint64 number, address distributor) external {
        distributorOf[number] = distributor;
    }

    function send(Workers token, address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}

/// @dev A custody endpoint used to model pools and claim distributors; not a production AMM.
contract TokenEndpoint {
    function send(Workers token, address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}

abstract contract WorkersFixture is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint64 internal constant LAUNCH_NUMBER = 41;

    LaunchFactoryMock internal factory;
    TokenEndpoint internal manager;
    TokenEndpoint internal venue;
    TokenEndpoint internal secondVenue;
    TokenEndpoint internal distributor;
    Workers internal token;

    address internal admin;
    address internal alice;
    address internal bob;
    address internal treasury;
    address internal spender;

    function setUp() public virtual {
        admin = makeAddr("requester");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        treasury = makeAddr("treasury");
        spender = makeAddr("spender");
        factory = new LaunchFactoryMock();
        manager = new TokenEndpoint();
        venue = new TokenEndpoint();
        secondVenue = new TokenEndpoint();
        distributor = new TokenEndpoint();
        token = factory.deploy(address(manager), LAUNCH_NUMBER, admin);
    }

    function _configure() internal {
        vm.startPrank(admin);
        token.setFeeRecipient(treasury);
        token.setTradeVenue(address(venue), true);
        token.setTradeVenue(address(secondVenue), true);
        vm.stopPrank();
    }

    function _fund(address to, uint256 amount) internal {
        factory.send(token, to, amount);
    }
}
