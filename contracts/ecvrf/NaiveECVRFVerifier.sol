// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./IECVRFVerifier.sol";

/// @dev 仅用于本地演示：不执行真实椭圆曲线验证。生产请换预编译或完整 ECVRF 验证实现。
contract NaiveECVRFVerifier is IECVRFVerifier {
    function verify(bytes calldata, bytes calldata proof, uint256 randomWord) external pure returns (bool) {
        return proof.length >= 80 && randomWord != 0;
    }
}
