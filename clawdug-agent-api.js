// ============================================================
//  CLAWDUG AGENT API SERVER
//  Node.js / Express — runs alongside the game
//
//  Endpoints:
//    POST /agent/register      — Register an OpenClaws agent
//    GET  /agent/state         — Full game state (JSON)
//    POST /agent/action        — Send game action
//    POST /agent/submit-score  — Sign & submit score on-chain
//    GET  /leaderboard         — Combined leaderboard
//    GET  /leaderboard/agents  — Agent-only board
//    GET  /leaderboard/humans  — Human-only board
//    GET  /epoch               — Current prize epoch info
//    WS   /agent/stream        — Real-time game state stream (10Hz)
//
//  Install:
//    npm install express ethers ws cors dotenv
//  Run:
//    node clawdug-agent-api.js
// ============================================================

import express    from 'express';
import { WebSocketServer } from 'ws';
import { ethers }  from 'ethers';
import cors        from 'cors';
import crypto      from 'crypto';
import { createServer } from 'http';
import dotenv      from 'dotenv';

dotenv.config();

// ============================================================
//  CONFIG
// ============================================================
const PORT            = process.env.PORT || 3847;
const CHAIN_ID        = 8453;                          // Base mainnet
const RPC_URL         = process.env.RPC_URL || 'https://mainnet.base.org';
const SCORE_SIGNER_PK = process.env.SCORE_SIGNER_PK;  // Server signing key
const GAME_CONTRACT   = process.env.GAME_CONTRACT;
const DUG_TOKEN       = process.env.DUG_TOKEN;
const REGISTRY        = process.env.REGISTRY;

// ============================================================
//  ABI FRAGMENTS  (just what we need)
// ============================================================
const GAME_ABI = [
  'function submitScore(uint256 score, uint256 round, uint256 kills, bytes32 sessionId, uint256 signedAt, bytes calldata signature) external',
  'function getHumanLeaderboard() external view returns (tuple(address player, uint256 score, uint256 round, uint256 kills, bool isAgent, uint256 timestamp, bytes32 sessionId)[20])',
  'function getAgentLeaderboard() external view returns (tuple(address player, uint256 score, uint256 round, uint256 kills, bool isAgent, uint256 timestamp, bytes32 sessionId)[20])',
  'function getCurrentEpoch() external view returns (tuple(uint256 id, uint256 startTime, uint256 endTime, uint256 prizePool, uint256 burnAmount, uint256 treasuryAmount, bool settled, address humanWinner, address agentWinner, uint256 humanTopScore, uint256 agentTopScore))',
  'function timeUntilEpochEnd() external view returns (uint256)',
  'event ScoreSubmitted(address indexed player, uint256 score, uint256 round, uint256 kills, bool isAgent, uint256 epochId, bytes32 sessionId)',
];

const REGISTRY_ABI = [
  'function register(bytes32 agentId, string calldata name, bool isAgent) external',
  'function getProfile(address wallet) external view returns (tuple(bytes32 agentId, string name, address wallet, bool isAgent, uint256 gamesPlayed, uint256 totalScore, uint256 bestScore, uint256 registeredAt))',
];

const DUG_ABI = [
  'function balanceOf(address account) external view returns (uint256)',
  'function totalSupply() external view returns (uint256)',
  'function approve(address spender, uint256 amount) external returns (bool)',
];

// ============================================================
//  BLOCKCHAIN SETUP
// ============================================================
let provider, signer, gameContract, registryContract, dugContract;

function initChain() {
  if (!SCORE_SIGNER_PK || !GAME_CONTRACT) {
    console.warn('[Chain] Missing env vars — running in mock mode');
    return false;
  }
  provider        = new ethers.JsonRpcProvider(RPC_URL, CHAIN_ID);
  signer          = new ethers.Wallet(SCORE_SIGNER_PK, provider);
  gameContract    = new ethers.Contract(GAME_CONTRACT, GAME_ABI, signer);
  registryContract= new ethers.Contract(REGISTRY, REGISTRY_ABI, signer);
  dugContract     = new ethers.Contract(DUG_TOKEN, DUG_ABI, provider);
  console.log('[Chain] Connected to Base. Signer:', signer.address);
  return true;
}

const chainReady = initChain();

// ============================================================
//  IN-MEMORY GAME STATE  (authoritative server state)
//  In production, one instance per active game session
// ============================================================
const activeSessions = new Map();  // sessionId -> GameSession

class GameSession {
  constructor(agentAddress, agentId, isAgent) {
    this.sessionId    = '0x' + crypto.randomBytes(32).toString('hex');
    this.agentAddress = agentAddress;
    this.agentId      = agentId;
    this.isAgent      = isAgent;
    this.startTime    = Date.now();
    this.lastAction   = Date.now();
    this.gameState    = this._initialState();
    this.actionQueue  = [];
    this.score        = 0;
    this.kills        = 0;
    this.round        = 1;
    this.alive        = true;
    this.scoreVerified= false;
    this.wsClients    = new Set();
  }

  _initialState() {
    return {
      frame:   0,
      score:   0,
      lives:   3,
      round:   1,
      player:  { x: 32, y: 32, tileR: 1, tileC: 1, dir: 1, alive: true, invincible: false, hasPump: false },
      enemies: [
        { type: 'POOKA', x: 384, y: 128, tileR: 4, tileC: 12, alive: true, ghost: false, pumped: false, inflate: 0 },
        { type: 'POOKA', x: 320, y: 192, tileR: 6, tileC: 10, alive: true, ghost: false, pumped: false, inflate: 0 },
        { type: 'FYGAR', x: 256, y: 256, tileR: 8, tileC: 8,  alive: true, ghost: false, pumped: false, inflate: 0 },
        { type: 'POOKA', x: 352, y: 320, tileR: 10, tileC: 11,alive: true, ghost: false, pumped: false, inflate: 0 },
        { type: 'FYGAR', x: 64,  y: 192, tileR: 6, tileC: 2,  alive: true, ghost: false, pumped: false, inflate: 0 },
      ],
      rocks: [
        { r: 3, c: 5, x: 160, y: 96, falling: false, active: true },
        { r: 5, c: 7, x: 224, y: 160, falling: false, active: true },
        { r: 7, c: 2, x: 64,  y: 224, falling: false, active: true },
      ],
      grid: Array(17).fill(null).map((_, r) => Array(15).fill(r < 1 ? 0 : 1)),
      actions: ['move_up','move_down','move_left','move_right','fire_pump','release_pump']
    };
  }

  // Simulate a tick of game state (simplified — real state lives in browser)
  tick(action) {
    this.gameState.frame++;
    this.lastAction = Date.now();

    if (!action) return;

    const { player, enemies } = this.gameState;

    // Apply action effects
    switch (action) {
      case 'move_right': player.x = Math.min(player.x + 4, 448); player.dir = 1; break;
      case 'move_left':  player.x = Math.max(player.x - 4, 0);   player.dir = 3; break;
      case 'move_down':  player.y = Math.min(player.y + 4, 528);  player.dir = 2; break;
      case 'move_up':    player.y = Math.max(player.y - 4, 0);    player.dir = 0; break;
      case 'fire_pump':  player.hasPump = true; break;
      case 'release_pump': player.hasPump = false; break;
    }

    player.tileR = Math.round(player.y / 32);
    player.tileC = Math.round(player.x / 32);

    // Undig tile
    if (player.tileR >= 1 && player.tileR < 17 && player.tileC >= 0 && player.tileC < 15) {
      this.gameState.grid[player.tileR][player.tileC] = 0;
    }
  }

  // Sign the final score for on-chain submission
  async signScore() {
    if (!chainReady) {
      // Mock signature in dev mode
      return {
        sessionId: this.sessionId,
        score:     this.score,
        round:     this.round,
        kills:     this.kills,
        signedAt:  Math.floor(Date.now() / 1000),
        signature: '0x' + crypto.randomBytes(65).toString('hex'),
        mock:      true
      };
    }

    const signedAt = Math.floor(Date.now() / 1000);
    const msgHash = ethers.solidityPackedKeccak256(
      ['address', 'uint256', 'uint256', 'uint256', 'bytes32', 'uint256', 'uint256'],
      [this.agentAddress, this.score, this.round, this.kills, this.sessionId, signedAt, CHAIN_ID]
    );
    const signature = await signer.signMessage(ethers.getBytes(msgHash));
    this.scoreVerified = true;

    return {
      sessionId: this.sessionId,
      score:     this.score,
      round:     this.round,
      kills:     this.kills,
      signedAt,
      signature,
      mock:      false
    };
  }
}

// ============================================================
//  MOCK LEADERBOARD  (used when chain not connected)
// ============================================================
const mockLeaderboard = {
  agents: [
    { player: '0xDEAD...BEEF', name: 'ClawBot-Prime', score: 48200, round: 9, kills: 47, timestamp: Date.now() - 3600000 },
    { player: '0xC0DE...CAFE', name: 'Pooka-Hunter-7', score: 31500, round: 6, kills: 31, timestamp: Date.now() - 7200000 },
    { player: '0xABCD...1234', name: 'RockMaster-AI', score: 22100, round: 4, kills: 22, timestamp: Date.now() - 10800000 },
  ],
  humans: [
    { player: '0x1234...5678', name: 'dutchiono', score: 18500, round: 3, kills: 18, timestamp: Date.now() - 1800000 },
    { player: '0x8765...4321', name: 'DugMaster', score: 12000, round: 2, kills: 12, timestamp: Date.now() - 5400000 },
  ],
};

// ============================================================
//  EXPRESS APP
// ============================================================
const app    = express();
const server = createServer(app);
const wss    = new WebSocketServer({ server, path: '/agent/stream' });

app.use(cors());
app.use(express.json());

// ---- Rate limiter (simple) ----
const rateLimits = new Map();
function rateLimit(ip, limit = 30, windowMs = 60000) {
  const now = Date.now();
  const key = `${ip}:${Math.floor(now / windowMs)}`;
  const count = (rateLimits.get(key) || 0) + 1;
  rateLimits.set(key, count);
  if (count > limit) return false;
  // Cleanup old keys
  if (rateLimits.size > 10000) {
    for (const [k] of rateLimits) {
      if (!k.includes(String(Math.floor(now / windowMs)))) rateLimits.delete(k);
    }
  }
  return true;
}

// ============================================================
//  ROUTES
// ============================================================

// Health check
app.get('/health', (req, res) => {
  res.json({
    ok:          true,
    service:     'ClawDug Agent API',
    version:     '1.0.0',
    chainReady,
    activeSessions: activeSessions.size,
    timestamp:   Date.now()
  });
});

// ---- Register agent ----
app.post('/agent/register', async (req, res) => {
  const { agentId, name, wallet, isAgent = true } = req.body;
  if (!agentId || !name || !wallet) {
    return res.status(400).json({ error: 'agentId, name, wallet required' });
  }
  if (!ethers.isAddress(wallet)) {
    return res.status(400).json({ error: 'invalid wallet address' });
  }

  try {
    let txHash = null;
    if (chainReady) {
      // Register on-chain
      const agentIdBytes = ethers.zeroPadBytes(
        ethers.toUtf8Bytes(agentId.slice(0, 32)), 32
      );
      const tx = await registryContract.register(agentIdBytes, name, isAgent);
      await tx.wait();
      txHash = tx.hash;
    }

    // Create session
    const session = new GameSession(wallet, agentId, isAgent);
    activeSessions.set(session.sessionId, session);

    res.json({
      ok:        true,
      sessionId: session.sessionId,
      txHash,
      message:   isAgent
        ? `Agent "${name}" registered. Use sessionId for all subsequent calls.`
        : `Human player "${name}" registered.`,
      endpoints: {
        state:       `GET  /agent/state?session=${session.sessionId}`,
        action:      `POST /agent/action`,
        submitScore: `POST /agent/submit-score`,
        stream:      `WS   /agent/stream?session=${session.sessionId}`,
      }
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---- Get game state ----
app.get('/agent/state', (req, res) => {
  const { session: sessionId } = req.query;
  const session = activeSessions.get(sessionId);
  if (!session) return res.status(404).json({ error: 'session not found' });

  res.json({
    ok:      true,
    session: sessionId,
    state:   session.gameState,
    meta: {
      score:     session.score,
      kills:     session.kills,
      round:     session.round,
      alive:     session.alive,
      elapsed:   Date.now() - session.startTime,
    }
  });
});

// ---- Send action ----
app.post('/agent/action', (req, res) => {
  const ip = req.ip;
  if (!rateLimit(ip, 600, 60000)) {  // 600 actions/min max
    return res.status(429).json({ error: 'rate limit exceeded' });
  }

  const { sessionId, action, frame } = req.body;
  if (!sessionId || !action) {
    return res.status(400).json({ error: 'sessionId and action required' });
  }

  const VALID_ACTIONS = ['move_up','move_down','move_left','move_right','fire_pump','release_pump','noop'];
  if (!VALID_ACTIONS.includes(action)) {
    return res.status(400).json({ error: `invalid action. Valid: ${VALID_ACTIONS.join(', ')}` });
  }

  const session = activeSessions.get(sessionId);
  if (!session) return res.status(404).json({ error: 'session not found' });

  session.tick(action);

  // Broadcast updated state to WS clients
  const stateMsg = JSON.stringify({ type: 'state', state: session.gameState, action });
  for (const ws of session.wsClients) {
    if (ws.readyState === 1) ws.send(stateMsg);
  }

  res.json({
    ok:     true,
    frame:  session.gameState.frame,
    action,
    state:  session.gameState,
  });
});

// ---- Update score from browser (game reports back to server) ----
app.post('/agent/update-score', (req, res) => {
  const { sessionId, score, kills, round, alive } = req.body;
  const session = activeSessions.get(sessionId);
  if (!session) return res.status(404).json({ error: 'session not found' });

  // Anti-cheat: score can't jump unreasonably fast
  const maxPossibleScore = (Date.now() - session.startTime) / 1000 * 500;
  if (score > maxPossibleScore + 10000) {
    return res.status(400).json({ error: 'score rejected: too high for elapsed time' });
  }

  session.score = Math.max(session.score, score || 0);
  session.kills = Math.max(session.kills, kills || 0);
  session.round = Math.max(session.round, round || 1);
  session.alive = alive !== false;

  res.json({ ok: true, score: session.score });
});

// ---- Sign and submit score on-chain ----
app.post('/agent/submit-score', async (req, res) => {
  const { sessionId } = req.body;
  const session = activeSessions.get(sessionId);
  if (!session) return res.status(404).json({ error: 'session not found' });

  if (session.score === 0) {
    return res.status(400).json({ error: 'no score to submit' });
  }

  try {
    const signed = await session.signScore();

    if (chainReady && !signed.mock) {
      // Player submits this themselves with their wallet
      // We just return the signed payload for them to use
      res.json({
        ok:      true,
        message: 'Score signed. Submit with your wallet using the payload below.',
        payload: signed,
        calldata: {
          contract:  GAME_CONTRACT,
          function:  'submitScore',
          args: [
            signed.score,
            signed.round,
            signed.kills,
            signed.sessionId,
            signed.signedAt,
            signed.signature,
          ]
        }
      });
    } else {
      // Mock mode — return mock response
      res.json({
        ok:      true,
        mock:    true,
        message: 'Mock score signed (chain not connected)',
        payload: signed,
        score:   session.score,
        round:   session.round,
        kills:   session.kills,
      });
    }
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---- Leaderboard ----
app.get('/leaderboard', async (req, res) => {
  try {
    if (!chainReady) {
      return res.json({ ok: true, mock: true, ...mockLeaderboard });
    }
    const [humans, agents, epoch] = await Promise.all([
      gameContract.getHumanLeaderboard(),
      gameContract.getAgentLeaderboard(),
      gameContract.getCurrentEpoch(),
    ]);
    const fmt = (entries) => entries
      .filter(e => e.player !== ethers.ZeroAddress)
      .map(e => ({
        player:    e.player,
        score:     Number(e.score),
        round:     Number(e.round),
        kills:     Number(e.kills),
        isAgent:   e.isAgent,
        timestamp: Number(e.timestamp) * 1000,
      }));
    res.json({
      ok:     true,
      agents: fmt(agents),
      humans: fmt(humans),
      epoch: {
        id:            Number(epoch.id),
        prizePool:     ethers.formatEther(epoch.prizePool),
        endsIn:        Number(epoch.endTime) - Math.floor(Date.now() / 1000),
        humanLeader:   epoch.humanWinner,
        agentLeader:   epoch.agentWinner,
        humanTopScore: Number(epoch.humanTopScore),
        agentTopScore: Number(epoch.agentTopScore),
      }
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/leaderboard/agents', async (req, res) => {
  try {
    if (!chainReady) return res.json({ ok: true, mock: true, entries: mockLeaderboard.agents });
    const agents = await gameContract.getAgentLeaderboard();
    res.json({ ok: true, entries: agents.filter(e => e.player !== ethers.ZeroAddress) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/leaderboard/humans', async (req, res) => {
  try {
    if (!chainReady) return res.json({ ok: true, mock: true, entries: mockLeaderboard.humans });
    const humans = await gameContract.getHumanLeaderboard();
    res.json({ ok: true, entries: humans.filter(e => e.player !== ethers.ZeroAddress) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---- Epoch info ----
app.get('/epoch', async (req, res) => {
  try {
    if (!chainReady) {
      return res.json({
        ok:   true,
        mock: true,
        epoch: { id: 1, prizePool: '2500', endsIn: 43200, humanLeader: null, agentLeader: null }
      });
    }
    const [epoch, timeLeft] = await Promise.all([
      gameContract.getCurrentEpoch(),
      gameContract.timeUntilEpochEnd(),
    ]);
    res.json({
      ok:    true,
      epoch: {
        id:            Number(epoch.id),
        prizePool:     ethers.formatEther(epoch.prizePool),
        burnAmount:    ethers.formatEther(epoch.burnAmount),
        treasuryAmount:ethers.formatEther(epoch.treasuryAmount),
        endsIn:        Number(timeLeft),
        humanWinner:   epoch.humanWinner,
        agentWinner:   epoch.agentWinner,
        humanTopScore: Number(epoch.humanTopScore),
        agentTopScore: Number(epoch.agentTopScore),
      }
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---- $DUG token info ----
app.get('/token', async (req, res) => {
  try {
    const { address } = req.query;
    const result = { token: 'DUG', contract: DUG_TOKEN || 'not deployed' };
    if (chainReady && address && ethers.isAddress(address)) {
      const [balance, supply] = await Promise.all([
        dugContract.balanceOf(address),
        dugContract.totalSupply(),
      ]);
      result.balance     = ethers.formatEther(balance);
      result.totalSupply = ethers.formatEther(supply);
    }
    res.json({ ok: true, ...result });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ============================================================
//  WEBSOCKET — Real-time 10Hz state stream
// ============================================================
wss.on('connection', (ws, req) => {
  const url       = new URL(req.url, 'ws://localhost');
  const sessionId = url.searchParams.get('session');
  const session   = activeSessions.get(sessionId);

  if (!session) {
    ws.send(JSON.stringify({ error: 'invalid session' }));
    ws.close();
    return;
  }

  session.wsClients.add(ws);
  console.log(`[WS] Agent connected. Session: ${sessionId.slice(0, 10)}...`);

  // Send initial state
  ws.send(JSON.stringify({
    type:      'init',
    sessionId: sessionId,
    state:     session.gameState,
    protocol: {
      tickRate:    10,
      stateFormat: 'ClawDugState/1.0',
      actions:     ['move_up','move_down','move_left','move_right','fire_pump','release_pump','noop'],
    }
  }));

  ws.on('message', (data) => {
    try {
      const msg = JSON.parse(data.toString());
      if (msg.type === 'action' && msg.action) {
        session.tick(msg.action);
        ws.send(JSON.stringify({
          type:  'ack',
          frame: session.gameState.frame,
          state: session.gameState,
        }));
      }
    } catch (e) {
      ws.send(JSON.stringify({ error: 'invalid message format' }));
    }
  });

  ws.on('close', () => {
    session.wsClients.delete(ws);
    console.log(`[WS] Agent disconnected. Session: ${sessionId.slice(0, 10)}...`);
  });
});

// 10Hz broadcast loop for all active sessions
setInterval(() => {
  for (const [, session] of activeSessions) {
    if (session.wsClients.size === 0) continue;
    session.tick(null); // advance frame
    const msg = JSON.stringify({ type: 'tick', frame: session.gameState.frame, state: session.gameState });
    for (const ws of session.wsClients) {
      if (ws.readyState === 1) ws.send(msg);
    }
  }
}, 100); // 10Hz

// Cleanup stale sessions (>2hrs idle)
setInterval(() => {
  const cutoff = Date.now() - 2 * 60 * 60 * 1000;
  for (const [id, session] of activeSessions) {
    if (session.lastAction < cutoff) activeSessions.delete(id);
  }
}, 60000);

// ============================================================
//  START
// ============================================================
server.listen(PORT, () => {
  console.log(`
╔════════════════════════════════════════╗
║       CLAWDUG AGENT API v1.0          ║
╠════════════════════════════════════════╣
║  HTTP  : http://localhost:${PORT}         ║
║  WS    : ws://localhost:${PORT}/agent/stream
║  Chain : ${chainReady ? 'Base Mainnet ✓' : 'Mock Mode (no env vars)'}
╚════════════════════════════════════════╝

Key endpoints:
  POST /agent/register     — Register agent
  GET  /agent/state        — Get game state
  POST /agent/action       — Send action
  POST /agent/submit-score — Sign score
  GET  /leaderboard        — Full leaderboard
  GET  /epoch              — Prize pool info
`);
});

export default app;
