import XCTest
@testable import PumpX2Kit

/// Control-IQ 监视层的解析测试。
///
/// 这里没有真机抓包（真机抓包要等用户把日志给我），所以向量是**按 pumpX2 的
/// parse 顺序手工构造**的：字节位置和 pumpX2 的 `ControlIQInfoV1Response.parse`
/// 一一对应，断言也逐字段写，不做整串 hex 比对——整串比对会把「解析偏一位」
/// 和「期望值写错」混成同一个失败，之前踩过。
final class ControlIQMessageTests: XCTestCase {

    // MARK: 0x69（10 字节）

    /// [0] 闭环开 [1..2] 体重 [3] 单位 [4] 每日总量 [5] 模式 [6..8] 保留 [9] 控制状态
    private let v1 = [UInt8](arrayLiteral: 1, 70, 0, 0, 45, 0, 0, 0, 0, 3)

    func testInfoV1Fields() throws {
        let info = try XCTUnwrap(ControlIQMessages.parseInfoV1(v1))
        XCTAssertEqual(info.version, 1)
        XCTAssertTrue(info.closedLoopEnabled)
        XCTAssertEqual(info.weight, 70, "体重是小端 u16，第 1–2 字节")
        XCTAssertEqual(info.weightUnit, .kilograms)
        XCTAssertEqual(info.totalDailyInsulinUnits, 45)
        XCTAssertEqual(info.userMode, .standard)
        XCTAssertEqual(info.controlStateRaw, 3, "控制状态码在第 9 字节")
        XCTAssertEqual(info.reservedBytes, [0, 0, 0])
        XCTAssertNil(info.exerciseDurationSeconds, "V1 没有运动模式字段")
    }

    func testInfoV1ClosedLoopOffAndSleepMode() throws {
        let cargo: [UInt8] = [0, 80, 0, 1, 60, 1, 0, 0, 0, 0]
        let info = try XCTUnwrap(ControlIQMessages.parseInfoV1(cargo))
        XCTAssertFalse(info.closedLoopEnabled)
        XCTAssertEqual(info.weight, 80)
        XCTAssertEqual(info.weightUnit, .pounds)
        XCTAssertEqual(info.userMode, .sleep)
        XCTAssertEqual(info.headline, "Control-IQ 已关闭", "关着时先说关掉，别说模式")
    }

    func testInfoV1RejectsShortCargo() {
        XCTAssertNil(ControlIQMessages.parseInfoV1([0, 1, 2]))
    }

    /// 固件以后加新模式时不能瞎猜成「标准」：保留原始码，让界面显示「未知(N)」
    func testUnknownUserModeKeepsRawCode() throws {
        let cargo: [UInt8] = [1, 70, 0, 0, 45, 9, 0, 0, 0, 0]
        let info = try XCTUnwrap(ControlIQMessages.parseInfoV1(cargo))
        XCTAssertNil(info.userMode)
        XCTAssertEqual(info.userModeRaw, 9)
        XCTAssertEqual(info.userModeText, "未知(9)")
    }

    func testHeadlineReflectsExerciseMode() throws {
        let cargo: [UInt8] = [1, 70, 0, 0, 45, 2, 0, 0, 0, 0]
        let info = try XCTUnwrap(ControlIQMessages.parseInfoV1(cargo))
        XCTAssertEqual(info.headline, "Control-IQ 运行中 · 运动模式")
    }

    // MARK: 0xB3（19 字节）

    /// 前 10 字节与 V1 同构，[10] exerciseChoice，[11..14] 时长，[15..18] 剩余（u32le）
    private let v2: [UInt8] = [
        1, 70, 0, 0, 45, 2, 0, 0, 0, 3,
        1,
        0x10, 0x0E, 0x00, 0x00,   // 3600 秒
        0x08, 0x07, 0x00, 0x00    // 1800 秒
    ]

    func testInfoV2Fields() throws {
        let info = try XCTUnwrap(ControlIQMessages.parseInfoV2(v2))
        XCTAssertEqual(info.version, 2)
        XCTAssertTrue(info.closedLoopEnabled)
        XCTAssertEqual(info.weight, 70, "V2 前 10 字节必须和 V1 解析出一样的体重")
        XCTAssertEqual(info.userMode, .exercise)
        XCTAssertEqual(info.exerciseDurationSeconds, 3600)
        XCTAssertEqual(info.exerciseRemainingSeconds, 1800)
    }

    func testInfoV2RejectsShortCargo() {
        XCTAssertNil(ControlIQMessages.parseInfoV2(Array(v1)))
    }

    // MARK: 0x6B（24 字节 = 4 × 6）

    /// 一条 22:00–07:00 的工作日睡眠时段 + 三条空位
    private let sleep: [UInt8] = [
        1, 0x1F, 0x28, 0x05, 0xA4, 0x01,   // 启用、工作日、1320、420
        0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0
    ]

    func testSleepScheduleFields() throws {
        let s = try XCTUnwrap(ControlIQMessages.parseSleepSchedule(sleep))
        XCTAssertEqual(s.windows.count, 4)
        let w = s.windows[0]
        XCTAssertTrue(w.enabled)
        XCTAssertEqual(w.activeDaysBitmask, 0x1F)
        XCTAssertEqual(w.startMinutes, 1320)
        XCTAssertEqual(w.endMinutes, 420)
        XCTAssertEqual(w.startText, "22:00")
        XCTAssertEqual(w.endText, "07:00")
        XCTAssertEqual(w.daysText, "工作日")
        XCTAssertFalse(s.windows[1].enabled)
    }

    func testSleepScheduleRejectsShortCargo() {
        XCTAssertNil(ControlIQMessages.parseSleepSchedule(Array(sleep.prefix(20))))
    }

    /// 跨零点：23:00–07:00 在 02:00 也算「正在睡」
    func testSleepWindowSpansMidnight() throws {
        let cargo: [UInt8] = [
            1, 0x7F, 0x64, 0x05, 0x1C, 0x02,
            0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0
        ]
        let s = try XCTUnwrap(ControlIQMessages.parseSleepSchedule(cargo))
        XCTAssertEqual(s.windows[0].startText, "23:00")
        XCTAssertEqual(s.windows[0].endText, "07:00")
        XCTAssertEqual(s.windows[0].daysText, "每天")
        XCTAssertNotNil(s.activeWindow(atMinutes: 2 * 60), "02:00 应落在跨零点时段里")
        XCTAssertNil(s.activeWindow(atMinutes: 12 * 60), "中午不在睡眠时段")
    }

    func testDaysTextVariants() throws {
        var cargo = [UInt8](repeating: 0, count: 24)
        cargo[0] = 1
        cargo[1] = 0x01                       // 只有周一
        let s = try XCTUnwrap(ControlIQMessages.parseSleepSchedule(cargo))
        XCTAssertEqual(s.windows[0].daysText, "周一")
        XCTAssertEqual(s.windows[1].daysText, "无", "未启用/空掩码说「无」，不要说「每天」")
    }
}
