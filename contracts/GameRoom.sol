// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./StakingVault.sol";
import "./vrf/OptionalVRFConsumer.sol";
import "./vrf/IVRFCoordinatorV2.sol";

contract GameRoom is OptionalVRFConsumer {
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
    address public immutable host;
    /// @dev 非零且 vrfCoordinator 为零时：满员进入 DEALING，由 ECVRFRelay.submitRandomWord 喂入随机数
    address public immutable ecvrfRelay;

    address[] public players;
    mapping(address => Player) public playerData;
    uint256 public currentPlayerIndex;

    event PlayerJoined(uint256 indexed gameId, address indexed player, uint256 stakeAmount);
    event GameStarted(uint256 indexed gameId);
    event VrfRandomRequested(uint256 indexed gameId, uint256 requestId);
    /// @dev alpha 约定为 abi.encode(gameId, address(this))，链下 Prove 须使用相同输入
    event ECVRFRandomRequested(uint256 indexed gameId, address indexed room, bytes32 alphaCommitment);
    event CardTaken(address indexed from, address indexed to, uint8 cardNumber);
    event PlayerOut(address indexed player);
    event GameEnded(uint256 indexed gameId, address[] losers, address[] winners);

    constructor(
        uint256 _gameId,
        address payable _stakingVault,
        GameConfig memory _config,
        address _vrfCoordinator,
        uint64 _vrfSubId,
        bytes32 _vrfKeyHash,
        uint32 _vrfCallbackGasLimit,
        uint16 _vrfRequestConfirmations,
        address _ecvrfRelay
    ) OptionalVRFConsumer(_vrfCoordinator, _vrfSubId, _vrfKeyHash, _vrfCallbackGasLimit, _vrfRequestConfirmations) {
        require(_stakingVault != address(0), "!vault");
        require(!(_vrfCoordinator != address(0) && _ecvrfRelay != address(0)), "!two randomness");
        gameId = _gameId;
        stakingVault = StakingVault(_stakingVault);
        config = _config;
        gameState = GameState.PENDING;
        host = msg.sender;
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

        emit PlayerJoined(gameId, msg.sender, val);

        if (players.length == config.maxPlayers) {
            _beginStartSequence();
        }
    }

    /// @dev 满员后：Chainlink VRF > ECVRF 中继 > 同步发牌
    function _beginStartSequence() internal {
        require(players.length >= config.minPlayers, "!enough");
        if (vrfCoordinator != address(0)) {
            gameState = GameState.DEALING;
            uint256 requestId = IVRFCoordinatorV2(vrfCoordinator).requestRandomWords(
                vrfKeyHash,
                vrfSubId,
                vrfRequestConfirmations,
                vrfCallbackGasLimit,
                1
            );
            emit VrfRandomRequested(gameId, requestId);
        } else if (ecvrfRelay != address(0)) {
            gameState = GameState.DEALING;
            bytes32 commit = keccak256(abi.encode(gameId, address(this)));
            emit ECVRFRandomRequested(gameId, address(this), commit);
        } else {
            gameState = GameState.PLAYING;
            _shuffleAndDealAllCardsLegacy();
            emit GameStarted(gameId);
        }
    }

    /// @dev 仅允许 ECVRFRelay 调用；randomWord 建议为链下 ECVRF 输出左对齐填入 uint256（如 bytes32 转 uint256）
    function applyECVRFSeed(uint256 randomWord) external {
        require(msg.sender == ecvrfRelay, "!relay");
        require(gameState == GameState.DEALING, "!dealing");
        require(randomWord != 0, "!zero");
        gameState = GameState.PLAYING;
        _shuffleAndDealFromVrfSeed(randomWord);
        emit GameStarted(gameId);
    }

    /// @dev Chainlink 回调：用 VRF 随机字作为熵源扩展洗牌与小丑分配（不可由出块者单独操纵 timestamp）
    function fulfillRandomWords(uint256, uint256[] memory randomWords) internal override {
        require(gameState == GameState.DEALING, "!dealing");
        require(randomWords.length >= 1, "!words");
        gameState = GameState.PLAYING;
        _shuffleAndDealFromVrfSeed(randomWords[0]);
        emit GameStarted(gameId);
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

    /// @param cardNumber 0 = 小丑，1–10 = 数字牌（与手牌下标 0–9 对应）
    function takeCard(address target, uint8 cardNumber) external {
        require(gameState == GameState.PLAYING, "!playing");
        require(players[currentPlayerIndex] == msg.sender, "!turn");
        require(!playerData[msg.sender].isOut, "out");
        require(target != address(0), "!target");

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

        if (_isAllClear(msg.sender)) {
            playerData[msg.sender].isOut = true;
            emit PlayerOut(msg.sender);
        }

        _nextTurn();
        if (_isGameOver()) _endGame();
    }

    function _autoEliminate(address player, uint8 idx) internal {
        uint cnt = playerData[player].handCards[idx];
        if (cnt >= 2) playerData[player].handCards[idx] = cnt % 2;
    }

    function _isAllClear(address player) internal view returns (bool) {
        if (playerData[player].jokerCount > 0) return false;
        for (uint8 i = 0; i < 10; i++) {
            if (playerData[player].handCards[i] > 0) return false;
        }
        return true;
    }

    function _nextTurn() internal {
        uint nextIdx = (currentPlayerIndex + 1) % players.length;
        while (playerData[players[nextIdx]].isOut) {
            nextIdx = (nextIdx + 1) % players.length;
        }
        currentPlayerIndex = nextIdx;
    }

    function _isGameOver() internal view returns (bool) {
        uint active;
        for (uint i = 0; i < players.length; i++) {
            if (!playerData[players[i]].isOut) active++;
        }
        return active <= 1;
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

        (bool sent, ) = address(stakingVault).call{value: address(this).balance}("");
        require(sent, "!transfer");

        stakingVault.distributeRewards(gameId, winners, losers);
        emit GameEnded(gameId, losers, winners);
    }

    function getPlayerCards(address p) external view returns (uint256[10] memory, uint256) {
        return (playerData[p].handCards, playerData[p].jokerCount);
    }
}
