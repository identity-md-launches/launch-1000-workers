// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface ILaunchFactory {
    function distributorOf(uint64 launchNumber) external view returns (address);
}

/// @title Workers (WORK)
/// @notice Fixed-supply token charging 2% on transfers involving a registered trading venue.
/// @dev Launch settlement and distributor claims are exempt. The fee is paid in WORK, not burned.
contract Workers is ERC20, Ownable2Step {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 public constant TRADE_FEE_BPS = 200;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    address public immutable launchFactory;
    address public immutable poolManager;
    uint64 public immutable launchNumber;

    /// @notice Unset until the owner provides the actual fee recipient.
    address public feeRecipient;
    mapping(address venue => bool enabled) public isTradeVenue;

    error InvalidLaunchFactory(address factory);
    error InvalidPoolManager(address manager);
    error InvalidFeeRecipient(address recipient);
    error InvalidTradeVenue(address venue);
    error FeeRecipientNotConfigured();
    error DistributorLookupFailed();
    error OwnershipRenunciationDisabled();

    event FeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event TradeVenueUpdated(address indexed venue, bool enabled);
    event TradeFeePaid(address indexed from, address indexed to, address indexed recipient, uint256 fee);

    /// @param factory_ Launch factory, also the deploying caller ($factory).
    /// @param poolManager_ Verified launch PoolManager ($poolManager).
    /// @param launchNumber_ Launch registry key ($launchNumber).
    /// @param initialOwner_ Requester's literal administration address; does not receive the mint.
    constructor(address factory_, address poolManager_, uint64 launchNumber_, address initialOwner_)
        ERC20("Workers", "WORK")
        Ownable(initialOwner_)
    {
        if (factory_ == address(0) || factory_ != msg.sender || factory_.code.length == 0) {
            revert InvalidLaunchFactory(factory_);
        }
        if (poolManager_ == address(0) || poolManager_.code.length == 0 || poolManager_ == factory_) {
            revert InvalidPoolManager(poolManager_);
        }
        if (initialOwner_ == factory_ || initialOwner_ == poolManager_) revert OwnableInvalidOwner(initialOwner_);
        launchFactory = factory_;
        poolManager = poolManager_;
        launchNumber = launchNumber_;
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @notice Set the real fee destination; this cannot change the fee rate or any balance.
    function setFeeRecipient(address recipient) external onlyOwner {
        if (
            recipient == address(0) || recipient == address(this) || recipient == launchFactory
                || recipient == poolManager || isTradeVenue[recipient] || recipient == launchDistributor()
        ) revert InvalidFeeRecipient(recipient);
        address previous = feeRecipient;
        feeRecipient = recipient;
        emit FeeRecipientUpdated(previous, recipient);
    }

    /// @notice Register or remove a fee-aware venue. Unregistered transfers are untaxed.
    /// @dev Configure the recipient first. Protected launch endpoints and the fee recipient cannot be registered.
    function setTradeVenue(address venue, bool enabled) external onlyOwner {
        if (enabled) {
            if (feeRecipient == address(0)) revert FeeRecipientNotConfigured();
            if (
                venue.code.length == 0 || venue == address(this) || venue == launchFactory || venue == poolManager
                    || venue == feeRecipient || venue == launchDistributor()
            ) revert InvalidTradeVenue(venue);
        }
        isTradeVenue[venue] = enabled;
        emit TradeVenueUpdated(venue, enabled);
    }

    /// @notice Resolve the distributor at use time because it is deployed after this token.
    /// @dev The factory may return zero before registering its distributor. Zero is never an exemption.
    function launchDistributor() public view returns (address distributor) {
        try ILaunchFactory(launchFactory).distributorOf(launchNumber) returns (address registered) {
            return registered;
        } catch {
            revert DistributorLookupFailed();
        }
    }

    /// @notice Keep settings recoverable; use the inherited two-step ownership transfer instead.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRenunciationDisabled();
    }

    function _update(address from, address to, uint256 amount) internal override {
        // Minting happens only in the constructor. Neither mint nor burn is externally exposed.
        // Manager settlement is untaxed when neither endpoint is a venue. Manager-to-venue
        // transfers must pay the fee because anyone can relay tokens through the manager.
        if (
            from == address(0) || to == address(0) || msg.sender == launchFactory
                || (!isTradeVenue[from] && !isTradeVenue[to])
        ) {
            super._update(from, to, amount);
            return;
        }

        address distributor = launchDistributor();
        if (distributor != address(0) && (msg.sender == distributor || from == distributor || to == distributor)) {
            super._update(from, to, amount);
            return;
        }

        address recipient = feeRecipient;
        if (recipient == address(0)) revert FeeRecipientNotConfigured();

        // Validate the gross amount before splitting, including when recipient == from or to.
        uint256 available = balanceOf(from);
        if (available < amount) revert ERC20InsufficientBalance(from, available, amount);

        // Fixed supply bounds amount; multiplication cannot overflow after the balance check.
        uint256 fee = (amount * TRADE_FEE_BPS) / BPS_DENOMINATOR;
        if (fee != 0) {
            super._update(from, recipient, fee);
            emit TradeFeePaid(from, to, recipient, fee);
        }
        super._update(from, to, amount - fee);
    }
}
