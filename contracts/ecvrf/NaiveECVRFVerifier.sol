// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./IECVRFVerifier.sol";

/// @dev 仅用于本地/单元测试：不验椭圆曲线，只检查 proof 长度与 randomWord 非零。生产请用 Secp256k1Sha256TaiECVRFVerifier。
contract NaiveECVRFVerifier is IECVRFVerifier {
    function verify(bytes calldata, bytes calldata proof, uint256 randomWord) external pure returns (bool) {
        return proof.length == 81 && randomWord != 0;
    }
}
