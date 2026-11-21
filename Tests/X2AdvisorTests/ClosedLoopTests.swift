import XCTest
@testable import X2Advisor

/// 闭环决策核的测试。
///
/// 重点不是"算得准不准"，而是**每一条拦截都真的会拦**。算法把剂量算对只是及格线；
/// 血糖已经 60 了还因为别的原因放行，才是要命的那种错。所以每条 hold 都单独一个用例，
/// 且都构造在"其他条件全部正常"的前提下，确保拦下它的是那个闸门本身。
final class ClosedLoopTests: XCTestCase {

    private var settings = ClosedLoop.Settings()

    /// 一切正常的基线输入：血糖 120、5 分钟前读数、IOB 0.5、计划基础率 1 U/h
    private func healthyInputs() -> ClosedLoop.Inputs {
        ClosedLoop.Inputs(cgmMgdl: 120,
                          cgmAgeMinutes: 5,
                          iobUnits: 0.5,
                          basalProfileUnitsPerHour: 1.0,
                          deliveredLastHourUnits: 0.3,
                          eventualBg: 120,
                          minutesToLow: nil,
                          trendPerMinute: 0,
                          controlIQEnabled: false,
                          carriedUnits: 0,
                          pumpBusy: false)
    }

    // MARK: 闸门

    func testControlIQOnAlwaysHolds() {
        var inputs = healthyInputs()
        inputs.controlIQEnabled = true
        inputs.eventualBg = 300          // 即便血糖很高也不许出针：双控制器会叠加
        let d = ClosedLoop.decide(settings, inputs)
        XCTAssertEqual(d.hold, .controlIQOn)
        XCTAssertEqual(d.units, 0)
    }

    func testControlIQUnknownHolds() {
        // 没读到 Control-IQ 状态时按"可能开着"处理：宁可停一拍，
        // 也不要在泵自己调基础率时叠一针上去
        var inputs = healthyInputs()
        inputs.controlIQEnabled = nil
        let d = ClosedLoop.decide(settings, inputs)
        XCTAssertEqual(d.hold, .controlIQUnknown)
        XCTAssertEqual(d.units, 0)
    }

    func testMissingCGMHolds() {
        var inputs = healthyInputs()
        inputs.cgmMgdl = nil
        XCTAssertEqual(ClosedLoop.decide(settings, inputs).hold, .cgmMissing)
    }

    func testStaleCGMHolds() {
        var inputs = healthyInputs()
        inputs.cgmAgeMinutes = 20
        XCTAssertEqual(ClosedLoop.decide(settings, inputs).hold, .cgmStale)
    }

    func testLowGlucoseHolds() {
        var inputs = healthyInputs()
        inputs.cgmMgdl = 65
        XCTAssertEqual(ClosedLoop.decide(settings, inputs).hold, .glucoseLow)
    }

    func testPredictedLowHolds() {
        var inputs = healthyInputs()
        inputs.minutesToLow = 20
        XCTAssertEqual(ClosedLoop.decide(settings, inputs).hold, .predictedLow)
    }

    func testPredictedLowOutsideWindowDoesNotHold() {
        var inputs = healthyInputs()
        inputs.minutesToLow = 45
        XCTAssertNil(ClosedLoop.decide(settings, inputs).hold)
    }

    func testFallingFastHolds() {
        var inputs = healthyInputs()
        inputs.trendPerMinute = -2.5
        XCTAssertEqual(ClosedLoop.decide(settings, inputs).hold, .fallingFast)
    }

    func testIobAtCapHolds() {
        var inputs = healthyInputs()
        inputs.iobUnits = 4.2
        XCTAssertEqual(ClosedLoop.decide(settings, inputs).hold, .iobAtCap)
    }

    func testHourlyCapHolds() {
        var inputs = healthyInputs()
        inputs.deliveredLastHourUnits = 1.6
        XCTAssertEqual(ClosedLoop.decide(settings, inputs).hold, .hourlyCap)
    }

    func testNoBasalProfileHolds() {
        var inputs = healthyInputs()
        inputs.basalProfileUnitsPerHour = nil
        XCTAssertEqual(ClosedLoop.decide(settings, inputs).hold, .noBasalProfile)
    }

    func testPumpBusyHolds() {
        var inputs = healthyInputs()
        inputs.pumpBusy = true
        XCTAssertEqual(ClosedLoop.decide(settings, inputs).hold, .pumpBusy)
    }

    // MARK: 剂量换算

    func testBasalEquivPerFiveMinutes() {
        // 1 U/h → 每 5 分钟 0.0833 U → 向下取整到 0.05，剩 0.0333 留到下一拍
        let d = ClosedLoop.decide(settings, healthyInputs())
        XCTAssertEqual(d.basalEquiv, 1.0 * 300 / 3600, accuracy: 0.0001)
        XCTAssertEqual(d.units, 0.05, accuracy: 0.0001)
        XCTAssertEqual(d.carriedOut, 0.0333, accuracy: 0.002)
        XCTAssertNil(d.hold)
    }

    func testCarriedUnitsAccumulate() {
        var inputs = healthyInputs()
        inputs.carriedUnits = 0.02
        let d = ClosedLoop.decide(settings, inputs)
        // 0.02 + 0.0833 = 0.1033 → 0.10，剩 0.0033
        XCTAssertEqual(d.units, 0.10, accuracy: 0.0001)
        XCTAssertEqual(d.carriedOut, 0.0033, accuracy: 0.002)
    }

    func testFloorNeverRoundsUp() {
        var inputs = healthyInputs()
        inputs.carriedUnits = 0.049      // 差一点点才够一步
        let d = ClosedLoop.decide(settings, inputs)
        XCTAssertEqual(d.basalEquiv, 0.0833, accuracy: 0.001)
        // 0.049 + 0.0833 = 0.1323 → 0.10；不能因为"差不多"就给 0.15
        XCTAssertEqual(d.units, 0.10, accuracy: 0.0001)
    }

    func testSmallAmountBelowStepIsCarried() {
        var inputs = healthyInputs()
        inputs.basalProfileUnitsPerHour = 0.3   // 每 5 分钟 0.025 U
        let d = ClosedLoop.decide(settings, inputs)
        XCTAssertEqual(d.hold, .doseBelowStep)
        XCTAssertEqual(d.units, 0)
    }

    func testHighGlucoseAddsCorrection() {
        var inputs = healthyInputs()
        inputs.cgmMgdl = 200
        inputs.eventualBg = 200          // (200-130)/50 = 1.4 U，被单次上限 0.30 截断
        let d = ClosedLoop.decide(settings, inputs)
        XCTAssertEqual(d.correction, 0.30, accuracy: 0.0001)
        XCTAssertEqual(d.units, 0.30, accuracy: 0.0001, "单次上限生效，不会把 1.4 U 分一次打出去")
    }

    func testCorrectionCappedByBasalMultiple() {
        var inputs = healthyInputs()
        inputs.basalProfileUnitsPerHour = 0.2   // 每段 0.0167 U，×4 = 0.0667
        inputs.cgmMgdl = 250
        inputs.eventualBg = 250
        let d = ClosedLoop.decide(settings, inputs)
        XCTAssertEqual(d.correction, 0.0667, accuracy: 0.002, "基础率很小时追加也要跟着小")
    }

    func testEventualBelowTargetSuppressesBasal() {
        var inputs = healthyInputs()
        inputs.cgmMgdl = 100
        inputs.eventualBg = 85           // 预测会往目标以下走
        let d = ClosedLoop.decide(settings, inputs)
        XCTAssertEqual(d.basalEquiv, 0.0833, accuracy: 0.001, "算出来的基础段要照实记录")
        XCTAssertEqual(d.units, 0, "但这一拍不打——只能减到 0，不能减成负的")
        XCTAssertEqual(d.hold, .doseBelowStep)
    }

    func testIobHeadroomLimitsDose() {
        var inputs = healthyInputs()
        inputs.iobUnits = 3.9            // 上限 4.0，只剩 0.1 的空间
        inputs.cgmMgdl = 220
        inputs.eventualBg = 220
        let d = ClosedLoop.decide(settings, inputs)
        XCTAssertLessThanOrEqual(d.units, 0.1 + 0.001)
    }

    // MARK: 参数校验

    func testSettingsRejectBadISF() {
        var s = ClosedLoop.Settings()
        s.isf = 0
        XCTAssertNotNil(s.invalidReason)
    }

    func testSettingsRejectInvertedTargets() {
        var s = ClosedLoop.Settings()
        s.targetHigh = s.targetLow - 10
        XCTAssertNotNil(s.invalidReason)
    }

    func testSettingsRejectHourlyBelowSingle() {
        var s = ClosedLoop.Settings()
        s.maxHourlyMicroBolus = 0.2
        s.maxSingleMicroBolus = 0.3
        XCTAssertNotNil(s.invalidReason)
    }

    func testDefaultSettingsAreValid() {
        XCTAssertNil(ClosedLoop.Settings().invalidReason)
    }

    // MARK: 接管模式（泵自己也在跑基础率）

    /// 泵在跑 1 U/h 的计划基础率时，App 不该再补一份基础率——否则两份叠加
    func testPumpBasalIsSubtractedFromRequiredBasal() {
        settings.pumpBasalUnitsPerHour = 1.0          // 泵自己跑满 1 U/h
        var inputs = healthyInputs()                   // 计划基础率 1 U/h，血糖 120（目标内）
        inputs.eventualBg = 120
        let d = ClosedLoop.decide(settings, inputs)
        XCTAssertEqual(d.basalEquiv, 0, accuracy: 1e-9, "泵已在跑满，净补应为 0")
        XCTAssertEqual(d.units, 0)
    }

    /// 泵只留 0.3 U/h 的安全下限，App 补剩下的 0.7 U/h → 5 分钟 = 0.058 U
    func testPumpSafetyFloorLeavesTopUpForApp() {
        settings.pumpBasalUnitsPerHour = 0.3
        let d = ClosedLoop.decide(settings, healthyInputs())
        XCTAssertEqual(d.basalEquiv, 0.7 / 12, accuracy: 1e-9)
        XCTAssertEqual(d.units, 0.05, accuracy: 1e-9, "0.058 U 向下取整到 0.05 的步进")
    }

    /// 净补被扣光时，高血糖追加仍然按「计划」算倍数上限，不会被压成 0
    func testCorrectionCapUsesPlanNotNetBasal() {
        settings.pumpBasalUnitsPerHour = 0.95
        var inputs = healthyInputs()
        inputs.cgmMgdl = 250
        inputs.eventualBg = 260
        let d = ClosedLoop.decide(settings, inputs)
        XCTAssertGreaterThan(d.correction, 0, "净补很小不代表不能纠正高血糖")
        XCTAssertGreaterThan(d.units, 0)
    }

    // MARK: 24h 上限

    func testDailyCapHolds() {
        settings.maxDailyUnits = 10
        var inputs = healthyInputs()
        inputs.deliveredTodayUnits = 10
        let d = ClosedLoop.decide(settings, inputs)
        XCTAssertEqual(d.hold, .dailyCap)
        XCTAssertEqual(d.units, 0)
    }

    func testDailyCapZeroMeansUnlimited() {
        settings.maxDailyUnits = 0
        var inputs = healthyInputs()
        inputs.deliveredTodayUnits = 99
        let d = ClosedLoop.decide(settings, inputs)
        XCTAssertEqual(d.hold, nil, "0 表示不限，不该拦")
    }

    func testDailyCapBelowHourlyIsInvalid() {
        settings.maxDailyUnits = 0.5      // 小于每小时上限 1.5
        XCTAssertNotNil(settings.invalidReason)
    }

    /// 把「单拍追加上限倍数」调大之后，一针确实能到 0.5 U。
    /// 这条测试存在的意义：不动倍数上限时，单把单针上限改成 0.5 是没用的。
    func testCorrectionMultipleUnlocksLargerSingleDose() {
        var settings = ClosedLoop.Settings()
        settings.maxSingleMicroBolus = 0.5
        settings.maxHourlyMicroBolus = 5
        settings.maxIobUnits = 8
        settings.maxCorrectionMultipleOfBasal = 20

        var inputs = ClosedLoop.Inputs()
        inputs.controlIQEnabled = false
        inputs.cgmMgdl = 250
        inputs.cgmAgeMinutes = 3
        inputs.iobUnits = 0
        inputs.basalProfileUnitsPerHour = 0.3
        inputs.trendPerMinute = 0
        inputs.eventualBg = 250
        inputs.deliveredLastHourUnits = 0

        let decision = ClosedLoop.decide(settings, inputs)
        XCTAssertEqual(decision.units, 0.5)
    }

    /// 同样参数但倍数还是默认 4：一针被压到 0.1 U 左右
    func testDefaultMultipleCapsDoseRegardlessOfSingleCap() {
        var settings = ClosedLoop.Settings()
        settings.maxSingleMicroBolus = 0.5
        settings.maxHourlyMicroBolus = 5
        settings.maxCorrectionMultipleOfBasal = 4

        var inputs = ClosedLoop.Inputs()
        inputs.controlIQEnabled = false
        inputs.cgmMgdl = 250
        inputs.cgmAgeMinutes = 3
        inputs.basalProfileUnitsPerHour = 0.3
        inputs.trendPerMinute = 0
        inputs.eventualBg = 250

        let decision = ClosedLoop.decide(settings, inputs)
        XCTAssertLessThanOrEqual(decision.units, 0.15)
    }

    func testCorrectionMultipleOutOfRangeIsInvalid() {
        var settings = ClosedLoop.Settings()
        settings.maxCorrectionMultipleOfBasal = 60
        XCTAssertNotNil(settings.invalidReason)
        settings.maxCorrectionMultipleOfBasal = 0.5
        XCTAssertNotNil(settings.invalidReason)
        settings.maxCorrectionMultipleOfBasal = 20
        XCTAssertNil(settings.invalidReason)
    }

    /// 药筒见底时不发针：泵会 Nack，先给出「去换药筒」而不是每拍失败一次
    func testReservoirLowHoldsWithoutTrying() {
        var settings = ClosedLoop.Settings()
        var inputs = ClosedLoop.Inputs()
        inputs.controlIQEnabled = false
        inputs.cgmMgdl = 200
        inputs.cgmAgeMinutes = 2
        inputs.basalProfileUnitsPerHour = 0.5
        inputs.eventualBg = 200
        inputs.reservoirUnits = 3

        let decision = ClosedLoop.decide(settings, inputs)
        XCTAssertEqual(decision.hold, .reservoirLow)
        XCTAssertEqual(decision.units, 0)
    }

    func testReservoirUnknownDoesNotBlock() {
        var inputs = ClosedLoop.Inputs()
        inputs.controlIQEnabled = false
        inputs.cgmMgdl = 200
        inputs.cgmAgeMinutes = 2
        inputs.basalProfileUnitsPerHour = 0.6
        inputs.eventualBg = 200

        let decision = ClosedLoop.decide(ClosedLoop.Settings(), inputs)
        XCTAssertNotEqual(decision.hold, .reservoirLow)
    }
}

extension ClosedLoopTests {
    /// 老配置（缺 maxCorrectionMultipleOfBasal 这些后加的键）要能解出来，不能整条丢回默认。
    func testLegacyJSONKeepsValues() throws {
        let legacy = """
        {"targetLow":100,"targetHigh":130,"isf":45,"insulinDurationMinutes":300,
         "maxSingleMicroBolus":0.5,"maxHourlyMicroBolus":5,"maxIobUnits":8,
         "lowSuspendThreshold":80,"predictedLowWindowMinutes":30,"maxFallingRate":2,
         "maxCgmAgeMinutes":12,"tickSeconds":300,"minStepUnits":0.05}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(ClosedLoop.Settings.self, from: legacy)

        XCTAssertEqual(s.targetLow, 100)
        XCTAssertEqual(s.maxSingleMicroBolus, 0.5)
        XCTAssertEqual(s.maxHourlyMicroBolus, 5)
        XCTAssertEqual(s.maxIobUnits, 8)
        // 缺的键回落到默认，而不是让整条解码失败
        XCTAssertEqual(s.maxCorrectionMultipleOfBasal, 4.0)
        XCTAssertEqual(s.pumpBasalUnitsPerHour, 0)
    }

    func testNewFieldsRoundTrip() throws {
        var s = ClosedLoop.Settings()
        s.maxCorrectionMultipleOfBasal = 12
        s.pumpBasalUnitsPerHour = 0.25
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(ClosedLoop.Settings.self, from: data)
        XCTAssertEqual(back.maxCorrectionMultipleOfBasal, 12)
        XCTAssertEqual(back.pumpBasalUnitsPerHour, 0.25)
    }
}
