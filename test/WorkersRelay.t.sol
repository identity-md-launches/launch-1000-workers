// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Workers} from "../src/Workers.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {WorkersFixture, TokenEndpoint} from "./WorkersFixtures.sol";

interface IRelayCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @dev Models public sync/settle/take without a pool. An unlock must finish with no credit outstanding.
contract RelayManagerMock {
    Workers internal token;
    address internal unlocker;
    uint256 internal reserves;
    uint256 public credit;

    modifier onlyUnlocker() {
        require(msg.sender == unlocker, "not unlocker");
        _;
    }

    function setToken(Workers token_) external {
        token = token_;
    }

    function unlock(bytes calldata data) external {
        require(unlocker == address(0), "already unlocked");
        unlocker = msg.sender;
        IRelayCallback(msg.sender).unlockCallback(data);
        require(credit == 0, "unsettled credit");
        unlocker = address(0);
    }

    function sync() external onlyUnlocker {
        reserves = token.balanceOf(address(this));
    }

    function settle() external onlyUnlocker returns (uint256 paid) {
        paid = token.balanceOf(address(this)) - reserves;
        reserves += paid;
        credit += paid;
    }

    function take(address recipient, uint256 amount) external onlyUnlocker {
        credit -= amount;
        token.transfer(recipient, amount);
    }
}

contract VenueRelay is IRelayCallback {
    Workers internal immutable token;
    RelayManagerMock internal immutable manager;

    constructor(Workers token_, RelayManagerMock manager_) {
        token = token_;
        manager = manager_;
    }

    function trade(TokenEndpoint venue, bool sell, uint256 amount) external {
        manager.unlock(abi.encode(venue, msg.sender, sell, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (TokenEndpoint venue, address trader, bool sell, uint256 amount) =
            abi.decode(data, (TokenEndpoint, address, bool, uint256));
        manager.sync();
        if (sell) token.transferFrom(trader, address(manager), amount);
        else venue.send(token, address(manager), amount);
        uint256 paid = manager.settle();
        manager.take(sell ? address(venue) : trader, paid);
        return "";
    }
}

contract WorkersRelayTest is WorkersFixture {
    RelayManagerMock internal relayManager;
    VenueRelay internal relay;

    event TradeFeePaid(address indexed from, address indexed to, address indexed recipient, uint256 fee);

    function setUp() public override {
        super.setUp();
        relayManager = new RelayManagerMock();
        token = factory.deploy(address(relayManager), LAUNCH_NUMBER, admin);
        relayManager.setToken(token);
        relay = new VenueRelay(token, relayManager);
        _configure();
    }

    function test_RelayedSellPaysVenueFeeAndConsumesGrossAllowance() public {
        _fund(alice, 100 ether);
        vm.startPrank(alice);
        token.approve(address(relay), 100 ether);
        vm.expectEmit(true, true, true, true, address(token));
        emit TradeFeePaid(address(relayManager), address(venue), treasury, 2 ether);
        relay.trade(venue, true, 100 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(venue)), 98 ether);
        assertEq(token.balanceOf(treasury), 2 ether);
        assertEq(token.allowance(alice, address(relay)), 0);
        assertEq(token.balanceOf(address(relayManager)), 0);
        assertEq(relayManager.credit(), 0);
    }

    function test_RelayedBuySettlesNetAmountAndPaysVenueFee() public {
        _fund(address(venue), 100 ether);
        vm.expectEmit(true, true, true, true, address(token));
        emit TradeFeePaid(address(venue), address(relayManager), treasury, 2 ether);
        vm.prank(alice);
        relay.trade(venue, false, 100 ether);
        assertEq(token.balanceOf(address(venue)), 0);
        assertEq(token.balanceOf(alice), 98 ether);
        assertEq(token.balanceOf(treasury), 2 ether);
        assertEq(token.balanceOf(address(relayManager)), 0);
        assertEq(relayManager.credit(), 0);
    }

    function test_RelayedSellWithoutGrossAllowanceRevertsAtomically() public {
        _fund(alice, 100 ether);
        vm.startPrank(alice);
        token.approve(address(relay), 98 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(relay), 98 ether, 100 ether
            )
        );
        relay.trade(venue, true, 100 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(address(venue)), 0);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.allowance(alice, address(relay)), 98 ether);
        assertEq(token.balanceOf(address(relayManager)), 0);
        assertEq(relayManager.credit(), 0);
    }
}
