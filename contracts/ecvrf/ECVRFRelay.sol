// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./IECVRFVerifier.sol";

interface IGameRoomEcvrf {
    function applyECVRFSeed(uint256 randomWord) external;

    function gameId() external view returns (uint256);
}

/**
 * @title ECVRFRelay
 * @dev 链下用 brokerchain-academic/shard/vrf 同类算法（如 go-ecvrf Prove）生成 randomWord 与 proof，
 *      再由此合约调用房间。verifier 为 0 时仅信任 relayer 地址（学术网/测试常用）；生产可接入真实 verify。
 */
contract ECVRFRelay {
    address public immutable relayer;
    IECVRFVerifier public immutable verifier;

    event RandomnessSubmitted(address indexed room, uint256 indexed gameId, uint256 randomWord);

    constructor(address _relayer, address _verifier) {
        require(_relayer != address(0), "!relayer");
        relayer = _relayer;
        verifier = IECVRFVerifier(_verifier);
    }

    /**
     * @param alpha 必须与房间内约定的 abi.encode(gameId, room) 一致（与链下 Prove 输入一致）
     */
    function submitRandomWord(address room, bytes calldata alpha, bytes calldata proof, uint256 randomWord) external {
        if (address(verifier) == address(0)) {
            require(msg.sender == relayer, "!relayer");
        } else {
            require(verifier.verify(alpha, proof, randomWord), "!ecvrf");
        }

        uint256 gid = IGameRoomEcvrf(room).gameId();
        require(keccak256(alpha) == keccak256(abi.encode(gid, room)), "!alpha");

        IGameRoomEcvrf(room).applyECVRFSeed(randomWord);
        emit RandomnessSubmitted(room, gid, randomWord);
    }
}
