// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title OracleToken
 * @dev A simple ERC20 token used for staking in the Decentralized Oracle Network.
 * Nodes must stake this token to participate.
 */
contract OracleToken {
    string public name = "Oracle Staking Token";
    string public symbol = "OST";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public owner;
    address public oracleAddress;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(uint256 initialSupply) {
        owner = msg.sender;
        totalSupply = initialSupply * 10 ** uint256(decimals);
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function setOracleAddress(address _oracleAddress) external {
        require(msg.sender == owner, "Only owner can set oracle");
        oracleAddress = _oracleAddress;
    }

    function transfer(address to, uint256 value) public returns (bool) {
        require(balanceOf[msg.sender] >= value, "Insufficient balance");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        require(balanceOf[from] >= value, "Insufficient balance");
        require(allowance[from][msg.sender] >= value, "Allowance exceeded");
        
        balanceOf[from] -= value;
        allowance[from][msg.sender] -= value;
        balanceOf[to] += value;
        
        emit Transfer(from, to, value);
        return true;
    }

    // A function allowing the Oracle Contract to burn slashed tokens
    function burn(address from, uint256 value) external {
        require(msg.sender == oracleAddress, "Only authorized oracle can burn");
        require(balanceOf[from] >= value, "Insufficient balance to burn");
        
        balanceOf[from] -= value;
        totalSupply -= value;
        emit Transfer(from, address(0), value);
    }
}
