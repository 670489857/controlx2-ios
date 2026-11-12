import XCTest
@testable import PumpX2Kit

final class CredentialsTests: XCTestCase {

    func testRoundTripCodable() throws {
        let creds = PumpCredentials(appInstanceId: 1,
                                    derivedSecret: (0..<32).map { UInt8($0) })
        let data = try JSONEncoder().encode(creds)
        let back = try JSONDecoder().decode(PumpCredentials.self, from: data)
        XCTAssertEqual(creds, back)
        XCTAssertEqual(back.derivedSecret.count, 32)
    }

    func testInMemoryStore() {
        let store = InMemoryCredentialStore()
        let key = "pump-uuid"
        XCTAssertNil(store.load(for: key))

        let creds = PumpCredentials(appInstanceId: 1, derivedSecret: [UInt8](repeating: 3, count: 32))
        store.save(creds, for: key)
        XCTAssertEqual(store.load(for: key), creds)

        store.delete(for: key)
        XCTAssertNil(store.load(for: key))
    }

    /// 快速重连必须从第 3 步（0x26）开始，不能重跑 1a/1b/2
    func testResumeStartsAtConfirmStep() throws {
        let auth = try JPAKEAuth(derivedSecret: [UInt8](repeating: 7, count: 32))
        XCTAssertEqual(auth.step.rawValue, JPAKEAuth.Step.confirmInitial.rawValue)
        XCTAssertEqual(auth.appInstanceId, 1)

        let first = try XCTUnwrap(try auth.nextRequest())
        XCTAssertEqual(first.opCode, 0x26)
        XCTAssertEqual(first.characteristic, .authorization)
        // 请求体 = 2 字节 appInstanceId + 空载荷
        XCTAssertEqual(first.cargo, [1, 0])
    }

    func testResumeRejectsWrongSecretLength() {
        XCTAssertThrowsError(try JPAKEAuth(derivedSecret: [UInt8](repeating: 0, count: 16)))
        XCTAssertThrowsError(try JPAKEAuth(derivedSecret: []))
    }

    /// 完整配对仍从 1a 开始，未被快速重连路径影响
    func testFullPairingStillStartsAtBootstrap() throws {
        let auth = try JPAKEAuth(pairingCode: "123456")
        XCTAssertEqual(auth.step.rawValue, JPAKEAuth.Step.bootstrapInitial.rawValue)
        let first = try XCTUnwrap(try auth.nextRequest())
        XCTAssertEqual(first.opCode, 0x20)
    }
}
