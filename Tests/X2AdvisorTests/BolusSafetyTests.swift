import XCTest
@testable import X2Advisor

/// 剂量闸门与台账。
///
/// 这些用例的立场是「宁可拦住」：每条闸门都单独造一个刚越界的数据，
/// 确认它拦得住，而不是只测全通过那一条。
final class BolusSafetyTests: XCTestCase {

    private let base = Date(timeIntervalSinceReferenceDate: 0)

    private func context(units: Double,
                         reservoir: Double? = 20,
                         glucose: Int? = 150,
                         iob: Double? = 1,
                         delivered24h: Double = 0,
                         lastMinutesAgo: Double? = nil,
                         policy: BolusPolicy = BolusPolicy()) -> BolusContext {
        BolusContext(requestedUnits: units,
                     now: base,
                     policy: policy,
                     lastBolusAt: lastMinutesAgo.map { base.addingTimeInterval(-$0 * 60) },
                     delivered24h: delivered24h,
                     reservoirUnits: reservoir,
                     glucoseMgdl: glucose,
                     iobUnits: iob)
    }

    func testAllGatesPass() {
        let d = BolusGuard.evaluate(context(units: 1.0))
        XCTAssertTrue(d.allowed)
        XCTAssertEqual(d.units, 1.0)
        XCTAssertTrue(d.blocks.isEmpty)
    }

    func testRoundsDownToStep() {
        let d = BolusGuard.evaluate(context(units: 1.07))
        XCTAssertEqual(d.units, 1.05)
        XCTAssertTrue(d.allowed)
    }

    func testDoseBelowStepBlocked() {
        let d = BolusGuard.evaluate(context(units: 0.04))
        XCTAssertFalse(d.allowed)
        XCTAssertEqual(d.primaryBlock?.reason, .doseTooSmall)
    }

    func testOverSingleLimitBlocked() {
        let d = BolusGuard.evaluate(context(units: 6.0))
        XCTAssertFalse(d.allowed)
        XCTAssertEqual(d.primaryBlock?.reason, .aboveSingleLimit)
        XCTAssertTrue(d.primaryBlock?.detail.contains("6.00") == true)
    }

    func testCustomSingleLimitApplies() {
        var p = BolusPolicy()
        p.maxSingleUnits = 1.0
        let d = BolusGuard.evaluate(context(units: 1.2, policy: p))
        XCTAssertFalse(d.allowed)
        XCTAssertEqual(d.primaryBlock?.reason, .aboveSingleLimit)
    }

    func testDailyTotalBlocked() {
        let d = BolusGuard.evaluate(context(units: 1.0, delivered24h: 11.5))
        XCTAssertFalse(d.allowed)
        XCTAssertEqual(d.primaryBlock?.reason, .aboveDailyLimit)
    }

    func testTooSoonBlocked() {
        let d = BolusGuard.evaluate(context(units: 0.5, lastMinutesAgo: 20))
        XCTAssertFalse(d.allowed)
        XCTAssertEqual(d.primaryBlock?.reason, .tooSoon)
    }

    func testIntervalJustOverThresholdPasses() {
        let d = BolusGuard.evaluate(context(units: 0.5, lastMinutesAgo: 61))
        XCTAssertTrue(d.allowed)
    }

    func testLowGlucoseBlocked() {
        let d = BolusGuard.evaluate(context(units: 0.5, glucose: 70))
        XCTAssertFalse(d.allowed)
        XCTAssertEqual(d.primaryBlock?.reason, .lowGlucose)
    }

    func testReservoirTooLowBlocked() {
        let d = BolusGuard.evaluate(context(units: 1.0, reservoir: 1.0))
        XCTAssertFalse(d.allowed)
        XCTAssertEqual(d.primaryBlock?.reason, .reservoirLow)
    }

    func testMissingReservoirBlockedInsteadOfAssumed() {
        let d = BolusGuard.evaluate(context(units: 1.0, reservoir: nil))
        XCTAssertFalse(d.allowed)
        XCTAssertEqual(d.primaryBlock?.reason, .reservoirUnknown)
    }

    func testHighIobOnlyWarns() {
        let d = BolusGuard.evaluate(context(units: 1.0, iob: 6.0))
        XCTAssertTrue(d.allowed, "IOB 是推断值，不该直接拦死")
        XCTAssertTrue(d.warnings.contains { $0.contains("偏高") })
    }

    func testMissingGlucoseOnlyWarns() {
        let d = BolusGuard.evaluate(context(units: 1.0, glucose: nil))
        XCTAssertTrue(d.allowed)
        XCTAssertTrue(d.warnings.contains { $0.contains("没有血糖读数") })
    }

    func testRoundingIsStableAtExactSteps() {
        XCTAssertEqual(BolusGuard.roundDown(0.05), 0.05)
        XCTAssertEqual(BolusGuard.roundDown(1.00), 1.00)
        XCTAssertEqual(BolusGuard.roundDown(2.50), 2.50)
        XCTAssertEqual(BolusGuard.roundDown(0.049), 0)
    }

    // MARK: 台账

    func testLedgerSumsWithinWindow() {
        var ledger = BolusLedger()
        ledger.append(units: 1.0, at: base.addingTimeInterval(-3 * 3600))
        ledger.append(units: 2.5, at: base.addingTimeInterval(-1 * 3600))
        ledger.append(units: 0.5, at: base.addingTimeInterval(-30))
        XCTAssertEqual(ledger.delivered(now: base), 4.0)
        XCTAssertEqual(ledger.last(now: base)?.units, 0.5)
    }

    func testLedgerPrunesOlderThanWindow() {
        var ledger = BolusLedger()
        ledger.append(units: 3.0, at: base.addingTimeInterval(-30 * 3600))
        ledger.append(units: 1.0, at: base.addingTimeInterval(-2 * 3600))
        ledger.prune(now: base)
        XCTAssertEqual(ledger.records.count, 1)
        XCTAssertEqual(ledger.delivered(now: base), 1.0)
    }

    func testLedgerIgnoresFutureRecords() {
        var ledger = BolusLedger()
        ledger.append(units: 1.0, at: base.addingTimeInterval(3600))
        XCTAssertEqual(ledger.delivered(now: base), 0)
        XCTAssertNil(ledger.last(now: base))
    }

    func testLedgerJsonRoundTrip() {
        var ledger = BolusLedger()
        ledger.append(units: 1.5, at: base.addingTimeInterval(-600))
        let decoded = BolusLedger.decode(ledger.jsonData())
        XCTAssertEqual(decoded.records.count, 1)
        XCTAssertEqual(decoded.records[0].units, 1.5)
    }

    func testLedgerDecodeGarbageFallsBackToEmpty() {
        let decoded = BolusLedger.decode(Data("not json".utf8))
        XCTAssertTrue(decoded.records.isEmpty)
        XCTAssertTrue(BolusLedger.decode(nil).records.isEmpty)
    }
}
