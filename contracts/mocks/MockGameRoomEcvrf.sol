// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev 用于测试 ECVRFRelay：行为上仅校验 msg.sender == ecvrfRelay，并记录种子。
contract MockGameRoomEcvrf {
    uint256 public immutable gameId;
    address public immutable ecvrfRelay;
    uint256 public lastSeed;
    bool public dealing;

    constructor(uint256 _gameId, address _relay) {
        gameId = _gameId;
        ecvrfRelay = _relay;
        dealing = true;
    }

    function applyECVRFSeed(uint256 randomWord) external {
        require(msg.sender == ecvrfRelay, "!relay");
        require(dealing, "!dealing");
        require(randomWord != 0, "!zero");
        lastSeed = randomWord;
        dealing = false;
    }
}
