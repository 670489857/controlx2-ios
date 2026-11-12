import XCTest
@testable import PumpX2Kit

/// 配对码长度与编码：t:slim X2 旧固件是 16 位字母数字，v7.7+ 与 Mobi 是 6 位数字。
final class PairingCodeTests: XCTestCase {

    func testNormalizeStripsSeparatorsAndUppercases() {
        XCTAssertEqual(JPAKEAuth.normalize("a1b2-c3d4-e5f6-7890"), "A1B2C3D4E5F67890")
        XCTAssertEqual(JPAKEAuth.normalize(" 123 456 "), "123456")
        XCTAssertEqual(JPAKEAuth.normalize("12-34-56"), "123456")
    }

    func testDigitsMapToASCII() {
        XCTAssertEqual(JPAKEAuth.codeToBytes("012345"), [48, 49, 50, 51, 52, 53])
    }

    /// 与 pumpX2 `JpakeAuthBuilder.charCode` 对齐：非数字字符一律为 (byte) -1
    func testLettersMapToFF() {
        XCTAssertEqual(JPAKEAuth.codeToBytes("A1"), [0xFF, 49])
        XCTAssertEqual(JPAKEAuth.codeToBytes("Z9"), [0xFF, 57])
    }

    func testSixAndSixteenCharCodesAccepted() throws {
        _ = try JPAKEAuth(pairingCode: "123456")
        _ = try JPAKEAuth(pairingCode: "A1B2-C3D4-E5F6-7890")
    }

    func testOtherLengthsRejected() {
        XCTAssertThrowsError(try JPAKEAuth(pairingCode: "12345"))
        XCTAssertThrowsError(try JPAKEAuth(pairingCode: "1234567"))
        XCTAssertThrowsError(try JPAKEAuth(pairingCode: ""))
    }
}
