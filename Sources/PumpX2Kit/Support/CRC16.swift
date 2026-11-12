import Foundation

/// CRC-16/CCITT（多项式 0x1021，初值 0xFFFF，不反射，不做最终异或）。
/// 与 pumpX2 `Bytes.calculateCRC16` 逐位一致；结果以小端两字节追加在报文尾部。
public enum CRC16 {
    private static let table: [UInt16] = {
        (0...255).map { i -> UInt16 in
            var c = UInt16(i) << 8
            for _ in 0..<8 {
                c = (c & 0x8000) != 0 ? (c << 1) ^ 0x1021 : (c << 1)
            }
            return c
        }
    }()

    public static func compute(_ bytes: [UInt8], initial: UInt16 = 0xFFFF) -> UInt16 {
        var crc = initial
        for b in bytes {
            let idx = Int((crc >> 8) ^ UInt16(b)) & 0xFF
            crc = (crc << 8) ^ table[idx]
        }
        return crc
    }

    /// 小端两字节
    public static func checksum(_ bytes: [UInt8]) -> [UInt8] {
        let c = compute(bytes)
        return [UInt8(c & 0xFF), UInt8(c >> 8)]
    }
}
