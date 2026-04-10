// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev 可选 VRF：coordinator 为 address(0) 时不发起请求；回调仅允许 coordinator 调用
abstract contract OptionalVRFConsumer {
    address internal immutable vrfCoordinator;
    uint64 internal immutable vrfSubId;
    bytes32 internal immutable vrfKeyHash;
    uint32 internal immutable vrfCallbackGasLimit;
    uint16 internal immutable vrfRequestConfirmations;

    constructor(
        address _vrfCoordinator,
        uint64 _vrfSubId,
        bytes32 _vrfKeyHash,
        uint32 _vrfCallbackGasLimit,
        uint16 _vrfRequestConfirmations
    ) {
        vrfCoordinator = _vrfCoordinator;
        vrfSubId = _vrfSubId;
        vrfKeyHash = _vrfKeyHash;
        vrfCallbackGasLimit = _vrfCallbackGasLimit;
        vrfRequestConfirmations = _vrfRequestConfirmations;
    }

    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external virtual {
        require(vrfCoordinator != address(0), "vrf off");
        require(msg.sender == vrfCoordinator, "only coordinator");
        fulfillRandomWords(requestId, randomWords);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal virtual;
}
