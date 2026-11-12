import Foundation

/// P-256（secp256r1）曲线运算。仅覆盖 EC-JPAKE 所需：点加、倍点、标量乘、压缩/非压缩编解码。
public enum P256 {
    public static let p = U256(hex: "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff")
    public static let n = U256(hex: "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
    public static let b = U256(hex: "5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b")
    public static let gx = U256(hex: "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296")
    public static let gy = U256(hex: "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")

    static let fp = Modulus(p)
    static let fn = Modulus(n)

    public struct Affine: Equatable {
        public let x: U256
        public let y: U256
        public init(x: U256, y: U256) { self.x = x; self.y = y }
    }

    public static let generator = Affine(x: gx, y: gy)

    // MARK: 域运算

    @inline(__always) static func fadd(_ a: U256, _ b: U256) -> U256 { Modulus.addMod(a, b, p) }
    @inline(__always) static func fsub(_ a: U256, _ b: U256) -> U256 { Modulus.subMod(a, b, p) }
    @inline(__always) static func fmul(_ a: U256, _ b: U256) -> U256 { fp.fromMont(fp.mul(fp.toMont(a), fp.toMont(b))) }
    @inline(__always) static func fsqr(_ a: U256) -> U256 { fmul(a, a) }
    static func finv(_ a: U256) -> U256 { fp.inverse(a) }

    // MARK: Jacobian 点

    public struct Jacobian {
        public var x: U256
        public var y: U256
        public var z: U256
        public var isInfinity: Bool
        public init(x: U256, y: U256, z: U256, isInfinity: Bool = false) {
            self.x = x; self.y = y; self.z = z; self.isInfinity = isInfinity
        }
        static let infinity = Jacobian(x: .zero, y: .zero, z: .zero, isInfinity: true)
    }

    public static func toJacobian(_ a: Affine) -> Jacobian {
        Jacobian(x: a.x, y: a.y, z: U256(1))
    }

    public static func toAffine(_ j: Jacobian) -> Affine? {
        if j.isInfinity || j.z.isZero { return nil }
        let zi = finv(j.z)
        let zi2 = fsqr(zi)
        let zi3 = fmul(zi2, zi)
        return Affine(x: fmul(j.x, zi2), y: fmul(j.y, zi3))
    }

    public static func double(_ j: Jacobian) -> Jacobian {
        if j.isInfinity || j.y.isZero { return .infinity }
        // a = -3 的标准倍点公式
        let delta = fsqr(j.z)
        let gamma = fsqr(j.y)
        let beta = fmul(j.x, gamma)
        let alpha = fmul(fmul(U256(3), fsub(j.x, delta)), fadd(j.x, delta))
        let x3 = fsub(fsqr(alpha), fmul(U256(8), beta))
        let z3 = fsub(fsub(fsqr(fadd(j.y, j.z)), gamma), delta)
        let y3 = fsub(fmul(alpha, fsub(fmul(U256(4), beta), x3)), fmul(U256(8), fsqr(gamma)))
        return Jacobian(x: x3, y: y3, z: z3)
    }

    public static func add(_ p1: Jacobian, _ p2: Jacobian) -> Jacobian {
        if p1.isInfinity { return p2 }
        if p2.isInfinity { return p1 }
        let z1z1 = fsqr(p1.z)
        let z2z2 = fsqr(p2.z)
        let u1 = fmul(p1.x, z2z2)
        let u2 = fmul(p2.x, z1z1)
        let s1 = fmul(p1.y, fmul(p2.z, z2z2))
        let s2 = fmul(p2.y, fmul(p1.z, z1z1))
        let h = fsub(u2, u1)
        let r = fsub(s2, s1)
        if h.isZero {
            if r.isZero { return double(p1) }
            return .infinity
        }
        let hh = fsqr(h)
        let hhh = fmul(h, hh)
        let v = fmul(u1, hh)
        let x3 = fsub(fsub(fsqr(r), hhh), fmul(U256(2), v))
        let y3 = fsub(fmul(r, fsub(v, x3)), fmul(s1, hhh))
        let z3 = fmul(fmul(p1.z, p2.z), h)
        return Jacobian(x: x3, y: y3, z: z3)
    }

    public static func add(_ p1: Jacobian, _ a: Affine) -> Jacobian {
        add(p1, toJacobian(a))
    }

    /// 标量乘（double-and-add，非恒定时间；BLE 场景下不构成实际可行的时间侧信道）
    public static func multiply(_ k: U256, _ point: Jacobian) -> Jacobian {
        var result = Jacobian.infinity
        var addend = point
        let bits = max(k.bitLength, 1)
        for i in 0..<bits {
            if k.bit(i) { result = add(result, addend) }
            addend = double(addend)
        }
        return result
    }

    public static func multiply(_ k: U256, _ point: Affine) -> Affine? {
        toAffine(multiply(k, toJacobian(point)))
    }

    // MARK: 编解码

    public static func encodeUncompressed(_ a: Affine) -> [UInt8] {
        [0x04] + a.x.bytesBE() + a.y.bytesBE()
    }

    public static func encodeCompressed(_ a: Affine) -> [UInt8] {
        [a.y.w[0] & 1 == 0 ? 0x02 : 0x03] + a.x.bytesBE()
    }

    public enum DecodeError: Error { case invalidLength, invalidPrefix, notOnCurve, badPoint }

    public static func decode(_ data: [UInt8]) throws -> Affine {
        guard !data.isEmpty else { throw DecodeError.invalidLength }
        switch data[0] {
        case 0x04:
            guard data.count == 65 else { throw DecodeError.invalidLength }
            let x = U256(bytesBE: Array(data[1..<33]))
            let y = U256(bytesBE: Array(data[33..<65]))
            let point = Affine(x: x, y: y)
            guard isOnCurve(point) else { throw DecodeError.notOnCurve }
            return point
        case 0x02, 0x03:
            guard data.count == 33 else { throw DecodeError.invalidLength }
            let x = U256(bytesBE: Array(data[1...32]))
            guard x < p else { throw DecodeError.badPoint }
            let rhs = fadd(fadd(fmul(fsqr(x), x), fmul(P256.p.subtracting(U256(3)).0, x)), b)
            // p ≡ 3 (mod 4)，开方 = rhs^((p+1)/4)
            let exp = p.adding(U256(1)).0.shiftedRight2()
            var y = fp.pow(rhs, exp)
            if fsqr(y) != rhs { throw DecodeError.notOnCurve }
            let wantOdd = data[0] == 0x03
            if (y.w[0] & 1 == 1) != wantOdd { y = fsub(p, y) }
            let point = Affine(x: x, y: y)
            guard isOnCurve(point) else { throw DecodeError.notOnCurve }
            return point
        default:
            throw DecodeError.invalidPrefix
        }
    }

    public static func isOnCurve(_ a: Affine) -> Bool {
        // y^2 = x^3 - 3x + b
        let lhs = fsqr(a.y)
        let rhs = fadd(fadd(fmul(fsqr(a.x), a.x), fmul(p.subtracting(U256(3)).0, a.x)), b)
        return lhs == rhs
    }

    // MARK: 标量域

    public static func scalarAdd(_ a: U256, _ b: U256) -> U256 { Modulus.addMod(a, b, n) }
    public static func scalarSub(_ a: U256, _ b: U256) -> U256 { Modulus.subMod(a, b, n) }
    public static func scalarMul(_ a: U256, _ b: U256) -> U256 {
        fn.fromMont(fn.mul(fn.toMont(Modulus.reduce(a, n)), fn.toMont(Modulus.reduce(b, n))))
    }
    public static func scalarNegate(_ a: U256) -> U256 { fn.negate(Modulus.reduce(a, n)) }
    public static func scalarReduce(_ a: U256) -> U256 { Modulus.reduce(a, n) }
}

extension U256 {
    func shiftedRight2() -> U256 { shiftedRight1().shiftedRight1() }
}
