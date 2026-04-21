// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./StakingVault.sol";

contract GameRoom {
    enum GameState { PENDING, DEALING, PLAYING, ENDED }

    struct GameConfig {
        uint256 minPlayers;
        uint256 maxPlayers;
        uint256 minStake;
        uint256 maxStake;
        uint256 jokerCount;
        uint256[10] cardCounts;
    }

    struct Player {
        address addr;
        uint256 stakeAmount;
        bool isActive;
        bool isOut;
        uint256[10] handCards;
        uint256 jokerCount;
    }

    uint256 public immutable gameId;
    StakingVault public immutable stakingVault;
    GameConfig public config;
    GameState public gameState;
    /// @dev 创建房间的钱包地址，可调用 startGame
    address public immutable roomOwner;
    address public immutable ecvrfRelay;

    address[] public players;
    mapping(address => Player) public playerData;
    uint256 public currentPlayerIndex;

    /// @dev 客户端用此种子与当前手牌 multiset 做确定性洗牌，保证所有人看到的扇面顺序一致
    mapping(address => uint256) public handDisplaySeed;

    event PlayerJoined(uint256 indexed gameId, address indexed player, uint256 stakeAmount);
    event GameStarted(uint256 indexed gameId);
    event ECVRFRandomRequested(uint256 indexed gameId, address indexed room, bytes32 alphaCommitment);
    event CardTaken(address indexed from, address indexed to, uint8 cardNumber);
    event PlayerOut(address indexed player);
    event GameEnded(uint256 indexed gameId, address[] losers, address[] winners);

    constructor(
        uint256 _gameId,
        address payable _stakingVault,
        address _roomOwner,
        GameConfig memory _config,
        address _ecvrfRelay
    ) {
        require(_stakingVault != address(0), "!vault");
        require(_roomOwner != address(0), "!owner");
        gameId = _gameId;
        stakingVault = StakingVault(_stakingVault);
        config = _config;
        gameState = GameState.PENDING;
        roomOwner = _roomOwner;
        ecvrfRelay = _ecvrfRelay;
    }

    function joinGame() external payable {
        require(gameState == GameState.PENDING, "!pending");
        require(!playerData[msg.sender].isActive, "joined");
        require(players.length < config.maxPlayers, "full");

        uint256 val = msg.value;
        if (config.maxStake == 0) {
            require(val == config.minStake, "fixed stake");
        } else {
            require(val >= config.minStake && val <= config.maxStake, "range");
        }

        Player storage p = playerData[msg.sender];
        p.addr = msg.sender;
        p.stakeAmount = val;
        p.isActive = true;
        players.push(msg.sender);
        // 质押资金即时记入 Vault，避免终局分配时 gamePools/gameStakes 为空导致回滚。
        stakingVault.stakeFor{value: val}(gameId, msg.sender);

        emit PlayerJoined(gameId, msg.sender, val);

        if (players.length == config.maxPlayers) {
            _beginStartSequence();
        }
    }

    /// @dev 未满员时，房主可在达到最小人数后手动开局
    function startGame() external {
        require(msg.sender == roomOwner, "!owner");
        require(gameState == GameState.PENDING, "!pending");
        require(players.length >= config.minPlayers, "!min");
        require(players.length < config.maxPlayers, "!full auto");
        _beginStartSequence();
    }

    function _beginStartSequence() internal {
        require(players.length >= config.minPlayers, "!enough");
        if (ecvrfRelay != address(0)) {
            gameState = GameState.DEALING;
            bytes32 commit = keccak256(abi.encode(gameId, address(this)));
            emit ECVRFRandomRequested(gameId, address(this), commit);
        } else {
            gameState = GameState.PLAYING;
            uint256 entropy = uint256(keccak256(abi.encodePacked(block.timestamp, gameId, address(this))));
            _shuffleAndDealAllCardsLegacy();
            _setHandDisplaySeeds(entropy);
            emit GameStarted(gameId);
        }
    }

    function applyECVRFSeed(uint256 randomWord) external {
        require(msg.sender == ecvrfRelay, "!relay");
        require(gameState == GameState.DEALING, "!dealing");
        require(randomWord != 0, "!zero");
        gameState = GameState.PLAYING;
        _shuffleAndDealFromVrfSeed(randomWord);
        _setHandDisplaySeeds(randomWord);
        emit GameStarted(gameId);
    }

    function _setHandDisplaySeeds(uint256 entropy) internal {
        for (uint i = 0; i < players.length; i++) {
            address p = players[i];
            handDisplaySeed[p] = uint256(keccak256(abi.encodePacked(entropy, gameId, address(this), p)));
        }
    }

    function _shuffleAndDealAllCardsLegacy() internal {
        uint256 pCount = players.length;
        uint256[] memory deck = _generateFullDeckLegacy();

        for (uint i = 0; i < deck.length; i++) {
            address to = players[i % pCount];
            uint8 num = uint8(deck[i]);
            playerData[to].handCards[num]++;
            _autoEliminate(to, num);
        }

        uint256 jokerTotal = config.jokerCount;
        for (uint i = 0; i < jokerTotal; i++) {
            address to = players[uint(keccak256(abi.encodePacked(block.timestamp, i))) % pCount];
            playerData[to].jokerCount += 1;
        }
    }

    function _generateFullDeckLegacy() internal view returns (uint256[] memory) {
        uint256 totalCards;
        for (uint i = 0; i < 10; i++) totalCards += config.cardCounts[i];

        uint256[] memory deck = new uint256[](totalCards);
        uint idx;
        for (uint8 num = 0; num < 10; num++) {
            uint cnt = config.cardCounts[num];
            for (uint i = 0; i < cnt; i++) deck[idx++] = num;
        }

        for (uint i = 0; i < deck.length; i++) {
            uint r = uint(keccak256(abi.encodePacked(block.timestamp, i))) % deck.length;
            (deck[i], deck[r]) = (deck[r], deck[i]);
        }
        return deck;
    }

    function _shuffleAndDealFromVrfSeed(uint256 seed) internal {
        uint256 pCount = players.length;
        uint256[] memory deck = _buildDeckOrdered();
        uint256 len = deck.length;

        for (uint i = 0; i < len; i++) {
            uint r = uint(keccak256(abi.encodePacked(seed, gameId, address(this), i))) % len;
            (deck[i], deck[r]) = (deck[r], deck[i]);
        }

        for (uint i = 0; i < len; i++) {
            address to = players[i % pCount];
            uint8 num = uint8(deck[i]);
            playerData[to].handCards[num]++;
            _autoEliminate(to, num);
        }

        uint256 jokerTotal = config.jokerCount;
        for (uint i = 0; i < jokerTotal; i++) {
            address to = players[uint(keccak256(abi.encodePacked(seed, gameId, address(this), i, uint8(1)))) % pCount];
            playerData[to].jokerCount += 1;
        }
    }

    function _buildDeckOrdered() internal view returns (uint256[] memory) {
        uint256 totalCards;
        for (uint i = 0; i < 10; i++) totalCards += config.cardCounts[i];

        uint256[] memory deck = new uint256[](totalCards);
        uint idx;
        for (uint8 num = 0; num < 10; num++) {
            uint cnt = config.cardCounts[num];
            for (uint i = 0; i < cnt; i++) deck[idx++] = num;
        }
        return deck;
    }

    /// @dev 是否仍持有任意可展示/可被抽的牌（数字或小丑）
    function _hasAnyCard(address p) internal view returns (bool) {
        if (playerData[p].jokerCount > 0) return true;
        for (uint8 j = 0; j < 10; j++) {
            if (playerData[p].handCards[j] > 0) return true;
        }
        return false;
    }

    /// @param cardNumber 0 = 小丑（不可成对消除，仅转移），1–10 = 数字牌
    function takeCard(address target, uint8 cardNumber) external {
        require(gameState == GameState.PLAYING, "!playing");
        require(players[currentPlayerIndex] == msg.sender, "!turn");
        require(target != address(0), "!target");
        // 手牌已空者应观战，不得再作为行动方抽牌
        require(_hasAnyCard(msg.sender), "!empty");

        if (cardNumber == 0) {
            require(playerData[target].jokerCount > 0, "no joker");
            playerData[target].jokerCount--;
            playerData[msg.sender].jokerCount++;
            emit CardTaken(target, msg.sender, 0);
        } else {
            require(cardNumber >= 1 && cardNumber <= 10, "card 1-10");
            uint8 idx = cardNumber - 1;
            require(playerData[target].handCards[idx] > 0, "no card");

            playerData[target].handCards[idx]--;
            playerData[msg.sender].handCards[idx]++;
            _autoEliminate(msg.sender, idx);
            emit CardTaken(target, msg.sender, cardNumber);
        }

        if (!_hasAnyCard(target)) {
            playerData[target].isOut = true;
            emit PlayerOut(target);
        }
        if (!_hasAnyCard(msg.sender)) {
            playerData[msg.sender].isOut = true;
            emit PlayerOut(msg.sender);
        }

        _advanceTurnSkipEmpty();
        if (_allPlayersNoNumberCards()) _endGame();
    }

    function _autoEliminate(address player, uint8 idx) internal {
        uint cnt = playerData[player].handCards[idx];
        if (cnt >= 2) playerData[player].handCards[idx] = cnt % 2;
    }

    /// @dev 轮到顺时针下一位「仍持有至少一张牌」的玩家；已清空手牌者仅观战不参与轮转
    function _advanceTurnSkipEmpty() internal {
        uint256 n = players.length;
        if (n == 0) return;
        for (uint256 step = 0; step < n; step++) {
            currentPlayerIndex = (currentPlayerIndex + 1) % n;
            if (_hasAnyCard(players[currentPlayerIndex])) return;
        }
    }

    /// @dev 所有玩家数字牌张数均为 0 时终局；有小丑者输，无小丑者赢并按质押分池
    function _allPlayersNoNumberCards() internal view returns (bool) {
        for (uint i = 0; i < players.length; i++) {
            address p = players[i];
            for (uint8 j = 0; j < 10; j++) {
                if (playerData[p].handCards[j] > 0) return false;
            }
        }
        return true;
    }

    function _endGame() internal {
        gameState = GameState.ENDED;

        address[] memory losers = new address[](players.length);
        address[] memory winners = new address[](players.length);
        uint l;
        uint w;

        for (uint i = 0; i < players.length; i++) {
            address p = players[i];
            if (playerData[p].jokerCount > 0) losers[l++] = p;
            else winners[w++] = p;
        }

        assembly {
            mstore(losers, l)
            mstore(winners, w)
        }

        require(w > 0, "!winners");
        // 兼容旧房间：如果历史版本把质押留在房间内，这里按玩家质押额补记到 Vault。
        // 新版本 joinGame 已在入场时 stakeFor，因此一般 balance 为 0，不会重复记账。
        if (address(this).balance > 0) {
            for (uint i = 0; i < players.length; i++) {
                address p = players[i];
                uint256 amt = playerData[p].stakeAmount;
                if (amt > 0) {
                    stakingVault.stakeFor{value: amt}(gameId, p);
                }
            }
        }

        stakingVault.distributeRewards(gameId, winners, losers);
        emit GameEnded(gameId, losers, winners);
    }

    function getPlayerCards(address p) external view returns (uint256[10] memory, uint256) {
        return (playerData[p].handCards, playerData[p].jokerCount);
    }

    function getCurrentTurnPlayer() external view returns (address) {
        if (players.length == 0) return address(0);
        return players[currentPlayerIndex];
    }

    /// @dev 抽牌目标：从当前回合玩家顺时针找第一位「仍有牌」的玩家（跳过已清空手牌的观战者）
    function getTakeTarget() external view returns (address) {
        uint256 n = players.length;
        if (n < 2) return address(0);
        uint256 idx = (currentPlayerIndex + 1) % n;
        for (uint256 k = 0; k < n; k++) {
            address t = players[idx];
            if (_hasAnyCard(t)) return t;
            idx = (idx + 1) % n;
        }
        return address(0);
    }

    /// @dev RPC 不支持 eth_getLogs 时，客户端用此函数拉取玩家列表
    function getPlayers() external view returns (address[] memory) {
        return players;
    }

    /// @dev 便于客户端快速显示人数
    function getPlayerCount() external view returns (uint256) {
        return players.length;
    }
}
