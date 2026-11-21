import XCTest
@testable import X2Advisor

final class TakeoverCheckTests: XCTestCase {

    private func healthyFacts() -> TakeoverCheck.Facts {
        var f = TakeoverCheck.Facts()
        f.linkReady = true
        f.controlIQEnabled = false
        f.pumpBasalRateNow = 0.30
        f.pumpBasalSetting = 0.30
        f.pumpBatteryPercent = 80
        f.reservoirUnits = 150
        f.pumpMaxBolusUnits = 10
        f.bolusEnabled = true
        f.bolusRiskAccepted = true
        f.cgmAgeMinutes = 3
        f.usingNightscout = false
        f.pumpHasCgm = true
        f.backgroundAudioEnabled = true
        f.pumpClockLooksValid = true
        return f
    }

    func testHealthySetupPassesWithNoBlockers() {
        let report = TakeoverCheck.evaluate(healthyFacts())
        XCTAssertTrue(report.blockers.isEmpty, report.firstBlockReason ?? "")
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertTrue(report.canProceed(warningsAcknowledged: false))
    }

    func testControlIQStillOnIsBlocker() {
        var f = healthyFacts()
        f.controlIQEnabled = true
        let report = TakeoverCheck.evaluate(f)
        XCTAssertEqual(report.blockers.map(\.id), ["ciq"])
        XCTAssertFalse(report.canProceed(warningsAcknowledged: true))
    }

    /// 读不到 Control-IQ 时按"可能在跑"处理：宁可拦住，也不赌
    func testUnknownControlIQIsBlocker() {
        var f = healthyFacts()
        f.controlIQEnabled = nil
        XCTAssertTrue(TakeoverCheck.evaluate(f).blockers.contains { $0.id == "ciq" })
    }

    /// App 填的基础率低于泵实际值 → 两份叠加，必须硬拦
    func testUnderFilledBasalIsBlocker() {
        var f = healthyFacts()
        f.pumpBasalRateNow = 0.80
        f.pumpBasalSetting = 0.30
        let report = TakeoverCheck.evaluate(f)
        XCTAssertTrue(report.blockers.contains { $0.id == "basal" })
        XCTAssertFalse(report.canProceed(warningsAcknowledged: true))
    }

    /// App 填得比实际高 → 只是少补（血糖会爬），给警告而不是硬拦
    func testOverFilledBasalIsWarning() {
        var f = healthyFacts()
        f.pumpBasalRateNow = 0.30
        f.pumpBasalSetting = 0.80
        let report = TakeoverCheck.evaluate(f)
        XCTAssertTrue(report.blockers.isEmpty)
        XCTAssertTrue(report.warnings.contains { $0.id == "basal" })
        XCTAssertFalse(report.canProceed(warningsAcknowledged: false))
        XCTAssertTrue(report.canProceed(warningsAcknowledged: true))
    }

    func testUnreadableBasalRateIsBlocker() {
        var f = healthyFacts()
        f.pumpBasalRateNow = nil
        XCTAssertTrue(TakeoverCheck.evaluate(f).blockers.contains { $0.id == "basal" })
    }

    /// 0 基础率不是禁止，但必须用户自己确认过一次
    func testZeroBasalIsWarningOnly() {
        var f = healthyFacts()
        f.pumpBasalRateNow = nil
        f.pumpBasalRateNow = 0
        f.pumpBasalSetting = 0
        let report = TakeoverCheck.evaluate(f)
        XCTAssertTrue(report.warnings.contains { $0.id == "floor" })
        XCTAssertTrue(report.canProceed(warningsAcknowledged: true))
    }

    func testStaleCgmIsBlocker() {
        var f = healthyFacts()
        f.cgmAgeMinutes = 20
        XCTAssertTrue(TakeoverCheck.evaluate(f).blockers.contains { $0.id == "cgm" })
    }

    func testMissingCgmIsBlocker() {
        var f = healthyFacts()
        f.cgmAgeMinutes = nil
        XCTAssertTrue(TakeoverCheck.evaluate(f).blockers.contains { $0.id == "cgm" })
    }

    /// 只有 App 这一路血糖是现状说明，不该挡自检，也不该要求逐条确认。
    func testNightscoutOnlyIsInfo() {
        var f = healthyFacts()
        f.usingNightscout = true
        f.pumpHasCgm = false
        let report = TakeoverCheck.evaluate(f)
        XCTAssertFalse(report.warnings.contains { $0.id == "singlecgm" })
        XCTAssertTrue(report.items.contains { $0.id == "singlecgm" && $0.severity == .info })
        XCTAssertTrue(report.canProceed(warningsAcknowledged: false))
    }

    func testPumpMaxBolusTooSmallIsBlocker() {
        var f = healthyFacts()
        f.pumpMaxBolusUnits = 0.10
        f.loopMaxSingleMicroBolus = 0.30
        XCTAssertTrue(TakeoverCheck.evaluate(f).blockers.contains { $0.id == "maxbolus" })
    }

    func testLowReservoirIsBlocker() {
        var f = healthyFacts()
        f.reservoirUnits = 2
        XCTAssertTrue(TakeoverCheck.evaluate(f).blockers.contains { $0.id == "reservoir" })
    }

    func testInvalidLoopSettingsIsBlocker() {
        var f = healthyFacts()
        f.loopSettingsInvalidReason = "单次上限小于最小步进"
        XCTAssertTrue(TakeoverCheck.evaluate(f).blockers.contains { $0.id == "settings" })
    }

    func testBolusChannelClosedIsBlocker() {
        var f = healthyFacts()
        f.bolusRiskAccepted = false
        XCTAssertTrue(TakeoverCheck.evaluate(f).blockers.contains { $0.id == "bolus" })
    }

    func testBackgroundKeepAliveOffIsWarning() {
        var f = healthyFacts()
        f.backgroundAudioEnabled = false
        let report = TakeoverCheck.evaluate(f)
        XCTAssertTrue(report.blockers.isEmpty)
        XCTAssertTrue(report.warnings.contains { $0.id == "audio" })
    }

    func testFirstBlockReasonPointsAtBlocker() {
        var f = healthyFacts()
        f.linkReady = false
        f.controlIQEnabled = true
        let report = TakeoverCheck.evaluate(f)
        XCTAssertEqual(report.firstBlockReason?.hasPrefix("泵链路已连接"), true)
    }
}
