import XCTest
@testable import PumpX2Kit

/// 0x85 报文的字段偏移来自 pumpX2 的 `PumpVersionBResponse.parse`。
/// 这里用一条自造的 cargo 把偏移钉住：改偏移而没改测试，会立刻红。
final class PumpVersionTests: XCTestCase {

    private func le(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    private func cargo(name: String, serial: UInt32, model: UInt32, rev: String,
                       extraLength: Int = 0) -> [UInt8] {
        var bytes: [UInt8] = []
        let nameBytes = Array(name.utf8)
        bytes += nameBytes + Array(repeating: 0, count: max(0, 20 - nameBytes.count))
        bytes += le(0x1111) + le(0x2222)          // configA / configB
        bytes += le(serial)
        bytes += le(model)
        let revBytes = Array(rev.utf8)
        bytes += revBytes + Array(repeating: 0, count: max(0, 8 - revBytes.count))
        bytes += le(0x3333) + le(0x4444)
        bytes += Array(repeating: 0, count: 8)     // pcbRevision
        if extraLength > 0 { bytes += Array(repeating: 0, count: extraLength) }
        return bytes
    }

    func testParsesKnownFields() {
        let c = cargo(name: "7.8.0", serial: 12345, model: 1000098, rev: "A1")
        let v = StatusDecoder.pumpVersionB(c)
        XCTAssertNotNil(v)
        XCTAssertEqual(v?.softwareName, "7.8.0")
        XCTAssertEqual(v?.serialNumber, 12345)
        XCTAssertEqual(v?.modelNumber, 1000098)
        XCTAssertEqual(v?.pumpRevision, "A1")
    }

    /// 定长字符串是 NUL 填充的，不能把尾部的 \0 带进界面
    func testTrimsNullPadding() {
        let c = cargo(name: "7.7", serial: 1, model: 2, rev: "")
        XCTAssertEqual(StatusDecoder.pumpVersionB(c)?.softwareName, "7.7")
        XCTAssertEqual(StatusDecoder.pumpVersionB(c)?.pumpRevision, "")
    }

    /// 长度不够时返回 nil，而不是按偏移硬解出半截数字
    func testShortCargoRejected() {
        XCTAssertNil(StatusDecoder.pumpVersionB(Array(repeating: 0, count: 40)))
    }
}
