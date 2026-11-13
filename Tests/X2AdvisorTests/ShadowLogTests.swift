import XCTest
@testable import X2Advisor

final class ShadowLogTests: XCTestCase {

    private var dir: URL!
    private var file: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("shadow.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func record(_ d: Double, units: Double, hold: String? = nil) -> ShadowRecord {
        ShadowRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_000 + d),
                     bg: 180, trendCode: 5, iob: 1.0, carbsOnBoard: 0,
                     eventualBg: 130, suggestedUnits: units,
                     holdReason: hold, capped: false)
    }

    func testAppendAndReadBack() {
        let log = ShadowLog(fileURL: file)
        log.append(record(0, units: 1.0))
        log.append(record(300, units: 0, hold: "predictedInRange"))
        let all = log.readAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[1].holdReason, "predictedInRange")
        XCTAssertEqual(all[0].iob, 1.0, accuracy: 1e-9)
    }

    func testSurvivesCorruptedTailLine() throws {
        let log = ShadowLog(fileURL: file)
        log.append(record(0, units: 1.0))
        // 模拟写到一半被杀的残行
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"timestamp\":\"2024-".utf8))
        try handle.close()

        let all = log.readAll()
        XCTAssertEqual(all.count, 1, "坏行应被跳过而不是让整体读取失败")
    }

    func testReadAllReturnsEmptyForMissingFile() {
        XCTAssertTrue(ShadowLog(fileURL: dir.appendingPathComponent("nope.jsonl")).readAll().isEmpty)
        XCTAssertTrue(ShadowLog(fileURL: nil).readAll().isEmpty)
    }

    func testSummaryCountsHoldsAndUnits() {
        let log = ShadowLog(fileURL: file)
        log.append(record(0, units: 1.0))
        log.append(record(300, units: 0, hold: "fallingFast"))
        log.append(record(600, units: 0, hold: "fallingFast"))
        log.append(record(900, units: 0.5))
        let s = log.summarize()
        XCTAssertEqual(s.total, 4)
        XCTAssertEqual(s.correctCount, 2)
        XCTAssertEqual(s.totalSuggestedUnits, 1.5, accuracy: 1e-9)
        XCTAssertEqual(s.holdBreakdown["fallingFast"], 2)
        XCTAssertEqual(s.correctRate, 0.5, accuracy: 1e-9)
    }

    func testCSVHasHeaderAndOneRowPerRecord() {
        let log = ShadowLog(fileURL: file)
        log.append(record(0, units: 1.25))
        log.append(record(300, units: 0, hold: "iobTooHigh"))
        let lines = log.exportCSV().split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("timestamp,bg"))
        XCTAssertTrue(lines[1].contains(",1.25,,"))
        XCTAssertTrue(lines[2].contains("iobTooHigh"))
    }
}
