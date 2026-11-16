import XCTest
@testable import PumpX2Kit

/// 基础率计划（只读）的报文解析。
///
/// 每个向量都来自 pumpX2 的抓包测试（`ProfileStatusResponseTest` /
/// `IDPSettingsResponseTest` / `IDPSegmentResponseTest`），只取 cargo 部分：
/// 帧头里的 `len` 字节不是 cargo，看错一位会让所有字段平移。
final class ProfileMessageTests: XCTestCase {

    func testProfileStatusFromCapture() throws {
        // 00033f03080100ffffffffff03d4c6 → op 0x3F, len 08, cargo:
        let status = try XCTUnwrap(ProfileMessages.parseStatus(
            try Hex.decode("0100ffffffffff03")))
        XCTAssertEqual(status.numberOfProfiles, 1)
        XCTAssertEqual(status.slotIds, [0, -1, -1, -1, -1, -1])
        XCTAssertEqual(status.activeSegmentIndex, 3)
        XCTAssertEqual(status.activeIdpId, 0)
    }

    func testProfileStatusWithTwoProfiles() throws {
        // 00043f0408020001ffffffff034403
        let status = try XCTUnwrap(ProfileMessages.parseStatus(
            try Hex.decode("020001ffffffff03")))
        XCTAssertEqual(status.numberOfProfiles, 2)
        XCTAssertEqual(status.activeIdpId, 0, "槽位 0 里的计划 ID 才是正在生效的那个")
    }

    func testProfileStatusWithoutActiveProfile() throws {
        // 槽位 0 是 0xFF：泵上没有可用计划
        let status = try XCTUnwrap(ProfileMessages.parseStatus(
            try Hex.decode("00ffffffffffff00")))
        XCTAssertNil(status.activeIdpId)
    }

    func testSettingsFromCapture() throws {
        // 00044104170041000000000000000000000000000000042c01a86101c2a5
        // 解析：idpId=0, name="A", 4 段, 胰岛素作用 300 分钟, 单次上限 25 U, 碳水录入开
        let settings = try XCTUnwrap(ProfileMessages.parseSettings(
            try Hex.decode("0041000000000000000000000000000000042c01a86101")))
        XCTAssertEqual(settings.idpId, 0)
        XCTAssertEqual(settings.name, "A")
        XCTAssertEqual(settings.segmentCount, 4)
        XCTAssertEqual(settings.insulinDurationMinutes, 300)
        XCTAssertEqual(settings.maxBolusUnits, 25.0)
        XCTAssertTrue(settings.carbEntry)
    }

    func testSettingsWithTwoCharName() throws {
        // 0005410517014e61000000000000000000000000000001e001a861015ef2
        let settings = try XCTUnwrap(ProfileMessages.parseSettings(
            try Hex.decode("014e61000000000000000000000000000001e001a86101")))
        XCTAssertEqual(settings.name, "Na")
        XCTAssertEqual(settings.segmentCount, 1)
        XCTAssertEqual(settings.insulinDurationMinutes, 480, "8 小时作用时长")
        XCTAssertEqual(settings.maxBolusUnits, 25.0)
    }

    func testSegmentMidnightFromCapture() throws {
        // 000443040f0000000020037017000078001e000f3078
        // 0.8 U/h，1:6 碳水比，目标 120，ISF 30
        let segment = try XCTUnwrap(ProfileMessages.parseSegment(
            try Hex.decode("0000000020037017000078001e000f")))
        XCTAssertEqual(segment.index, 0)
        XCTAssertEqual(segment.startMinutes, 0)
        XCTAssertEqual(segment.startText, "00:00")
        XCTAssertEqual(segment.basalRateUnitsPerHour, 0.8, accuracy: 1e-9)
        XCTAssertEqual(segment.carbRatioGramsPerUnit, 6.0, accuracy: 1e-9)
        XCTAssertEqual(segment.targetBgMgdl, 120)
        XCTAssertEqual(segment.isfMgdlPerUnit, 30)
        XCTAssertEqual(segment.statusBitmask, 0x0F, "低四位都填了：基础率/碳水比/目标/ISF")
    }

    func testSegmentSixAmFromCapture() throws {
        // 000543050f00016801e2047017000078001e000f121d
        let segment = try XCTUnwrap(ProfileMessages.parseSegment(
            try Hex.decode("00016801e2047017000078001e000f")))
        XCTAssertEqual(segment.index, 1)
        XCTAssertEqual(segment.startMinutes, 360)
        XCTAssertEqual(segment.startText, "06:00")
        XCTAssertEqual(segment.basalRateUnitsPerHour, 1.25, accuracy: 1e-9)
    }

    func testParsersRejectShortCargo() {
        XCTAssertNil(ProfileMessages.parseStatus([0, 0]))
        XCTAssertNil(ProfileMessages.parseSettings([0, 0]))
        XCTAssertNil(ProfileMessages.parseSegment([0, 0]))
    }

    // MARK: 请求

    func testRequestOpcodesAndCargo() throws {
        let status = ProfileMessages.profileStatusRequest()
        XCTAssertEqual(status.opCode, 0x3E)
        XCTAssertTrue(status.cargo.isEmpty)

        let settings = ProfileMessages.settingsRequest(idpId: 2)
        XCTAssertEqual(settings.opCode, 0x40)
        XCTAssertEqual(settings.cargo, [2])

        let segment = ProfileMessages.segmentRequest(idpId: 2, index: 3)
        XCTAssertEqual(segment.opCode, 0x42)
        XCTAssertEqual(segment.cargo, [2, 3])
    }

    // MARK: 汇总

    func testDailyBasalTotalCoversWholeDay() throws {
        // 00:00 0.8 U/h 到 06:00，06:00 1.25 U/h 到 24:00
        let midnight = try XCTUnwrap(ProfileMessages.parseSegment(
            try Hex.decode("0000000020037017000078001e000f")))
        let sixAm = try XCTUnwrap(ProfileMessages.parseSegment(
            try Hex.decode("00016801e2047017000078001e000f")))
        let profile = BasalProfile(idpId: 0, name: "A",
                                   insulinDurationMinutes: 300,
                                   maxBolusUnits: 25,
                                   carbEntry: true,
                                   segments: [midnight, sixAm],
                                   activeSegmentIndex: 1)
        // 0.8×6 + 1.25×18 = 4.8 + 22.5 = 27.3
        XCTAssertEqual(profile.totalDailyBasalUnits, 27.3, accuracy: 1e-6)
        XCTAssertEqual(profile.currentSegment?.index, 1)
    }

    func testEmptyProfileHasZeroTotal() {
        let profile = BasalProfile(idpId: 0, name: "空", insulinDurationMinutes: 0,
                                   maxBolusUnits: 0, carbEntry: false,
                                   segments: [], activeSegmentIndex: nil)
        XCTAssertEqual(profile.totalDailyBasalUnits, 0)
        XCTAssertNil(profile.currentSegment)
    }
}
