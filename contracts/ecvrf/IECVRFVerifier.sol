// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev 链上 ECVRF 验证接口（可与预编译或完整 Solidity 实现对接；address(0) 表示不在链上验证明）
interface IECVRFVerifier {
    function verify(bytes calldata alpha, bytes calldata proof, uint256 randomWord) external view returns (bool);
}
