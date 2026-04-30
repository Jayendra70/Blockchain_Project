// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title SecureOracle
 * @dev This contract mitigates Eclipse attacks by requiring price updates 
 * to be verified by a quorum of independent nodes.
 * Eclipsing one node is feasible, but eclipsing a distributed quorum is
 * astronomically difficult.
 */
contract SecureOracle {
    mapping(address => bool) public authorizedNodes;
    uint256 public requiredSignatures;
    uint256 public totalNodes;

    uint256 public latestPrice;
    uint256 public lastUpdated;

    // To prevent replay attacks and track submissions per round
    uint256 public currentRound;
    mapping(uint256 => mapping(address => bool)) public hasSubmitted;
    mapping(uint256 => uint256[]) public roundPrices;

    event PriceUpdated(uint256 price, uint256 timestamp, uint256 round);

    constructor(address[] memory _nodes, uint256 _requiredSignatures) {
        require(_requiredSignatures <= _nodes.length, "Invalid required signatures");
        require(_requiredSignatures > 0, "Requires at least 1 signature");

        for (uint256 i = 0; i < _nodes.length; i++) {
            require(!authorizedNodes[_nodes[i]], "Duplicate node");
            authorizedNodes[_nodes[i]] = true;
        }
        totalNodes = _nodes.length;
        requiredSignatures = _requiredSignatures;
        currentRound = 1;
    }

    /**
     * @dev Nodes submit their price. Once the quorum is reached for a round,
     * the median (or average) price is set as the latest.
     */
    function submitPrice(uint256 _price) external {
        require(authorizedNodes[msg.sender], "Not authorized node");
        require(!hasSubmitted[currentRound][msg.sender], "Already submitted this round");

        hasSubmitted[currentRound][msg.sender] = true;
        roundPrices[currentRound].push(_price);

        if (roundPrices[currentRound].length >= requiredSignatures) {
            _finalizeRound();
        }
    }

    function _finalizeRound() internal {
        uint256 sum = 0;
        uint256 count = roundPrices[currentRound].length;
        for (uint256 i = 0; i < count; i++) {
            sum += roundPrices[currentRound][i];
        }
        
        latestPrice = sum / count; // Simple average for demonstration
        lastUpdated = block.timestamp;
        
        emit PriceUpdated(latestPrice, lastUpdated, currentRound);
        currentRound++;
    }
}
