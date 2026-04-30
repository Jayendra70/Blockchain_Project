#!/bin/bash

set -euo pipefail

echo "Deploying contracts to local Anvil node..."

# Run the Forge script
forge script script/Deploy.s.sol:DeployScript --rpc-url http://localhost:8545 --broadcast

echo "Copying ABIs to frontend..."
mkdir -p frontend/src

# Copy the ABI artifacts.
cp artifacts/AdvancedSecureOracle.sol/AdvancedSecureOracle.json frontend/src/
cp artifacts/OracleToken.sol/OracleToken.json frontend/src/
cp artifacts/VulnerableOracle.sol/VulnerableOracle.json frontend/src/

echo "Deployment complete. Config and ABI exported to frontend."
