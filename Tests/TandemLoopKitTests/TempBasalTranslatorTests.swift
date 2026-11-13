import XCTest
@testable import TandemLoopKit

final class TempBasalTranslatorTests: XCTestCase {

    private func schedule(_ pairs: [(Int, Double)]) throws -> BasalSchedule {
        try BasalSchedule(segments: pairs.map { BasalSegment(startMinute: $0.0, rate: $0.1) })
    }

    /// 成人常见 profile：0–6 点 0.8，6–22 点 1.0，22–24 点 0.7
    private func adultSchedule() throws -> BasalSchedule {
        try schedule([(0, 0.8), (360, 1.0), (1320, 0.7)])
    }

    // MARK: 基本换算

    func testExactMultiple() throws {
        // base 1.0，请求 1.25 → 125%，无误差
        let s = try schedule([(0, 1.0)])
        let c = try TempBasalTranslator.translate(
            requestedRate: 1.25, duration: 1800, schedule: s, minuteOfDay: 600)
        XCTAssertEqual(c.percent, 125)
        XCTAssertEqual(c.effectiveRate, 1.25, accuracy: 1e-9)
        XCTAssertEqual(c.rateError, 0, accuracy: 1e-9)
        XCTAssertEqual(c.saturation, .none)
        XCTAssertFalse(c.truncatedAtSegmentBoundary)
    }

    func testRoundingIsReported() throws {
        // base 0.8，请求 1.05 → 131.25% → 131% → 1.048，少给 0.002
        let s = try schedule([(0, 0.8)])
        let c = try TempBasalTranslator.translate(
            requestedRate: 1.05, duration: 1800, schedule: s, minuteOfDay: 600)
        XCTAssertEqual(c.percent, 131)
        XCTAssertEqual(c.effectiveRate, 1.048, accuracy: 1e-9)
        XCTAssertEqual(c.rateError, -0.002, accuracy: 1e-9)
        XCTAssertEqual(c.saturation, .rounding)
        XCTAssertLessThan(abs(c.relativeError), 0.005)
    }

    func testZeroRateMapsToZeroPercent() throws {
        let s = try adultSchedule()
        let c = try TempBasalTranslator.translate(
            requestedRate: 0, duration: 1800, schedule: s, minuteOfDay: 600)
        XCTAssertEqual(c.percent, 0)
        XCTAssertEqual(c.effectiveRate, 0, accuracy: 1e-9)
    }

    func testScheduleSelectionFollowsTimeOfDay() throws {
        let s = try adultSchedule()
        // 05:00 用 0.8，08:00 用 1.0，23:00 用 0.7
        XCTAssertEqual(s.segment(atMinuteOfDay: 300).rate, 0.8)
        XCTAssertEqual(s.segment(atMinuteOfDay: 480).rate, 1.0)
        XCTAssertEqual(s.segment(atMinuteOfDay: 1380).rate, 0.7)
        // 23:00 请求 0.7 → 100%
        let c = try TempBasalTranslator.translate(
            requestedRate: 0.7, duration: 1800, schedule: s, minuteOfDay: 1380)
        XCTAssertEqual(c.percent, 100)
    }

    // MARK: 250% 上限——这是 Mobi 接 Loop 的真实约束

    func testLowProfileBaseCannotReachHighDemand() throws {
        // 儿童夜间 base 0.1，Loop 请求 0.3（300%）→ 泵最多 250% = 0.25
        let s = try schedule([(0, 0.1)])
        let c = try TempBasalTranslator.translate(
            requestedRate: 0.3, duration: 1800, schedule: s, minuteOfDay: 120)
        XCTAssertEqual(c.percent, 250)
        XCTAssertEqual(c.effectiveRate, 0.25, accuracy: 1e-9)
        XCTAssertEqual(c.rateError, -0.05, accuracy: 1e-9)
        XCTAssertEqual(c.saturation, .highLimit)
        // 少给 16.7%，必须让上层知道
        XCTAssertEqual(c.relativeError, -1.0 / 6.0, accuracy: 1e-9)
    }

    func testHighProfileBaseAlsoCapped() throws {
        // base 2.0，请求 6.0（300%）→ 上限 5.0
        let s = try schedule([(0, 2.0)])
        let c = try TempBasalTranslator.translate(
            requestedRate: 6.0, duration: 1800, schedule: s, minuteOfDay: 600)
        XCTAssertEqual(c.percent, 250)
        XCTAssertEqual(c.effectiveRate, 5.0, accuracy: 1e-9)
        XCTAssertEqual(c.saturation, .highLimit)
    }

    func testExactlyAtCapIsNotFlaggedAsSaturated() throws {
        // base 2.0，请求 5.0 = 250%，刚好触及上限但无偏差
        let s = try schedule([(0, 2.0)])
        let c = try TempBasalTranslator.translate(
            requestedRate: 5.0, duration: 1800, schedule: s, minuteOfDay: 600)
        XCTAssertEqual(c.percent, 250)
        XCTAssertEqual(c.effectiveRate, 5.0, accuracy: 1e-9)
        XCTAssertEqual(c.saturation, .none)
    }

    func testMaximumDeliverableRateIsTwoAndHalfTimesBase() throws {
        let s = try adultSchedule()   // 08:00 段 base 1.0
        let c = try TempBasalTranslator.translate(
            requestedRate: 2.5, duration: 1800, schedule: s, minuteOfDay: 480)
        XCTAssertEqual(c.percent, 250)
        XCTAssertEqual(c.effectiveRate, 2.5, accuracy: 1e-9)
        XCTAssertEqual(c.saturation, .none)
    }

    // MARK: 失败路径

    func testZeroProfileBaseIsUnsupported() throws {
        let s = try schedule([(0, 0.0), (360, 1.0)])
        XCTAssertThrowsError(try TempBasalTranslator.translate(
            requestedRate: 0.5, duration: 1800, schedule: s, minuteOfDay: 120)
        ) { XCTAssertEqual($0 as? TempBasalTranslationError, .zeroProfileBasalRate) }
    }

    func testDurationBelowPumpMinimum() throws {
        let s = try adultSchedule()
        XCTAssertThrowsError(try TempBasalTranslator.translate(
            requestedRate: 1.0, duration: 600, schedule: s, minuteOfDay: 600)
        ) { XCTAssertEqual($0 as? TempBasalTranslationError, .durationOutOfRange) }
    }

    func testDurationAbovePumpMaximum() throws {
        let s = try adultSchedule()
        XCTAssertThrowsError(try TempBasalTranslator.translate(
            requestedRate: 1.0, duration: 73 * 3600, schedule: s, minuteOfDay: 600)
        ) { XCTAssertEqual($0 as? TempBasalTranslationError, .durationOutOfRange) }
    }

    func testNegativeRateRejected() throws {
        let s = try adultSchedule()
        XCTAssertThrowsError(try TempBasalTranslator.translate(
            requestedRate: -0.1, duration: 1800, schedule: s, minuteOfDay: 600)
        ) { XCTAssertEqual($0 as? TempBasalTranslationError, .invalidRequestedRate) }
    }

    func testScheduleValidation() throws {
        XCTAssertThrowsError(try schedule([])) {
            XCTAssertEqual($0 as? TempBasalTranslationError, .emptySchedule)
        }
        XCTAssertThrowsError(try schedule([(60, 1.0)])) {
            XCTAssertEqual($0 as? TempBasalTranslationError, .scheduleMustStartAtMidnight)
        }
        XCTAssertThrowsError(try schedule([(0, 1.0), (0, 2.0)])) {
            XCTAssertEqual($0 as? TempBasalTranslationError, .duplicateSegmentStart)
        }
        XCTAssertThrowsError(try schedule([(0, -1.0)])) {
            XCTAssertEqual($0 as? TempBasalTranslationError, .invalidSegmentRate)
        }
    }

    // MARK: 段边界截断

    func testDurationTruncatedAtSegmentBoundary() throws {
        // 05:50 请求 30 分钟，06:00 是段边界 → 距边界 10 分钟，不足 15 分钟下限
        let s = try adultSchedule()
        let c = try TempBasalTranslator.translate(
            requestedRate: 1.2, duration: 1800, schedule: s, minuteOfDay: 350)
        XCTAssertTrue(c.truncatedAtSegmentBoundary)
        // 距边界 10 分钟 < 15 分钟下限，只能按 30 分钟下发，跨段不精确
        XCTAssertEqual(c.duration, 1800, accuracy: 0.5)
        XCTAssertEqual(c.percent, 150)   // 按 0.8 段计算
    }

    func testDurationTruncatedWhenBoundaryAllows() throws {
        // 05:30 请求 60 分钟，距 06:00 有 30 分钟 → 截到 30 分钟
        let s = try adultSchedule()
        let c = try TempBasalTranslator.translate(
            requestedRate: 0.4, duration: 3600, schedule: s, minuteOfDay: 330)
        XCTAssertTrue(c.truncatedAtSegmentBoundary)
        XCTAssertEqual(c.duration, 1800, accuracy: 0.5)
        XCTAssertEqual(c.percent, 50)    // 0.4 / 0.8
        XCTAssertEqual(c.effectiveRate, 0.4, accuracy: 1e-9)
    }

    func testNoTruncationWellInsideSegment() throws {
        let s = try adultSchedule()
        let c = try TempBasalTranslator.translate(
            requestedRate: 0.9, duration: 1800, schedule: s, minuteOfDay: 720)
        XCTAssertFalse(c.truncatedAtSegmentBoundary)
        XCTAssertEqual(c.duration, 1800, accuracy: 0.5)
    }

    func testLastSegmentBoundaryRollsToMidnight() throws {
        // 23:50，下一个边界是次日 00:00，距 10 分钟
        let s = try adultSchedule()
        XCTAssertEqual(s.minutesUntilNextBoundary(afterMinuteOfDay: 1430), 10)
        // 00:00 本身距下一边界 360 分钟
        XCTAssertEqual(s.minutesUntilNextBoundary(afterMinuteOfDay: 0), 360)
    }

    func testMinuteOfDayWrapsCorrectly() throws {
        let s = try adultSchedule()
        XCTAssertEqual(s.segment(atMinuteOfDay: 1440).rate, 0.8)   // 次日零点
        XCTAssertEqual(s.segment(atMinuteOfDay: -60).rate, 0.7)    // 前一天 23:00
    }

    // MARK: 与 Loop 实际调用方式的对照

    func testTypicalLoopCycle() throws {
        // Loop 每 5 分钟一轮，下发 30 分钟 temp basal。
        // 这里检查在常见 profile 下，Loop 想要的速率都能在 1% 误差内执行。
        let s = try adultSchedule()
        let requests: [Double] = [0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.2, 1.5, 2.0, 2.4]
        for r in requests {
            let c = try TempBasalTranslator.translate(
                requestedRate: r, duration: 1800, schedule: s, minuteOfDay: 600)
            XCTAssertEqual(c.saturation, .none, "请求 \(r) 不应触及上限")
            XCTAssertEqual(c.effectiveRate, r, accuracy: 0.005, "请求 \(r) 的换算偏差过大")
        }
    }
}
