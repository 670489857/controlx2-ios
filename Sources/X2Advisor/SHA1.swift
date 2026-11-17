import Foundation

/// SHA-1（十六进制小写）。
///
/// # 为什么自己写
///
/// Nightscout 的「网址 + 密码」模式要的是 `api-secret: sha1(密码)` 这个头，
/// 而不是密码原文。用现成库会有两个问题：CryptoKit 在 iOS 上可用、在 Linux 上
/// 不可用（单测跑在 Linux），引 SwiftCrypto 又要多一个包依赖。SHA-1 的算法是
/// 完全公开且固定的，这里按 FIPS 180-1 实现，用标准向量对拍。
///
/// 注意：SHA-1 在这里不是用来做安全承诺的——它只是 Nightscout 的传输约定，
/// 密码本身的强度由用户决定，不要因为"用了哈希"就以为这条链路更安全。
public enum SHA1 {

    public static func hex(_ text: String) -> String {
        digest(Array(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func digest(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]

        // 补位：0x80 → 补 0 到 56 (mod 64) → 64 位大端长度
        var padded = message
        let bitLength = UInt64(message.count) * 8
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: padded.count, by: 64) {
            for i in 0..<16 {
                let o = chunk + i * 4
                w[i] = (UInt32(padded[o]) << 24)
                    | (UInt32(padded[o + 1]) << 16)
                    | (UInt32(padded[o + 2]) << 8)
                    | UInt32(padded[o + 3])
            }
            for i in 16..<80 {
                let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = (x << 1) | (x >> 31)
            }

            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20:
                    f = (b & c) | ((~b) & d)
                    k = 0x5A827999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1BBCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62C1D6
                }
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = (b << 30) | (b >> 2)
                b = a
                a = temp
            }

            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
        }

        var out = [UInt8]()
        out.reserveCapacity(20)
        for word in h {
            out.append(UInt8((word >> 24) & 0xFF))
            out.append(UInt8((word >> 16) & 0xFF))
            out.append(UInt8((word >> 8) & 0xFF))
            out.append(UInt8(word & 0xFF))
        }
        return out
    }
}
