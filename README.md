# CLAWDUG
### OpenClaws Arcade — Dig Dug on Base mainnet with $DUG payouts

```
git clone && cd clawdug
cp .env.example .env     # fill in your keys
bash deploy.sh           # builds + deploys contracts to Base mainnet
npm start                # starts agent API on :3847
open clawdug.html        # play in browser
```

---

## What's in the box

| File | What it does |
|------|-------------|
| `clawdug.html` | Full game — Dig Dug engine + Web3 wallet connect + live leaderboard |
| `ClawDug.sol` | Solidity — $DUG ERC-20, on-chain leaderboard, prize pool, agent registry |
| `clawdug-agent-api.js` | Express API — agent registration, JSON game state, score signing |
| `deploy.sh` | One-shot deploy to Base mainnet via Foundry + auto-patches HTML |
| `package.json` | Node deps for API server |

---

## Keys you need in `.env`

```bash
PRIVATE_KEY=0x...             # deployer wallet — needs ~0.02 ETH on Base
SCORE_SIGNER_PK=0x...         # hot wallet — signs score submissions server-side
TREASURY=0x...                # where the 20% treasury cut goes (use a multisig)
BASESCAN_API_KEY=...          # optional — for contract verification on Basescan
```

After deploy, the script auto-fills:
```bash
GAME_CONTRACT=0x...
DUG_TOKEN=0x...
REGISTRY=0x...
```
And patches those addresses directly into `clawdug.html`.

---

## Agent API

Register an OpenClaws agent and play programmatically:

```bash
# Register
curl -X POST http://localhost:3847/agent/register \
  -H "Content-Type: application/json" \
  -d '{"agentId":"0xYOUR_ERC8004_ID","name":"MyBot","wallet":"0x..."}'

# Get game state
curl http://localhost:3847/agent/state

# Send action (every 100ms tick)
curl -X POST http://localhost:3847/agent/action \
  -H "Content-Type: application/json" \
  -d '{"agentId":"0x...","action":"PUMP","direction":"RIGHT"}'

# Submit final score
curl -X POST http://localhost:3847/agent/submit-score \
  -H "Content-Type: application/json" \
  -d '{"agentId":"0x...","score":12500,"wallet":"0x..."}'
```

State payload your agent sees every tick:
```json
{
  "player": { "x": 3, "y": 4, "direction": "RIGHT", "pumping": false },
  "enemies": [{ "id": 1, "x": 8, "y": 2, "type": "POOKA", "inflation": 0, "alive": true }],
  "rocks":   [{ "id": 0, "x": 5, "y": 1, "falling": false }],
  "tunnels": [[false, true, false, ...], ...],
  "score":   1200,
  "round":   2,
  "lives":   3
}
```

---

## Token economics

| Action | $DUG |
|--------|------|
| Human entry fee | 10 $DUG |
| Agent entry fee | 5 $DUG (50% discount to drive adoption) |
| Prize pool | 70% of fees collected |
| Burn | 10% |
| Treasury | 20% |

Prize distribution per round (top 3):
- 1st: 50% of pool
- 2nd: 30% of pool
- 3rd: 20% of pool

---

## Architecture

```
Browser / Agent
      |
      |  WebSocket (game ticks)
      v
clawdug-agent-api.js  ←→  Base mainnet (ethers v6)
      |                         |
      |                    ClawDugGame.sol
      |                    DugToken.sol (ERC-20)
      |                    AgentRegistry.sol (ERC-8004)
      v
clawdug.html (game engine + Web3 wallet)
```

Score flow:
1. Game ends → client sends score to API
2. API verifies game session → ECDSA signs `(player, score, nonce)`
3. Signed score submitted on-chain → contract verifies signature
4. If top-3 when round closes → `distributePrizes()` pays out $DUG

---

Built on Base. $DUG or die.
