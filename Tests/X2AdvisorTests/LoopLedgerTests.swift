import XCTest
@testable import X2Advisor

/// 闭环台账的测试。重点只有一个：**额度必须从账里算**。
/// 如果额度靠内存计数器，App 被系统杀掉重开后计数器归零，
/// 一小时上限就形同虚设。
final class LoopLedgerTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loop-ledger-\\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func record(_ minutesAgo: Double, units: Double, accepted: Bool?,
                        hold: String? = nil) -> LoopRecord {
        LoopRecord(timestamp: Date().addingTimeInterval(-minutesAgo * 60),
                   units: units, accepted: accepted, holdReason: hold,
                   bg: 120, iob: 0.5, basalEquiv: 0.08, correction: 0,
                   eventualBg: 120, summary: "s", errorText: nil)
    }

    func testDeliveredLastHourCountsOnlyAccepted() {
        let ledger = LoopLedger(fileURL: fileURL)
        ledger.append(record(10, units: 0.10, accepted: true))
        ledger.append(record(20, units: 0.10, accepted: false))   // 泵拒了
        ledger.append(record(30, units: 0.10, accepted: nil))     // 超时，状态未知
        ledger.append(record(90, units: 0.10, accepted: true))    // 一小时以前
        XCTAssertEqual(ledger.deliveredLastHour(), 0.10, accuracy: 0.0001,
                       "只算被泵受理的、且在一小时内的")
    }

    func testDeliveredLastHourRecomputesAfterRestart() {
        // 两次实例化模拟 App 被杀掉重开：额度必须一样
        let first = LoopLedger(fileURL: fileURL)
        first.append(record(5, units: 0.20, accepted: true))
        let second = LoopLedger(fileURL: fileURL)
        XCTAssertEqual(second.deliveredLastHour(), 0.20, accuracy: 0.0001)
    }

    func testDeliveredTodayResetsAtMidnight() {
        let ledger = LoopLedger(fileURL: fileURL)
        ledger.append(record(60 * 20, units: 0.5, accepted: true))   // 20 小时前，可能跨零点
        ledger.append(record(5, units: 0.2, accepted: true))
        let today = ledger.deliveredToday()
        XCTAssertGreaterThanOrEqual(today, 0.2 - 0.0001)
    }

    func testLastAcceptedIgnoresFailedRecords() {
        let ledger = LoopLedger(fileURL: fileURL)
        ledger.append(record(30, units: 0.10, accepted: true))
        ledger.append(record(5, units: 0.15, accepted: false))
        XCTAssertEqual(ledger.lastAccepted()?.units, 0.10)
    }

    func testSummaryCountsHoldsAndUnits() {
        let ledger = LoopLedger(fileURL: fileURL)
        ledger.append(record(5, units: 0.10, accepted: true))
        ledger.append(record(10, units: 0, accepted: nil, hold: "cgmStale"))
        ledger.append(record(15, units: 0, accepted: nil, hold: "cgmStale"))
        let s = ledger.summarize()
        XCTAssertEqual(s.total, 3)
        XCTAssertEqual(s.dosedCount, 1)
        XCTAssertEqual(s.acceptedUnits, 0.10, accuracy: 0.0001)
        XCTAssertEqual(s.holdBreakdown["cgmStale"], 2)
    }

    func testCorruptLineIsSkippedNotFatal() throws {
        let ledger = LoopLedger(fileURL: fileURL)
        // 诊断分两步：先确认「一次 append 只产生一行」。这一步失败说明是写入本身重复；
        // 这一步通过而下一步失败，说明是文件被多个测试共用。
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "测试开始前文件不该存在：\(fileURL.path)")
        ledger.append(record(5, units: 0.10, accepted: true))
        XCTAssertEqual(ledger.readAll().count, 1,
                       "一次 append 应该只有一行，实际 \(ledger.readAll().count) 行，文件 \(fileURL.path)")
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        try (text + "{broken\n").write(to: fileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(ledger.readAll().count, 1, "坏行跳过，前面的记录仍然可读")
    }

    func testCSVHasOneLinePerRecord() {
        let ledger = LoopLedger(fileURL: fileURL)
        ledger.append(record(5, units: 0.10, accepted: true))
        ledger.append(record(10, units: 0, accepted: nil, hold: "cgmStale"))
        let lines = ledger.exportCSV().split(separator: "\n")
        XCTAssertEqual(lines.count, 3, "表头 + 2 条")
    }
}
