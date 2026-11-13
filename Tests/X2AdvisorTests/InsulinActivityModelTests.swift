import XCTest
@testable import X2Advisor

final class InsulinActivityModelTests: XCTestCase {

    let model = InsulinActivityModel(peakMinutes: 75, durationMinutes: 360)

    func testBoundaries() {
        XCTAssertEqual(model.remainingFraction(atMinutes: 0), 1, accuracy: 1e-12)
        XCTAssertEqual(model.remainingFraction(atMinutes: 360), 0, accuracy: 1e-12)
        XCTAssertEqual(model.remainingFraction(atMinutes: 10_000), 0, accuracy: 1e-12)
    }

    func testHalfConsumedAtPeak() {
        // 这是选 Walsh 而不是 Gamma 的唯一理由，必须钉死
        XCTAssertEqual(model.remainingFraction(atMinutes: 75), 0.5, accuracy: 1e-12)
    }

    func testNegativeTimeCountsAsNotYetActive() {
        XCTAssertEqual(model.remainingFraction(atMinutes: -30), 1)
    }

    func testMonotonicallyDecreasing() {
        var previous = 1.0
        for t in stride(from: 0.0, through: 400.0, by: 5.0) {
            let r = model.remainingFraction(atMinutes: t)
            XCTAssertLessThanOrEqual(r, previous + 1e-12, "t=\(t) 出现反弹")
            previous = r
        }
    }

    func testRiseHalfHasConstantSlope() {
        // 0→peak 是直线：等间隔采样的下降量应相等
        let d1 = model.remainingFraction(atMinutes: 0) - model.remainingFraction(atMinutes: 25)
        let d2 = model.remainingFraction(atMinutes: 25) - model.remainingFraction(atMinutes: 50)
        XCTAssertEqual(d1, d2, accuracy: 1e-12)
    }

    func testFractionConsumedIsAdditive() {
        let whole = model.fractionConsumed(fromMinutes: 0, toMinutes: 240)
        let part1 = model.fractionConsumed(fromMinutes: 0, toMinutes: 90)
        let part2 = model.fractionConsumed(fromMinutes: 90, toMinutes: 240)
        XCTAssertEqual(part1 + part2, whole, accuracy: 1e-12)
    }

    func testInvalidParametersFallBackTogether() {
        // peak ≥ duration 无意义，应整体回退，不能只保留 duration 造出负区间
        let bad = InsulinActivityModel(peakMinutes: 400, durationMinutes: 360)
        XCTAssertEqual(bad.peakMinutes, InsulinActivityModel.defaultPeak)
        XCTAssertEqual(bad.durationMinutes, InsulinActivityModel.defaultDuration)
        XCTAssertEqual(InsulinActivityModel(peakMinutes: 0).peakMinutes,
                       InsulinActivityModel.defaultPeak)
        XCTAssertEqual(InsulinActivityModel(peakMinutes: .nan).durationMinutes,
                       InsulinActivityModel.defaultDuration)
        XCTAssertEqual(InsulinActivityModel(peakMinutes: 10, durationMinutes: -5).peakMinutes,
                       InsulinActivityModel.defaultPeak)
    }

    func testActionDurationIsTheHorizon() {
        XCTAssertEqual(model.actionDurationMinutes, 360)
    }
}
