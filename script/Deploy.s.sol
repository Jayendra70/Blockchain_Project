// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/OracleToken.sol";
import "../contracts/VulnerableOracle.sol";
import "../contracts/AdvancedSecureOracle.sol";

contract DeployScript is Script {
    uint256 internal constant QUORUM = 3;
    uint256 internal constant STAKE_AMOUNT = 1000 * 10**18;
    uint256 internal constant HONEST_PRICE = 60000;
    uint256 internal constant MALICIOUS_PRICE = 1;
    string internal constant RPC_URL = "http://127.0.0.1:8545";

    function run() external {
        // Set up accounts (using standard anvil accounts)
        uint256 deployerKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerKey);
        
        // Let's use other anvil accounts for nodes
        address node1 = vm.addr(0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d);
        address node2 = vm.addr(0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a);
        address node3 = vm.addr(0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6);
        address eclipsedNode1 = vm.addr(0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a);
        address eclipsedNode2 = vm.addr(0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba);

        address[] memory nodes = new address[](5);
        nodes[0] = node1;
        nodes[1] = node2;
        nodes[2] = node3;
        nodes[3] = eclipsedNode1;
        nodes[4] = eclipsedNode2;

        vm.startBroadcast(deployerKey);

        // 1. Deploy Vulnerable Oracle
        VulnerableOracle vulnOracle = new VulnerableOracle(eclipsedNode1);
        
        // 2. Deploy Token
        OracleToken token = new OracleToken(100000);

        // 3. Deploy Advanced Oracle
        AdvancedSecureOracle oracle = new AdvancedSecureOracle(address(token), nodes, QUORUM);
        
        // 4. Set Authorized Oracle
        token.setOracleAddress(address(oracle));
        
        // 5. Distribute Tokens
        for (uint i = 0; i < nodes.length; i++) {
            token.transfer(nodes[i], STAKE_AMOUNT);
        }
        vm.stopBroadcast();

        // Set initial honest price (must broadcast as eclipsedNode1 for vulnerableOracle)
        vm.startBroadcast(0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a);
        vulnOracle.updatePrice(HONEST_PRICE);
        vm.stopBroadcast();

        // 6. Stake
        uint256[5] memory keys = [
            uint256(0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d),
            uint256(0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a),
            uint256(0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6),
            uint256(0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a),
            uint256(0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba)
        ];

        for (uint i = 0; i < nodes.length; i++) {
            vm.startBroadcast(keys[i]);
            token.approve(address(oracle), STAKE_AMOUNT);
            oracle.stake();
            vm.stopBroadcast();
        }

        generateJson(address(oracle), address(token), address(vulnOracle), node1, node2, node3, eclipsedNode1, eclipsedNode2);
    }

    function generateJson(
        address oracle, 
        address token, 
        address vulnOracle, 
        address node1, 
        address node2, 
        address node3, 
        address eclipsedNode1, 
        address eclipsedNode2
    ) internal {
        string memory s1 = string.concat("{\n  \"rpcUrl\": \"", RPC_URL, "\",\n");
        string memory s2 = string.concat("  \"oracleAddress\": \"", vm.toString(oracle), "\",\n");
        string memory s3 = string.concat("  \"tokenAddress\": \"", vm.toString(token), "\",\n");
        string memory s4 = string.concat("  \"vulnOracleAddress\": \"", vm.toString(vulnOracle), "\",\n");
        string memory s5 = string.concat("  \"requiredSignatures\": ", vm.toString(QUORUM), ",\n");
        string memory s6 = string.concat("  \"honestPrice\": ", vm.toString(HONEST_PRICE), ",\n");
        string memory s7 = string.concat("  \"maliciousPrice\": ", vm.toString(MALICIOUS_PRICE), ",\n");
        string memory s8 = "  \"nodes\": [\n";
        string memory s9 = string.concat("    { \"name\": \"Honest Node 1\", \"address\": \"", vm.toString(node1), "\", \"isEclipsed\": false },\n");
        string memory s10 = string.concat("    { \"name\": \"Honest Node 2\", \"address\": \"", vm.toString(node2), "\", \"isEclipsed\": false },\n");
        
        string memory jsonStringPart1 = string.concat(s1, s2, s3, s4, s5, s6, s7, s8, s9, s10);
        
        string memory s11 = string.concat("    { \"name\": \"Honest Node 3\", \"address\": \"", vm.toString(node3), "\", \"isEclipsed\": false },\n");
        string memory s12 = string.concat("    { \"name\": \"Eclipsed Node 1\", \"address\": \"", vm.toString(eclipsedNode1), "\", \"isEclipsed\": true },\n");
        string memory s13 = string.concat("    { \"name\": \"Eclipsed Node 2\", \"address\": \"", vm.toString(eclipsedNode2), "\", \"isEclipsed\": true }\n");
        string memory s14 = "  ]\n}\n";
        
        string memory jsonStringPart2 = string.concat(s11, s12, s13, s14);
        
        string memory jsonString = string.concat(jsonStringPart1, jsonStringPart2);

        vm.writeFile("./frontend/src/config.json", jsonString);
    }
}
