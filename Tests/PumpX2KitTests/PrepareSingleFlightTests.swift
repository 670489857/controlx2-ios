import XCTest
@testable import PumpX2Kit

/// 记录每一帧发出的事务，并按需回包
private final class CountingLink: PumpLink {
    private let continuation: AsyncStream<AssembledFrame>.Continuation
    let frames: AsyncStream<AssembledFrame>
    private let lock = NSLock()
    private var sent: [UInt8] = []

    init() {
        var c: AsyncStream<AssembledFrame>.Continuation!
        frames = AsyncStream { c = $0 }
        continuation = c
    }

    func updateAuthenticationKey(_ key: [UInt8]?) {}

    func count(of opCode: UInt8) -> Int {
        lock.lock(); defer { lock.unlock() }
        return sent.filter { $0 == opCode }.count
    }

    func write(_ packets: [[UInt8]], to characteristic: Characteristic) async throws {
        guard let first = packets.first else { return }
        // packet 布局：[remaining, txId, opCode, len, ...]
        let opCode = first[2]
        let txId = first[1]
        lock.lock(); sent.append(opCode); lock.unlock()

        // 故意延迟回包，让第二个请求有机会在第一个完成前进入——这正是
        // actor 在 await 处重入的窗口，没有单飞就会连发两个 0x10。
        try? await Task.sleep(for: .milliseconds(30))

        switch opCode {
        case 0x10:
            var cargo: [UInt8] = [0x01, 0x00]
            cargo += [UInt8](repeating: 0xAB, count: 20)
            cargo += [UInt8](repeating: 0xCD, count: 8)
            continuation.yield(.init(opCode: 0x11, txId: txId, cargo: cargo,
                                     signed: false, hmacVerified: false))
        case 0x12:
            continuation.yield(.init(opCode: 0x13, txId: txId, cargo: [0x01, 0x00, 0x01],
                                     signed: false, hmacVerified: false))
        default:
            break
        }
    }
}

final class PrepareSingleFlightTests: XCTestCase {

    /// 并发调用 prepare 只能触发一次 CentralChallenge。
    ///
    /// 这不是理论风险：连接流程和链路就绪回调会同时调它，而 PumpSession 是 actor，
    /// await 期间可重入，两个调用都会看到 preparedInstanceId 为 nil。
    /// 泵收到两个未完成的认证请求会直接断链——症状是「链路已就绪」后立刻断开。
    func testConcurrentPrepareSendsOnlyOneChallenge() async throws {
        let link = CountingLink()
        let session = PumpSession(link: link)
        await session.start()

        async let a = session.prepare()
        async let b = session.prepare()
        async let c = session.prepare()
        let ids = try await [a, b, c]

        XCTAssertEqual(link.count(of: 0x10), 1, "三个并发 prepare 只应发一个 CentralChallenge")
        XCTAssertEqual(link.count(of: 0x12), 1)
        XCTAssertEqual(Set(ids).count, 1, "三个调用应拿到同一个 instanceId")
    }

    /// 握手完成后再次 prepare 直接命中缓存，不再产生任何流量
    func testPrepareIsCached() async throws {
        let link = CountingLink()
        let session = PumpSession(link: link)
        await session.start()

        _ = try await session.prepare()
        _ = try await session.prepare()
        _ = try await session.prepare()

        XCTAssertEqual(link.count(of: 0x10), 1)
    }

    /// 同一 opCode 的第二个在途请求必须在写入前被拦下
    func testDuplicateRequestRejectedBeforeWrite() async throws {
        let link = CountingLink()
        let session = PumpSession(link: link)
        await session.start()

        // 第一个请求进入等待回包状态
        let first = Task { try await session.prepare() }
        try await Task.sleep(for: .milliseconds(5))
        // 绕过单飞直接打底层，模拟别处误加的第二条通道
        let second = Task { try await session.prepare(hint: 0) }
        _ = try await first.value
        _ = try await second.value

        XCTAssertEqual(link.count(of: 0x10), 1)
    }
}
