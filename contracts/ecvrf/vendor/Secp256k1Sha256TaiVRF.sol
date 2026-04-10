// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./EllipticCurve.sol";

/**
 * @title SECP256K1_SHA256_TAI VRF verify (Witnet vrf-solidity)
 * @dev VRF-draft-04 / Witnet test vectors. decodeProof fixed for Solidity 0.8 bytes memory layout.
 */
library Secp256k1Sha256TaiVRF {
    uint256 internal constant GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    uint256 internal constant GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
    uint256 internal constant AA = 0;
    uint256 internal constant BB = 7;
    uint256 internal constant PP = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    uint256 internal constant NN = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function derivePoint(uint256 _d, uint256 _x, uint256 _y) internal pure returns (uint256, uint256) {
        return EllipticCurve.ecMul(_d, _x, _y, AA, PP);
    }

    function deriveY(uint8 _yByte, uint256 _x) internal pure returns (uint256) {
        return EllipticCurve.deriveY(_yByte, _x, AA, BB, PP);
    }

    /// @dev VRF beta as bytes32; ECVRFRelay randomWord must be uint256(beta) (big-endian).
    function gammaToHash(uint256 _gammaX, uint256 _gammaY) internal pure returns (bytes32) {
        bytes memory c = abi.encodePacked(uint8(0xFE), uint8(0x03), encodePoint(_gammaX, _gammaY));
        return sha256(c);
    }

    function verify(uint256[2] memory _publicKey, uint256[4] memory _proof, bytes memory _message) internal pure returns (bool) {
        (uint256 hPointX, uint256 hPointY) = hashToTryAndIncrement(_publicKey, _message);
        (uint256 uPointX, uint256 uPointY) = ecMulSubMul(_proof[3], GX, GY, _proof[2], _publicKey[0], _publicKey[1]);
        (uint256 vPointX, uint256 vPointY) = ecMulSubMul(_proof[3], hPointX, hPointY, _proof[2], _proof[0], _proof[1]);
        bytes16 derivedC = hashPoints(hPointX, hPointY, _proof[0], _proof[1], uPointX, uPointY, vPointX, vPointY);
        return uint128(derivedC) == _proof[2];
    }

    /// @dev 81 bytes: gamma_sign(1) | gamma_x(32) | c(16) | s(32)
    function decodeProof(bytes memory _proof) internal pure returns (uint256[4] memory r) {
        require(_proof.length == 81, "Malformed VRF proof");
        uint8 gammaSign = uint8(_proof[0]);
        uint256 gammaX;
        uint128 c;
        uint256 s;
        assembly {
            let base := add(_proof, 32)
            gammaX := mload(add(base, 1))
            let w := mload(add(base, 33))
            c := shr(128, w)
            s := mload(add(base, 49))
        }
        uint256 gammaY = deriveY(gammaSign, gammaX);
        r[0] = gammaX;
        r[1] = gammaY;
        r[2] = uint256(c);
        r[3] = s;
    }

    function decodePoint(bytes memory _point) internal pure returns (uint256[2] memory r) {
        require(_point.length == 33, "Malformed compressed EC point");
        uint8 sign = uint8(_point[0]);
        uint256 x;
        assembly {
            x := mload(add(add(_point, 32), 1))
        }
        r[0] = x;
        r[1] = deriveY(sign, x);
    }

    function hashToTryAndIncrement(uint256[2] memory _publicKey, bytes memory _message) internal pure returns (uint256, uint256) {
        bytes memory c = abi.encodePacked(uint8(254), uint8(1), encodePoint(_publicKey[0], _publicKey[1]), _message);
        for (uint256 ctr = 0; ctr < 256; ctr++) {
            bytes32 sha = sha256(abi.encodePacked(c, uint8(ctr)));
            uint256 hPointX = uint256(sha);
            uint256 hPointY = deriveY(2, hPointX);
            if (EllipticCurve.isOnCurve(hPointX, hPointY, AA, BB, PP)) {
                return (hPointX, hPointY);
            }
        }
        revert("No valid point was found");
    }

    function hashPoints(
        uint256 _hPointX,
        uint256 _hPointY,
        uint256 _gammaX,
        uint256 _gammaY,
        uint256 _uPointX,
        uint256 _uPointY,
        uint256 _vPointX,
        uint256 _vPointY
    ) internal pure returns (bytes16) {
        bytes memory c = abi.encodePacked(
            uint8(254),
            uint8(2),
            encodePoint(_hPointX, _hPointY),
            encodePoint(_gammaX, _gammaY),
            encodePoint(_uPointX, _uPointY),
            encodePoint(_vPointX, _vPointY)
        );
        bytes32 sha = sha256(c);
        bytes16 half1;
        assembly {
            let p := mload(0x40)
            mstore(p, sha)
            half1 := mload(p)
        }
        return half1;
    }

    function encodePoint(uint256 _x, uint256 _y) internal pure returns (bytes memory) {
        uint8 prefix = uint8(2 + (_y % 2));
        return abi.encodePacked(prefix, _x);
    }

    function ecMulSubMul(
        uint256 _scalar1,
        uint256 _a1,
        uint256 _a2,
        uint256 _scalar2,
        uint256 _b1,
        uint256 _b2
    ) internal pure returns (uint256, uint256) {
        (uint256 m1, uint256 m2) = derivePoint(_scalar1, _a1, _a2);
        (uint256 n1, uint256 n2) = derivePoint(_scalar2, _b1, _b2);
        return EllipticCurve.ecSub(m1, m2, n1, n2, AA, PP);
    }
}
