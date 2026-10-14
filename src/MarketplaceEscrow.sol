// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @title MarketplaceEscrow
/// @notice Sellers list items, buyers pay into escrow, and funds are released to the
/// seller once the buyer confirms receipt (or the confirmation window passes).
/// An arbitrator settles disputes and the marketplace takes a small fee on completed sales.
contract MarketplaceEscrow is ReentrancyGuard {
    // =========================
    // CONFIG
    // =========================

    uint256 public constant MAX_FEE_BPS = 1000; // 10%
    uint256 private constant BPS_DENOMINATOR = 10_000;

    address public immutable arbitrator;
    address public immutable feeRecipient;
    uint256 public immutable feeBps;
    uint256 public immutable confirmWindow;
    // How long the arbitrator has to rule before the buyer can reclaim the funds
    uint256 public immutable disputeWindow;

    constructor(
        address _arbitrator,
        address _feeRecipient,
        uint256 _feeBps,
        uint256 _confirmWindow,
        uint256 _disputeWindow
    ) {
        require(_arbitrator != address(0), "Invalid arbitrator");
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_feeBps <= MAX_FEE_BPS, "Fee too high");
        require(_confirmWindow > 0, "Invalid window");
        require(_disputeWindow > 0, "Invalid dispute window");

        arbitrator = _arbitrator;
        feeRecipient = _feeRecipient;
        feeBps = _feeBps;
        confirmWindow = _confirmWindow;
        disputeWindow = _disputeWindow;
    }

    // =========================
    // DATA
    // =========================

    enum OrderStatus {
        Paid,
        Shipped,
        Completed,
        Disputed,
        Refunded
    }

    struct Listing {
        address seller;
        string title;
        uint256 price;
        uint256 stock;
        bool active;
    }

    struct Order {
        uint256 listingId;
        address buyer;
        address seller;
        uint256 amount;
        OrderStatus status;
        uint256 shippedAt;
    }

    uint256 public listingCount;
    uint256 public orderCount;

    // Fees earned by the marketplace that have not been withdrawn yet
    uint256 public feesAccrued;

    mapping(uint256 => Listing) public listings;

    // When each order's dispute was opened (0 if never disputed)
    mapping(uint256 => uint256) public disputedAt;

    mapping(uint256 => Order) public orders;

    modifier listingExists(uint256 _listingId) {
        require(_listingId < listingCount, "Listing does not exist");
        _;
    }

    modifier orderExists(uint256 _orderId) {
        require(_orderId < orderCount, "Order does not exist");
        _;
    }

    // =========================
    // EVENTS
    // =========================

    event ListingCreated(uint256 indexed listingId, address indexed seller, uint256 price, uint256 stock);

    event ListingCancelled(uint256 indexed listingId);

    event OrderPlaced(uint256 indexed orderId, uint256 indexed listingId, address indexed buyer, uint256 amount);

    event OrderShipped(uint256 indexed orderId);

    event OrderCompleted(uint256 indexed orderId);

    event OrderRefunded(uint256 indexed orderId);

    event DisputeOpened(uint256 indexed orderId);

    event DisputeResolved(uint256 indexed orderId, bool paidSeller);

    event DisputeTimedOut(uint256 indexed orderId);

    event FeesWithdrawn(uint256 amount);

    // =========================
    // LISTINGS
    // =========================

    function createListing(string calldata _title, uint256 _price, uint256 _stock) external {
        // The arbitrator must stay neutral: if it were a party, nobody could resolve the dispute
        require(msg.sender != arbitrator, "Arbitrator cannot sell");

        require(_price > 0, "Price must be greater than zero");

        require(_stock > 0, "Stock must be greater than zero");

        Listing storage listing = listings[listingCount];
        listing.seller = msg.sender;
        listing.title = _title;
        listing.price = _price;
        listing.stock = _stock;
        listing.active = true;

        emit ListingCreated(listingCount, msg.sender, _price, _stock);

        listingCount++;
    }

    function cancelListing(uint256 _listingId) external listingExists(_listingId) {
        Listing storage listing = listings[_listingId];

        require(msg.sender == listing.seller, "Only seller can cancel");

        require(listing.active, "Listing not active");

        listing.active = false;

        emit ListingCancelled(_listingId);
    }

    // =========================
    // BUY
    // =========================

    function buy(uint256 _listingId) external payable listingExists(_listingId) {
        Listing storage listing = listings[_listingId];

        require(listing.active, "Listing not active");

        require(listing.stock > 0, "Out of stock");

        require(msg.sender != listing.seller, "Seller cannot buy own listing");

        require(msg.sender != arbitrator, "Arbitrator cannot buy");

        require(msg.value == listing.price, "Incorrect payment");

        listing.stock--;

        Order storage order = orders[orderCount];
        order.listingId = _listingId;
        order.buyer = msg.sender;
        order.seller = listing.seller;
        order.amount = msg.value;
        order.status = OrderStatus.Paid;

        emit OrderPlaced(orderCount, _listingId, msg.sender, msg.value);

        orderCount++;
    }

    // =========================
    // SHIP
    // =========================

    function markShipped(uint256 _orderId) external orderExists(_orderId) {
        Order storage order = orders[_orderId];

        require(msg.sender == order.seller, "Only seller can ship");

        require(order.status == OrderStatus.Paid, "Order is not awaiting shipment");

        order.status = OrderStatus.Shipped;
        order.shippedAt = block.timestamp;

        emit OrderShipped(_orderId);
    }

    // =========================
    // CONFIRM RECEIPT
    // =========================

    function confirmReceived(uint256 _orderId) external nonReentrant orderExists(_orderId) {
        Order storage order = orders[_orderId];

        require(msg.sender == order.buyer, "Only buyer can confirm");

        require(order.status == OrderStatus.Shipped, "Order not shipped");

        order.status = OrderStatus.Completed;

        emit OrderCompleted(_orderId);

        _payoutSeller(order);
    }

    // Seller protection: if the buyer stays silent, the seller can claim after the window
    function claimAfterTimeout(uint256 _orderId) external nonReentrant orderExists(_orderId) {
        Order storage order = orders[_orderId];

        require(msg.sender == order.seller, "Only seller can claim");

        require(order.status == OrderStatus.Shipped, "Order not shipped");

        require(block.timestamp >= order.shippedAt + confirmWindow, "Confirmation window still open");

        order.status = OrderStatus.Completed;

        emit OrderCompleted(_orderId);

        _payoutSeller(order);
    }

    // =========================
    // CANCEL / REFUND
    // =========================

    // Buyer protection: the buyer can cancel until the seller ships
    function cancelOrder(uint256 _orderId) external nonReentrant orderExists(_orderId) {
        Order storage order = orders[_orderId];

        require(msg.sender == order.buyer, "Only buyer can cancel");

        require(order.status == OrderStatus.Paid, "Order cannot be cancelled");

        order.status = OrderStatus.Refunded;

        emit OrderRefunded(_orderId);

        _refundBuyer(order);
    }

    // The seller can always give the money back before the order is settled
    function refundOrder(uint256 _orderId) external nonReentrant orderExists(_orderId) {
        Order storage order = orders[_orderId];

        require(msg.sender == order.seller, "Only seller can refund");

        require(order.status == OrderStatus.Paid || order.status == OrderStatus.Shipped, "Cannot refund order");

        order.status = OrderStatus.Refunded;

        emit OrderRefunded(_orderId);

        _refundBuyer(order);
    }

    // =========================
    // DISPUTES
    // =========================

    function openDispute(uint256 _orderId) external orderExists(_orderId) {
        Order storage order = orders[_orderId];

        require(msg.sender == order.buyer || msg.sender == order.seller, "Only parties can dispute");

        require(order.status == OrderStatus.Paid || order.status == OrderStatus.Shipped, "Cannot dispute order");

        order.status = OrderStatus.Disputed;
        disputedAt[_orderId] = block.timestamp;

        emit DisputeOpened(_orderId);
    }

    function resolveDispute(uint256 _orderId, bool _paySeller) external nonReentrant orderExists(_orderId) {
        Order storage order = orders[_orderId];

        require(msg.sender == arbitrator, "Only arbitrator can resolve");

        require(order.status == OrderStatus.Disputed, "Order is not disputed");

        if (_paySeller) {
            order.status = OrderStatus.Completed;

            _payoutSeller(order);
        } else {
            order.status = OrderStatus.Refunded;

            _refundBuyer(order);
        }

        emit DisputeResolved(_orderId, _paySeller);
    }

    // If the arbitrator does not rule within the dispute window, the buyer can take the money back.
    // The arbitrator can still rule at any time until this is called.
    function claimDisputeTimeout(uint256 _orderId) external nonReentrant orderExists(_orderId) {
        Order storage order = orders[_orderId];

        require(msg.sender == order.buyer, "Only buyer can claim");

        require(order.status == OrderStatus.Disputed, "Order is not disputed");

        require(block.timestamp >= disputedAt[_orderId] + disputeWindow, "Dispute window still open");

        order.status = OrderStatus.Refunded;

        _refundBuyer(order);

        emit DisputeTimedOut(_orderId);
    }

    // =========================
    // FEES
    // =========================

    function withdrawFees() external nonReentrant {
        require(msg.sender == feeRecipient, "Only fee recipient");

        uint256 amount = feesAccrued;

        require(amount > 0, "No fees to withdraw");

        feesAccrued = 0;

        (bool success,) = payable(feeRecipient).call{value: amount}("");

        require(success, "Withdraw failed");

        emit FeesWithdrawn(amount);
    }

    // =========================
    // INTERNAL PAYOUTS
    // =========================

    // The fee is rounded down, so seller amount + fee always equals the order amount exactly
    function _payoutSeller(Order storage order) internal {
        uint256 fee = (order.amount * feeBps) / BPS_DENOMINATOR;

        feesAccrued += fee;

        (bool success,) = payable(order.seller).call{value: order.amount - fee}("");

        require(success, "Payment failed");
    }

    // Refunds never charge a fee. If the order was never shipped, the unit goes back on the
    // shelf, so cancelling cannot permanently use up a listing's stock.
    function _refundBuyer(Order storage order) internal {
        if (order.shippedAt == 0) {
            listings[order.listingId].stock++;
        }

        (bool success,) = payable(order.buyer).call{value: order.amount}("");

        require(success, "Refund failed");
    }
}
