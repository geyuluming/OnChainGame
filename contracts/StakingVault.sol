// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title StakingVault
 * @dev 处理BrokerChain原生BKC质押、锁定和收益分配
 * 无需ERC20授权，直接接收原生BKC
 */
contract StakingVault {
    // 游戏质押记录：gameId → player → stakeAmount
    mapping(uint256 => mapping(address => uint256)) public gameStakes;
    // 游戏奖池：gameId → totalPool
    mapping(uint256 => uint256) public gamePools;
    // 游戏房间：gameId -> roomAddress
    mapping(uint256 => address) public gameRooms;
    // 协议手续费率：1%（10/1000）
    uint256 public constant FEE_RATE = 10;
    // 手续费接收地址（部署者）
    address public immutable feeReceiver;
    address public factory;

    // 事件定义
    event Staked(uint256 indexed gameId, address indexed player, uint256 amount);
    event RewardsDistributed(uint256 indexed gameId, uint256 totalRewards, uint256 fee);
    event GameRoomRegistered(uint256 indexed gameId, address indexed room);

    /**
     * @dev 构造函数：初始化手续费接收地址
     */
    constructor() {
        feeReceiver = msg.sender;
        factory = msg.sender;
    }

    function setFactory(address _factory) external {
        require(msg.sender == feeReceiver, "StakingVault: only fee receiver");
        require(_factory != address(0), "StakingVault: factory is zero");
        factory = _factory;
    }

    /**
     * @dev 接收原生BKC的回调函数（必须实现，否则合约无法接收BKC）
     */
    receive() external payable {}

    /**
     * @dev 玩家质押原生BKC到指定游戏
     * @param gameId 游戏ID
     * 注意：质押金额通过交易的value参数传入，而非函数参数
     */
    function stake(uint256 gameId) external payable {
        uint256 amount = msg.value; // 从交易value中获取质押金额（原生BKC，wei单位）
        require(amount > 0, "StakingVault: amount must be > 0");
        require(gamePools[gameId] + amount > gamePools[gameId], "StakingVault: overflow");

        // 更新质押记录和奖池（无需转账，BKC已通过msg.value进入合约）
        gameStakes[gameId][msg.sender] += amount;
        gamePools[gameId] += amount;

        emit Staked(gameId, msg.sender, amount);
    }

    /**
     * @dev 由房间代玩家质押（用于GameRoom.joinGame时透传玩家地址）
     */
    function stakeFor(uint256 gameId, address player) external payable {
        uint256 amount = msg.value;
        require(player != address(0), "StakingVault: player is zero");
        require(amount > 0, "StakingVault: amount must be > 0");
        require(gamePools[gameId] + amount > gamePools[gameId], "StakingVault: overflow");

        gameStakes[gameId][player] += amount;
        gamePools[gameId] += amount;

        emit Staked(gameId, player, amount);
    }

    function registerGameRoom(uint256 gameId, address room) external {
        require(msg.sender == factory, "StakingVault: only factory");
        require(room != address(0), "StakingVault: room is zero");
        require(gameRooms[gameId] == address(0), "StakingVault: room exists");
        gameRooms[gameId] = room;
        emit GameRoomRegistered(gameId, room);
    }

    /**
     * @dev 分配游戏奖励（仅游戏房间合约可调用）
     * @param gameId 游戏ID
     * @param winners 获胜者列表
     * @param losers 失败者列表
     */
    function distributeRewards(
        uint256 gameId,
        address[] calldata winners,
        address[] calldata losers
    ) external {
        require(msg.sender == gameRooms[gameId], "StakingVault: only game room");
        uint256 totalPool = gamePools[gameId];
        require(totalPool > 0, "StakingVault: no pool for game");
        require(winners.length > 0, "StakingVault: no winners");

        // 计算手续费和可分配奖励
        uint256 fee = (totalPool * FEE_RATE) / 1000;
        uint256 rewardPool = totalPool - fee;

        // 发放手续费（原生BKC转账）
        if (fee > 0) {
            (bool feeSuccess, ) = feeReceiver.call{value: fee}("");
            require(feeSuccess, "StakingVault: fee transfer failed");
        }

        // 仅在获胜者内部按质押比例分配奖励
        uint256 winnersStakeTotal = 0;
        for (uint256 i = 0; i < winners.length; i++) {
            winnersStakeTotal += gameStakes[gameId][winners[i]];
        }
        require(winnersStakeTotal > 0, "StakingVault: winners stake is zero");

        for (uint256 i = 0; i < winners.length; i++) {
            address winner = winners[i];
            uint256 winnerStake = gameStakes[gameId][winner];
            if (winnerStake == 0) continue;

            uint256 reward = (winnerStake * rewardPool) / winnersStakeTotal;
            if (reward > 0) {
                (bool rewardSuccess, ) = winner.call{value: reward}("");
                require(rewardSuccess, "StakingVault: reward transfer failed");
            }

            // 清空获胜者质押记录
            delete gameStakes[gameId][winner];
        }

        // 清空失败者质押记录
        for (uint256 i = 0; i < losers.length; i++) {
            delete gameStakes[gameId][losers[i]];
        }

        // 清空奖池
        delete gamePools[gameId];

        emit RewardsDistributed(gameId, rewardPool, fee);
    }

    /**
     * @dev 查询玩家在指定游戏的质押额
     * @param gameId 游戏ID
     * @param player 玩家地址
     * @return 质押金额
     */
    function getPlayerStake(uint256 gameId, address player) external view returns (uint256) {
        return gameStakes[gameId][player];
    }

    /**
     * @dev 紧急提取合约中多余的BKC（仅部署者可用）
     */
    function emergencyWithdraw(uint256 amount) external {
        require(msg.sender == feeReceiver, "StakingVault: only fee receiver");
        require(address(this).balance >= amount, "StakingVault: insufficient balance");
        (bool success, ) = feeReceiver.call{value: amount}("");
        require(success, "StakingVault: emergency transfer failed");
    }
}