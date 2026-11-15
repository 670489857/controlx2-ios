import XCTest
@testable import PumpX2Kit

final class ProtocolTraceTests: XCTestCase {

    func testKeepsOnlyRecentEntries() {
        let trace = ProtocolTrace(capacity: 5)
        for i in 0..<12 {
            trace.add(.note, "event \(i)")
        }
        let entries = trace.snapshot()
        XCTAssertEqual(entries.count, 5)
        // 留下的是最后 5 条，顺序不能反
        XCTAssertEqual(entries.map(\.text), ["event 7", "event 8", "event 9", "event 10", "event 11"])
    }

    func testPacketLineCarriesLengthAndHex() {
        let trace = ProtocolTrace()
        trace.addPacket(.tx, [0x00, 0x01, 0x10, 0xaa, 0xbb], note: "0x10 auth")
        let line = trace.dump()
        XCTAssertTrue(line.contains("5B"))
        XCTAssertTrue(line.contains("00 01 10 aa bb"))
        XCTAssertTrue(line.contains("[0x10 auth]"))
        XCTAssertTrue(line.contains("TX"))
    }

    func testClearDropsEverything() {
        let trace = ProtocolTrace()
        trace.add(.rx, "x")
        trace.clear()
        XCTAssertTrue(trace.dump().isEmpty)
    }

    /// 记录必须能区分方向，否则排障时看不出是没发出去还是没收到
    func testDirectionPrefixesDiffer() {
        let trace = ProtocolTrace()
        trace.add(.tx, "out")
        trace.add(.rx, "in")
        let lines = trace.dump().split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains(" TX "))
        XCTAssertTrue(lines[1].contains(" RX "))
    }
}
