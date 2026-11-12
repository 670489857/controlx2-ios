import XCTest
@testable import PumpX2Kit

final class CryptoTests: XCTestCase {

    func testSHA256() {
        XCTAssertEqual(Hex.encode(SHA256.hash([])),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Hex.encode(SHA256.hash(Array("abc".utf8))),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSHA1() {
        XCTAssertEqual(Hex.encode(SHA1.hash(Array("abc".utf8))),
                       "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    func testHMACSHA1RFC2202() {
        // RFC 2202 test case 1
        XCTAssertEqual(Hex.encode(HMAC.sha1(key: [UInt8](repeating: 0x0b, count: 20),
                                            message: Array("Hi There".utf8))),
                       "b617318655057264e28bc0b6fb378c8ef146be00")
    }

    func testHMACSHA256RFC4231() {
        // RFC 4231 test case 1
        XCTAssertEqual(Hex.encode(HMAC.sha256(key: [UInt8](repeating: 0x0b, count: 20),
                                              message: Array("Hi There".utf8))),
                       "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    }

    func testP256GeneratorMultiples() {
        let two = P256.multiply(U256(2), P256.generator)!
        XCTAssertEqual(Hex.encode(two.x.bytesBE()),
                       "7cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc47669978")
        XCTAssertEqual(Hex.encode(two.y.bytesBE()),
                       "07775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1")

        let k = U256(hex: "deadbeefcafebabe1234567890abcdef")
        let p = P256.multiply(k, P256.generator)!
        XCTAssertEqual(Hex.encode(p.x.bytesBE()),
                       "5d2bf6649b350c64674924d0530a4ff137fd35c97d4665e7dad49b767a925bae")
        XCTAssertEqual(Hex.encode(p.y.bytesBE()),
                       "ca0f1f709875c72e913d393986234a33736e248548cb5e19da85c144fd179737")
    }

    func testPointEncodingRoundTrip() throws {
        let point = P256.multiply(U256(2), P256.generator)!
        let compressed = P256.encodeCompressed(point)
        XCTAssertEqual(compressed.count, 33)
        let decoded = try P256.decode(compressed)
        XCTAssertEqual(decoded.x, point.x)
        XCTAssertEqual(decoded.y, point.y)

        let uncompressed = P256.encodeUncompressed(point)
        XCTAssertEqual(uncompressed.count, 65)
        let decoded2 = try P256.decode(uncompressed)
        XCTAssertEqual(decoded2.x, point.x)
        XCTAssertEqual(decoded2.y, point.y)
    }

    func testScalarArithmetic() {
        let a = U256(hex: "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632550")
        XCTAssertEqual(P256.scalarAdd(a, U256(1)), U256.zero)
        XCTAssertEqual(P256.scalarNegate(U256(1)), a)
    }

    /// 双端各自跑完 EC-JPAKE，派生密钥必须一致；这是对点运算、ZKP、序列化的端到端校验
    func testJPAKEClientServerAgreement() throws {
        let secret = Array("123456".utf8)
        let client = ECJPAKE(role: .client, secret: secret)
        let server = ECJPAKE(role: .server, secret: secret)

        let c1 = try client.round1()
        let s1 = try server.round1()
        XCTAssertEqual(c1.count, 330)
        XCTAssertEqual(s1.count, 330)

        try server.readRound1(c1)
        try client.readRound1(s1)

        let c2 = try client.round2()
        let s2 = try server.round2()
        XCTAssertEqual(c2.count, 165)
        XCTAssertEqual(s2.count, 168)

        try server.readRound2(c2)
        try client.readRound2(s2)

        let cs = try client.deriveSecret()
        let ss = try server.deriveSecret()
        XCTAssertEqual(Hex.encode(cs), Hex.encode(ss))
        XCTAssertEqual(cs.count, 32)
    }

    func testJPAKEWrongSecretMismatch() throws {
        let client = ECJPAKE(role: .client, secret: Array("123456".utf8))
        let server = ECJPAKE(role: .server, secret: Array("654321".utf8))
        try server.readRound1(try client.round1())
        try client.readRound1(try server.round1())
        try server.readRound2(try client.round2())
        try client.readRound2(try server.round2())
        XCTAssertNotEqual(Hex.encode(try client.deriveSecret()),
                          Hex.encode(try server.deriveSecret()))
    }
}
