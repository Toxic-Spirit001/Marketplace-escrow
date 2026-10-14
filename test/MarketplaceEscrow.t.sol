// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MarketplaceEscrow} from "../src/MarketplaceEscrow.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @dev No receive/fallback, so any ETH sent to it reverts.
contract MarketEtherRejecter {}

/// @dev Acts as any party. When it receives ETH it tries one re-entrant call and records the outcome.
contract MarketReentrant {
    address public target;
    bytes public payload;
    bool public attempted;
    bool public reentered;
    bytes public reason;

    function arm(address _target, bytes calldata _payload) external {
        target = _target;
        payload = _payload;
    }

    function exec(address _to, bytes calldata _data, uint256 _value) external {
        (bool ok,) = _to.call{value: _value}(_data);
        require(ok, "exec failed");
    }

    receive() external payable {
        if (attempted) return;
        attempted = true;

        (bool ok, bytes memory ret) = target.call(payload);
        reentered = ok;
        reason = ret;
    }
}

contract MarketplaceEscrowTest is Test {
    MarketplaceEscrow market;

    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address arbitrator = makeAddr("arbitrator");
    address feeRecipient = makeAddr("feeRecipient");
    address stranger = makeAddr("stranger");
    address rejecter;

    uint256 constant PRICE = 1 ether;
    uint256 constant FEE_BPS = 250; // 2.5%
    uint256 constant WINDOW = 3 days;
    uint256 constant DISPUTE_WINDOW = 7 days;
    uint256 constant FEE = 0.025 ether;
    uint256 constant SELLER_NET = 0.975 ether;

    function setUp() public {
        market = new MarketplaceEscrow(arbitrator, feeRecipient, FEE_BPS, WINDOW, DISPUTE_WINDOW);
        rejecter = address(new MarketEtherRejecter());

        vm.deal(buyer, 10 ether);
        vm.deal(rejecter, 10 ether);
        vm.deal(arbitrator, 10 ether);
    }

    // =========================
    // HELPERS
    // =========================

    function _listAs(address _seller, uint256 _stock) internal returns (uint256 listingId) {
        vm.prank(_seller);
        market.createListing("Laptop", PRICE, _stock);
        listingId = market.listingCount() - 1;
    }

    function _buyAs(address _buyer, uint256 _listingId) internal returns (uint256 orderId) {
        vm.prank(_buyer);
        market.buy{value: PRICE}(_listingId);
        orderId = market.orderCount() - 1;
    }

    /// Seller lists (stock 2), buyer buys the first unit.
    function _paidOrder() internal returns (uint256 orderId) {
        uint256 listingId = _listAs(seller, 2);
        orderId = _buyAs(buyer, listingId);
    }

    function _shippedOrder() internal returns (uint256 orderId) {
        orderId = _paidOrder();

        vm.prank(seller);
        market.markShipped(orderId);
    }

    function _status(uint256 orderId) internal view returns (MarketplaceEscrow.OrderStatus status) {
        (,,,, status,) = market.orders(orderId);
    }

    // =========================
    // CONSTRUCTOR
    // =========================

    function testConstructorSetsConfig() public view {
        assertEq(market.arbitrator(), arbitrator);
        assertEq(market.feeRecipient(), feeRecipient);
        assertEq(market.feeBps(), FEE_BPS);
        assertEq(market.confirmWindow(), WINDOW);
        assertEq(market.disputeWindow(), DISPUTE_WINDOW);
    }

    function testConstructorRejectsZeroArbitrator() public {
        vm.expectRevert("Invalid arbitrator");
        new MarketplaceEscrow(address(0), feeRecipient, FEE_BPS, WINDOW, DISPUTE_WINDOW);
    }

    function testConstructorRejectsZeroFeeRecipient() public {
        vm.expectRevert("Invalid fee recipient");
        new MarketplaceEscrow(arbitrator, address(0), FEE_BPS, WINDOW, DISPUTE_WINDOW);
    }

    function testConstructorRejectsFeeAboveMax() public {
        vm.expectRevert("Fee too high");
        new MarketplaceEscrow(arbitrator, feeRecipient, 1001, WINDOW, DISPUTE_WINDOW);
    }

    function testConstructorAllowsMaxFee() public {
        MarketplaceEscrow m = new MarketplaceEscrow(arbitrator, feeRecipient, 1000, WINDOW, DISPUTE_WINDOW);
        assertEq(m.feeBps(), 1000);
    }

    function testConstructorRejectsZeroWindow() public {
        vm.expectRevert("Invalid window");
        new MarketplaceEscrow(arbitrator, feeRecipient, FEE_BPS, 0, DISPUTE_WINDOW);
    }

    // =========================
    // LISTINGS
    // =========================

    function testCreateListingStoresFields() public {
        _listAs(seller, 2);

        (address s, string memory title, uint256 price, uint256 stock, bool active) = market.listings(0);

        assertEq(s, seller);
        assertEq(title, "Laptop");
        assertEq(price, PRICE);
        assertEq(stock, 2);
        assertTrue(active);
        assertEq(market.listingCount(), 1);
    }

    function testCannotCreateListingWithZeroPrice() public {
        vm.prank(seller);
        vm.expectRevert("Price must be greater than zero");
        market.createListing("Laptop", 0, 1);
    }

    function testCannotCreateListingWithZeroStock() public {
        vm.prank(seller);
        vm.expectRevert("Stock must be greater than zero");
        market.createListing("Laptop", PRICE, 0);
    }

    function testSellerCanCancelListing() public {
        uint256 listingId = _listAs(seller, 1);

        vm.prank(seller);
        market.cancelListing(listingId);

        (,,,, bool active) = market.listings(listingId);
        assertFalse(active);
    }

    function testOnlySellerCanCancelListing() public {
        uint256 listingId = _listAs(seller, 1);

        vm.prank(stranger);
        vm.expectRevert("Only seller can cancel");
        market.cancelListing(listingId);
    }

    function testCannotCancelListingTwice() public {
        uint256 listingId = _listAs(seller, 1);

        vm.prank(seller);
        market.cancelListing(listingId);

        vm.prank(seller);
        vm.expectRevert("Listing not active");
        market.cancelListing(listingId);
    }

    function testCannotCancelNonexistentListing() public {
        vm.prank(seller);
        vm.expectRevert("Listing does not exist");
        market.cancelListing(99);
    }

    // =========================
    // BUY
    // =========================

    function testBuyCreatesOrderAndReducesStock() public {
        uint256 listingId = _listAs(seller, 2);
        uint256 orderId = _buyAs(buyer, listingId);

        (uint256 oListing, address oBuyer, address oSeller, uint256 amount,,) = market.orders(orderId);
        (,,,,, uint256 shippedAt) = market.orders(orderId);

        assertEq(oListing, listingId);
        assertEq(oBuyer, buyer);
        assertEq(oSeller, seller);
        assertEq(amount, PRICE);
        assertEq(uint256(_status(orderId)), uint256(MarketplaceEscrow.OrderStatus.Paid));
        assertEq(shippedAt, 0);

        (,,, uint256 stock,) = market.listings(listingId);
        assertEq(stock, 1);

        assertEq(market.orderCount(), 1);
        assertEq(address(market).balance, PRICE);
        assertEq(buyer.balance, 9 ether);
    }

    function testCannotBuyCancelledListing() public {
        uint256 listingId = _listAs(seller, 1);

        vm.prank(seller);
        market.cancelListing(listingId);

        vm.prank(buyer);
        vm.expectRevert("Listing not active");
        market.buy{value: PRICE}(listingId);
    }

    function testCannotBuyWhenOutOfStock() public {
        uint256 listingId = _listAs(seller, 1);
        _buyAs(buyer, listingId);

        vm.prank(buyer);
        vm.expectRevert("Out of stock");
        market.buy{value: PRICE}(listingId);
    }

    function testSellerCannotBuyOwnListing() public {
        uint256 listingId = _listAs(seller, 1);
        vm.deal(seller, 1 ether);

        vm.prank(seller);
        vm.expectRevert("Seller cannot buy own listing");
        market.buy{value: PRICE}(listingId);
    }

    function testCannotBuyWithTooLittle() public {
        uint256 listingId = _listAs(seller, 1);

        vm.prank(buyer);
        vm.expectRevert("Incorrect payment");
        market.buy{value: 0.5 ether}(listingId);
    }

    function testCannotBuyWithTooMuch() public {
        uint256 listingId = _listAs(seller, 1);

        vm.prank(buyer);
        vm.expectRevert("Incorrect payment");
        market.buy{value: 2 ether}(listingId);
    }

    function testCannotBuyNonexistentListing() public {
        vm.prank(buyer);
        vm.expectRevert("Listing does not exist");
        market.buy{value: PRICE}(99);
    }

    // =========================
    // SHIP
    // =========================

    function testSellerCanMarkShipped() public {
        uint256 orderId = _paidOrder();

        vm.prank(seller);
        market.markShipped(orderId);

        (,,,,, uint256 shippedAt) = market.orders(orderId);

        assertEq(uint256(_status(orderId)), uint256(MarketplaceEscrow.OrderStatus.Shipped));
        assertEq(shippedAt, block.timestamp);
    }

    function testOnlySellerCanShip() public {
        uint256 orderId = _paidOrder();

        vm.prank(buyer);
        vm.expectRevert("Only seller can ship");
        market.markShipped(orderId);
    }

    function testCannotShipTwice() public {
        uint256 orderId = _shippedOrder();

        vm.prank(seller);
        vm.expectRevert("Order is not awaiting shipment");
        market.markShipped(orderId);
    }

    function testCannotShipNonexistentOrder() public {
        vm.prank(seller);
        vm.expectRevert("Order does not exist");
        market.markShipped(99);
    }

    // =========================
    // CONFIRM RECEIPT
    // =========================

    function testConfirmReceivedPaysSellerMinusFee() public {
        uint256 orderId = _shippedOrder();

        vm.prank(buyer);
        market.confirmReceived(orderId);

        assertEq(seller.balance, SELLER_NET);
        assertEq(market.feesAccrued(), FEE);
        assertEq(address(market).balance, FEE);
        assertEq(uint256(_status(orderId)), uint256(MarketplaceEscrow.OrderStatus.Completed));
    }

    function testOnlyBuyerCanConfirm() public {
        uint256 orderId = _shippedOrder();

        vm.prank(seller);
        vm.expectRevert("Only buyer can confirm");
        market.confirmReceived(orderId);
    }

    function testCannotConfirmUnshippedOrder() public {
        uint256 orderId = _paidOrder();

        vm.prank(buyer);
        vm.expectRevert("Order not shipped");
        market.confirmReceived(orderId);
    }

    function testCannotConfirmTwice() public {
        uint256 orderId = _shippedOrder();

        vm.prank(buyer);
        market.confirmReceived(orderId);

        vm.prank(buyer);
        vm.expectRevert("Order not shipped");
        market.confirmReceived(orderId);
    }

    function testConfirmPaymentFailureReverts() public {
        uint256 listingId = _listAs(rejecter, 1);
        uint256 orderId = _buyAs(buyer, listingId);

        vm.prank(rejecter);
        market.markShipped(orderId);

        vm.prank(buyer);
        vm.expectRevert("Payment failed");
        market.confirmReceived(orderId);

        // Nothing was lost: the order is still shipped and the fee was not booked
        assertEq(uint256(_status(orderId)), uint256(MarketplaceEscrow.OrderStatus.Shipped));
        assertEq(market.feesAccrued(), 0);
    }

    // =========================
    // CLAIM AFTER TIMEOUT
    // =========================

    function testSellerCanClaimExactlyAtWindowEnd() public {
        uint256 orderId = _shippedOrder();

        vm.warp(block.timestamp + WINDOW);

        vm.prank(seller);
        market.claimAfterTimeout(orderId);

        assertEq(seller.balance, SELLER_NET);
        assertEq(market.feesAccrued(), FEE);
        assertEq(uint256(_status(orderId)), uint256(MarketplaceEscrow.OrderStatus.Completed));
    }

    function testCannotClaimBeforeWindowEnds() public {
        uint256 orderId = _shippedOrder();

        vm.warp(block.timestamp + WINDOW - 1);

        vm.prank(seller);
        vm.expectRevert("Confirmation window still open");
        market.claimAfterTimeout(orderId);
    }

    function testOnlySellerCanClaim() public {
        uint256 orderId = _shippedOrder();

        vm.warp(block.timestamp + WINDOW);

        vm.prank(buyer);
        vm.expectRevert("Only seller can claim");
        market.claimAfterTimeout(orderId);
    }

    function testCannotClaimUnshippedOrder() public {
        uint256 orderId = _paidOrder();

        vm.warp(block.timestamp + WINDOW);

        vm.prank(seller);
        vm.expectRevert("Order not shipped");
        market.claimAfterTimeout(orderId);
    }

    // =========================
    // CANCEL (BUYER)
    // =========================

    function testBuyerCanCancelPaidOrder() public {
        uint256 orderId = _paidOrder();

        vm.prank(buyer);
        market.cancelOrder(orderId);

        assertEq(buyer.balance, 10 ether);
        assertEq(address(market).balance, 0);
        assertEq(market.feesAccrued(), 0);
        assertEq(uint256(_status(orderId)), uint256(MarketplaceEscrow.OrderStatus.Refunded));

        // The unit goes back on the shelf
        (,,, uint256 stock,) = market.listings(0);
        assertEq(stock, 2);
    }

    function testOnlyBuyerCanCancel() public {
        uint256 orderId = _paidOrder();

        vm.prank(seller);
        vm.expectRevert("Only buyer can cancel");
        market.cancelOrder(orderId);
    }

    function testCannotCancelShippedOrder() public {
        uint256 orderId = _shippedOrder();

        vm.prank(buyer);
        vm.expectRevert("Order cannot be cancelled");
        market.cancelOrder(orderId);
    }

    function testCancelRefundFailureReverts() public {
        uint256 listingId = _listAs(seller, 1);
        uint256 orderId = _buyAs(rejecter, listingId);

        vm.prank(rejecter);
        vm.expectRevert("Refund failed");
        market.cancelOrder(orderId);
    }

    function testCancelledOrderCannotLockListing() public {
        uint256 listingId = _listAs(seller, 1);

        // A buyer takes the only unit and cancels...
        uint256 orderId = _buyAs(buyer, listingId);
        vm.prank(buyer);
        market.cancelOrder(orderId);

        // ...and the listing can still be bought
        _buyAs(buyer, listingId);

        (,,, uint256 stock,) = market.listings(listingId);
        assertEq(stock, 0);
    }

    // =========================
    // REFUND (SELLER)
    // =========================

    function testSellerCanRefundPaidOrder() public {
        uint256 orderId = _paidOrder();

        vm.prank(seller);
        market.refundOrder(orderId);

        assertEq(buyer.balance, 10 ether);
        assertEq(address(market).balance, 0);
        assertEq(uint256(_status(orderId)), uint256(MarketplaceEscrow.OrderStatus.Refunded));
    }

    function testSellerCanRefundShippedOrder() public {
        uint256 orderId = _shippedOrder();

        vm.prank(seller);
        market.refundOrder(orderId);

        assertEq(buyer.balance, 10 ether);
        assertEq(address(market).balance, 0);
    }

    function testOnlySellerCanRefund() public {
        uint256 orderId = _paidOrder();

        vm.prank(buyer);
        vm.expectRevert("Only seller can refund");
        market.refundOrder(orderId);
    }

    function testCannotRefundCompletedOrder() public {
        uint256 orderId = _shippedOrder();

        vm.prank(buyer);
        market.confirmReceived(orderId);

        vm.prank(seller);
        vm.expectRevert("Cannot refund order");
        market.refundOrder(orderId);
    }

    function testRefundOfUnshippedOrderRestoresStock() public {
        uint256 orderId = _paidOrder();

        vm.prank(seller);
        market.refundOrder(orderId);

        (,,, uint256 stock,) = market.listings(0);
        assertEq(stock, 2);
    }

    function testRefundOfShippedOrderDoesNotRestoreStock() public {
        uint256 orderId = _shippedOrder();

        vm.prank(seller);
        market.refundOrder(orderId);

        (,,, uint256 stock,) = market.listings(0);
        assertEq(stock, 1);
    }

    // =========================
    // DISPUTES
    // =========================

    function testBuyerCanOpenDispute() public {
        uint256 orderId = _paidOrder();

        vm.prank(buyer);
        market.openDispute(orderId);

        assertEq(uint256(_status(orderId)), uint256(MarketplaceEscrow.OrderStatus.Disputed));
    }

    function testSellerCanOpenDispute() public {
        uint256 orderId = _shippedOrder();

        vm.prank(seller);
        market.openDispute(orderId);

        assertEq(uint256(_status(orderId)), uint256(MarketplaceEscrow.OrderStatus.Disputed));
    }

    function testStrangerCannotOpenDispute() public {
        uint256 orderId = _paidOrder();

        vm.prank(stranger);
        vm.expectRevert("Only parties can dispute");
        market.openDispute(orderId);
    }

    function testCannotDisputeCompletedOrder() public {
        uint256 orderId = _shippedOrder();

        vm.prank(buyer);
        market.confirmReceived(orderId);

        vm.prank(buyer);
        vm.expectRevert("Cannot dispute order");
        market.openDispute(orderId);
    }

    function testDisputeFreezesTimeoutClaim() public {
        uint256 orderId = _shippedOrder();

        vm.prank(buyer);
        market.openDispute(orderId);

        vm.warp(block.timestamp + WINDOW);

        vm.prank(seller);
        vm.expectRevert("Order not shipped");
        market.claimAfterTimeout(orderId);
    }

    // =========================
    // RESOLVE DISPUTE
    // =========================

    function testArbitratorResolvesForSeller() public {
        uint256 orderId = _shippedOrder();

        vm.prank(buyer);
        market.openDispute(orderId);

        vm.prank(arbitrator);
        market.resolveDispute(orderId, true);

        assertEq(seller.balance, SELLER_NET);
        assertEq(market.feesAccrued(), FEE);
        assertEq(address(market).balance, FEE);
        assertEq(uint256(_status(orderId)), uint256(MarketplaceEscrow.OrderStatus.Completed));
    }

    function testArbitratorResolvesForBuyer() public {
        uint256 orderId = _shippedOrder();

        vm.prank(buyer);
        market.openDispute(orderId);

        vm.prank(arbitrator);
        market.resolveDispute(orderId, false);

        assertEq(buyer.balance, 10 ether);
        assertEq(market.feesAccrued(), 0);
        assertEq(address(market).balance, 0);
        assertEq(uint256(_status(orderId)), uint256(MarketplaceEscrow.OrderStatus.Refunded));
    }

    function testOnlyArbitratorCanResolve() public {
        uint256 orderId = _paidOrder();

        vm.prank(buyer);
        market.openDispute(orderId);

        vm.prank(buyer);
        vm.expectRevert("Only arbitrator can resolve");
        market.resolveDispute(orderId, false);
    }

    function testCannotResolveUndisputedOrder() public {
        uint256 orderId = _paidOrder();

        vm.prank(arbitrator);
        vm.expectRevert("Order is not disputed");
        market.resolveDispute(orderId, true);
    }

    function testArbitratorCannotBuy() public {
        uint256 listingId = _listAs(seller, 1);

        vm.prank(arbitrator);
        vm.expectRevert("Arbitrator cannot buy");
        market.buy{value: PRICE}(listingId);
    }

    function testArbitratorCannotCreateListing() public {
        vm.prank(arbitrator);
        vm.expectRevert("Arbitrator cannot sell");
        market.createListing("Laptop", PRICE, 1);
    }

    function testResolvePayoutFailureReverts() public {
        uint256 listingId = _listAs(rejecter, 1);
        uint256 orderId = _buyAs(buyer, listingId);

        vm.prank(buyer);
        market.openDispute(orderId);

        vm.prank(arbitrator);
        vm.expectRevert("Payment failed");
        market.resolveDispute(orderId, true);
    }

    function testResolveRefundFailureReverts() public {
        uint256 listingId = _listAs(seller, 1);
        uint256 orderId = _buyAs(rejecter, listingId);

        vm.prank(rejecter);
        market.openDispute(orderId);

        vm.prank(arbitrator);
        vm.expectRevert("Refund failed");
        market.resolveDispute(orderId, false);
    }

    function testDisputeRefundOfUnshippedOrderRestoresStock() public {
        uint256 orderId = _paidOrder();

        vm.prank(buyer);
        market.openDispute(orderId);

        vm.prank(arbitrator);
        market.resolveDispute(orderId, false);

        (,,, uint256 stock,) = market.listings(0);
        assertEq(stock, 2);
    }

    function testDisputeRefundOfShippedOrderDoesNotRestoreStock() public {
        uint256 orderId = _shippedOrder();

        vm.prank(buyer);
        market.openDispute(orderId);

        vm.prank(arbitrator);
        market.resolveDispute(orderId, false);

        (,,, uint256 stock,) = market.listings(0);
        assertEq(stock, 1);
    }

    function testDisputeSellerPayoutDoesNotChangeStock() public {
        uint256 orderId = _shippedOrder();

        vm.prank(buyer);
        market.openDispute(orderId);

        vm.prank(arbitrator);
        market.resolveDispute(orderId, true);

        (,,, uint256 stock,) = market.listings(0);
        assertEq(stock, 1);
    }

    // =========================
    // DISPUTE TIMEOUT
    // =========================

    function _disputedShippedOrder() internal returns (uint256 orderId) {
        orderId = _shippedOrder();

        vm.prank(buyer);
        market.openDispute(orderId);
    }

    function testConstructorRejectsZeroDisputeWindow() public {
        vm.expectRevert("Invalid dispute window");
        new MarketplaceEscrow(arbitrator, feeRecipient, FEE_BPS, WINDOW, 0);
    }

    function testDisputeRecordsOpenTime() public {
        uint256 orderId = _disputedShippedOrder();

        assertEq(market.disputedAt(orderId), block.timestamp);
    }

    function testBuyerCanReclaimAfterDisputeTimeout() public {
        uint256 orderId = _disputedShippedOrder();
        uint256 balanceBefore = buyer.balance;

        vm.warp(block.timestamp + DISPUTE_WINDOW);

        vm.prank(buyer);
        market.claimDisputeTimeout(orderId);

        assertEq(uint256(_status(orderId)), uint256(MarketplaceEscrow.OrderStatus.Refunded));
        assertEq(buyer.balance, balanceBefore + PRICE);
        assertEq(address(market).balance, 0);

        // The order had shipped, so the unit is not put back on the shelf
        (,,, uint256 stock,) = market.listings(0);
        assertEq(stock, 1);
    }

    function testDisputeTimeoutRestoresStockForUnshippedOrder() public {
        uint256 orderId = _paidOrder();

        vm.prank(buyer);
        market.openDispute(orderId);

        vm.warp(block.timestamp + DISPUTE_WINDOW);

        vm.prank(buyer);
        market.claimDisputeTimeout(orderId);

        (,,, uint256 stock,) = market.listings(0);
        assertEq(stock, 2);
    }

    function testCannotClaimDisputeTimeoutEarly() public {
        uint256 orderId = _disputedShippedOrder();

        vm.warp(block.timestamp + DISPUTE_WINDOW - 1);

        vm.prank(buyer);
        vm.expectRevert("Dispute window still open");
        market.claimDisputeTimeout(orderId);
    }

    function testOnlyBuyerCanClaimDisputeTimeout() public {
        uint256 orderId = _disputedShippedOrder();

        vm.warp(block.timestamp + DISPUTE_WINDOW);

        vm.prank(seller);
        vm.expectRevert("Only buyer can claim");
        market.claimDisputeTimeout(orderId);

        vm.prank(stranger);
        vm.expectRevert("Only buyer can claim");
        market.claimDisputeTimeout(orderId);
    }

    function testCannotClaimDisputeTimeoutOnUndisputedOrder() public {
        uint256 orderId = _shippedOrder();

        vm.warp(block.timestamp + DISPUTE_WINDOW);

        vm.prank(buyer);
        vm.expectRevert("Order is not disputed");
        market.claimDisputeTimeout(orderId);
    }

    function testCannotClaimDisputeTimeoutTwice() public {
        uint256 orderId = _disputedShippedOrder();

        vm.warp(block.timestamp + DISPUTE_WINDOW);

        vm.prank(buyer);
        market.claimDisputeTimeout(orderId);

        vm.prank(buyer);
        vm.expectRevert("Order is not disputed");
        market.claimDisputeTimeout(orderId);
    }

    function testArbitratorCanStillResolveAfterDisputeWindow() public {
        uint256 orderId = _disputedShippedOrder();

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1 days);

        vm.prank(arbitrator);
        market.resolveDispute(orderId, true);

        assertEq(uint256(_status(orderId)), uint256(MarketplaceEscrow.OrderStatus.Completed));
        assertEq(seller.balance, SELLER_NET);
    }

    function testCannotClaimDisputeTimeoutAfterArbitratorRules() public {
        uint256 orderId = _disputedShippedOrder();

        vm.prank(arbitrator);
        market.resolveDispute(orderId, true);

        vm.warp(block.timestamp + DISPUTE_WINDOW);

        vm.prank(buyer);
        vm.expectRevert("Order is not disputed");
        market.claimDisputeTimeout(orderId);
    }

    function testDisputeTimeoutRefundFailureReverts() public {
        uint256 listingId = _listAs(seller, 1);
        uint256 orderId = _buyAs(rejecter, listingId);

        vm.prank(rejecter);
        market.openDispute(orderId);

        vm.warp(block.timestamp + DISPUTE_WINDOW);

        vm.prank(rejecter);
        vm.expectRevert("Refund failed");
        market.claimDisputeTimeout(orderId);
    }

    // =========================
    // REENTRANCY
    // =========================

    function testReentrancyBlockedDuringSellerPayout() public {
        MarketReentrant attacker = new MarketReentrant();

        attacker.exec(address(market), abi.encodeCall(market.createListing, ("Item", PRICE, 1)), 0);
        uint256 orderId = _buyAs(buyer, 0);
        attacker.exec(address(market), abi.encodeCall(market.markShipped, (orderId)), 0);

        // While being paid, the seller tries to pull the refund path
        attacker.arm(address(market), abi.encodeCall(market.refundOrder, (orderId)));

        vm.prank(buyer);
        market.confirmReceived(orderId);

        assertTrue(attacker.attempted());
        assertFalse(attacker.reentered());
        assertEq(bytes4(attacker.reason()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(address(attacker).balance, SELLER_NET);
    }

    function testReentrancyBlockedDuringBuyerRefund() public {
        MarketReentrant attacker = new MarketReentrant();
        vm.deal(address(attacker), 10 ether);

        uint256 listingId = _listAs(seller, 1);
        attacker.exec(address(market), abi.encodeCall(market.buy, (listingId)), PRICE);

        // While being refunded, the buyer tries to cancel again
        attacker.arm(address(market), abi.encodeCall(market.cancelOrder, (0)));

        attacker.exec(address(market), abi.encodeCall(market.cancelOrder, (0)), 0);

        assertTrue(attacker.attempted());
        assertFalse(attacker.reentered());
        assertEq(bytes4(attacker.reason()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(address(attacker).balance, 10 ether);
        assertEq(address(market).balance, 0);
    }

    function testReentrancyBlockedDuringFeeWithdrawal() public {
        MarketReentrant attacker = new MarketReentrant();
        MarketplaceEscrow m = new MarketplaceEscrow(arbitrator, address(attacker), FEE_BPS, WINDOW, DISPUTE_WINDOW);

        vm.prank(seller);
        m.createListing("Laptop", PRICE, 1);

        vm.prank(buyer);
        m.buy{value: PRICE}(0);

        vm.prank(seller);
        m.markShipped(0);

        vm.prank(buyer);
        m.confirmReceived(0);

        attacker.arm(address(m), abi.encodeCall(m.withdrawFees, ()));
        attacker.exec(address(m), abi.encodeCall(m.withdrawFees, ()), 0);

        assertTrue(attacker.attempted());
        assertFalse(attacker.reentered());
        assertEq(bytes4(attacker.reason()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(address(attacker).balance, FEE);
        assertEq(address(m).balance, 0);
    }

    // =========================
    // FEES
    // =========================

    function testFeeRecipientCanWithdrawFees() public {
        uint256 orderId = _shippedOrder();

        vm.prank(buyer);
        market.confirmReceived(orderId);

        vm.prank(feeRecipient);
        market.withdrawFees();

        assertEq(feeRecipient.balance, FEE);
        assertEq(market.feesAccrued(), 0);
        assertEq(address(market).balance, 0);
    }

    function testOnlyFeeRecipientCanWithdrawFees() public {
        vm.prank(stranger);
        vm.expectRevert("Only fee recipient");
        market.withdrawFees();
    }

    function testCannotWithdrawZeroFees() public {
        vm.prank(feeRecipient);
        vm.expectRevert("No fees to withdraw");
        market.withdrawFees();
    }

    function testCannotWithdrawFeesTwice() public {
        uint256 orderId = _shippedOrder();

        vm.prank(buyer);
        market.confirmReceived(orderId);

        vm.prank(feeRecipient);
        market.withdrawFees();

        vm.prank(feeRecipient);
        vm.expectRevert("No fees to withdraw");
        market.withdrawFees();
    }

    function testWithdrawFeesFailureReverts() public {
        MarketplaceEscrow m = new MarketplaceEscrow(arbitrator, rejecter, FEE_BPS, WINDOW, DISPUTE_WINDOW);

        vm.prank(seller);
        m.createListing("Laptop", PRICE, 1);

        vm.prank(buyer);
        m.buy{value: PRICE}(0);

        vm.prank(seller);
        m.markShipped(0);

        vm.prank(buyer);
        m.confirmReceived(0);

        vm.prank(rejecter);
        vm.expectRevert("Withdraw failed");
        m.withdrawFees();
    }

    function testZeroFeeMarketplacePaysSellerInFull() public {
        MarketplaceEscrow m = new MarketplaceEscrow(arbitrator, feeRecipient, 0, WINDOW, DISPUTE_WINDOW);

        vm.prank(seller);
        m.createListing("Laptop", PRICE, 1);

        vm.prank(buyer);
        m.buy{value: PRICE}(0);

        vm.prank(seller);
        m.markShipped(0);

        vm.prank(buyer);
        m.confirmReceived(0);

        assertEq(seller.balance, PRICE);
        assertEq(m.feesAccrued(), 0);
        assertEq(address(m).balance, 0);
    }

    // =========================
    // FUZZ
    // =========================

    /// Seller amount + marketplace fee always equals the price, and nothing is left over.
    function testFuzzFeeSplitIsExact(uint256 price, uint256 bps) public {
        price = bound(price, 1, 100 ether);
        bps = bound(bps, 0, 1000);

        MarketplaceEscrow m = new MarketplaceEscrow(arbitrator, feeRecipient, bps, WINDOW, DISPUTE_WINDOW);

        vm.prank(seller);
        m.createListing("Item", price, 1);

        vm.deal(buyer, price);

        vm.prank(buyer);
        m.buy{value: price}(0);

        vm.prank(seller);
        m.markShipped(0);

        vm.prank(buyer);
        m.confirmReceived(0);

        assertEq(seller.balance + m.feesAccrued(), price);
        assertEq(address(m).balance, m.feesAccrued());
    }
}
