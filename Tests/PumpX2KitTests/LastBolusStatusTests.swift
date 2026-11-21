import XCTest
@testable import PumpX2Kit

final class LastBolusStatusTests: XCTestCase {

    /// 药筒空的时候泵也会受理，但实际输注是 0——台账必须记 0，不能记请求量。
    func testDeliveredZeroWhenNothingWentIn() throws {
        var cargo = [UInt8](repeating: 0, count: 24)
        cargo[0] = 0                       // status = 0 成功
        cargo[1] = 0x34; cargo[2] = 0x12   // bolusId = 0x1234
        cargo[3] = 0; cargo[4] = 0
        // timestamp @5 留 0
        // delivered @9 = 0
        cargo[13] = 0; cargo[14] = 0; cargo[15] = 0
        // requested @20 = 500 → 0.5 U
        cargo[20] = 0xF4; cargo[21] = 0x01
        let status = StatusDecoder.lastBolusStatusV2(cargo)
        XCTAssertEqual(status?.bolusId, 0x1234)
        XCTAssertEqual(status?.deliveredUnits, 0)
        XCTAssertEqual(status?.requestedUnits, 0.5)
    }

    func testDeliveredPartial() throws {
        var cargo = [UInt8](repeating: 0, count: 24)
        cargo[1] = 0x07; cargo[2] = 0x00   // bolusId = 7
        cargo[9] = 0xD0; cargo[10] = 0x07  // delivered = 2000 → 2.0 U
        cargo[20] = 0x10; cargo[21] = 0x27 // requested = 10000 → 10 U
        let status = StatusDecoder.lastBolusStatusV2(cargo)
        XCTAssertEqual(status?.bolusId, 7)
        XCTAssertEqual(status?.deliveredUnits, 2.0)
        XCTAssertEqual(status?.requestedUnits, 10.0)
    }

    func testShortCargoRejected() {
        XCTAssertNil(StatusDecoder.lastBolusStatusV2([UInt8](repeating: 0, count: 23)))
    }
}
