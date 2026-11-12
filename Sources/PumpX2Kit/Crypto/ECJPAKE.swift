import Foundation

/// 随机源抽象，便于测试注入确定性随机数。
public protocol RandomSource {
    func bytes(_ count: Int) -> [UInt8]
}

public struct SystemRandomSource: RandomSource {
    public init() {}
    public func bytes(_ count: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
    }
}

/// EC-JPAKE（P-256 / SHA-256），逐行对应 pumpX2 的 `io.particle.crypto.EcJpake`，
/// 后者移植自 mbed TLS，并修正了标量最短编码导致的偶发配对失败。
public final class ECJPAKE {
    public enum Role { case client, server }
    public enum JPAKEError: Error {
        case invalidState, validationFailed, unexpectedCurve, malformed, emptySecret
    }

    private let role: Role
    private let secret: U256
    private let myId: [UInt8]
    private let peerId: [UInt8]
    private let random: RandomSource
    private let fn = Modulus(P256.n)

    private var xm1: U256?
    private var Xm1: P256.Affine?
    private var xm2: U256?
    private var Xm2: P256.Affine?
    private var Xp1: P256.Affine?
    private var Xp2: P256.Affine?
    private var Xp: P256.Affine?

    private var hasPeerRound1 = false
    private var hasPeerRound2 = false
    private var myRound1Bytes: [UInt8]?
    private var myRound2Bytes: [UInt8]?
    private var derived: [UInt8]?

    public init(role: Role, secret: [UInt8], random: RandomSource = SystemRandomSource()) {
        self.role = role
        self.secret = U256(bytesBE: secret)
        self.random = random
        self.myId = role == .client ? Array("client".utf8) : Array("server".utf8)
        self.peerId = role == .client ? Array("server".utf8) : Array("client".utf8)
    }

    // MARK: 第一轮

    public func round1() throws -> [UInt8] {
        if let r = myRound1Bytes { return r }
        guard !secret.isZero else { throw JPAKEError.emptySecret }
        var out: [UInt8] = []

        var kp = try generateKeyPair()
        xm1 = kp.0; Xm1 = kp.1
        writePoint(&out, kp.1)
        try writeZKP(&out, base: P256.generator, x: kp.0, X: kp.1, id: myId)

        kp = try generateKeyPair()
        xm2 = kp.0; Xm2 = kp.1
        writePoint(&out, kp.1)
        try writeZKP(&out, base: P256.generator, x: kp.0, X: kp.1, id: myId)

        myRound1Bytes = out
        return out
    }

    public func readRound1(_ data: [UInt8]) throws {
        guard !hasPeerRound1 else { throw JPAKEError.invalidState }
        var r = Reader(data)
        Xp1 = try readPoint(&r)
        try readZKP(&r, base: P256.generator, X: Xp1!, id: peerId)
        Xp2 = try readPoint(&r)
        try readZKP(&r, base: P256.generator, X: Xp2!, id: peerId)
        hasPeerRound1 = true
    }

    // MARK: 第二轮

    public func round2() throws -> [UInt8] {
        if let r = myRound2Bytes { return r }
        guard hasPeerRound1, let my1 = myRound1Bytes, let xm1, let Xm1, let Xp1, let Xp2 else {
            throw JPAKEError.invalidState
        }
        _ = my1
        var out: [UInt8] = []
        let g = P256.add(P256.add(P256.toJacobian(Xp1), Xp2), Xm1)
        guard let gAffine = P256.toAffine(g) else { throw JPAKEError.malformed }
        let xm = mulSecret(xm2!, negate: false)
        guard let Xm = P256.multiply(xm, gAffine) else { throw JPAKEError.malformed }

        if role == .server {
            out += [3]                       // named_curve
            out += ByteUtil.u32be(23).suffix(2) // P-256 = 23, big-endian uint16
        }
        writePoint(&out, Xm)
        try writeZKP(&out, base: gAffine, x: xm, X: Xm, id: myId)
        myRound2Bytes = out
        return out
    }

    public func readRound2(_ data: [UInt8]) throws {
        guard hasPeerRound1, myRound1Bytes != nil, !hasPeerRound2 else { throw JPAKEError.invalidState }
        var r = Reader(data)
        if role == .client { try readCurveId(&r) }
        guard let Xm1, let Xm2, let Xp1 else { throw JPAKEError.invalidState }
        let g = P256.add(P256.add(P256.toJacobian(Xm1), Xm2), Xp1)
        guard let gAffine = P256.toAffine(g) else { throw JPAKEError.malformed }
        let point = try readPoint(&r)
        try readZKP(&r, base: gAffine, X: point, id: peerId)
        Xp = point
        hasPeerRound2 = true
    }

    // MARK: 密钥派生

    public func deriveSecret() throws -> [UInt8] {
        if let d = derived { return d }
        guard hasPeerRound2, let Xp, let Xp2, let xm2 else { throw JPAKEError.invalidState }
        let xm2s = mulSecret(xm2, negate: true)
        guard let t1 = P256.multiply(xm2s, Xp2) else { throw JPAKEError.malformed }
        let sum = P256.add(P256.toJacobian(Xp), t1)
        let k = P256.multiply(xm2, sum)
        guard let kAffine = P256.toAffine(k) else {
            throw JPAKEError.malformed
        }
        let secretBytes = SHA256.hash(kAffine.x.bytesBE())   // 定长 32 字节，不能去掉前导零
        derived = secretBytes
        return secretBytes
    }

    // MARK: 内部

    private func randomScalar() throws -> U256 {
        for _ in 0..<8 {
            let k = P256.scalarReduce(U256(bytesBE: random.bytes(32)))
            if !k.isZero { return k }
        }
        throw JPAKEError.malformed
    }

    private func generateKeyPair() throws -> (U256, P256.Affine) {
        for _ in 0..<8 {
            let k = P256.scalarReduce(U256(bytesBE: random.bytes(32)))
            if k.isZero { continue }
            if let pub = P256.multiply(k, P256.generator) { return (k, pub) }
        }
        throw JPAKEError.malformed
    }

    /// b = rand16 * n + s 只是盲化，标量上等价于 b ≡ s (mod n)
    private func mulSecret(_ x: U256, negate: Bool) -> U256 {
        var r = P256.scalarMul(x, secret)
        if negate { r = P256.scalarNegate(r) }
        return r
    }

    private func writePoint(_ out: inout [UInt8], _ p: P256.Affine) {
        let enc = P256.encodeUncompressed(p)
        out.append(UInt8(enc.count))
        out += enc
    }

    private func readPoint(_ r: inout Reader) throws -> P256.Affine {
        let len = try r.uint8()
        let enc = try r.bytes(Int(len))
        return try P256.decode(enc)
    }

    private func writeZKP(_ out: inout [UInt8], base: P256.Affine, x: U256, X: P256.Affine,
                          id: [UInt8]) throws {
        let v = try randomScalar()
        guard let V = P256.multiply(v, base) else { throw JPAKEError.malformed }
        let h = zkpHash(base, V, X, id)
        let r = P256.scalarSub(v, P256.scalarMul(x, h))
        writePoint(&out, V)
        writeNum(&out, r)
    }

    private func readZKP(_ r: inout Reader, base: P256.Affine, X: P256.Affine, id: [UInt8]) throws {
        let V = try readPoint(&r)
        let scalar = try readNum(&r)
        let h = zkpHash(base, V, X, id)
        guard let gr = P256.multiply(scalar, base), let xh = P256.multiply(h, X) else {
            throw JPAKEError.malformed
        }
        let vv = P256.toAffine(P256.add(P256.toJacobian(gr), xh))
        guard vv == V else { throw JPAKEError.validationFailed }
    }

    private func zkpHash(_ g: P256.Affine, _ v: P256.Affine, _ x: P256.Affine, _ id: [UInt8]) -> U256 {
        var buf: [UInt8] = []
        for p in [g, v, x] {
            let enc = P256.encodeCompressed(p)
            buf += ByteUtil.u32be(UInt32(enc.count))
            buf += enc
        }
        buf += ByteUtil.u32be(UInt32(id.count))
        buf += id
        return P256.scalarReduce(U256(bytesBE: SHA256.hash(buf)))
    }

    private func writeNum(_ out: inout [UInt8], _ value: U256) {
        // 定长 32 字节，与上游修复后的行为一致
        let enc = value.bytesBE()
        out.append(32)
        out += enc
    }

    private func readNum(_ r: inout Reader) throws -> U256 {
        let len = try r.uint8()
        guard len >= 1, len <= 32 else { throw JPAKEError.malformed }
        return P256.scalarReduce(U256(bytesBE: try r.bytes(Int(len))))
    }

    private func readCurveId(_ r: inout Reader) throws {
        let type = try r.uint8()
        guard type == 3 else { throw JPAKEError.unexpectedCurve }
        let hi = try r.uint8(), lo = try r.uint8()
        guard UInt16(hi) << 8 | UInt16(lo) == 23 else { throw JPAKEError.unexpectedCurve }
    }
}

struct Reader {
    let data: [UInt8]
    var offset = 0
    init(_ d: [UInt8]) { data = d }
    var remaining: Int { data.count - offset }
    mutating func uint8() throws -> UInt8 {
        guard offset < data.count else { throw ECJPAKE.JPAKEError.malformed }
        defer { offset += 1 }
        return data[offset]
    }
    mutating func bytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, offset + n <= data.count else { throw ECJPAKE.JPAKEError.malformed }
        defer { offset += n }
        return Array(data[offset..<offset + n])
    }
}
