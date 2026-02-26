#!/bin/bash
# ============================================================
#  CLAWDUG — Mainnet Deploy Script (Base, chain 8453)
#  Usage: bash deploy.sh
# ============================================================
set -e
set -o pipefail

echo ""
echo "===================================================="
echo "  CLAWDUG — DEPLOYING TO BASE MAINNET"
echo "===================================================="
echo ""

# ---- Check env ----
: "${PRIVATE_KEY:?Need PRIVATE_KEY set}"
: "${SCORE_SIGNER_PK:?Need SCORE_SIGNER_PK set}"
: "${TREASURY:?Need TREASURY address set}"

RPC="https://mainnet.base.org"
CHAIN_ID=8453
EXPLORER="https://basescan.org"

# ---- Deps ----
echo "[1/6] Checking dependencies..."
command -v forge &>/dev/null || {
  echo "  Installing Foundry..."
  curl -L https://foundry.paradigm.xyz | bash
  export PATH="$HOME/.foundry/bin:$PATH"
  foundryup
}
command -v node &>/dev/null || { echo "ERROR: node not found"; exit 1; }

# ---- Project scaffold ----
echo "[2/6] Scaffolding Foundry project..."
rm -rf clawdug-contracts
forge init clawdug-contracts --no-git --no-commit 2>/dev/null || true
mkdir -p clawdug-contracts/src clawdug-contracts/script

# Copy contract
cp ClawDug.sol clawdug-contracts/src/ClawDug.sol

# Write Foundry config
cat > clawdug-contracts/foundry.toml << 'TOML'
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "0.8.24"
optimizer = true
optimizer_runs = 200

[rpc_endpoints]
base = "https://mainnet.base.org"

[etherscan]
base = { key = "${BASESCAN_API_KEY}", url = "https://api.basescan.org/api" }
TOML

# ---- Install OZ ----
echo "[3/6] Installing OpenZeppelin..."
cd clawdug-contracts
forge install OpenZeppelin/openzeppelin-contracts --no-git 2>/dev/null || true

# ---- Write deploy script ----
echo "[4/6] Writing deploy script..."
cat > script/Deploy.s.sol << 'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/ClawDug.sol";

contract DeployScript is Script {
    function run() external {
        address scoreSigner = vm.envAddress("SCORE_SIGNER_ADDRESS");
        address treasury    = vm.envAddress("TREASURY");

        vm.startBroadcast();

        // 1. $DUG token
        DugToken dug = new DugToken();
        console.log("DugToken:      ", address(dug));

        // 2. Agent registry (ERC-8004 compatible)
        AgentRegistry registry = new AgentRegistry();
        console.log("AgentRegistry: ", address(registry));

        // 3. Game contract
        ClawDugGame game = new ClawDugGame(
            address(dug),
            address(registry),
            scoreSigner,
            treasury
        );
        console.log("ClawDugGame:   ", address(game));

        // 4. Wire permissions
        dug.setGameContract(address(game));
        registry.transferOwnership(address(game));

        vm.stopBroadcast();

        // Output for .env
        console.log("\n# Paste into .env:");
        console.log("GAME_CONTRACT=", vm.toString(address(game)));
        console.log("DUG_TOKEN=",     vm.toString(address(dug)));
        console.log("REGISTRY=",      vm.toString(address(registry)));
    }
}
SOL

# ---- Build ----
echo "[5/6] Building contracts..."
SCORE_SIGNER_ADDRESS=$(node --input-type=module << 'JS'
import { ethers } from 'ethers';
const w = new ethers.Wallet(process.env.SCORE_SIGNER_PK);
console.log(w.address);
JS
)
export SCORE_SIGNER_ADDRESS

forge build --sizes

# ---- Deploy ----
echo "[6/6] Deploying to Base mainnet..."
DEPLOY_OUTPUT=$(forge script script/Deploy.s.sol \
  --rpc-url "$RPC" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --verify \
  --etherscan-api-key "${BASESCAN_API_KEY:-}" \
  --chain-id $CHAIN_ID \
  -vvv 2>&1)

echo "$DEPLOY_OUTPUT"

# ---- Parse addresses ----
GAME_CONTRACT=$(echo "$DEPLOY_OUTPUT" | grep "ClawDugGame:" | awk '{print $NF}')
DUG_TOKEN=$(echo "$DEPLOY_OUTPUT"     | grep "DugToken:"    | awk '{print $NF}')
REGISTRY=$(echo "$DEPLOY_OUTPUT"      | grep "AgentRegistr" | awk '{print $NF}')

cd ..

# ---- Write .env ----
cat > .env << ENV
# ClawDug — Base Mainnet
RPC_URL=https://mainnet.base.org
CHAIN_ID=8453

PRIVATE_KEY=${PRIVATE_KEY}
SCORE_SIGNER_PK=${SCORE_SIGNER_PK}
SCORE_SIGNER_ADDRESS=${SCORE_SIGNER_ADDRESS}
TREASURY=${TREASURY}

GAME_CONTRACT=${GAME_CONTRACT}
DUG_TOKEN=${DUG_TOKEN}
REGISTRY=${REGISTRY}

PORT=3847
ENV

echo ""
echo "===================================================="
echo "  DEPLOYED"
echo "===================================================="
echo "  Game:     $GAME_CONTRACT"
echo "  \$DUG:     $DUG_TOKEN"
echo "  Registry: $REGISTRY"
echo ""
echo "  Explorer: $EXPLORER/address/$GAME_CONTRACT"
echo ""

# ---- Patch contract addresses into game HTML ----
echo "Patching clawdug.html with live addresses..."
sed -i.bak \
  -e "s|GAME_CONTRACT:  '0x0000000000000000000000000000000000000000'|GAME_CONTRACT:  '${GAME_CONTRACT}'|g" \
  -e "s|DUG_TOKEN:      '0x0000000000000000000000000000000000000000'|DUG_TOKEN:      '${DUG_TOKEN}'|g" \
  -e "s|REGISTRY:       '0x0000000000000000000000000000000000000000'|REGISTRY:       '${REGISTRY}'|g" \
  clawdug.html
rm -f clawdug.html.bak
echo "  clawdug.html patched."

# ---- Install API deps ----
echo ""
echo "Installing API dependencies..."
npm install

echo ""
echo "===================================================="
echo "  READY TO RUN"
echo "===================================================="
echo "  Start API:  npm start"
echo "  Open game:  open clawdug.html"
echo "  Leaderboard: http://localhost:3847/leaderboard"
echo "  Agent docs:  http://localhost:3847/docs"
echo "===================================================="
echo ""
