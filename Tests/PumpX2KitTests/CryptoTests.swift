import XCTest
@testable import PumpX2Kit

/// 按固定字节流供给随机数，用于复现 Java 参考实现的已知答案向量
final class FixedRandomSource: RandomSource {
    private let stream: [UInt8]
    private var offset = 0
    init(hex: String) {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        stream = out
    }
    func bytes(_ count: Int) -> [UInt8] {
        precondition(offset + count <= stream.count, "随机流耗尽：需要 \(count) 字节")
        defer { offset += count }
        return Array(stream[offset..<offset + count])
    }
}

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

    /// 与 particle-iot/ecjpake-java 的已知答案向量逐步对齐（client role）。
    ///
    /// 这是唯一能抓到「双方都用自己实现、错误互相抵消」的检查：
    /// 之前 ZKP 哈希用压缩点编码，客户端与服务端自测照样能通过，
    /// 但和泵端 mbedtls 算出的挑战值完全不同 —— 泵校验失败后直接断链。
    func testECJPAKEKnownAnswerClient() throws {
        let rand = FixedRandomSource(hex:
                     "0bb1b515aebb230d9d16ec3702d92738dc9cd0819bf37787c456fbe39c6bcacd" +
                     "2613f01a23a6e679b97ba9ec5d4be5f2dbf14bbbb9ea7b9f6651d96ef4e31b68" +
                     "69b1439020883249904ceb5b4a15c40e34176df0ff8bc27029da4147665dcb59" +
                     "10873ba39ebbeacb24ab2695fcc35e14bca6e512bf42f08b8dd838bde922f847" +
                     "455d8e81bee36509d0f77860a0641312e14648731067823471832c9f3dc9e482" +
                     "75f1041b0332f5447cad007341a5e3c3fc55f787a26b3f5619c891a3cd34907b")
        let client = ECJPAKE(role: .client, secret: Array("passw0rd".utf8), random: rand)
        let round1 = try client.round1()
        XCTAssertEqual(Hex.encode(round1),
                       "4104e92f1a97685b86ea2e8a583724095e355955d1356942c2fa7a0da21f1486" +
                       "90052607421562f9771fbcf70fdc33056b2f2596145d8c5cd7be986259e2918d" +
                       "9f554104854faebe27e2f81652f0e71b38410d704fc521965bd40005fa47de22" +
                       "d7de67c2ba301fe248f63b954891e5ba9237c4dace174b022dcc6d55cc977115" +
                       "e0e5e24a2062080ced0ce4c03ca7fb9c80e1374939956623bc951905ac6ed5c6" +
                       "a96ea647c34104580e59d4e2377620a0e2003a22cf5b603165676e48de7095c2" +
                       "1f8c76afdef847bc976aa1f58ee050c757f9ccc2af19142a15714a27268886fc" +
                       "50ddf0f8b4573e41046b1d85ca2a6bf3e956269bac6529856ab73089e1522eba" +
                       "11b2b16f2e50908cd6ee7bb6b1f7ecefc424bebe177039e9e2c98da07c7f5213" +
                       "88789d5bb37dc2830e209967d2ec8e533bb526645218a376bb3d318103e0aef9" +
                       "6c300f30986ab3d0e027")
        XCTAssertEqual(round1.count, 330)

        try client.readRound1(Hex.decode(
            "4104e7c5d0684bb95148e935d86377befafeb346036808c8ce70f295ba471baf" +
            "ffeef40c462dd49716f13d2ff82f4365d4429d9280caf443dcd0ec79161b0d9c" +
            "e4cd4104a3b138f08ac33bd583035bec94575073245eb08d7b3aebfb948d139f" +
            "b8504b67167a9c6ff8dfca50787f5a3e31ed8ddb4af5d717456aa6f3ac8ddbbc" +
            "9d1a2cba20459cdfbcaae4e8b1017df914f01848eb40149188a3cfc2a988e03d" +
            "794df6ba1e41040f825be5af5c808c38e0e8878751b07d4bddd372df34a1c64f" +
            "feb5a1e8b97fad413c18bd62a55b02fad86b1cef68b6cce71daf3c932f3bf15c" +
            "5e57dca9dd15b34104d057ea7f55f38a200966ff4ac8fddc1fd8a6021e6ee2f5" +
            "0739e61c6bfca0bcb28b92b964ca24f846327695d654ba1f363cbf8b9ba67b12" +
            "c61d4c58e34e2176f4201e77da3bb44e301aac88dc3749ff33d1f78ce1a73afc" +
            "7de414e584bca28c37ab"))

        let round2 = try client.round2()
        XCTAssertEqual(Hex.encode(round2),
                       "410401cbf7400850b52ab66bc0633de63a83b2a0e8b679451bca80573a5ef5a4" +
                       "116f36c7ef60efae1a46df7988d63c58136adadcc52e6e1cec0641c99d494523" +
                       "d15c41040fbeb1bc502d7017aa8d15e20cc43f89c46270c4a3a101cb5cb7ea9b" +
                       "2075ad10753dd1a327f9bdf91121d5da5c8c3e1827fcd21951f9dd944faffdf6" +
                       "688fcf1120e636ca18769e80923b24d4636191aac2a7573d9a0c3898e690f735" +
                       "425d8702fd")

        try client.readRound2(Hex.decode(
            "0300174104a674d165d4b727d76954b810d90c8c549b38bacf9b322d32f8f5ed" +
            "5d2bd00b0a93326843b9955024b84eb22c320d36350caa57ad4a0744e322d6dc" +
            "98cec8635b4104474737716644c4813db988da1de8284ac59cc18f9e172da43d" +
            "b80e9e4ef70eae998857526e53a99156d4e137c1cdd3ab1033d343dda08c5810" +
            "85a71fc6478c4120c52706456c50213629b91a003078544dc6da201caed7d4f9" +
            "a7189fa1e537259f"))

        XCTAssertEqual(Hex.encode(try client.deriveSecret()),
                         "e734344901549417f6243f8e4a712f87ae9409476f8d022c347ff690249683aa")
    }

    /// HKDF 的密钥/消息顺序必须与 pumpX2 完全一致。
    ///
    /// 期望值由 JDK 实跑 pumpX2 的 Hkdf.java 得到。写反成 HMAC(key: keyMaterial, data: nonce)
    /// 会得到 d0aba68b…，长度一样、自测照样通过，但泵算出的第 6 步摘要不同，
    /// 结果是 0x28 发出后泵一条回复都不给就断链。
    func testHKDFMatchesPumpX2() throws {
        let nonce = try Hex.decode("e734344901549417")
        let keyMaterial = try Hex.decode("e734344901549417f6243f8e4a712f87ae9409476f8d022c347ff690249683aa")
        XCTAssertEqual(Hex.encode(HKDF.build(nonce: nonce, keyMaterial: keyMaterial)),
                       "c47d71d77ff8a9001f53ee15fcdccfc0b3bd85232e8be18ec431f2f5f16f03e9")
    }

    /// 第 4 步确认摘要：HMAC-SHA256(key: HKDF(nonce3, secret), data: nonce4)。
    /// 期望值同样由 JDK 跑 pumpX2 的 Hkdf + HmacSha256 得到。
    func testKeyConfirmationDigest() throws {
        let secret = (0...31).map { UInt8($0) }
        let nonce3 = try Hex.decode("1122334455667788")
        let nonce4 = try Hex.decode("99aabbccddeeff00")
        let okm = HKDF.build(nonce: nonce3, keyMaterial: secret)
        XCTAssertEqual(Hex.encode(okm),
                       "9975790885aa35399285519cf4c1e0413487fbdf92ceb3d7910383cb1b49e67f")
        XCTAssertEqual(Hex.encode(HMAC.sha256(key: okm, message: nonce4)),
                       "60416617f993a8871a4c80d5d2d83c549644774be11dcb03c3d75c7a5aa60020")
    }
}
