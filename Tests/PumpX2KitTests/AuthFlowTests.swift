import XCTest
@testable import PumpX2Kit

/// 可编排的假链路：把发出的分片拼回整帧记录下来，并按需回包。
final class ScriptedLink: PumpLink {
    private let continuation: AsyncStream<AssembledFrame>.Continuation
    let frames: AsyncStream<AssembledFrame>

    private let lock = NSLock()
    private var _records: [(op: UInt8, txId: UInt8, cargo: [UInt8])] = []
    /// 请求 opCode → (回复 opCode, 回复 cargo)
    private var script: [UInt8: (UInt8, [UInt8])] = [:]

    init() {
        var c: AsyncStream<AssembledFrame>.Continuation!
        frames = AsyncStream { c = $0 }
        continuation = c
    }

    func reply(to op: UInt8, with responseOp: UInt8, cargo: [UInt8]) {
        lock.lock(); script[op] = (responseOp, cargo); lock.unlock()
    }

    var records: [(op: UInt8, txId: UInt8, cargo: [UInt8])] {
        lock.lock(); defer { lock.unlock() }
        return _records
    }

    var ops: [UInt8] { records.map(\.op) }

    func updateAuthenticationKey(_ key: [UInt8]?) {}

    func write(_ packets: [[UInt8]], to characteristic: Characteristic) async throws {
        // 分片格式：[remaining, txId, ...]；把各片载荷顺序拼回整帧
        var frame: [UInt8] = []
        var txId: UInt8 = 0
        for p in packets {
            guard p.count > 2 else { continue }
            txId = p[1]
            frame += p.dropFirst(2)
        }
        guard frame.count >= 3 else { return }
        let op = frame[0]
        let len = Int(frame[2])
        let cargo = frame.count >= 3 + len ? Array(frame[3..<(3 + len)]) : []
        lock.lock()
        _records.append((op, txId, cargo))
        let response = script[op]
        lock.unlock()

        if let (respOp, respCargo) = response {
            continuation.yield(.init(opCode: respOp, txId: txId, cargo: respCargo,
                                     signed: false, hmacVerified: false))
        }
    }
}

final class AuthFlowTests: XCTestCase {

    /// 等到链路记录里出现第一条报文。
    ///
    /// 不能用 2 秒：`pair()` 会先跑 EC-JPAKE 第一轮，纯 Swift 的 P-256 在 debug
    /// 构建 + CI 冷启动下可以到好几秒（同文件里那条已知答案用例单跑就 6 秒），
    /// 窗口太窄会把「算得慢」误报成「没发报文」。
    private func waitForFirstFrame(_ link: ScriptedLink,
                                   seconds: Int = 20,
                                   _ file: StaticString = #filePath,
                                   _ line: UInt = #line) async {
        for _ in 0..<(seconds * 50) {
            if !link.records.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("\(seconds) 秒内没有发出任何报文", file: file, line: line)
    }

    /// 6 位码必须直接进 JPAKE：首条报文是 0x20（Jpake1a），且全程不能出现 0x10。
    ///
    /// 这是上一版跑不通的根因：连接后先发了 0x10 中央挑战。v7.7+ 的泵只认
    /// JPAKE 序列，收到不认识的 0x10 会立刻断链且不回任何报文——日志里就是
    /// 「TX 17B 00 00 10 …」紧跟一条 disconnect，零 RX。
    func testSixDigitCodeStartsJpake() async {
        let link = ScriptedLink()
        let session = PumpSession(link: link)
        await session.start()

        Task { try? await session.pair(code: "123456") }
        await waitForFirstFrame(link)

        guard let first = link.records.first else { return XCTFail("没有发出任何报文") }
        XCTAssertEqual(first.op, 0x20, "6 位码的第一条必须是 Jpake1a")
        XCTAssertFalse(link.ops.contains(0x10), "6 位码路径不允许出现 CentralChallenge")
        XCTAssertEqual(first.txId, 0, "新连接首帧事务号必须是 0")
        XCTAssertEqual(first.cargo.count, 167, "Jpake1a cargo 固定 167 字节")
        // appInstanceId 为 0，与 t:connect 抓包一致
        XCTAssertEqual(first.cargo[0], 0)
        XCTAssertEqual(first.cargo[1], 0)
    }

    /// 已存凭据的快速重连：首条是 0x26（Jpake3SessionKey），同样不能有 0x10。
    func testResumeStartsAtSessionKey() async {
        let link = ScriptedLink()
        let session = PumpSession(link: link)
        await session.start()

        let saved = PumpCredentials(appInstanceId: 0,
                                    derivedSecret: [UInt8](repeating: 0x11, count: 32))
        Task { _ = try? await session.resume(with: saved) }
        await waitForFirstFrame(link)

        guard let first = link.records.first else { return XCTFail("没有发出任何报文") }
        XCTAssertEqual(first.op, 0x26)
        XCTAssertFalse(link.ops.contains(0x10))
        XCTAssertEqual(first.cargo.count, 2, "Jpake3SessionKey cargo 只有 appInstanceId")
    }

    /// 16 位旧固件码：0x10 → 0x12，且 0x12 的载荷是对**配对码**做 HMAC-SHA1。
    func testLegacySixteenCharUsesHmacOverCode() async throws {
        let link = ScriptedLink()
        let hmacKey: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04]
        var central: [UInt8] = [0x00, 0x00]
        central += [UInt8](repeating: 0x5A, count: 20)
        central += hmacKey
        link.reply(to: 0x10, with: 0x11, cargo: central)
        link.reply(to: 0x12, with: 0x13, cargo: [0x00, 0x00, 0x01])

        let session = PumpSession(link: link)
        await session.start()
        try await session.pair(code: "A1B2-C3D4-E5F6-7890")

        XCTAssertEqual(link.ops, [0x10, 0x12])

        let code = "A1B2C3D4E5F67890"
        let expected = HMAC.sha1(key: hmacKey, message: Array(code.utf8))
        let sent = link.records[1].cargo
        XCTAssertEqual(sent.count, 22, "PumpChallenge cargo = appInstanceId(2) + HMAC(20)")
        XCTAssertEqual(Array(sent.dropFirst(2)), expected,
                       "载荷必须是 HMAC-SHA1(hmacKey, 配对码)，不是对空串签名")
        let creds = await session.credentials
        XCTAssertNotNil(creds)
    }

    /// 认证进行中再次点「开始配对」不能插队，否则泵侧状态机会乱
    func testConcurrentPairIsRejected() async {
        let link = ScriptedLink()
        let session = PumpSession(link: link)
        await session.start()

        Task { try? await session.pair(code: "123456") }
        await waitForFirstFrame(link)

        do {
            try await session.pair(code: "123456")
            XCTFail("第二次配对应被拒绝")
        } catch {
            // 期望：invalidState
        }
        XCTAssertEqual(link.ops.filter { $0 == 0x20 }.count, 1)
    }

    /// 快速重连的第 4 步摘要必须能被泵验过。
    ///
    /// 现场日志里 0x20→0x21…0x26→0x27 全部正常，唯独 0x28 发出后 1.2 秒被泵断开、
    /// 连 0x29 都不给——原因就是摘要的 HKDF 把 nonce 和密钥材料的角色弄反了。
    func testResumeKeyConfirmationDigest() throws {
        let secret = (0...31).map { UInt8($0) }
        let auth = try JPAKEAuth(derivedSecret: secret, appInstanceId: 0,
                                 random: FixedRandomSource(hex: "99aabbccddeeff00"))

        let first = try XCTUnwrap(try auth.nextRequest())
        XCTAssertEqual(first.opCode, 0x26)

        // 泵的 0x27：appInstanceId(2) + deviceKeyNonce(8) + reserved(8)
        let nonce3 = try Hex.decode("1122334455667788")
        let nonce4 = try Hex.decode("99aabbccddeeff00")
        var resp: [UInt8] = [0, 0]
        resp += nonce3
        resp += [UInt8](repeating: 0, count: 8)
        try auth.process(opCode: 0x27, cargo: resp)

        let fourth = try XCTUnwrap(try auth.nextRequest())
        XCTAssertEqual(fourth.opCode, 0x28)
        XCTAssertEqual(fourth.cargo.count, 50, "0x28 固定 50 字节")
        XCTAssertEqual(Array(fourth.cargo[2..<10]), nonce4, "客户端 nonce 在前")
        XCTAssertEqual(Array(fourth.cargo[10..<18]), [UInt8](repeating: 0, count: 8), "reserved 全 0")
        XCTAssertEqual(Hex.encode(Array(fourth.cargo[18..<50])),
                       "60416617f993a8871a4c80d5d2d83c549644774be11dcb03c3d75c7a5aa60020",
                       "摘要 = HMAC-SHA256(key: HKDF(nonce3, secret), data: nonce4)")

        // 配对后的签名密钥同样是 HKDF(nonce3, secret)，不是 JPAKE 原始派生值。
        // 用错了，配对照样显示成功，但第一条签名报文必被泵拒。
        let signingKey = try XCTUnwrap(auth.authenticationKey)
        XCTAssertEqual(Hex.encode(signingKey),
                       "9975790885aa35399285519cf4c1e0413487fbdf92ceb3d7910383cb1b49e67f")
    }
}
