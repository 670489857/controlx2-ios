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

    // MARK: 第一轮的短编码与载荷补齐

    /// 把一轮 330 字节里的第一个 ZKP 标量改成 31 字节（最短编码），
    /// 整轮因此短 1 字节，与泵端「约 1/256 每次标量」的行为一致。
    private func makeShortRound1(_ full: [UInt8]) -> (a: [UInt8], b: [UInt8], all: [UInt8]) {
        // 布局：X1(66) + V1(66) + s1(33) | X2(66) + V2(66) + s2(33)
        let s1Prefix = 132
        var short = Array(full[0..<s1Prefix])
        short += [31]                       // 长度前缀改为 31
        short += full[(s1Prefix + 2)..<full.count]  // 丢掉标量首字节
        precondition(short.count == full.count - 1)
        return (Array(short[0..<164]), Array(short[164..<short.count]), short)
    }

    /// 泵把 1a 装在 167 字节的 cargo 里，但载荷只有 164 字节时，尾部会补 0。
    /// 补满到 165 再拼接，第二轮的点才落在正确位置。
    func testShortRound1CargoIsZeroPadded() throws {
        let secret = Array("123456".utf8)
        let server = ECJPAKE(role: .server, secret: secret)
        let full = try server.round1()
        XCTAssertEqual(full.count, 330)

        let split = makeShortRound1(full)

        let client = ECJPAKE(role: .client, secret: secret)
        _ = try client.round1()             // 生成自己的 Xm1/Xm2/xm2

        // 1a：164 字节真实载荷 + 1 个补位 0，总 cargo 167（= 2 appId + 165）
        let aCargo: [UInt8] = [0, 0] + split.a + [0]
        XCTAssertEqual(aCargo.count, 167)
        try client.readRound1(try AuthMessages.jpakePayload(aCargo, fixedLength: 165))
        XCTAssertFalse(client.peerRound1Complete, "1a 只有半轮，此时不应认为第一轮已完成")

        // 1b：165 字节
        let bCargo: [UInt8] = [0, 0] + split.b
        XCTAssertEqual(bCargo.count, 167)
        try client.readRound1(try AuthMessages.jpakePayload(bCargo, fixedLength: 165))
        XCTAssertTrue(client.peerRound1Complete)

        // 两个点都解析正确，才能算出共享点 g —— round2 成功即证明这一点
        XCTAssertNoThrow(try client.round2())
    }

    /// 短编码（标量按最短长度写出）本身能被增量解析吞下：每个字段都带长度前缀。
    /// 但泵的 cargo 是固定长度的，缺的字节由 0 补满；补齐与不补齐必须得到同一个结果，
    /// 否则说明解析器偷偷依赖了字节偏移，而不是长度前缀。
    ///
    /// 这条用例同时守住「不要退回按固定偏移切 165 + 165」——那种写法只有在
    /// 每轮都恰好 165 字节时才成立，泵一旦短编码就会把第二轮的点读错位置。
    func testShortRound1ParsesWithAndWithoutPadding() throws {
        let secret = Array("123456".utf8)
        let server = ECJPAKE(role: .server, secret: secret)
        let full = try server.round1()
        let split = makeShortRound1(full)
        XCTAssertEqual(split.a.count + split.b.count, 329)

        // 补齐路径
        let padded = ECJPAKE(role: .client, secret: secret)
        _ = try padded.round1()
        try padded.readRound1(try AuthMessages.jpakePayload([0, 0] + split.a + [0], fixedLength: 165))
        try padded.readRound1(try AuthMessages.jpakePayload([0, 0] + split.b, fixedLength: 165))
        XCTAssertTrue(padded.peerRound1Complete)

        // 不补齐路径：直接接上
        let raw = ECJPAKE(role: .client, secret: secret)
        _ = try raw.round1()
        try raw.readRound1(split.a)
        try raw.readRound1(split.b)
        XCTAssertTrue(raw.peerRound1Complete)

        // 两条路径解出的点一致 —— round2 依赖 Xp1/Xp2，能算出来即证明点位相同
        XCTAssertNoThrow(try padded.round2())
        XCTAssertNoThrow(try raw.round2())
    }

    /// 0x25 的载荷声明 168 字节（curveId 3 + 一轮 165），同样要补满。
    func testShortRound2CargoIsZeroPadded() throws {
        let secret = Array("123456".utf8)
        let alice = ECJPAKE(role: .server, secret: secret)
        let bob = ECJPAKE(role: .client, secret: secret)

        // 双方先交换第一轮
        let a1 = try alice.round1()
        let b1 = try bob.round1()
        try alice.readRound1(b1)
        try bob.readRound1(a1)

        let b2 = try bob.round2()
        try alice.readRound2(b2)

        let r2 = try alice.round2()          // [3, 0, 23] + X + ZKP = 168
        XCTAssertEqual(r2.count, 168)

        // 把标量改成 31 字节，整条短 1 字节；泵会把它补满到 168 再发
        let scalarPrefix = 3 + 66 + 66
        XCTAssertEqual(r2[scalarPrefix], 32)
        var short = Array(r2[0..<scalarPrefix])
        short += [31]
        short += r2[(scalarPrefix + 2)..<r2.count]
        let padded = try AuthMessages.jpakePayload([0, 0] + short, fixedLength: 168)
        XCTAssertEqual(padded.count, 168)

        XCTAssertNoThrow(try bob.readRound2(padded))
        // 补位只让 ZKP 校验不过（记告警），共享点仍是同一个，派生密钥必须相等
        XCTAssertEqual(try bob.deriveSecret(), try alice.deriveSecret())
    }

    /// 载荷补齐的边界：不足补 0，正好原样，超长报错而不是悄悄截断。
    func testJpakePayloadLengthHandling() throws {
        XCTAssertEqual(try AuthMessages.jpakePayload([0, 0, 1, 2, 3], fixedLength: 5),
                       [1, 2, 3, 0, 0])
        XCTAssertEqual(try AuthMessages.jpakePayload([0, 0, 1, 2, 3, 4, 5], fixedLength: 5),
                       [1, 2, 3, 4, 5])
        XCTAssertThrowsError(try AuthMessages.jpakePayload([0, 0] + [UInt8](repeating: 9, count: 6),
                                                           fixedLength: 5)) { error in
            guard case ProtocolError.unexpectedCargoSize(found: 6, expected: 5) = error else {
                return XCTFail("应为长度不符，实际 \(error)")
            }
        }
        XCTAssertThrowsError(try AuthMessages.jpakePayload([0], fixedLength: 5))
    }

    /// 收到 0x21 之后必须继续发 0x22；泵那侧不回应时，报错要带「第几步、哪个 opCode」。
    ///
    /// 现场日志里出现过「TX 0x20 → RX 0x21 → 之后既没有 TX 也没有断链」。
    /// 无论那一次是发送队列卡住还是状态机没推进，这里都要求两条底线：
    /// 0x22 一定被发出；失败信息必须指向第 2 步，而不是笼统的「超时」。
    func testPairContinuesToRound1BAndReportsStep() async throws {
        let secret = Array("123456".utf8)
        let server = ECJPAKE(role: .server, secret: secret)
        let r1 = try server.round1()

        let link = ScriptedLink()
        link.reply(to: 0x20, with: 0x21, cargo: [0, 0] + Array(r1[0..<165]))
        // 故意不给 0x23 的回复

        let session = PumpSession(link: link)
        await session.start()

        do {
            try await session.pair(code: "123456")
            XCTFail("泵不回 0x23，配对应失败")
        } catch let ProtocolError.authStepFailed(step, opCode, _) {
            XCTAssertEqual(step, 2, "停在第 2 步（0x22）")
            XCTAssertEqual(opCode, 0x22)
        } catch {
            XCTFail("应带轮次信息，实际 \(error)")
        }

        XCTAssertEqual(link.ops, [0x20, 0x22], "0x21 之后必须继续发 0x22")
    }
}
