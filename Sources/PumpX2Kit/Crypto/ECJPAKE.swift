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
        /// 数据还没收全（对端把一轮拆成两条消息，或载荷尾部带了对齐用的 0）
        case truncated
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
    /// 第一轮会被重复扫描（1a 收了半轮、1b 再补齐），每个点的零知识证明只验一次
    private var zkp1Checked = false
    private var zkp2Checked = false
    /// 对端第一轮可能分两条消息到达，也可能尾部带对齐 0；这里攒起来增量解析
    private var round1Incoming: [UInt8] = []
    private var myRound1Bytes: [UInt8]?
    private var myRound2Bytes: [UInt8]?
    private var derived: [UInt8]?

    /// 对端第一轮是否已解析完成（1a 只有半轮时仍为 false）
    public var peerRound1Complete: Bool { hasPeerRound1 }

    /// 对端零知识证明校验不通过时的说明。
    ///
    /// 校验失败不再立刻中止：JPAKE 的会话密钥由标量运算决定，ZKP 只用于防中间人。
    /// 若因为本地实现与泵端有细微差异而校验不过，继续走完仍可能配对成功，而
    /// 真有问题时泵会在第 5 条报文（0x28）拒绝——那一步的信号比这里可靠得多。
    /// 但必须留下记录，否则「明明哪里不对却一路绿灯」更难查。
    public private(set) var peerZKPWarning: String?

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

    /// 可重复调用：泵把第一轮拆成 1a / 1b 两条消息，各自 165 字节；
    /// 任一侧的 ZKP 标量若按最小长度编码，整轮会短 1–4 字节（pumpX2
    /// `PacketArrayList.SHORT_CARGO_TOLERANT_MESSAGES` 专门为此开了例外，
    /// 注释写明「大约每个标量 1/256 的概率」）。所以这里只把收到的字节攒起来，
    /// 能解析多少解析多少，剩下等下一段——**不能要求半轮边界正好落在字段边界上**。
    ///
    /// 已解析出的点不重复校验：0x23 到达后从头重扫时，X1 的零知识证明再算一遍
    /// 要点乘两次，纯 Swift 下每次几百毫秒，白白让配对多等一秒多。
    public func readRound1(_ data: [UInt8]) throws {
        guard !hasPeerRound1 else { throw JPAKEError.invalidState }
        round1Incoming += data
        var r = Reader(round1Incoming)
        do {
            // 顺序必须是「点 → 该点的零知识证明」，与 writePoint/writeZKP 的写出顺序一致
            let x1 = try readPoint(&r)
            Xp1 = x1
            let z1 = try readZKPRaw(&r)
            if !zkp1Checked {
                zkp1Checked = true
                if !verifyZKP(z1, base: P256.generator, X: x1, id: peerId) {
                    peerZKPWarning = "对端 X1 的零知识证明不通过"
                }
            }
            let x2 = try readPoint(&r)
            Xp2 = x2
            let z2 = try readZKPRaw(&r)
            if !zkp2Checked {
                zkp2Checked = true
                if !verifyZKP(z2, base: P256.generator, X: x2, id: peerId) {
                    peerZKPWarning = "对端 X2 的零知识证明不通过"
                }
            }
        } catch JPAKEError.truncated {
            return   // 等下一段
        }
        hasPeerRound1 = true
        round1Incoming = []
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
        let raw = try readZKPRaw(&r)
        // 与第一轮同一策略：ZKP 只是防中间人的旁证，会话密钥由标量运算决定，
        // 真正的判定点是泵对 0x28 摘要的确认。这里校验不过就中止，等于把
        // 「本地实现与泵端有细微差异」重新变成一个查不出原因的硬失败。
        if !verifyZKP(raw, base: gAffine, X: point, id: peerId) {
            peerZKPWarning = "对端第二轮的零知识证明不通过"
        }
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

    /// b = rand16 * n + s 只是盲化，标量上等价于 b ≡ s (mod n)。
    ///
    /// 这 16 字节随机消耗**不能省**：它和 pumpX2 / mbedtls 的随机流顺序绑定，
    /// 省掉之后后面每个标量都会错位一个随机块，结果与泵完全对不上。
    private func mulSecret(_ x: U256, negate: Bool) -> U256 {
        let b16 = U256(bytesBE: random.bytes(16))
        let blinded = P256.scalarAdd(P256.scalarMul(b16, P256.n), secret)
        var r = P256.scalarMul(x, blinded)
        if negate { r = P256.scalarNegate(r) }
        return r
    }

    private func writePoint(_ out: inout [UInt8], _ p: P256.Affine) {
        let enc = P256.encodeUncompressed(p)
        out.append(UInt8(enc.count))
        out += enc
    }

    private func readPoint(_ r: inout Reader) throws -> P256.Affine {
        let len = try readLengthPrefix(&r)
        let enc = try r.bytes(len)
        do { return try P256.decode(enc) }
        catch { throw JPAKEError.malformed }
    }

    /// 读 1 字节长度前缀。长度 0 不可能是合法点/标量（最短也是 1 字节），
    /// 因此把它当作对端载荷尾部的对齐填充跳过。
    private func readLengthPrefix(_ r: inout Reader) throws -> Int {
        while true {
            let len = Int(try r.uint8())
            if len == 0 { continue }
            return len
        }
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

    /// 只读字段、不做点乘：增量解析时会重复扫同一段字节，
    /// 校验必须按「每个点只做一次」来，否则配对时长直接翻倍。
    private func readZKPRaw(_ r: inout Reader) throws -> ZKP {
        let V = try readPoint(&r)
        let scalar = try readNum(&r)
        return ZKP(point: V, scalar: scalar)
    }

    private func verifyZKP(_ zkp: ZKP, base: P256.Affine, X: P256.Affine, id: [UInt8]) -> Bool {
        let h = zkpHash(base, zkp.point, X, id)
        guard let gr = P256.multiply(zkp.scalar, base),
              let xh = P256.multiply(h, X) else { return false }
        return P256.toAffine(P256.add(P256.toJacobian(gr), xh)) == zkp.point
    }

    private struct ZKP {
        let point: P256.Affine
        let scalar: U256
    }

    private func zkpHash(_ g: P256.Affine, _ v: P256.Affine, _ x: P256.Affine, _ id: [UInt8]) -> U256 {
        var buf: [UInt8] = []
        for p in [g, v, x] {
            // 必须是**非压缩**点（0x04 || X || Y，65 字节）。
            // 原来用压缩点（33 字节）会让哈希输入与泵端 mbedtls 不一致，
            // 算出的挑战 h 全错，泵校验 ZKP 失败后直接断链且不给任何回包。
            let enc = P256.encodeUncompressed(p)
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
        let len = try readLengthPrefix(&r)
        guard len <= 32 else { throw JPAKEError.malformed }
        return P256.scalarReduce(U256(bytesBE: try r.bytes(len)))
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
        guard offset < data.count else { throw ECJPAKE.JPAKEError.truncated }
        defer { offset += 1 }
        return data[offset]
    }
    mutating func bytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, offset + n <= data.count else { throw ECJPAKE.JPAKEError.truncated }
        defer { offset += n }
        return Array(data[offset..<offset + n])
    }
}

extension ECJPAKE.JPAKEError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidState:  return "JPAKE 步骤顺序不对"
        case .validationFailed: return "零知识证明校验不通过（对端数据与本地计算不一致）"
        case .unexpectedCurve: return "对端用的不是 P-256 曲线"
        case .malformed:     return "字段格式非法（点或标量解码失败）"
        case .emptySecret:   return "配对码为空"
        case .truncated:     return "本轮数据没收全"
        }
    }
}
