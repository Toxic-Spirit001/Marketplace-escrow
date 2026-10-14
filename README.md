# Marketplace-escrow
A buyer-seller marketplace escrow contract written in Solidity and tested with Foundry.
Buyers pay into the contract, not to the seller. The money is released only when the order is confirmed, when the confirmation window runs out, or when an arbitrator rules on a dispute.
How an order works
List: a seller creates a listing with a title, price and stock.
Buy: a buyer pays the exact price. The funds are held by the contract and one unit of stock is reserved.
Ship: the seller marks the order as shipped.
Confirm: the buyer confirms receipt and the seller is paid (minus the marketplace fee).
Timeout: if the buyer never confirms, the seller can claim payment after the confirmation window.
Cancels, refunds and disputes
The buyer can cancel an order that has not shipped yet and get a full refund.
The seller can refund an order at any time before it is completed.
Either party can open a dispute on a paid or shipped order. The arbitrator resolves it by paying the seller or refunding the buyer. If the arbitrator has not ruled when the dispute window ends, the buyer can reclaim the funds with claimDisputeTimeout(). The arbitrator can still rule until that happens.
Refunds never charge a fee. If the order was never shipped, the unit goes back into the listing's stock.
The arbitrator cannot create listings or buy, so they are never a party to a dispute.
Fees
The marketplace takes a fee in basis points (capped at 10%) from seller payouts. The fee recipient withdraws accumulated fees with withdrawFees().
The suite has 81 tests, including fuzz tests and reentrancy checks.
Known limitations
Timeout favors the buyer. If the arbitrator is silent, the buyer is refunded even if the goods arrived. The arbitrator address is fixed at deployment.
Push payouts. ETH is sent directly to the seller or buyer. A contract account that rejects ETH can block its own payout.
Not audited. Do not use with real funds before an independent review.
