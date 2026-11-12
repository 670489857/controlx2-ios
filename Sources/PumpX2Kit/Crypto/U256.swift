import Foundation

/// 256 位无符号整数（8 个 32 位 limb，小端），只覆盖协议需要的运算。
public struct U256: Equatable, Comparable, CustomStringConvertible {
    public var w: [UInt32]

    public init(words: [UInt32]) {
        precondition(words.count == 8)
        self.w = words
    }

    public init(_ value: UInt64) {
        var words = [UInt32](repeating: 0, count: 8)
        words[0] = UInt32(truncatingIfNeeded: value)
        words[1] = UInt32(truncatingIfNeeded: value >> 32)
        self.w = words
    }

    /// 大端字节，最多 32 字节（不足左补零；超过则取低 32 字节）
    public init(bytesBE: [UInt8]) {
        var b = bytesBE
        if b.count > 32 { b = Array(b.suffix(32)) }
        if b.count < 32 { b = [UInt8](repeating: 0, count: 32 - b.count) + b }
        var words = [UInt32](repeating: 0, count: 8)
        for i in 0..<8 {
            let o = i * 4
            words[7 - i] = UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
        }
        self.w = words
    }

    public static let zero = U256(words: [UInt32](repeating: 0, count: 8))

    public func bytesBE() -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(32)
        for i in (0..<8).reversed() { out += ByteUtil.u32be(w[i]) }
        return out
    }

    public var isZero: Bool { w.allSatisfy { $0 == 0 } }

    public var bitLength: Int {
        for i in (0..<8).reversed() where w[i] != 0 {
            return i * 32 + (32 - w[i].leadingZeroBitCount)
        }
        return 0
    }

    public func bit(_ i: Int) -> Bool {
        guard i >= 0 && i < 256 else { return false }
        return (w[i / 32] >> UInt32(i % 32)) & 1 == 1
    }

    public static func < (lhs: U256, rhs: U256) -> Bool {
        for i in (0..<8).reversed() {
            if lhs.w[i] != rhs.w[i] { return lhs.w[i] < rhs.w[i] }
        }
        return false
    }

    /// (self + other, carry)
    public func adding(_ other: U256) -> (U256, UInt32) {
        var r = [UInt32](repeating: 0, count: 8)
        var carry: UInt64 = 0
        for i in 0..<8 {
            let s = UInt64(w[i]) + UInt64(other.w[i]) + carry
            r[i] = UInt32(truncatingIfNeeded: s)
            carry = s >> 32
        }
        return (U256(words: r), UInt32(carry))
    }

    /// (self - other, borrow)
    public func subtracting(_ other: U256) -> (U256, UInt32) {
        var r = [UInt32](repeating: 0, count: 8)
        var borrow: UInt64 = 0
        for i in 0..<8 {
            let d = Int64(w[i]) - Int64(other.w[i]) - Int64(borrow)
            r[i] = UInt32(truncatingIfNeeded: d)
            borrow = d < 0 ? 1 : 0
        }
        return (U256(words: r), UInt32(borrow))
    }

    public func xor(_ other: U256) -> U256 {
        U256(words: (0..<8).map { w[$0] ^ other.w[$0] })
    }

    public func shiftedLeft1() -> (U256, UInt32) {
        var r = [UInt32](repeating: 0, count: 8)
        var carry: UInt32 = 0
        for i in 0..<8 {
            r[i] = (w[i] << 1) | carry
            carry = w[i] >> 31
        }
        return (U256(words: r), carry)
    }

    public func shiftedRight1() -> U256 {
        var r = [UInt32](repeating: 0, count: 8)
        var carry: UInt32 = 0
        for i in (0..<8).reversed() {
            r[i] = (w[i] >> 1) | (carry << 31)
            carry = w[i] & 1
        }
        return U256(words: r)
    }

    public var description: String { Hex.encode(bytesBE()) }

    public init(hex: String) {
        self.init(bytesBE: (try? Hex.decode(hex)) ?? [])
    }
}

/// Montgomery 域运算（模数为奇数），用于 P-256 的素域与标量域。
public struct Modulus {
    public let n: U256
    let n0inv: UInt32
    let rr: U256      // R^2 mod n
    let oneMont: U256 // R mod n

    public init(_ modulus: U256) {
        precondition(!modulus.isZero && modulus.w[0] & 1 == 1, "modulus must be odd")
        self.n = modulus

        // -n0^{-1} mod 2^32（Newton 迭代，5 次收敛到 32 位）
        var inv: UInt32 = 1
        for _ in 0..<5 {
            inv = inv &* (2 &- modulus.w[0] &* inv)
        }
        self.n0inv = 0 &- inv

        // oneMont = 2^256 mod n：从 1 开始做 256 次加倍取模
        var x = U256(1)
        for _ in 0..<256 { x = Modulus.addMod(x, x, modulus) }
        self.oneMont = x

        // rr = 2^512 mod n：从 2^256 mod n 继续加倍 256 次
        var y = x
        for _ in 0..<256 { y = Modulus.addMod(y, y, modulus) }
        self.rr = y
    }

    /// 普通（非 Montgomery）模加，处理进位与单次条件减
    public static func addMod(_ a: U256, _ b: U256, _ m: U256) -> U256 {
        let (s, carry) = a.adding(b)
        if carry != 0 || s >= m { return s.subtracting(m).0 }
        return s
    }

    public static func subMod(_ a: U256, _ b: U256, _ m: U256) -> U256 {
        let (d, borrow) = a.subtracting(b)
        return borrow != 0 ? d.adding(m).0 : d
    }

    /// 把任意 256 位值规约到 [0, m)。m 接近 2^256，最多减一次。
    public static func reduce(_ a: U256, _ m: U256) -> U256 {
        return a < m ? a : a.subtracting(m).0
    }

    public func mul(_ a: U256, _ b: U256) -> U256 {
        var t = [UInt32](repeating: 0, count: 10)
        for i in 0..<8 {
            var carry: UInt64 = 0
            let ai = UInt64(a.w[i])
            for j in 0..<8 {
                let uv = UInt64(t[j]) &+ ai &* UInt64(b.w[j]) &+ carry
                t[j] = UInt32(truncatingIfNeeded: uv)
                carry = uv >> 32
            }
            var uv = UInt64(t[8]) &+ carry
            t[8] = UInt32(truncatingIfNeeded: uv)
            t[9] = UInt32(uv >> 32)

            let m = UInt32(truncatingIfNeeded: UInt64(t[0]) &* UInt64(n0inv))
            carry = 0
            let mi = UInt64(m)
            for j in 0..<8 {
                let uv2 = UInt64(t[j]) &+ mi &* UInt64(n.w[j]) &+ carry
                t[j] = UInt32(truncatingIfNeeded: uv2)
                carry = uv2 >> 32
            }
            uv = UInt64(t[8]) &+ carry
            t[8] = UInt32(truncatingIfNeeded: uv)
            t[9] = t[9] &+ UInt32(uv >> 32)

            for k in 0..<9 { t[k] = t[k + 1] }
            t[9] = 0
        }
        var r = U256(words: Array(t[0..<8]))
        if t[8] != 0 || !(r < n) { r = r.subtracting(n).0 }
        return r
    }

    public func sqr(_ a: U256) -> U256 { mul(a, a) }

    public func toMont(_ a: U256) -> U256 { mul(Modulus.reduce(a, n), rr) }
    public func fromMont(_ a: U256) -> U256 { mul(a, U256(1)) }

    /// 模幂：base 为普通值，返回普通值
    public func pow(_ base: U256, _ exponent: U256) -> U256 {
        var result = oneMont
        var b = toMont(base)
        let bits = max(exponent.bitLength, 1)
        for i in (0..<bits).reversed() {
            result = mul(result, result)
            if exponent.bit(i) { result = mul(result, b) }
        }
        return fromMont(result)
    }

    public func inverse(_ a: U256) -> U256 {
        // n 为素数，费马小定理
        pow(a, n.subtracting(U256(2)).0)
    }

    public func negate(_ a: U256) -> U256 {
        a.isZero ? a : n.subtracting(Modulus.reduce(a, n)).0
    }
}
