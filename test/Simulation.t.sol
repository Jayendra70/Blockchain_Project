// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/OracleToken.sol";
import "../contracts/AdvancedSecureOracle.sol";
import "../contracts/VulnerableOracle.sol";

contract SimulationTest is Test {
    OracleToken token;
    AdvancedSecureOracle advancedOracle;
    VulnerableOracle vulnerableOracle;

    address[] nodes;
    address attacker;

    function setUp() public {
        attacker = address(0x999);
        nodes.push(address(0x1));
        nodes.push(address(0x2));
        nodes.push(address(0x3));
        nodes.push(address(0x4));
        nodes.push(address(0x5));

        // Deploy Token
        token = new OracleToken(10000);
        
        // Deploy Vulnerable (Attacker isolates and acts as the authorized node's feed)
        vulnerableOracle = new VulnerableOracle(nodes[0]);

        // Deploy Advanced
        advancedOracle = new AdvancedSecureOracle(address(token), nodes, 3);
        
        // Set authorized oracle for token burning
        token.setOracleAddress(address(advancedOracle));

        // Fund nodes and stake
        for(uint i=0; i<nodes.length; i++) {
            token.transfer(nodes[i], 1000 * 10**18);
            vm.startPrank(nodes[i]);
            token.approve(address(advancedOracle), 1000 * 10**18);
            advancedOracle.stake();
            vm.stopPrank();
        }
    }

    function test_VulnerableOracle_Attack() public {
        // Eclipsed node (nodes[0]) feeds manipulated price because it's isolated
        vm.prank(nodes[0]);
        vulnerableOracle.updatePrice(1500);
        assertEq(vulnerableOracle.latestPrice(), 1500);
    }

    function test_AdvancedOracle_AccessControl_Burn() public {
        vm.prank(attacker);
        vm.expectRevert("Only authorized oracle can burn");
        token.burn(nodes[0], 100);
    }

    function test_AdvancedOracle_ConstructorRejectsInvalidQuorum() public {
        vm.expectRevert("Invalid quorum");
        new AdvancedSecureOracle(address(token), nodes, 0);

        vm.expectRevert("Invalid quorum");
        new AdvancedSecureOracle(address(token), nodes, 6);
    }

    function test_AdvancedOracle_ReportsRoundState() public {
        (
            uint256 round,
            AdvancedSecureOracle.Phase phase,
            uint256 commits,
            uint256 reveals,
            uint256 price,
            uint256 activeNodes,
            uint256 quorum
        ) = advancedOracle.getRoundState();

        assertEq(round, 1);
        assertEq(uint256(phase), uint256(AdvancedSecureOracle.Phase.Commit));
        assertEq(commits, 0);
        assertEq(reveals, 0);
        assertEq(price, 0);
        assertEq(activeNodes, 5);
        assertEq(quorum, 3);
    }

    function test_AdvancedOracle_Eclipse_Simulation() public {
        // Round 1
        uint256 honestPrice = 1000;
        uint256 attackerPrice = 1500;
        uint256 salt = 1234;

        // Commits
        for(uint i=0; i<4; i++) {
            vm.prank(nodes[i]);
            advancedOracle.commitPrice(keccak256(abi.encodePacked(honestPrice, salt)));
        }
        vm.prank(nodes[4]); // The eclipsed node
        advancedOracle.commitPrice(keccak256(abi.encodePacked(attackerPrice, salt)));

        // Reveals
        for(uint i=0; i<4; i++) {
            vm.prank(nodes[i]);
            advancedOracle.revealPrice(honestPrice, salt);
        }
        vm.prank(nodes[4]);
        advancedOracle.revealPrice(attackerPrice, salt); // This should finalize the round

        // 1. Median price should be 1000
        assertEq(advancedOracle.latestPrice(), 1000);

        // 2. Anomaly detection: node 4 should be challenged
        (bool isChallenged, , uint256 amountToSlash) = advancedOracle.nodeChallenges(nodes[4]);
        assertTrue(isChallenged);
        assertEq(amountToSlash, 1000 * 10**18);
        assertEq(advancedOracle.getActiveNodeCount(), 4);

        // 3. Fast forward time and slash
        vm.warp(block.timestamp + 1 days + 1);
        advancedOracle.executeSlashing(nodes[4]);

        assertEq(advancedOracle.stakes(nodes[4]), 0); // Slashed stake is 0
        assertEq(token.balanceOf(nodes[4]), 0); // Liquid balance is 0

        // 4. Verify Redistribution (1000 slashed -> 500 burned, 500 split among 4 honest nodes = 125 each)
        assertEq(token.balanceOf(nodes[0]), 125 * 10**18);
        assertEq(token.balanceOf(nodes[1]), 125 * 10**18);
        assertEq(token.balanceOf(nodes[2]), 125 * 10**18);
        assertEq(token.balanceOf(nodes[3]), 125 * 10**18);
    }

    function test_AdvancedOracle_ForceCommitTimeout() public {
        // 2 nodes commit, 3 withhold
        uint256 salt = 1234;
        vm.prank(nodes[0]);
        advancedOracle.commitPrice(keccak256(abi.encodePacked(uint256(1000), salt)));
        vm.prank(nodes[1]);
        advancedOracle.commitPrice(keccak256(abi.encodePacked(uint256(1000), salt)));

        // Fast forward past commit timeout
        vm.warp(block.timestamp + 5 minutes + 1);

        // Anyone can force commit timeout
        vm.prank(attacker);
        advancedOracle.forceCommitTimeout();

        // Round should be reset, and nodes 2,3,4 challenged
        assertEq(advancedOracle.currentRound(), 2);
        
        (bool isChallenged, ,) = advancedOracle.nodeChallenges(nodes[2]);
        assertTrue(isChallenged);
    }

    function test_AdvancedOracle_ForceRevealTimeout_WithQuorum() public {
        uint256 salt = 1234;
        uint256 honestPrice = 1000;

        // 5 nodes commit
        for(uint i=0; i<5; i++) {
            vm.prank(nodes[i]);
            advancedOracle.commitPrice(keccak256(abi.encodePacked(honestPrice, salt)));
        }

        // 3 nodes reveal (quorum met)
        for(uint i=0; i<3; i++) {
            vm.prank(nodes[i]);
            advancedOracle.revealPrice(honestPrice, salt);
        }

        // 2 nodes withhold. Fast forward past reveal timeout.
        vm.warp(block.timestamp + 5 minutes + 1);

        // Force timeout
        advancedOracle.forceTimeout();

        // 1. Median price should be successfully updated!
        assertEq(advancedOracle.latestPrice(), 1000);

        // 2. The withholding nodes should be challenged
        (bool isChallenged, , ) = advancedOracle.nodeChallenges(nodes[3]);
        assertTrue(isChallenged);
    }
}
