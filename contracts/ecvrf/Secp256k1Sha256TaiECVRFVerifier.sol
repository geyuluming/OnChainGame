// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./IECVRFVerifier.sol";
import "./vendor/Secp256k1Sha256TaiVRF.sol";

/**
 * @title Secp256k1Sha256TaiECVRFVerifier
 * @dev 与 Witnet vrf-solidity / 多数 SECP256K1-SHA256-TAI 链下 Prove 兼容。
 *      proof 为 81 字节：压缩 Gamma(33) | c(16) | s(32)，与 Witnet decodeProof 一致。
 *      randomWord 必须为 uint256(sha256(0xFE || 0x03 || compress(gamma)))，即 uint256(Secp256k1Sha256TaiVRF.gammaToHash(gx, gy))。
 */
contract Secp256k1Sha256TaiECVRFVerifier is IECVRFVerifier {
    uint256 public immutable publicKeyX;
    uint256 public immutable publicKeyY;

    constructor(uint256 _publicKeyX, uint256 _publicKeyY) {
        publicKeyX = _publicKeyX;
        publicKeyY = _publicKeyY;
    }

    function verify(bytes calldata alpha, bytes calldata proof, uint256 randomWord) external view override returns (bool) {
        uint256[2] memory pk = [publicKeyX, publicKeyY];
        bytes memory message = alpha;
        bytes memory proofMem = proof;
        uint256[4] memory pi = Secp256k1Sha256TaiVRF.decodeProof(proofMem);
        if (!Secp256k1Sha256TaiVRF.verify(pk, pi, message)) return false;
        if (randomWord == 0) return false;
        return uint256(Secp256k1Sha256TaiVRF.gammaToHash(pi[0], pi[1])) == randomWord;
    }
}
