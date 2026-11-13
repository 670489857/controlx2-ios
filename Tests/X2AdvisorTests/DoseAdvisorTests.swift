import XCTest
@testable import X2Advisor

final class DoseAdvisorTests: XCTestCase {

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(mgdl: Int, minutesAgo: Double = 2, trend: GlucoseTrend? = .flat) -> GlucoseSample {
        GlucoseSample(timestamp: now.addingTimeInterval(-minutesAgo * 60),
                      mgdl: mgdl, trendCode: trend?.rawValue)
    }

    private func advisor(_ mutate: (inout AdvisorSettings) -> Void = { _ in }) -> DoseAdvisor {
        var s = AdvisorSettings()
        mutate(&s)
        return DoseAdvisor(settings: s)
    }

    private func input(bg: GlucoseSample?, iob: Double = 0, cob: Double = 0,
                       lastBolusMinutesAgo: Double? = nil,
                       slope: Double? = nil) -> DoseAdvisor.Input {
        .init(now: now, latest: bg, iob: iob, carbsOnBoard: cob,
              lastBolusAt: lastBolusMinutesAgo.map { now.addingTimeInterval(-$0 * 60) },
              measuredSlope: slope)
    }

    // MARK: 安全闸门

    func testHoldsWithoutCGM() {
        XCTAssertEqual(advisor().advise(input(bg: nil)).holdReason, .cgmMissing)
    }

    func testHoldsWhenCGMStale() {
        let a = advisor()
        let advice = a.advise(input(bg: sample(mgdl: 250, minutesAgo: 30)))
        XCTAssertEqual(advice.holdReason, .cgmStale)
    }

    func testAcceptsSlightlyFutureTimestamp() {
        // 泵与手机的时钟可能有几十秒偏差，不应因此判定过期
        let a = advisor()
        let s = GlucoseSample(timestamp: now.addingTimeInterval(30), mgdl: 250, trendCode: 5)
        XCTAssertEqual(a.advise(input(bg: s)).holdReason, nil)
    }

    func testHoldsWhenGlucoseBelowCorrectionThreshold() {
        XCTAssertEqual(advisor().advise(input(bg: sample(mgdl: 115))).holdReason, .glucoseTooLow)
    }

    func testHoldsWhenFallingFast() {
        let advice = advisor().advise(input(bg: sample(mgdl: 220, trend: .down), slope: -1.5))
        XCTAssertEqual(advice.holdReason, .fallingFast)
    }

    func testMeasuredSlopeOverridesCoarseTrendCode() {
        // 趋势码说"平"，但实测斜率在跌；实测优先
        let advice = advisor().advise(input(bg: sample(mgdl: 220, trend: .flat), slope: -1.2))
        XCTAssertEqual(advice.holdReason, .fallingFast)
    }

    func testAllowsCorrectionWhileFallingWhenExplicitlyEnabled() {
        let a = advisor { $0.allowCorrectionWhileFalling = true }
        let advice = a.advise(input(bg: sample(mgdl: 260, trend: .down), slope: -1.5))
        XCTAssertEqual(advice.holdReason, nil, "开启后不应因下降而拒绝")
        XCTAssertGreaterThan(advice.suggestedUnits, 0)
    }

    func testHoldsWhenPredictedLow() {
        // 3 U 现存 × ISF 50 = 150 的降糖能力，从 150 出发稳态为 0
        let advice = advisor().advise(input(bg: sample(mgdl: 150), iob: 3.0))
        XCTAssertEqual(advice.holdReason, .predictedLow)
    }

    func testHoldsWhenIobAboveCap() {
        let advice = advisor().advise(input(bg: sample(mgdl: 300), iob: 4.0))
        XCTAssertEqual(advice.holdReason, .iobTooHigh)
    }

    func testHoldsWhenDoseTooRecent() {
        let advice = advisor().advise(input(bg: sample(mgdl: 300), lastBolusMinutesAgo: 10))
        XCTAssertEqual(advice.holdReason, .doseTooRecent)
    }

    func testAllowsAfterIntervalElapsed() {
        let advice = advisor().advise(input(bg: sample(mgdl: 300), lastBolusMinutesAgo: 60))
        XCTAssertEqual(advice.holdReason, nil)
    }

    func testHoldsWhenPredictedInRange() {
        // 140 − 0.6 × 50 = 110，正好等于目标，不需要动作
        let advice = advisor().advise(input(bg: sample(mgdl: 140), iob: 0.6))
        XCTAssertEqual(advice.holdReason, .predictedInRange)
    }

    func testHoldsWhenDoseBelowPumpStep() {
        let a = advisor { $0.targetBg = 119; $0.minBgToCorrect = 100 }
        let advice = a.advise(input(bg: sample(mgdl: 120)))
        // (120 − 119) / 50 = 0.02 U，小于 0.05 步进
        XCTAssertEqual(advice.holdReason, .doseTooSmall)
    }

    // MARK: 剂量计算

    func testComputesCorrectionDose() {
        // (200 − 110) / 50 = 1.8 U
        let advice = advisor().advise(input(bg: sample(mgdl: 200)))
        guard case let .correct(units, eventual, capped) = advice else {
            return XCTFail("应给出建议，实际 \(advice)")
        }
        XCTAssertEqual(units, 1.80, accuracy: 1e-9)
        XCTAssertEqual(eventual, 200, accuracy: 1e-9)
        XCTAssertFalse(capped)
    }

    func testDoseIsRoundedToPumpStep() {
        // (203 − 110) / 50 = 1.86 → 1.85
        let advice = advisor().advise(input(bg: sample(mgdl: 203)))
        guard case let .correct(units, _, _) = advice else { return XCTFail() }
        XCTAssertEqual(units, 1.85, accuracy: 1e-9)
    }

    func testDoseIsCappedAtSingleDoseLimit() {
        // (400 − 110) / 50 = 5.8 U → 截断到 2.0
        let advice = advisor().advise(input(bg: sample(mgdl: 400)))
        guard case let .correct(units, _, capped) = advice else { return XCTFail() }
        XCTAssertEqual(units, 2.0, accuracy: 1e-9)
        XCTAssertTrue(capped)
    }

    func testCarbsOnBoardIncreaseCorrectionDose() {
        // 待吸收碳水会推高稳态，需要更多胰岛素去覆盖。
        // 注意这条只在 IOB 未同步时成立：若餐前 bolus 已给，IOB 会同步上升，
        // 两项在 eventualBG 里相互抵消，这才是正常的一餐。
        let without = advisor().advise(input(bg: sample(mgdl: 150)))
        let with = advisor().advise(input(bg: sample(mgdl: 150), cob: 5))
        guard case let .correct(withoutUnits, _, _) = without,
              case let .correct(withUnits, _, _) = with else {
            return XCTFail("两者都应给出建议")
        }
        XCTAssertEqual(withoutUnits, 0.80, accuracy: 1e-9)
        XCTAssertEqual(withUnits, 1.30, accuracy: 1e-9)
    }

    func testCarbsCancelOutMatchedBolus() {
        // 餐前给了与碳水匹配的 bolus：COB 与 IOB 在 eventualBG 里相互抵消，
        // 建议剂量应回到"没吃也没给"时的值，而不是叠加两份
        let baseline = advisor().advise(input(bg: sample(mgdl: 150)))
        let matched = advisor().advise(input(bg: sample(mgdl: 150), iob: 3, cob: 30))
        XCTAssertEqual(baseline.suggestedUnits, matched.suggestedUnits, accuracy: 1e-9)
        XCTAssertEqual(matched.suggestedUnits, 0.80, accuracy: 1e-9)
    }

    func testHighIobSuppressesDose() {
        // 1.5 U 现存从 250 出发：(250 − 75 − 110) / 50 = 1.3
        let advice = advisor().advise(input(bg: sample(mgdl: 250), iob: 1.5))
        guard case let .correct(units, _, _) = advice else { return XCTFail() }
        XCTAssertEqual(units, 1.30, accuracy: 1e-9)
    }

    // MARK: 兜底

    func testSuggestedUnitsIsZeroForHold() {
        XCTAssertEqual(advisor().advise(input(bg: nil)).suggestedUnits, 0)
    }
}
