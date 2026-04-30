// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title VulnerableOracle
 * @dev This contract simulates an Oracle that relies on a single authorized node.
 * If the off-chain node is eclipsed (isolated by malicious peers), it can be fed
 * a false blockchain reality and report manipulated data to this contract.
 */
contract VulnerableOracle {
    address public authorizedNode;
    uint256 public latestPrice;
    uint256 public lastUpdated;

    event PriceUpdated(uint256 price, uint256 timestamp);

    constructor(address _authorizedNode) {
        authorizedNode = _authorizedNode;
    }

    /**
     * @dev Updates the price. Only the authorized node can call this.
     * In an Eclipse attack, the authorized node itself is victimized and 
     * unwittingly submits malicious data.
     */
    function updatePrice(uint256 _price) external {
        require(msg.sender == authorizedNode, "Not authorized node");
        latestPrice = _price;
        lastUpdated = block.timestamp;
        
        emit PriceUpdated(_price, lastUpdated);
    }
}
