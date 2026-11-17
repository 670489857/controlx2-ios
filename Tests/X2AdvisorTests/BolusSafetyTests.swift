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

    // MARK: 闸门可关闭（0 = 不限）

    /// 单次上限填 0 应当整条闸门关掉，而不是「上限 0 U，什么都超」。
    func testZeroSingleLimitDisablesGate() {
        var policy = BolusPolicy()
        policy.maxSingleUnits = 0
        let decision = BolusGuard.evaluate(context(units: 8.0, policy: policy))
        XCTAssertTrue(decision.allowed)
        XCTAssertTrue(decision.blocks.isEmpty)
    }

    /// 负数同理：手滑输进一个负号，不能让所有剂量都被判超限。
    func testNegativeSingleLimitTreatedAsUnlimited() {
        var policy = BolusPolicy()
        policy.maxSingleUnits = -1
        let decision = BolusGuard.evaluate(context(units: 2.0, policy: policy))
        XCTAssertTrue(decision.allowed)
    }

    func testZeroDailyLimitDisablesGate() {
        var policy = BolusPolicy()
        policy.max24hUnits = 0
        // 台账已记 20 U，再打 3 U，上限关掉后不该拦
        let decision = BolusGuard.evaluate(context(units: 3.0, delivered24h: 20.0, policy: policy))
        XCTAssertTrue(decision.allowed)
        XCTAssertTrue(decision.blocks.isEmpty)
        // 但累计本身仍然要报出来：关的是拦截，不是记录
        XCTAssertTrue(decision.warnings.contains { $0.contains("24 小时累计") })
    }

    func testZeroIntervalDisablesGate() {
        var policy = BolusPolicy()
        policy.minIntervalMinutes = 0
        let decision = BolusGuard.evaluate(context(units: 1.0, lastMinutesAgo: 1, policy: policy))
        XCTAssertTrue(decision.allowed, "上次是 1 分钟前，间隔要求关掉后应当放行")
    }

    func testLowGlucoseGateStillActiveWhenOthersDisabled() {
        // 只关这三条，低血糖与药筒不跟着关：这两条对应的是能看到的身体状态和余量
        var policy = BolusPolicy()
        policy.maxSingleUnits = 0
        policy.max24hUnits = 0
        policy.minIntervalMinutes = 0
        let decision = BolusGuard.evaluate(context(units: 1.0, reservoir: 10, glucose: 55, policy: policy))
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.blocks.map(\.reason), [.lowGlucose])
    }
}
