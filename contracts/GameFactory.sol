// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./StakingVault.sol";
import "./GameRoom.sol";

contract GameFactory {
    StakingVault public immutable stakingVault;
    uint256 public gameIdCounter;
    mapping(uint256 => address) public gameRooms;
    mapping(uint256 => GameRoom.GameConfig) public gameConfigs;

    struct CreateResult {
        uint256 gameId;
        address room;
    }

    event GameRoomCreated(uint256 indexed gameId, address indexed host, address indexed room, GameRoom.GameConfig cfg);

    constructor(address payable  _stakingVault) {
        require(_stakingVault != address(0));
        stakingVault = StakingVault(_stakingVault);
        gameIdCounter = 1;
    }

    function createGameRoom(
        uint256 minPlayers,
        uint256 maxPlayers,
        uint256 minStake,
        uint256 maxStake,
        uint256 jokerCount,
        uint256[10] calldata cardCounts,
        address vrfCoordinator,
        uint64 vrfSubId,
        bytes32 vrfKeyHash,
        uint32 vrfCallbackGasLimit,
        uint16 vrfRequestConfirmations,
        address ecvrfRelay
    ) external returns (CreateResult memory) {
        _validate(
            minPlayers,
            maxPlayers,
            minStake,
            maxStake,
            jokerCount,
            cardCounts
        );

        uint256 gameId = gameIdCounter++;
        GameRoom.GameConfig memory cfg = GameRoom.GameConfig({
            minPlayers: minPlayers,
            maxPlayers: maxPlayers,
            minStake: minStake,
            maxStake: maxStake,
            jokerCount: jokerCount,
            cardCounts: cardCounts
        });

        address room = address(
            new GameRoom(
                gameId,
                payable(address(stakingVault)),
                cfg,
                vrfCoordinator,
                vrfSubId,
                vrfKeyHash,
                vrfCallbackGasLimit,
                vrfRequestConfirmations,
                ecvrfRelay
            )
        );
        gameRooms[gameId] = room;
        gameConfigs[gameId] = cfg;
        stakingVault.registerGameRoom(gameId, room);

        emit GameRoomCreated(gameId, msg.sender, room, cfg);
        return CreateResult(gameId, room);
    }

    function _validate(
        uint256 minP,
        uint256 maxP,
        uint256 minS,
        uint256 maxS,
        uint256 jokers,
        uint256[10] calldata cards
    ) internal pure {
        require(minP >= 2 && maxP <= 8, "players 2-8");
        require(minP <= maxP, "min > max");
        require(minS > 0, "min stake >0");
        if (maxS > 0) require(maxS >= minS, "max < min");
        require(jokers <= 8, "jokers max 8");

        for (uint8 i = 0; i < 10; i++) {
            require(cards[i] % 2 == 0, "card must even");
            require(cards[i] <= 20, "card max 20");
        }
    }

    function getGameRoom(uint256 gameId) external view returns (GameRoom) {
        address room = gameRooms[gameId];
        require(room != address(0));
        return GameRoom(room);
    }
}