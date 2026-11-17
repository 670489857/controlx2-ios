import XCTest
@testable import PumpX2Kit

/// 只读状态的字段解码。
///
/// 这里的十六进制全部来自 jwoglom/pumpX2 的 `response/currentStatus/*ResponseTest`，
/// 是 t:connect 抓包的原样字节。用它们钉死偏移和字节序：改错一位，
/// 界面上仍会显示一个「看起来合理」的数字，只有对照真包才能发现。
final class StatusDecoderTests: XCTestCase {

    /// 去掉帧头（remaining、txId、opCode、txId、len）与 CRC，取出 cargo。
    /// 长度取自帧里的 len 字节，顺便验证它和实际一致。
    private func cargo(_ hex: String) throws -> [UInt8] {
        let bytes = try Hex.decode(hex)
        guard bytes.count >= 5 else { throw ProtocolError.truncated }
        let len = Int(bytes[4])
        let body = Array(bytes[5..<(5 + len)])
        XCTAssertEqual(bytes.count, 5 + len + 2, "帧长与 len 字节不符：\(hex)")
        return body
    }

    // MARK: 药筒余量（0x25）

    func testInsulinStatusFromCapturedFrame() throws {
        // pumpX2 InsulinStatusResponseTest：amount=0, isEstimate=0, lowAmount=35
        let s = try XCTUnwrap(StatusDecoder.insulinStatus(cargo("000425040400000023397d")))
        XCTAssertEqual(s.units, 0, accuracy: 0.0001)
        XCTAssertFalse(s.isEstimate)
        XCTAssertEqual(s.lowAmount, 35)
    }

    /// 真机标定：泵屏幕「+60 u」，同一条 0x25 的原始值是 60。
    ///
    /// 这条以前写的是「按 0.001 U 解释」，结果 60 U 被读成 0.06 U，闸门判定药筒
    /// 不够、把针拦掉。低余量阈值（lowAmount=35）与它同报文同刻度，也是整单位，
    /// 一条报文两套刻度本来就讲不通。
    func testInsulinStatusRealMachine60Units() throws {
        let s = try XCTUnwrap(StatusDecoder.insulinStatus([60, 0, 0, 35]))
        XCTAssertEqual(s.units, 60.0, accuracy: 1e-9)
        XCTAssertFalse(s.isEstimate)
        XCTAssertEqual(s.lowAmount, 35)
    }

    /// 正在装筒/回抽时泵会标 isEstimate，界面要能说出「这是估算」。
    func testInsulinStatusEstimateFlag() throws {
        let s = try XCTUnwrap(StatusDecoder.insulinStatus([5, 0, 1, 20]))
        XCTAssertTrue(s.isEstimate)
        XCTAssertEqual(s.units, 5.0, accuracy: 1e-9)
        XCTAssertEqual(s.lowAmount, 20)
    }

    /// 负数：药筒被抽空之后泵可能给出一个负的估计值，不能当成巨大的正数。
    func testInsulinStatusNegativeIsPreserved() throws {
        let s = try XCTUnwrap(StatusDecoder.insulinStatus([0x18, 0xFC, 0x00, 0x23]))  // -1000
        XCTAssertEqual(s.units, -1000.0, accuracy: 1e-9)
    }

    // MARK: 基础率（0x29）

    func testBasalStatusFromCapturedFrame() throws {
        // pumpX2 CurrentBasalStatusResponseTest：profile=800, current=0, bitmask=1
        // 真泵上「配置文件 0.8 U/h、当前 0 U/h」是常态：Control-IQ 把它压到 0 了。
        let s = try XCTUnwrap(StatusDecoder.currentBasal(cargo("0003290309200300000000000001d8d0")))
        XCTAssertEqual(s.profile, 0.8, accuracy: 0.0001)
        XCTAssertEqual(s.current, 0, accuracy: 0.0001)
        XCTAssertEqual(s.modified, 1)
        XCTAssertTrue(s.isModified)
    }

    func testBasalStatusSteadyState() throws {
        // profile = current = 1.25 U/h，未被修改
        var b = [UInt8]()
        b += [0xE2, 0x04, 0x00, 0x00]   // 1250
        b += [0xE2, 0x04, 0x00, 0x00]   // 1250
        b += [0x00]
        let s = try XCTUnwrap(StatusDecoder.currentBasal(b))
        XCTAssertEqual(s.current, 1.25, accuracy: 0.0001)
        XCTAssertEqual(s.profile, 1.25, accuracy: 0.0001)
        XCTAssertFalse(s.isModified)
    }

    // MARK: 活性胰岛素（0x6D）

    /// Control-IQ 关闭时泵用 Mudaliar 曲线
    func testIOBMudaliarFromCapturedFrame() throws {
        // mudaliar=192, total=241, swan6hr=161, time=14460, type=0
        let iob = try XCTUnwrap(StatusDecoder.controlIQIOB(
            cargo("00056d0511c00000007c380000f1000000a100000000ab8d")))
        XCTAssertEqual(iob.type, 0)
        XCTAssertEqual(iob.mudaliar, 0.192, accuracy: 0.0001)
        XCTAssertEqual(iob.swan6hr, 0.161, accuracy: 0.0001)
        XCTAssertEqual(iob.displayed, 0.192, accuracy: 0.0001)
        XCTAssertEqual(iob.typeName, "Mudaliar")
    }

    /// Control-IQ 打开时泵切到 Swan 6hr，屏幕显示的是 swan6hr 那个数。
    /// 一律读 mudaliar 会多算 0.03 U——正是「建议补一档」的量级。
    func testIOBSwan6hrFromCapturedFrame() throws {
        // mudaliar=184, total=241, swan6hr=154, time=14220, type=1
        let iob = try XCTUnwrap(StatusDecoder.controlIQIOB(
            cargo("00066d0611b80000008c370000f10000009a00000001c315")))
        XCTAssertEqual(iob.type, 1)
        XCTAssertEqual(iob.mudaliar, 0.184, accuracy: 0.0001)
        XCTAssertEqual(iob.swan6hr, 0.154, accuracy: 0.0001)
        XCTAssertEqual(iob.displayed, 0.154, accuracy: 0.0001)
        XCTAssertEqual(iob.typeName, "Swan 6hr")
    }

    /// 类型是固件给的，认不出来时取两者较大的那个：宁可高估在体内的量（建议更保守）
    func testIOBUnknownTypeTakesLarger() throws {
        var c = [UInt8](repeating: 0, count: 17)
        c[0] = 0x64                    // mudaliar 0.100
        c[12] = 0xC8                   // swan 0.200
        c[16] = 9                      // 未知类型
        let iob = try XCTUnwrap(StatusDecoder.controlIQIOB(c))
        XCTAssertEqual(iob.displayed, 0.2, accuracy: 0.0001)
        XCTAssertEqual(iob.typeName, "未知(9)")
    }

    // MARK: 电量（0x35）

    /// 泵屏幕上的百分比是第二个字节。第一个字节是另一个口径，99 vs 100 只差 1，
    /// 现场几乎发现不了——这条用例就是为了让它被发现。
    func testBatteryUsesSecondByte() throws {
        XCTAssertEqual(StatusDecoder.batteryPercent(try cargo("0003350302636452b9")), 100)
        XCTAssertEqual(StatusDecoder.batteryPercent(try cargo("00043504026464e871")), 100)
        XCTAssertEqual(StatusDecoder.batteryPercent([99, 100]), 100)
    }

    // MARK: 血糖（0x23）

    func testEGVFromCapturedFrame() throws {
        // timestamp=471039176, cgmReading=123, status=1(VALID), trend=-1
        let e = try XCTUnwrap(StatusDecoder.egv(cargo("0032233208c87c131c7b0001ff5eb5")))
        XCTAssertEqual(e.timestamp, 471039176)
        XCTAssertEqual(e.mgdl, 123)
        XCTAssertEqual(e.status, 1)
        XCTAssertEqual(e.trend, -1)
        XCTAssertFalse(e.isClamped)
    }

    /// 没有 CGM 时 status=4（不可用），读数不能当成 0 mg/dL 拿去预测
    func testEGVUnavailable() throws {
        let e = try XCTUnwrap(StatusDecoder.egv(cargo("000323030800000000000004007b52")))
        XCTAssertEqual(e.mgdl, 0)
        XCTAssertEqual(e.status, 4)
        XCTAssertEqual(e.statusName, "不可用")
    }

    /// LOW/HIGH 是夹紧值（40 / 400），必须在界面上标出来，否则会被当成真值
    func testEGVClampedStatus() throws {
        var c = [UInt8](repeating: 0, count: 8)
        c[4] = 40; c[6] = 2
        XCTAssertTrue(try XCTUnwrap(StatusDecoder.egv(c)).isClamped)

        c[4] = 0x90; c[5] = 0x01; c[6] = 3   // 400
        let high = try XCTUnwrap(StatusDecoder.egv(c))
        XCTAssertTrue(high.isClamped)
        XCTAssertEqual(high.mgdl, 400)
    }

    // MARK: 长度不足

    func testShortCargoIsRejected() {
        XCTAssertNil(StatusDecoder.insulinStatus([0, 0, 0]))
        XCTAssertNil(StatusDecoder.currentBasal([UInt8](repeating: 0, count: 8)))
        XCTAssertNil(StatusDecoder.controlIQIOB([UInt8](repeating: 0, count: 16)))
        XCTAssertNil(StatusDecoder.batteryPercent([75]))
        XCTAssertNil(StatusDecoder.egv([UInt8](repeating: 0, count: 7)))
    }
}
