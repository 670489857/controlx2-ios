import XCTest
@testable import PumpX2Kit

/// 大剂量报文的逐字节测试。
///
/// 期望值全部来自 pumpX2 的抓包向量（`InitiateBolusRequestTest`、
/// `BolusPermissionRequestTest`），密钥与泵计时也用抓包里那一组：
/// 只有这样才能同时钉住三件容易错的事——字段顺序、小端字节序、签名覆盖范围。
final class BolusMessageTests: XCTestCase {

    private let captureKey = Array("6VeDeRAL5DCigGw2".utf8)

    // MARK: 授权 0xA2

    func testPermissionRequestSignedFrameMatchesCapture() throws {
        // 抓包：BolusPermissionRequestTest.testBolusPermissionRequest_unknown1
        // `PUMP_AUTHENTICATION_KEY=6VeDeRAL5DCigGw2 PUMP_TIME_SINCE_RESET=461457713`
        // 帧里实际嵌入的泵计时是 461457181（比声明值小，抓包本身就是滞后的），
        // 签名尾正是按这个值算出来的，所以测试用嵌入值。
        let packets = try Packetize.encode(BolusMessages.permissionRequest(),
                                           txId: 0x34,
                                           authKey: captureKey,
                                           pumpTimeSinceReset: 461457181)
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(Hex.encode(packets[0]), "0134a234181d47811bc64bcd072fc978e4842046")
        XCTAssertEqual(Hex.encode(packets[1]), "003426b62ba72612b4f04978ac")
    }

    func testPermissionResponseFromCapture() throws {
        // 同一段抓包里泵的回复。cargo 从帧长度字节之后才开始，
        // 「1e」是 len(30) 不是 status，这一点看错会把 status 读成 30。
        let permission = try XCTUnwrap(BolusMessages.parsePermission(try Hex.decode("009c29000000")))
        XCTAssertEqual(permission.status, 0)
        XCTAssertEqual(permission.bolusId, 10652)
        XCTAssertEqual(permission.nackReason, 0)
        XCTAssertTrue(permission.granted, "nackReason=0 且给了 bolusId，泵是给这次输注发号了")
    }

    func testPermissionDeniedWhenNack() throws {
        // status=0, bolusId=0, 保留 0,0, nackReason=3（泵上已有另一处持有许可）
        let busy = try XCTUnwrap(BolusMessages.parsePermission(try Hex.decode("000000000003")))
        XCTAssertEqual(busy.nackReason, 3)
        XCTAssertFalse(busy.granted)
        XCTAssertTrue(busy.nackDescription.contains("另一处"))
    }

    func testPermissionParserRejectsShortCargo() {
        XCTAssertNil(BolusMessages.parsePermission([0, 0]))
    }

    // MARK: 发起 0x9E

    func testInitiateBolusCargoLayout() throws {
        let msg = try BolusMessages.initiateBolus(units: 1.0,
                                                  bolusId: 10650,
                                                  typeBitmask: BolusMessages.TypeMask.correction)
        XCTAssertEqual(msg.opCode, 0x9E)
        XCTAssertTrue(msg.signed)
        XCTAssertEqual(msg.cargo.count, 37)
        XCTAssertEqual(Hex.encode(Array(msg.cargo[0..<9])), "e80300009a29000008")
        XCTAssertTrue(msg.cargo[9...].allSatisfy { $0 == 0 }, "没有碳水/BG/IOB 元数据时后面必须全是 0")
    }

    func testInitiateBolusFrameMatchesCapture_1u() throws {
        // 抓包：InitiateBolusRequestTest.testInitiateBolusRequest_ID10650_1u
        // 1 U override bolus，bolusId=10650，typeBitmask=8（correction）
        let msg = try BolusMessages.initiateBolus(units: 1.0,
                                                  bolusId: 10650,
                                                  typeBitmask: BolusMessages.TypeMask.correction)
        let packets = try Packetize.encode(msg, txId: 0x39,
                                           authKey: captureKey,
                                           pumpTimeSinceReset: 461510642)
        XCTAssertEqual(packets.count, 4, "61 字节的签名帧按 18 字节切片就是 4 片")
        XCTAssertEqual(Hex.encode(packets[0]), "03399e393de80300009a29000008000000000000")
        XCTAssertEqual(Hex.encode(packets[1]), "0239000000000000000000000000000000000000")
        XCTAssertEqual(Hex.encode(packets[2]), "013900000000f217821b68f94cebe6717a5d1551")
        XCTAssertEqual(Hex.encode(packets[3]), "003927147fec9ad979926aaccd74")
    }

    func testInitiateBolusCarriesMetadataWithoutChangingVolume() throws {
        // 对应抓包 testInitiateBolusRequest_ID10652_013u_13g_carbs_142mgdl：
        // 0.13 U、13 g 碳水、142 mg/dL、bolusId=10652。
        // 逐字段断言而不是整段比字符串——偏移错一位时，报错会直接指到是哪个字段。
        let msg = try BolusMessages.initiateBolus(units: 0.13,
                                                  bolusId: 10652,
                                                  typeBitmask: BolusMessages.TypeMask.now,
                                                  foodVolumeUnits: 0.13,
                                                  carbsGrams: 13,
                                                  bgMgdl: 142)
        XCTAssertEqual(msg.cargo.count, 37)
        XCTAssertEqual(BolusMessages.leU32(msg.cargo, 0), 130)
        XCTAssertEqual(BolusMessages.leU16(msg.cargo, 4), 10652)
        XCTAssertEqual(msg.cargo[8], BolusMessages.TypeMask.now)
        XCTAssertEqual(BolusMessages.leU32(msg.cargo, 9), 130)
        XCTAssertEqual(BolusMessages.leU32(msg.cargo, 13), 0)
        XCTAssertEqual(BolusMessages.leU16(msg.cargo, 17), 13)
        XCTAssertEqual(BolusMessages.leU16(msg.cargo, 19), 142)
        XCTAssertEqual(BolusMessages.leU32(msg.cargo, 21), 0)
    }

    func testInitiateBolusRoundTripsVolume() throws {
        for units in [0.05, 0.5, 1.25, 7.3] {
            let msg = try BolusMessages.initiateBolus(units: units, bolusId: 42)
            let milli = Int(BolusMessages.leU32(msg.cargo, 0))
            XCTAssertEqual(InsulinUnit.fromMilli(milli), units, accuracy: 1e-9)
        }
    }

    func testInitiateBolusRejectsTooSmallDose() {
        XCTAssertThrowsError(try BolusMessages.initiateBolus(units: 0.04, bolusId: 100))
    }

    func testInitiateBolusRejectsMissingBolusId() {
        XCTAssertThrowsError(try BolusMessages.initiateBolus(units: 1.0, bolusId: 0))
    }

    func testInitiateResponseAcceptedAndRevoked() throws {
        let ok = try XCTUnwrap(BolusMessages.parseInitiate(try Hex.decode("009a29000000")))
        XCTAssertEqual(ok.bolusId, 10650)
        XCTAssertTrue(ok.accepted)

        let revoked = try XCTUnwrap(BolusMessages.parseInitiate(try Hex.decode("009a29000002")))
        XCTAssertEqual(revoked.statusType, 2)
        XCTAssertFalse(revoked.accepted)
    }

    // MARK: 取消 0xA0

    func testCancelBolusCargo() throws {
        let msg = try BolusMessages.cancelBolus(bolusId: 10650)
        XCTAssertEqual(msg.opCode, 0xA0)
        XCTAssertEqual(Hex.encode(msg.cargo), "9a290000")
    }

    func testCancelResponse() throws {
        let ok = try XCTUnwrap(BolusMessages.parseCancel(try Hex.decode("009a290000")))
        XCTAssertTrue(ok.cancelled)
        XCTAssertEqual(ok.bolusId, 10650)

        let alreadyDone = try XCTUnwrap(BolusMessages.parseCancel(try Hex.decode("019a290200")))
        XCTAssertFalse(alreadyDone.cancelled)
        XCTAssertEqual(alreadyDone.reason, 2)
    }

    // MARK: 释放 0xF0

    func testReleasePermissionCargo() throws {
        let msg = try BolusMessages.releasePermission(bolusId: 10652)
        XCTAssertEqual(msg.opCode, 0xF0)
        XCTAssertEqual(Hex.encode(msg.cargo), "9c290000")
    }

    func testReleaseResponseStatus() throws {
        XCTAssertEqual(BolusMessages.parseRelease([0]), 0)
        XCTAssertEqual(BolusMessages.parseRelease([1]), 1)
        XCTAssertNil(BolusMessages.parseRelease([]))
    }

    // MARK: 当前状态 0x2D

    func testCurrentBolusEmptyCapture() throws {
        // 抓包：CurrentBolusStatusResponseTest.testCurrentBolusStatusResponseEmpty
        let state = try XCTUnwrap(BolusMessages.parseCurrentBolus(try Hex.decode("000000000000000000000000000000")))
        XCTAssertEqual(state.statusId, 0)
        XCTAssertEqual(state.bolusId, 0)
        XCTAssertFalse(state.isDelivering)
        XCTAssertEqual(state.statusName, "无进行中的大剂量")
    }

    func testCurrentBolusDelivering() throws {
        // status=1（正在输注），bolusId=10652，requestedVolume=1000 毫单位
        let cargo = try Hex.decode("019c29000000000000e80300000000")
        let state = try XCTUnwrap(BolusMessages.parseCurrentBolus(cargo))
        XCTAssertTrue(state.isDelivering)
        XCTAssertEqual(state.bolusId, 10652)
        XCTAssertEqual(state.requestedUnits, 1.0, accuracy: 1e-9)
    }

    func testCurrentBolusShortCargo() {
        XCTAssertNil(BolusMessages.parseCurrentBolus(Array(repeating: 0, count: 14)))
    }

    // MARK: 单位换算

    func testRoundDownToStepNeverRoundsUp() {
        XCTAssertEqual(InsulinUnit.roundDownToStep(0.47), 0.45)
        XCTAssertEqual(InsulinUnit.roundDownToStep(0.049), 0)
        XCTAssertEqual(InsulinUnit.roundDownToStep(1.0), 1.0)
        XCTAssertEqual(InsulinUnit.toMilli(0.05), 50)
        XCTAssertEqual(InsulinUnit.fromMilli(50), 0.05)
    }
}
