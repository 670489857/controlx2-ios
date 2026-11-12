import Foundation

public enum HexError: Error { case oddLength, invalidCharacter }

public enum Hex {
    public static func decode(_ s: String) throws -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var hi: UInt8? = nil
        for ch in s.unicodeScalars {
            guard let v = val(ch) else {
                if ch == " " || ch == "\n" || ch == "\t" { continue }
                throw HexError.invalidCharacter
            }
            if let h = hi { out.append(h << 4 | v); hi = nil } else { hi = v }
        }
        if hi != nil { throw HexError.oddLength }
        return out
    }

    public static func encode(_ bytes: [UInt8], uppercase: Bool = false) -> String {
        let digits: [Character] = uppercase
            ? Array("0123456789ABCDEF") : Array("0123456789abcdef")
        var s = ""; s.reserveCapacity(bytes.count * 2)
        for b in bytes { s.append(digits[Int(b >> 4)]); s.append(digits[Int(b & 0x0F)]) }
        return s
    }

    private static func val(_ u: Unicode.Scalar) -> UInt8? {
        switch u {
        case "0"..."9": return UInt8(u.value - 48)
        case "a"..."f": return UInt8(u.value - 87)
        case "A"..."F": return UInt8(u.value - 55)
        default: return nil
        }
    }
}

public enum ByteUtil {
    public static func dropFirst(_ b: [UInt8], _ n: Int) -> [UInt8] { Array(b.dropFirst(n)) }
    public static func dropLast(_ b: [UInt8], _ n: Int) -> [UInt8] { Array(b.dropLast(n)) }
    public static func u32be(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
    public static func u32le(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]
    }
    public static func u64le(_ v: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) }
    }
    public static func u64be(_ v: UInt64) -> [UInt8] {
        (0..<8).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) }
    }
    public static func readU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
    public static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var d: UInt8 = 0
        for i in 0..<a.count { d |= a[i] ^ b[i] }
        return d == 0
    }
}
