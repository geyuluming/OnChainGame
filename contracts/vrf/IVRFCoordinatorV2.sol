// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Chainlink VRF v2 协调器最小接口（订阅模式）
interface IVRFCoordinatorV2 {
    function requestRandomWords(
        bytes32 keyHash,
        uint64 subId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords
    ) external returns (uint256 requestId);
}
