// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./OracleToken.sol";

/**
 * @title AdvancedSecureOracle
 * @dev A hybrid network and economic defense mechanism against Eclipse attacks.
 * Implements decentralized anomaly detection (Mean Absolute Deviation) and incentive enforcement.
 */
contract AdvancedSecureOracle {
    OracleToken public immutable token;
    
    uint256 public requiredStake = 1000 * 10**18;
    uint256 public immutable requiredSignatures; // Minimum Quorum (e.g. 3/5)
    uint256 public immutable totalAuthorizedNodes;
    
    mapping(address => uint256) public stakes;
    mapping(address => bool) public isAuthorizedNode;

    uint256 public latestPrice;
    uint256 public lastUpdated;
    uint256 public currentRound = 1;

    enum Phase { Commit, Reveal }
    Phase public currentPhase = Phase.Commit;
    uint256 public commitsThisRound;
    uint256 public revealsThisRound;
    
    // Timeout & Challenge Variables
    uint256 public roundStartTime;
    uint256 public commitStartTime;
    uint256 public timeoutDuration = 5 minutes;
    uint256 public commitTimeoutDuration = 5 minutes;
    uint256 public challengePeriod = 1 days;
    address[] public authorizedNodesList;

    struct Challenge {
        bool isChallenged;
        uint256 challengedAt;
        uint256 amountToSlash;
    }
    mapping(address => Challenge) public nodeChallenges;

    // Track submissions
    mapping(uint256 => mapping(address => bytes32)) public commitments;
    mapping(uint256 => mapping(address => bool)) public hasRevealed;
    
    address[] public roundCommitters;
    address[] public roundSubmitters;
    uint256[] public roundPrices;

    event Staked(address indexed node, uint256 amount);
    event PriceCommitted(address indexed node, uint256 round);
    event PriceRevealed(address indexed node, uint256 price, uint256 round);
    event RoundFinalized(uint256 finalPrice, uint256 round);
    event NodeChallenged(address indexed node, string reason, uint256 amount);
    event NodeSlashed(address indexed node, uint256 amountSlashed);
    event RewardDistributed(uint256 totalReward, uint256 honestNodeCount);
    event RoundReset(uint256 round);
    event PhaseTransition(uint256 indexed round, Phase phase, uint256 activeNodeCount);

    constructor(address _tokenAddress, address[] memory _nodes, uint256 _requiredSignatures) {
        require(_tokenAddress != address(0), "Invalid token");
        require(_nodes.length > 0, "No nodes configured");
        require(_requiredSignatures > 0 && _requiredSignatures <= _nodes.length, "Invalid quorum");

        token = OracleToken(_tokenAddress);
        requiredSignatures = _requiredSignatures;
        for (uint256 i = 0; i < _nodes.length; i++) {
            require(_nodes[i] != address(0), "Invalid node");
            require(!isAuthorizedNode[_nodes[i]], "Duplicate node");
            isAuthorizedNode[_nodes[i]] = true;
            authorizedNodesList.push(_nodes[i]);
        }
        totalAuthorizedNodes = _nodes.length;
        commitStartTime = block.timestamp;
    }

    function getActiveNodeCount() public view returns (uint256 activeCount) {
        for (uint256 i = 0; i < authorizedNodesList.length; i++) {
            address node = authorizedNodesList[i];
            if (isAuthorizedNode[node] && stakes[node] >= requiredStake) {
                activeCount++;
            }
        }
    }

    function getRoundState()
        external
        view
        returns (
            uint256 round,
            Phase phase,
            uint256 commits,
            uint256 reveals,
            uint256 price,
            uint256 activeNodes,
            uint256 quorum
        )
    {
        return (
            currentRound,
            currentPhase,
            commitsThisRound,
            revealsThisRound,
            latestPrice,
            getActiveNodeCount(),
            requiredSignatures
        );
    }

    function stake() external {
        require(isAuthorizedNode[msg.sender], "Not an authorized node");
        require(stakes[msg.sender] == 0, "Already staked");
        require(!nodeChallenges[msg.sender].isChallenged, "Node is currently challenged");
        
        require(token.transferFrom(msg.sender, address(this), requiredStake), "Stake transfer failed");
        stakes[msg.sender] = requiredStake;
        
        emit Staked(msg.sender, requiredStake);
    }

    function commitPrice(bytes32 _commitment) external {
        require(currentPhase == Phase.Commit, "Not in Commit Phase");
        require(isAuthorizedNode[msg.sender], "Not an authorized node");
        require(stakes[msg.sender] >= requiredStake, "Must stake first");
        require(commitments[currentRound][msg.sender] == bytes32(0), "Already committed");
        require(!nodeChallenges[msg.sender].isChallenged, "Node is currently challenged");

        commitments[currentRound][msg.sender] = _commitment;
        roundCommitters.push(msg.sender);
        commitsThisRound++;

        emit PriceCommitted(msg.sender, currentRound);

        // Auto-transition only if all active nodes have committed.
        uint256 activeCount = getActiveNodeCount();

        if (commitsThisRound == activeCount) {
            _moveToRevealPhase(activeCount);
        }
    }

    function revealPrice(uint256 _price, uint256 _salt) external {
        require(currentPhase == Phase.Reveal, "Not in Reveal Phase");
        require(commitments[currentRound][msg.sender] != bytes32(0), "Did not commit");
        require(!hasRevealed[currentRound][msg.sender], "Already revealed");

        bytes32 expectedCommitment = keccak256(abi.encodePacked(_price, _salt));
        require(expectedCommitment == commitments[currentRound][msg.sender], "Invalid reveal");

        hasRevealed[currentRound][msg.sender] = true;
        roundSubmitters.push(msg.sender);
        roundPrices.push(_price);
        revealsThisRound++;

        emit PriceRevealed(msg.sender, _price, currentRound);

        // Require all committers to reveal or timeout
        if (revealsThisRound >= requiredSignatures && revealsThisRound == commitsThisRound) {
            _finalizeRound();
        }
    }

    function forceTimeout() external {
        require(currentPhase == Phase.Reveal, "Not in Reveal Phase");
        require(block.timestamp > roundStartTime + timeoutDuration, "Timeout not reached");

        for (uint256 i = 0; i < roundCommitters.length; i++) {
            address node = roundCommitters[i];
            if (!hasRevealed[currentRound][node]) {
                _initiateChallenge(node, "Failed to reveal in time (DoS Attack)");
            }
        }

        if (revealsThisRound >= requiredSignatures) {
            _finalizeRound();
        } else {
            emit RoundReset(currentRound);
            _resetRound();
        }
    }

    function forceCommitTimeout() external {
        require(currentPhase == Phase.Commit, "Not in Commit Phase");
        require(block.timestamp > commitStartTime + commitTimeoutDuration, "Timeout not reached");

        for (uint256 i = 0; i < authorizedNodesList.length; i++) {
            address node = authorizedNodesList[i];
            if (isAuthorizedNode[node] && stakes[node] >= requiredStake) {
                if (commitments[currentRound][node] == bytes32(0)) {
                    _initiateChallenge(node, "Failed to commit in time (DoS Attack)");
                }
            }
        }

        if (commitsThisRound >= requiredSignatures) {
            // Quorum met: Transition to Reveal Phase
            _moveToRevealPhase(getActiveNodeCount());
        } else {
            // Quorum failed: Reset Round
            emit RoundReset(currentRound);
            _resetRound();
        }
    }

    function _sort(uint256[] memory data) internal pure returns (uint256[] memory) {
        uint256 length = data.length;
        for (uint256 i = 0; i < length; i++) {
            for (uint256 j = i + 1; j < length; j++) {
                if (data[i] > data[j]) {
                    uint256 temp = data[i];
                    data[i] = data[j];
                    data[j] = temp;
                }
            }
        }
        return data;
    }

    function _finalizeRound() internal {
        uint256 length = roundPrices.length;
        
        // 1. Calculate Median
        uint256[] memory memoryPrices = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            memoryPrices[i] = roundPrices[i];
        }
        
        memoryPrices = _sort(memoryPrices);
        
        uint256 medianPrice;
        if (length % 2 == 0) {
            medianPrice = (memoryPrices[(length / 2) - 1] + memoryPrices[length / 2]) / 2;
        } else {
            medianPrice = memoryPrices[length / 2];
        }
        
        latestPrice = medianPrice;
        lastUpdated = block.timestamp;
        
        // 2. Anomaly Detection: Calculate Mean Absolute Deviation (MAD)
        // Note: Due to gas-inefficiency and complexity of floating-point math (e.g., Variance/Standard Deviation) in Solidity,
        // we use Mean Absolute Deviation as an efficient linear approximation of variance for outlier detection.
        uint256 totalDeviation = 0;
        for (uint256 i = 0; i < length; i++) {
            uint256 price = roundPrices[i];
            uint256 diff = price > medianPrice ? price - medianPrice : medianPrice - price;
            totalDeviation += diff;
        }
        uint256 meanAbsoluteDeviation = totalDeviation / length;
        
        // Minimum allowable deviation (fallback if all nodes submit exact same price)
        uint256 minThreshold = medianPrice / 20; // 5% base threshold
        uint256 dynamicThreshold = meanAbsoluteDeviation * 2; // Equivalent to crude Z-Score > 2
        
        uint256 finalThreshold = dynamicThreshold > minThreshold ? dynamicThreshold : minThreshold;

        // 3. Initiate Challenges for Anomalies
        for (uint256 i = 0; i < length; i++) {
            uint256 submittedPrice = roundPrices[i];
            uint256 diff = submittedPrice > medianPrice ? submittedPrice - medianPrice : medianPrice - submittedPrice;
            
            if (diff > finalThreshold) {
                address maliciousNode = roundSubmitters[i];
                _initiateChallenge(maliciousNode, "Statistical Anomaly Detected (MAD)");
            }
        }

        emit RoundFinalized(latestPrice, currentRound);
        _resetRound();
    }

    // False Positive Protection: Challenge Period
    // Instead of instantly slashing, nodes are placed in a challenge state.
    function _initiateChallenge(address maliciousNode, string memory reason) internal {
        require(!nodeChallenges[maliciousNode].isChallenged, "Already challenged");
        
        nodeChallenges[maliciousNode] = Challenge({
            isChallenged: true,
            challengedAt: block.timestamp,
            amountToSlash: stakes[maliciousNode]
        });
        
        isAuthorizedNode[maliciousNode] = false; // Temporarily suspend
        emit NodeChallenged(maliciousNode, reason, stakes[maliciousNode]);
    }

    // Any user can execute the slash after the challenge period expires
    function executeSlashing(address maliciousNode) external {
        require(nodeChallenges[maliciousNode].isChallenged, "Node is not challenged");
        require(block.timestamp >= nodeChallenges[maliciousNode].challengedAt + challengePeriod, "Challenge period active");

        uint256 amountToSlash = nodeChallenges[maliciousNode].amountToSlash;
        stakes[maliciousNode] = 0;
        nodeChallenges[maliciousNode].isChallenged = false;
        nodeChallenges[maliciousNode].challengedAt = 0;
        nodeChallenges[maliciousNode].amountToSlash = 0;

        // Burn 50% of the slashed amount
        uint256 burnAmount = amountToSlash / 2;
        token.burn(address(this), burnAmount);
        
        // Redistribute the remaining 50% to all active (honest) nodes
        uint256 redistributeAmount = amountToSlash - burnAmount;
        uint256 activeCount = 0;
        
        for (uint256 i = 0; i < authorizedNodesList.length; i++) {
            if (isAuthorizedNode[authorizedNodesList[i]]) {
                activeCount++;
            }
        }
        
        if (activeCount > 0) {
            uint256 rewardPerNode = redistributeAmount / activeCount;
            for (uint256 i = 0; i < authorizedNodesList.length; i++) {
                address node = authorizedNodesList[i];
                if (isAuthorizedNode[node]) {
                    // Distribute directly to the node's liquid wallet balance
                    require(token.transfer(node, rewardPerNode), "Reward transfer failed");
                }
            }
            emit RewardDistributed(redistributeAmount, activeCount);
        } else {
            // Fallback: if no active nodes exist, burn the rest
            token.burn(address(this), redistributeAmount);
        }
        
        emit NodeSlashed(maliciousNode, amountToSlash);
    }

    function _moveToRevealPhase(uint256 activeCount) internal {
        currentPhase = Phase.Reveal;
        roundStartTime = block.timestamp;
        emit PhaseTransition(currentRound, Phase.Reveal, activeCount);
    }

    function _resetRound() internal {
        currentRound++;
        currentPhase = Phase.Commit;
        commitsThisRound = 0;
        revealsThisRound = 0;
        roundStartTime = 0;
        commitStartTime = block.timestamp;
        delete roundSubmitters;
        delete roundPrices;
        delete roundCommitters;
    }
}
