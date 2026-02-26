// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ============================================================
//  CLAWDUG — On-Chain Leaderboard + $DUG Token
//  Deployed on Base (chain ID 8453)
//
//  Architecture:
//    DugToken      — ERC-20, minted by the arcade contract
//    ClawDugGame   — Score submission, leaderboard, prize pools
//    AgentRegistry — ERC-8004-compatible agent identity tracking
// ============================================================

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

// ============================================================
//  $DUG TOKEN
// ============================================================
contract DugToken is ERC20, ERC20Burnable, Ownable {
    uint256 public constant MAX_SUPPLY = 100_000_000 * 10**18; // 100M DUG

    // Only the game contract can mint
    address public gameContract;

    event GameContractSet(address indexed game);

    constructor() ERC20("ClawDug Token", "DUG") Ownable(msg.sender) {}

    modifier onlyGame() {
        require(msg.sender == gameContract, "DUG: caller is not game");
        _;
    }

    function setGameContract(address _game) external onlyOwner {
        gameContract = _game;
        emit GameContractSet(_game);
    }

    function mint(address to, uint256 amount) external onlyGame {
        require(totalSupply() + amount <= MAX_SUPPLY, "DUG: max supply exceeded");
        _mint(to, amount);
    }
}

// ============================================================
//  AGENT REGISTRY  (ERC-8004 compatible)
// ============================================================
contract AgentRegistry is Ownable {
    struct AgentProfile {
        bytes32 agentId;       // OpenClaws agent ID
        string  name;
        address wallet;
        bool    isAgent;       // true = AI agent, false = human
        uint256 gamesPlayed;
        uint256 totalScore;
        uint256 bestScore;
        uint256 registeredAt;
    }

    mapping(address => AgentProfile) public profiles;
    mapping(bytes32 => address)      public agentIdToWallet;
    address[] public agentList;

    event AgentRegistered(address indexed wallet, bytes32 indexed agentId, string name, bool isAgent);
    event ProfileUpdated(address indexed wallet, uint256 gamesPlayed, uint256 totalScore);

    constructor() Ownable(msg.sender) {}

    function register(
        bytes32 agentId,
        string calldata name,
        bool isAgent
    ) external {
        require(profiles[msg.sender].registeredAt == 0, "Registry: already registered");
        if (isAgent) {
            require(agentIdToWallet[agentId] == address(0), "Registry: agentId taken");
            agentIdToWallet[agentId] = msg.sender;
        }
        profiles[msg.sender] = AgentProfile({
            agentId:      agentId,
            name:         name,
            wallet:       msg.sender,
            isAgent:      isAgent,
            gamesPlayed:  0,
            totalScore:   0,
            bestScore:    0,
            registeredAt: block.timestamp
        });
        agentList.push(msg.sender);
        emit AgentRegistered(msg.sender, agentId, name, isAgent);
    }

    function recordGame(address player, uint256 score) external onlyOwner {
        AgentProfile storage p = profiles[player];
        p.gamesPlayed++;
        p.totalScore += score;
        if (score > p.bestScore) p.bestScore = score;
        emit ProfileUpdated(player, p.gamesPlayed, p.totalScore);
    }

    function getProfile(address wallet) external view returns (AgentProfile memory) {
        return profiles[wallet];
    }

    function agentCount() external view returns (uint256) { return agentList.length; }
}

// ============================================================
//  MAIN GAME CONTRACT
// ============================================================
contract ClawDugGame is Ownable, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ---- External contracts ----
    DugToken      public dugToken;
    AgentRegistry public registry;

    // ---- Score signer (server-side key to prevent spoofed scores) ----
    address public scoreSigner;

    // ---- Economics ----
    uint256 public humanEntryFee  = 10 * 10**18; // 10 DUG
    uint256 public agentEntryFee  =  5 * 10**18; //  5 DUG (cheaper for agents)
    uint256 public constant PRIZE_POOL_BPS  = 7000; // 70%
    uint256 public constant BURN_BPS        = 1000; // 10%
    uint256 public constant TREASURY_BPS    = 2000; // 20%
    uint256 public constant BPS_DENOM       = 10000;

    // ---- Reward schedule per round ----
    // Flat DUG minted for scoring milestones (not from entry pool)
    uint256 public constant REWARD_PER_KILL   = 2  * 10**18;  //  2 DUG per enemy kill
    uint256 public constant REWARD_PER_ROUND  = 10 * 10**18;  // 10 DUG per round cleared
    uint256 public constant REWARD_MILESTONE  = 50 * 10**18;  // 50 DUG milestone bonus

    // ---- Leaderboard ----
    uint256 public constant LB_SIZE = 20;

    struct ScoreEntry {
        address player;
        uint256 score;
        uint256 round;
        uint256 kills;
        bool    isAgent;
        uint256 timestamp;
        bytes32 sessionId;
    }

    ScoreEntry[LB_SIZE] public humanLeaderboard;
    ScoreEntry[LB_SIZE] public agentLeaderboard;
    uint256 public humanLBCount;
    uint256 public agentLBCount;

    // ---- Prize pools (daily epoch) ----
    struct Epoch {
        uint256 id;
        uint256 startTime;
        uint256 endTime;
        uint256 prizePool;     // total DUG in pool
        uint256 burnAmount;
        uint256 treasuryAmount;
        bool    settled;
        address humanWinner;
        address agentWinner;
        uint256 humanTopScore;
        uint256 agentTopScore;
    }

    mapping(uint256 => Epoch) public epochs;
    uint256 public currentEpoch;
    uint256 public epochDuration = 1 days;

    // ---- Session tracking (prevent replay attacks) ----
    mapping(bytes32 => bool) public usedSessions;

    // ---- Treasury ----
    address public treasury;
    uint256 public treasuryBalance;

    // ---- Events ----
    event ScoreSubmitted(
        address indexed player,
        uint256 score,
        uint256 round,
        uint256 kills,
        bool isAgent,
        uint256 epochId,
        bytes32 sessionId
    );
    event LeaderboardUpdated(bool isAgent, uint8 rank, address player, uint256 score);
    event EpochSettled(
        uint256 indexed epochId,
        address humanWinner,
        uint256 humanPrize,
        address agentWinner,
        uint256 agentPrize
    );
    event RewardMinted(address indexed player, uint256 amount, string reason);
    event EpochStarted(uint256 indexed epochId, uint256 startTime, uint256 endTime);

    constructor(
        address _dugToken,
        address _registry,
        address _scoreSigner,
        address _treasury
    ) Ownable(msg.sender) {
        dugToken    = DugToken(_dugToken);
        registry    = AgentRegistry(_registry);
        scoreSigner = _scoreSigner;
        treasury    = _treasury;
        _startNewEpoch();
    }

    // ============================================================
    //  EPOCH MANAGEMENT
    // ============================================================
    function _startNewEpoch() internal {
        currentEpoch++;
        epochs[currentEpoch] = Epoch({
            id:            currentEpoch,
            startTime:     block.timestamp,
            endTime:       block.timestamp + epochDuration,
            prizePool:     0,
            burnAmount:    0,
            treasuryAmount:0,
            settled:       false,
            humanWinner:   address(0),
            agentWinner:   address(0),
            humanTopScore: 0,
            agentTopScore: 0
        });
        emit EpochStarted(currentEpoch, block.timestamp, block.timestamp + epochDuration);
    }

    function settleEpoch() external nonReentrant {
        Epoch storage epoch = epochs[currentEpoch];
        require(block.timestamp >= epoch.endTime, "Game: epoch not ended");
        require(!epoch.settled, "Game: already settled");

        epoch.settled = true;

        // Split prize pool: 50/50 between human and agent winner
        uint256 humanPrize = 0;
        uint256 agentPrize = 0;

        if (epoch.prizePool > 0) {
            uint256 half = epoch.prizePool / 2;

            if (epoch.humanWinner != address(0)) {
                humanPrize = half;
                dugToken.mint(epoch.humanWinner, humanPrize);
            }
            if (epoch.agentWinner != address(0)) {
                agentPrize = half;
                dugToken.mint(epoch.agentWinner, agentPrize);
            }

            // Handle case where one category has no players
            if (epoch.humanWinner == address(0) && epoch.agentWinner != address(0)) {
                agentPrize = epoch.prizePool;
                dugToken.mint(epoch.agentWinner, half); // already minted half
            }
            if (epoch.agentWinner == address(0) && epoch.humanWinner != address(0)) {
                humanPrize = epoch.prizePool;
                dugToken.mint(epoch.humanWinner, half);
            }
        }

        // Burn and treasury
        if (epoch.burnAmount > 0) {
            // Mint to this contract, then burn
            dugToken.mint(address(this), epoch.burnAmount);
            dugToken.burn(epoch.burnAmount);
        }
        if (epoch.treasuryAmount > 0) {
            dugToken.mint(treasury, epoch.treasuryAmount);
            treasuryBalance += epoch.treasuryAmount;
        }

        emit EpochSettled(
            currentEpoch,
            epoch.humanWinner, humanPrize,
            epoch.agentWinner, agentPrize
        );

        _startNewEpoch();
    }

    // ============================================================
    //  SCORE SUBMISSION
    //  Requires server-signed payload to prevent spoofing
    // ============================================================
    function submitScore(
        uint256 score,
        uint256 round,
        uint256 kills,
        bytes32 sessionId,
        uint256 signedAt,
        bytes calldata signature
    ) external nonReentrant {
        // 1. Replay protection
        require(!usedSessions[sessionId], "Game: session already used");
        require(block.timestamp <= signedAt + 5 minutes, "Game: signature expired");

        // 2. Verify server signature
        bytes32 msgHash = keccak256(abi.encodePacked(
            msg.sender, score, round, kills, sessionId, signedAt, block.chainid
        ));
        bytes32 ethHash = msgHash.toEthSignedMessageHash();
        address recovered = ethHash.recover(signature);
        require(recovered == scoreSigner, "Game: invalid signature");

        // 3. Mark session used
        usedSessions[sessionId] = true;

        // 4. Determine if agent
        AgentRegistry.AgentProfile memory profile = registry.getProfile(msg.sender);
        bool isAgent = profile.isAgent;

        // 5. Entry fee burns into prize pool
        uint256 fee = isAgent ? agentEntryFee : humanEntryFee;
        if (dugToken.allowance(msg.sender, address(this)) >= fee) {
            dugToken.transferFrom(msg.sender, address(this), fee);
            _distributeEntryFee(fee);
        }

        // 6. Update registry
        registry.recordGame(msg.sender, score);

        // 7. Mint gameplay rewards
        _mintGameplayRewards(msg.sender, kills, round);

        // 8. Update leaderboard
        if (isAgent) {
            _updateLeaderboard(agentLeaderboard, agentLBCount, msg.sender, score, round, kills, true, sessionId);
            if (agentLBCount < LB_SIZE) agentLBCount++;
        } else {
            _updateLeaderboard(humanLeaderboard, humanLBCount, msg.sender, score, round, kills, false, sessionId);
            if (humanLBCount < LB_SIZE) humanLBCount++;
        }

        // 9. Update epoch top scores
        Epoch storage epoch = epochs[currentEpoch];
        if (isAgent && score > epoch.agentTopScore) {
            epoch.agentTopScore = score;
            epoch.agentWinner   = msg.sender;
        }
        if (!isAgent && score > epoch.humanTopScore) {
            epoch.humanTopScore = score;
            epoch.humanWinner   = msg.sender;
        }

        emit ScoreSubmitted(msg.sender, score, round, kills, isAgent, currentEpoch, sessionId);
    }

    function _distributeEntryFee(uint256 fee) internal {
        Epoch storage epoch = epochs[currentEpoch];
        uint256 toPrize    = (fee * PRIZE_POOL_BPS)  / BPS_DENOM;
        uint256 toBurn     = (fee * BURN_BPS)         / BPS_DENOM;
        uint256 toTreasury = (fee * TREASURY_BPS)     / BPS_DENOM;
        epoch.prizePool     += toPrize;
        epoch.burnAmount    += toBurn;
        epoch.treasuryAmount += toTreasury;
    }

    function _mintGameplayRewards(address player, uint256 kills, uint256 round) internal {
        uint256 killReward  = kills * REWARD_PER_KILL;
        uint256 roundReward = round * REWARD_PER_ROUND;
        uint256 total = killReward + roundReward;

        // Milestone bonuses
        if (round >= 5)  total += REWARD_MILESTONE;
        if (round >= 10) total += REWARD_MILESTONE * 2;
        if (round >= 20) total += REWARD_MILESTONE * 5;

        if (total > 0) {
            dugToken.mint(player, total);
            emit RewardMinted(player, total, "gameplay");
        }
    }

    function _updateLeaderboard(
        ScoreEntry[LB_SIZE] storage lb,
        uint256 currentCount,
        address player,
        uint256 score,
        uint256 round,
        uint256 kills,
        bool isAgent,
        bytes32 sessionId
    ) internal {
        // Find insertion point
        uint8 insertAt = uint8(LB_SIZE); // beyond end = don't insert
        uint256 count = currentCount < LB_SIZE ? currentCount : LB_SIZE;

        for (uint8 i = 0; i < count; i++) {
            if (score > lb[i].score) { insertAt = i; break; }
        }
        if (insertAt == LB_SIZE && count < LB_SIZE) insertAt = uint8(count);

        if (insertAt < LB_SIZE) {
            // Shift down
            for (uint8 j = LB_SIZE - 1; j > insertAt; j--) {
                lb[j] = lb[j - 1];
            }
            lb[insertAt] = ScoreEntry({
                player:    player,
                score:     score,
                round:     round,
                kills:     kills,
                isAgent:   isAgent,
                timestamp: block.timestamp,
                sessionId: sessionId
            });
            emit LeaderboardUpdated(isAgent, insertAt, player, score);
        }
    }

    // ============================================================
    //  READ FUNCTIONS
    // ============================================================
    function getHumanLeaderboard() external view returns (ScoreEntry[LB_SIZE] memory) {
        return humanLeaderboard;
    }

    function getAgentLeaderboard() external view returns (ScoreEntry[LB_SIZE] memory) {
        return agentLeaderboard;
    }

    function getCurrentEpoch() external view returns (Epoch memory) {
        return epochs[currentEpoch];
    }

    function getEpoch(uint256 epochId) external view returns (Epoch memory) {
        return epochs[epochId];
    }

    function timeUntilEpochEnd() external view returns (uint256) {
        Epoch storage epoch = epochs[currentEpoch];
        if (block.timestamp >= epoch.endTime) return 0;
        return epoch.endTime - block.timestamp;
    }

    // ============================================================
    //  ADMIN
    // ============================================================
    function setScoreSigner(address _signer) external onlyOwner {
        scoreSigner = _signer;
    }

    function setFees(uint256 _humanFee, uint256 _agentFee) external onlyOwner {
        humanEntryFee = _humanFee;
        agentEntryFee = _agentFee;
    }

    function setEpochDuration(uint256 _duration) external onlyOwner {
        epochDuration = _duration;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function withdrawTreasury() external onlyOwner {
        // Treasury tokens were minted directly to treasury address
        // This function handles any ETH mistakenly sent
        payable(treasury).transfer(address(this).balance);
    }

    receive() external payable {}
}

// ============================================================
//  DEPLOY SCRIPT  (Foundry-style)
// ============================================================
// To deploy to Base mainnet:
//
//   forge script script/Deploy.s.sol \
//     --rpc-url https://mainnet.base.org \
//     --private-key $PRIVATE_KEY \
//     --broadcast --verify
//
// Deployment order:
//   1. Deploy DugToken
//   2. Deploy AgentRegistry
//   3. Deploy ClawDugGame(dugToken, registry, scoreSigner, treasury)
//   4. dugToken.setGameContract(clawDugGame.address)
//   5. registry.transferOwnership(clawDugGame.address)
