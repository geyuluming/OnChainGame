// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title Elliptic Curve Library
 * @dev From witnet/elliptic-curve-solidity (MIT). Used by Secp256k1Sha256TaiVRF.
 */
library EllipticCurve {
    uint256 private constant U255_MAX_PLUS_1 =
        57896044618658097711785492504343953926634992332820282019728792003956564819968;

    function invMod(uint256 _x, uint256 _pp) internal pure returns (uint256) {
        require(_x != 0 && _x != _pp && _pp != 0, "Invalid number");
        uint256 q = 0;
        uint256 newT = 1;
        uint256 r = _pp;
        uint256 t;
        uint256 x = _x;
        while (x != 0) {
            t = r / x;
            (q, newT) = (newT, addmod(q, (_pp - mulmod(t, newT, _pp)), _pp));
            (r, x) = (x, r - t * x);
        }
        return q;
    }

    function expMod(uint256 _base, uint256 _exp, uint256 _pp) internal pure returns (uint256) {
        require(_pp != 0, "EllipticCurve: modulus is zero");
        if (_base == 0) return 0;
        if (_exp == 0) return 1;
        uint256 r = 1;
        uint256 bit = U255_MAX_PLUS_1;
        assembly {
            for {} gt(bit, 0) {} {
                r := mulmod(mulmod(r, r, _pp), exp(_base, iszero(iszero(and(_exp, bit)))), _pp)
                r := mulmod(mulmod(r, r, _pp), exp(_base, iszero(iszero(and(_exp, div(bit, 2))))), _pp)
                r := mulmod(mulmod(r, r, _pp), exp(_base, iszero(iszero(and(_exp, div(bit, 4))))), _pp)
                r := mulmod(mulmod(r, r, _pp), exp(_base, iszero(iszero(and(_exp, div(bit, 8))))), _pp)
                bit := div(bit, 16)
            }
        }
        return r;
    }

    function toAffine(uint256 _x, uint256 _y, uint256 _z, uint256 _pp) internal pure returns (uint256, uint256) {
        uint256 zInv = invMod(_z, _pp);
        uint256 zInv2 = mulmod(zInv, zInv, _pp);
        uint256 x2 = mulmod(_x, zInv2, _pp);
        uint256 y2 = mulmod(_y, mulmod(zInv, zInv2, _pp), _pp);
        return (x2, y2);
    }

    function deriveY(uint8 _prefix, uint256 _x, uint256 _aa, uint256 _bb, uint256 _pp) internal pure returns (uint256) {
        require(_prefix == 0x02 || _prefix == 0x03, "EllipticCurve: invalid compressed EC point prefix");
        uint256 y2 = addmod(mulmod(_x, mulmod(_x, _x, _pp), _pp), addmod(mulmod(_x, _aa, _pp), _bb, _pp), _pp);
        y2 = expMod(y2, (_pp + 1) / 4, _pp);
        uint256 y = (y2 + _prefix) % 2 == 0 ? y2 : _pp - y2;
        return y;
    }

    function isOnCurve(uint256 _x, uint256 _y, uint256 _aa, uint256 _bb, uint256 _pp) internal pure returns (bool) {
        if (0 == _x || _x >= _pp || 0 == _y || _y >= _pp) return false;
        uint256 lhs = mulmod(_y, _y, _pp);
        uint256 rhs = mulmod(mulmod(_x, _x, _pp), _x, _pp);
        if (_aa != 0) rhs = addmod(rhs, mulmod(_x, _aa, _pp), _pp);
        if (_bb != 0) rhs = addmod(rhs, _bb, _pp);
        return lhs == rhs;
    }

    function ecInv(uint256 _x, uint256 _y, uint256 _pp) internal pure returns (uint256, uint256) {
        return (_x, (_pp - _y) % _pp);
    }

    function ecAdd(
        uint256 _x1,
        uint256 _y1,
        uint256 _x2,
        uint256 _y2,
        uint256 _aa,
        uint256 _pp
    ) internal pure returns (uint256, uint256) {
        uint256 x;
        uint256 y;
        uint256 z;
        if (_x1 == _x2) {
            if (addmod(_y1, _y2, _pp) == 0) return (0, 0);
            (x, y, z) = jacDouble(_x1, _y1, 1, _aa, _pp);
        } else {
            (x, y, z) = jacAdd(_x1, _y1, 1, _x2, _y2, 1, _pp);
        }
        return toAffine(x, y, z, _pp);
    }

    function ecSub(
        uint256 _x1,
        uint256 _y1,
        uint256 _x2,
        uint256 _y2,
        uint256 _aa,
        uint256 _pp
    ) internal pure returns (uint256, uint256) {
        (uint256 x, uint256 y) = ecInv(_x2, _y2, _pp);
        return ecAdd(_x1, _y1, x, y, _aa, _pp);
    }

    function ecMul(
        uint256 _k,
        uint256 _x,
        uint256 _y,
        uint256 _aa,
        uint256 _pp
    ) internal pure returns (uint256, uint256) {
        (uint256 x1, uint256 y1, uint256 z1) = jacMul(_k, _x, _y, 1, _aa, _pp);
        return toAffine(x1, y1, z1, _pp);
    }

    function jacAdd(
        uint256 _x1,
        uint256 _y1,
        uint256 _z1,
        uint256 _x2,
        uint256 _y2,
        uint256 _z2,
        uint256 _pp
    ) internal pure returns (uint256, uint256, uint256) {
        if (_x1 == 0 && _y1 == 0) return (_x2, _y2, _z2);
        if (_x2 == 0 && _y2 == 0) return (_x1, _y1, _z1);
        uint256[4] memory zs;
        zs[0] = mulmod(_z1, _z1, _pp);
        zs[1] = mulmod(_z1, zs[0], _pp);
        zs[2] = mulmod(_z2, _z2, _pp);
        zs[3] = mulmod(_z2, zs[2], _pp);
        zs = [
            mulmod(_x1, zs[2], _pp),
            mulmod(_y1, zs[3], _pp),
            mulmod(_x2, zs[0], _pp),
            mulmod(_y2, zs[1], _pp)
        ];
        require(zs[0] != zs[2] || zs[1] != zs[3], "Use jacDouble function instead");
        uint256[4] memory hr;
        hr[0] = addmod(zs[2], _pp - zs[0], _pp);
        hr[1] = addmod(zs[3], _pp - zs[1], _pp);
        hr[2] = mulmod(hr[0], hr[0], _pp);
        hr[3] = mulmod(hr[2], hr[0], _pp);
        uint256 qx = addmod(mulmod(hr[1], hr[1], _pp), _pp - hr[3], _pp);
        qx = addmod(qx, _pp - mulmod(2, mulmod(zs[0], hr[2], _pp), _pp), _pp);
        uint256 qy = mulmod(hr[1], addmod(mulmod(zs[0], hr[2], _pp), _pp - qx, _pp), _pp);
        qy = addmod(qy, _pp - mulmod(zs[1], hr[3], _pp), _pp);
        uint256 qz = mulmod(hr[0], mulmod(_z1, _z2, _pp), _pp);
        return (qx, qy, qz);
    }

    function jacDouble(
        uint256 _x,
        uint256 _y,
        uint256 _z,
        uint256 _aa,
        uint256 _pp
    ) internal pure returns (uint256, uint256, uint256) {
        if (_z == 0) return (_x, _y, _z);
        uint256 x = mulmod(_x, _x, _pp);
        uint256 y = mulmod(_y, _y, _pp);
        uint256 z = mulmod(_z, _z, _pp);
        uint256 s = mulmod(4, mulmod(_x, y, _pp), _pp);
        uint256 m = addmod(mulmod(3, x, _pp), mulmod(_aa, mulmod(z, z, _pp), _pp), _pp);
        x = addmod(mulmod(m, m, _pp), _pp - addmod(s, s, _pp), _pp);
        y = addmod(mulmod(m, addmod(s, _pp - x, _pp), _pp), _pp - mulmod(8, mulmod(y, y, _pp), _pp), _pp);
        z = mulmod(2, mulmod(_y, _z, _pp), _pp);
        return (x, y, z);
    }

    function jacMul(
        uint256 _d,
        uint256 _x,
        uint256 _y,
        uint256 _z,
        uint256 _aa,
        uint256 _pp
    ) internal pure returns (uint256, uint256, uint256) {
        if (_d == 0) return (_x, _y, _z);
        uint256 remaining = _d;
        uint256 qx = 0;
        uint256 qy = 0;
        uint256 qz = 1;
        uint256 px = _x;
        uint256 py = _y;
        uint256 pz = _z;
        while (remaining != 0) {
            if ((remaining & 1) != 0) {
                (qx, qy, qz) = jacAdd(qx, qy, qz, px, py, pz, _pp);
            }
            remaining = remaining / 2;
            (px, py, pz) = jacDouble(px, py, pz, _aa, _pp);
        }
        return (qx, qy, qz);
    }
}
