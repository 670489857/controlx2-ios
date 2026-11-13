import XCTest
@testable import X2Advisor

final class BGPPredictorTests: XCTestCase {

    let predictor = BGPPredictor()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func input(bg: Double = 150, iob: Double = 0, cob: Double = 0,
                       isf: Double = 50, cr: Double = 10,
                       horizon: Int = 240) -> BGPPredictor.Input {
        .init(currentBg: bg, now: now, iob: iob, isf: isf,
              carbsOnBoard: cob, carbRatio: cr, horizonMinutes: horizon)
    }

    func testNoInsulinNoCarbsStaysFlat() {
        let r = predictor.predict(input())
        XCTAssertTrue(r.points.allSatisfy { abs($0.mgdl - 150) < 1e-9 })
        XCTAssertEqual(r.eventualBg, 150, accuracy: 1e-9)
    }

    func testPointsCoverHorizonAtStepInterval() {
        let r = predictor.predict(input(horizon: 120))
        XCTAssertEqual(r.points.count, 25)  // 0, 5, ..., 120
        XCTAssertEqual(r.points.first?.mgdl, 150)
        XCTAssertEqual(r.points.last?.date, now.addingTimeInterval(120 * 60))
    }

    func testInsulinLowersGlucoseMonotonically() {
        let r = predictor.predict(input(bg: 200, iob: 2))
        var previous = Double.infinity
        for p in r.points {
            XCTAssertLessThanOrEqual(p.mgdl, previous + 1e-9)
            previous = p.mgdl
        }
        // 2 U × ISF 50 最终应降 100 mg/dL
        XCTAssertEqual(r.eventualBg, 100, accuracy: 1e-9)
    }

    func testCarbsRaiseGlucoseMonotonically() {
        let r = predictor.predict(input(bg: 100, cob: 40, isf: 50, cr: 10))
        // 40 g / 10 = 4 U 等价，× ISF 50 = 200 mg/dL
        XCTAssertEqual(r.eventualBg, 300, accuracy: 1e-9)
        var previous = -Double.infinity
        for p in r.points {
            XCTAssertGreaterThanOrEqual(p.mgdl, previous - 1e-9)
            previous = p.mgdl
        }
    }

    func testNegativeIobRaisesGlucose() {
        // Control-IQ 的净 IOB 可以为负，表示欠输，此时胰岛素项应升糖
        let r = predictor.predict(input(bg: 100, iob: -0.5))
        XCTAssertEqual(r.eventualBg, 125, accuracy: 1e-9)
        XCTAssertGreaterThan(r.points.last!.mgdl, 100)
    }

    func testPredictsLowCrossing() {
        let r = predictor.predict(input(bg: 120, iob: 1.5, isf: 60))
        // 1.5 U × 60 = 90，稳态 30，途中必然跌破 70
        XCTAssertEqual(r.eventualBg, 30, accuracy: 1e-9)
        XCTAssertNotNil(r.minutesToLow)
        XCTAssertTrue(r.isPredictedLow)
    }

    func testNoLowCrossingWhenStable() {
        let r = predictor.predict(input(bg: 140))
        XCTAssertNil(r.minutesToLow)
        XCTAssertNil(r.minutesToHigh)
    }

    func testHighCrossingDetected() {
        let r = predictor.predict(input(bg: 250))
        XCTAssertEqual(r.minutesToHigh, 0)  // 起点就已超阈值
    }

    func testInvalidIsfDoesNotFlipSign() {
        let r = predictor.predict(input(bg: 200, iob: 1, isf: 0))
        // ISF 退化到 1，仍应是降糖方向而不是不降或反向
        XCTAssertLessThan(r.eventualBg, 200)
    }

    func testInsulinEffectIsFrontLoaded() {
        // 峰值 75 分钟、DIA 360：t=90 时已消耗约 53%，之后是长尾
        let r = predictor.predict(input(bg: 300, iob: 2, isf: 50, horizon: 360))
        let at90 = r.points[18].mgdl   // t=90
        let dropAt90 = 300 - at90
        let dropTotal = 300 - r.points.last!.mgdl
        XCTAssertEqual(dropAt90 / dropTotal, 0.526, accuracy: 0.01)
    }

    func testFullySpentByActionDuration() {
        // 超过 DIA 后胰岛素项必须归零，否则预测会无限下坠
        let r = predictor.predict(input(bg: 300, iob: 2, isf: 50, horizon: 480))
        XCTAssertEqual(r.points.last!.mgdl, 200, accuracy: 1e-9)
        XCTAssertEqual(r.points[72].mgdl, 200, accuracy: 1e-9)  // t=360 已到底
    }
}
