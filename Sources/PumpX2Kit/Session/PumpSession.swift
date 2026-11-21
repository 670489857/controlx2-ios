import Foundation

/// 一个基础率计划（IDP）的只读快照。
///
/// 只有读：写入侧（临时基础率 / 暂停 / 恢复 / 改计划）在 X2 固件是 `MOBI_ONLY`，
/// 泵不收，所以这个类型刻意没有任何 mutate 方法。
public struct BasalProfile: Equatable, Sendable {
    public var idpId: Int
    public var name: String
    public var insulinDurationMinutes: Int
    /// 泵里给这个计划设的单次大剂量上限（U）
    public var maxBolusUnits: Double
    public var carbEntry: Bool
    public var segments: [ProfileMessages.Segment]
    /// 当前处在第几段（来自 0x3F）
    public var activeSegmentIndex: Int?

    public var totalDailyBasalUnits: Double {
        guard !segments.isEmpty else { return 0 }
        // 每段按「到下一段开始」的时长累加，最后一段跨到 24:00
        var total = 0.0
        for (i, segment) in segments.enumerated() {
            let start = segment.startMinutes
            let end = i + 1 < segments.count ? segments[i + 1].startMinutes : 24 * 60
            let hours = Double(max(0, end - start)) / 60.0
            total += segment.basalRateUnitsPerHour * hours
        }
        return total
    }

    public var currentSegment: ProfileMessages.Segment? {
        guard let idx = activeSegmentIndex else { return nil }
        return segments.first { $0.index == idx }
    }
}

/// 泵会话：事务 ID 管理、请求/响应配对、配对流程、只读状态刷新、大剂量。
///
/// 配对成功后 `credentials` 会带上派生密钥；把它持久化（App 侧用 Keychain），
/// 下次连接时调用 `resume(with:)` 即可跳过完整 JPAKE，不必再在泵上输配对码。
///
/// 写入方向只开放了大剂量（授权 → 发起 → 取消 → 释放），基础率与暂停仍是
/// `MOBI_ONLY`，X2 固件不接受。所有输注指令的剂量边界由上层 `BolusGuard` 负责，
/// 这一层只管「把报文发对、把回包读懂」。
public actor PumpSession {

    public enum SessionState: Equatable, Sendable {
        case idle
        case pairing(progress: Int)
        case ready(ApiVersion)
        case failed(String)
    }

    public struct ApiVersion: Equatable, Sendable {
        public let major: Int
        public let minor: Int
        public var description: String { "\(major).\(minor)" }
    }

    public struct Snapshot: Equatable, Sendable {
        public var apiVersion: ApiVersion?
        public var insulinUnits: Double?
        public var insulinIsEstimate: Bool = false
        /// 泵上设的低余量提醒阈值（U）。和 `insulinUnits` 一起看才知道「0 U 是不是真的空」
        public var insulinLowAmount: Double?
        public var pumpTimeSinceReset: UInt64?
        /// 最近一次 CGM 读数（mg/dL），来自 CurrentEGVGuiData
        public var glucoseMgdl: Int?
        /// 趋势方向原始码（0–9），与泵屏幕箭头对应
        public var glucoseTrend: Int?
        /// EGV 状态：0 无效 / 1 有效 / 2 低 / 3 高 / 4 不可用
        public var glucoseStatus: Int?
        /// 泵给这条 CGM 读数打的时间戳（泵计时秒）
        public var glucoseTimestamp: UInt32?
        /// 这条 CGM 读数距读取时刻多少秒。闭环用它判断「读数是新的还是几十分钟前的」，
        /// 不能只看「刷新成功了」——刷新成功但泵报的仍是同一旧读数，是最常见的假新鲜。
        public var glucoseAgeSeconds: Int?
        /// 活性胰岛素（U）
        public var iobUnits: Double?
        /// 泵当前用的 IOB 曲线（Mudaliar / Swan 6hr）。两种曲线给出的数不同，必须记下来
        public var iobTypeName: String?
        public var iobMudaliar: Double?
        public var iobSwan6hr: Double?
        public var batteryPercent: Int?
        /// 当前基础率（U/h）
        public var basalRate: Double?
        /// 当前时段配置文件里的基础率（U/h）。与 `basalRate` 不等说明正被 Control-IQ 或临时率调整
        public var basalProfile: Double?
        public var basalModified: Bool = false
        public var lastUpdated: Date?
        /// 当前/最近一次大剂量（CurrentBolusStatus 0x2D）。输注过程中靠它判断进度。
        public var currentBolus: BolusMessages.BolusState?
        /// 最近一次读到的当前基础率计划（只读）
        public var basalProfileSchedule: BasalProfile?
        /// 泵自带 Control-IQ 的当前状态（只读）。注意这是**泵的算法**在跑，
        /// 不是本 App 在闭环；App 只读不写。
        public var controlIQ: ControlIQMessages.Info?
        /// Control-IQ 的睡眠时段表（只读）
        public var controlIQSleep: ControlIQMessages.SleepSchedule?
        /// 最近一次读取的原始 cargo，按响应 opCode 索引。
        /// 只给「读数核对」页用：界面上的数字一旦和泵屏幕不一致，唯一能判断
        /// 「是解析错了还是泵就这么报的」的证据就是这几个字节。
        public var rawCargo: [UInt8: [UInt8]] = [:]

        // MARK: 泵自报的硬件/软件信息（0x85 PumpVersionB）
        /// 泵上报的软件名（X2 上一般是 16 位软件 ID 或 7.x 版本串）
        public var pumpSoftwareName: String?
        public var pumpModelNumber: UInt32?
        public var pumpSerialNumber: UInt32?
        public var pumpRevision: String?

        /// mg/dL → mmol/L，仅用于展示切换
        public var glucoseMmol: Double? {
            guard let g = glucoseMgdl else { return nil }
            return Double(g) / 18.0182
        }
    }

    public enum ResumeResult: Sendable {
        /// 泵认可已保存的凭据，会话已恢复
        case resumed
        /// 泵不认识这段凭据（重置、换泵、固件升级），需要重新输入配对码
        case needsPairing
    }

    private let link: PumpLink
    private var txId: UInt8 = 0
    private var authKey: [UInt8]?
    private var pending: [UInt8: CheckedContinuation<AssembledFrame, Error>] = [:]
    private var pumpTimeSinceReset: UInt32 = 0
    private var readerTask: Task<Void, Never>?
    /// 多设备区分用。t:connect 抓包里是 0，pumpX2 的 JPAKE 构建器也硬编码 0，这里跟 0。
    private var appInstanceId: UInt16 = 0
    /// 认证序列进行中。整个 0x20–0x28 不允许被打断，重复进入会让泵侧状态机错乱
    private var authInProgress = false
    /// 已发出、还没等到回复的 opCode。写之前就登记，避免重复事务上路。
    private var inFlightOps: Set<UInt8> = []

    public private(set) var state: SessionState = .idle
    public private(set) var snapshot = Snapshot()
    /// 版本报文只试一次，成败都记下来，不随每次刷新重试
    private var didAttemptVersionRead = false
    /// 仅在完整配对成功后才有值；持久化它即可免去下次输入配对码
    public private(set) var credentials: PumpCredentials?
    /// 本次连接是否已完成 JPAKE 认证。重连后 `resetSession()` 会把它清成 false，
    /// 上层必须先重新 `resume` 才能读状态——连接建立不等于会话已恢复。
    public var isAuthenticated: Bool { authKey != nil }

    public init(link: PumpLink) {
        self.link = link
    }

    public func start() {
        guard readerTask == nil else { return }
        let frames = link.frames
        readerTask = Task { [weak self] in
            for await frame in frames {
                await self?.dispatch(frame)
            }
        }
    }

    private func dispatch(_ frame: AssembledFrame) {
        // 0x04 = Nack：泵明确拒绝上一条请求。它只带 2 字节原因码，不带被拒请求的
        // opCode，所以只能配给当前在途的那一条。不处理的话会白等满 8 秒超时，
        // 现场表现为「发出去没回音」，而泵其实早就说了「不认这条」。
        if frame.opCode == 0x04 {
            let reason = frame.cargo.count >= 2
                ? Int(frame.cargo[0]) | Int(frame.cargo[1]) << 8
                : -1
            link.note("收到 Nack：reason=\(reason)（被拒的请求未得到正常回复）")
            if let (op, cont) = pending.first {
                pending.removeValue(forKey: op)
                cont.resume(throwing: ProtocolError.nacked(reason: reason))
            }
            return
        }
        if let cont = pending.removeValue(forKey: frame.opCode) {
            cont.resume(returning: frame)
        }
    }

    // MARK: 请求

    private func nextTxId() -> UInt8 {
        // 先取当前值、再递增，与 pumpX2 的 TransactionId 完全一致：
        //   byte currentTxId = Packetize.txId.get();  // 0
        //   Packetize.txId.increment();               // 1
        // 也就是每次新连接的第一条消息事务号必须是 0。
        // 反过来写（先加后返回）会让首条变成 1，泵按事务号顺序校验时
        // 等于看到「0 号事务凭空丢了」，直接断链且不给任何回应。
        let id = txId
        txId = txId &+ 1
        return id
    }

    private func request(_ message: PumpMessage, expecting opCode: UInt8,
                         timeout: Duration = .seconds(8)) async throws -> AssembledFrame {
        // 未认证就发状态请求，泵会直接断开（现场日志：重连后「链路已就绪」的
        // 第一秒发 0x24，749ms 后 CBErrorDomain 7，然后又是重连、又发 0x24，死循环）。
        // 与其让它看起来像「泵不稳定」，不如在这里立刻失败，把责任说清楚：
        // 连接建立不等于会话已恢复，重连之后必须重新走 0x26 / 0x20 那套认证。
        if message.characteristic == .currentStatus, authKey == nil {
            throw ProtocolError.notAuthenticated
        }
        // 拦截必须发生在写入之前。原来的检查放在 continuation 里，等于第二个请求
        // 已经带着新事务号发出去了才报错，泵那边已经收到重叠事务。
        guard !inFlightOps.contains(opCode), pending[opCode] == nil else {
            throw ProtocolError.concurrentRequest(opCode: opCode)
        }
        inFlightOps.insert(opCode)
        defer { inFlightOps.remove(opCode) }

        let id = nextTxId()
        let packets = try Packetize.encode(message, txId: id, authKey: authKey ?? [],
                                           pumpTimeSinceReset: pumpTimeSinceReset)

        // 先登记待回复，再写。反过来会丢第一帧：泵的回包可能比 write 返回还快，
        // 此时 pending 里还没有这个 opCode，dispatch 找不到接收者就把帧丢了，
        // 然后白等满 8 秒超时——表现为「发出去没回音」，极难与链路问题区分。
        return try await withCheckedThrowingContinuation { cont in
            // 用 updateValue 而不是下标赋值：Swift 5.9 会把 actor 内的下标 setter
            // 展开成 async inout 调用并拒绝编译，与逻辑无关，纯属编译器限制。
            _ = pending.updateValue(cont, forKey: opCode)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                if let c = await self?.takePending(opCode) {
                    c.resume(throwing: ProtocolError.truncated)
                }
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.link.write(packets, to: message.characteristic)
                } catch {
                    // 写失败要把等回复的 continuation 收掉，否则调用方要等到超时
                    if let c = await self.takePending(opCode) {
                        c.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func hex(_ v: UInt8) -> String { String(format: "%02x", v) }

    private func hex(prefix bytes: [UInt8], _ n: Int) -> String {
        bytes.prefix(n).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func takePending(_ opCode: UInt8) -> CheckedContinuation<AssembledFrame, Error>? {
        pending.removeValue(forKey: opCode)
    }

    // MARK: 认证

    /// 驱动 JPAKE 状态机直到结束，成功后写入会话密钥
    private func runAuth(_ auth: JPAKEAuth,
                         progress: @escaping @Sendable (Int) -> Void) async throws {
        var stepIndex = 0
        var lastZKPWarning: String?
        link.note("auth: 开始，mode=\(auth.modeDescription)，appInstance=\(appInstanceId)")
        while let next = try auth.nextRequest() {
            stepIndex += 1
            link.note("auth \(stepIndex): 发送 0x\(hex(next.opCode)) cargo=\(next.cargo.count)B")
            let frame: AssembledFrame
            do {
                frame = try await request(next, expecting: next.opCode &+ 1)
            } catch {
                // 把「第几步、哪个 opCode」一起抛出去。泵在授权中途断链时，
                // 界面只能看到「超时」；没有轮次信息就分不清是密码错还是链路断。
                link.note("auth \(stepIndex): 0x\(hex(next.opCode)) 没拿到回复：\(error)")
                throw ProtocolError.authStepFailed(step: stepIndex, opCode: next.opCode,
                                                   reason: error.localizedDescription)
            }
            link.note("auth \(stepIndex): 收到 0x\(hex(frame.opCode)) cargo=\(frame.cargo.count)B")
            do {
                try auth.process(opCode: frame.opCode, cargo: frame.cargo)
            } catch {
                // 这一层之前完全静默：解析/ZKP 校验失败时日志停在 RX 那一行，
                // 现场只能猜是「泵没回」还是「回了但没用」。现在把具体原因和
                // 载荷开头一起留下，一眼能分清是长度不够、点解码失败、还是校验不过。
                link.note("auth \(stepIndex): 0x\(hex(frame.opCode)) 处理失败：\(error)"
                          + "（cargo=\(frame.cargo.count)B 首 12 字节 \(hex(prefix: frame.cargo, 12))）")
                throw error
            }
            if let w = auth.zkpWarning, w != lastZKPWarning {
                lastZKPWarning = w
                link.note("auth \(stepIndex): 告警 \(w)（继续走，由 0x28 定成败）")
            }
            link.note("auth \(stepIndex): ok -> \(auth.stepDescription)")
            progress(min(95, auth.step.rawValue * 6))
        }
        guard auth.isComplete, let key = auth.authenticationKey else {
            throw JPAKEAuth.AuthError.badConfirmation
        }
        authKey = key
        link.updateAuthenticationKey(key)
    }

    /// 旧固件（16 位字母数字码）：0x10 中央挑战 → 0x12 泵挑战。
    ///
    /// 只有 16 位码才走这条路。v7.7 及以后的 X2 与 Mobi 必须先做 BLE 层配对，
    /// 然后直接进 EC-JPAKE；此时发 0x10 泵不认识，会**立刻主动断开**——
    /// 表现就是授权帧发出的同一瞬间断链，日志里一条回复都没有。
    private func legacyPair(code: String, progress: @escaping @Sendable (Int) -> Void) async throws {
        let challenge = (0..<8).map { _ in UInt8.random(in: 0...255) }
        let central = try await request(
            AuthMessages.centralChallengeRequest(appInstanceId: appInstanceId, challenge: challenge),
            expecting: AuthMessages.centralChallengeResponseOp)
        progress(20)
        let parsed = try AuthMessages.parseCentralChallengeResponse(central.cargo)

        let challengeReq = AuthMessages.pumpChallengeRequest(appInstanceId: parsed.appInstanceId,
                                                            hmacKey: parsed.hmacKey,
                                                            pairingCode: code)
        let resp = try await request(challengeReq, expecting: AuthMessages.pumpChallengeResponseOp)
        let (id, ok) = try AuthMessages.parsePumpChallengeResponse(resp.cargo)
        guard ok else { throw JPAKEAuth.AuthError.rejected }
        progress(60)

        // 旧固件的签名密钥就是配对码本身（pumpX2 `PumpState.getAuthenticationKey`）
        appInstanceId = id
        authKey = Array(code.utf8)
        link.updateAuthenticationKey(authKey)
        // 旧固件没有 "derivedSecret" 概念，用配对码字节当口令，下次仍要输码
        credentials = PumpCredentials(appInstanceId: id, derivedSecret: Array(code.utf8))
    }

    /// 完整配对：输入泵屏幕上的配对码。
    ///
    /// - 6 位数字（X2 v7.7+ / Mobi）→ EC-JPAKE（0x20 → 0x28，六条消息）
    /// - 16 位字母数字（更早固件）→ 0x10 → 0x12
    public func pair(code: String,
                     progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws {
        guard authInProgress == false else { throw JPAKEAuth.AuthError.invalidState }
        authInProgress = true
        defer { authInProgress = false }

        let normalized = JPAKEAuth.normalize(code)
        state = .pairing(progress: 0)
        do {
            if normalized.count == 16 {
                try await legacyPair(code: normalized, progress: progress)
            } else {
                let auth = try JPAKEAuth(pairingCode: normalized, appInstanceId: appInstanceId)
                progress(10)
                try await runAuth(auth, progress: progress)
                guard let secret = auth.derivedSecret else {
                    throw JPAKEAuth.AuthError.invalidState
                }
                credentials = PumpCredentials(appInstanceId: appInstanceId, derivedSecret: secret)
            }
            progress(100)
        } catch {
            state = .failed("\(error)")
            throw error
        }
    }

    /// 快速重连：用已保存的派生密钥直接做第 3、4 步确认，不需要配对码。
    ///
    /// 注意这里**不能**先发 0x10。新版固件只认 JPAKE 序列，多一条 0x10
    /// 就等于在泵的授权状态机里插了一条它不认识的报文，结果是断链。
    /// 失败时不抛错，返回 `.needsPairing` 让界面回退到输入配对码。
    public func resume(with saved: PumpCredentials,
                       progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> ResumeResult {
        guard authInProgress == false else { return .needsPairing }
        authInProgress = true
        defer { authInProgress = false }

        state = .pairing(progress: 0)
        do {
            appInstanceId = saved.appInstanceId
            let auth = try JPAKEAuth(derivedSecret: saved.derivedSecret,
                                     appInstanceId: saved.appInstanceId)
            progress(10)
            try await runAuth(auth, progress: progress)
            credentials = saved
            progress(100)
            return .resumed
        } catch {
            state = .idle
            return .needsPairing
        }
    }

    /// 链路断开时调用：清掉会话级状态，重连后重新授权。
    /// 不清的话，第二次连接会沿用上一次的实例号与旧密钥。
    public func resetSession() {
        authInProgress = false
        inFlightOps.removeAll()
        // 事务号必须归零。pumpX2 的重连流程也是这么做的：泵对每次连接
        // 从头计事务，沿用上一条连接的号会被当成过期包丢掉。
        txId = 0
        authKey = nil
        link.updateAuthenticationKey(nil)
        for (_, c) in pending { c.resume(throwing: ProtocolError.truncated) }
        pending.removeAll()
        state = .idle
    }

    // MARK: 只读状态

    public func refresh() async throws {
        if let v = try? await readApiVersion() { snapshot.apiVersion = v }

        // 版本信息只尝试一次：X2 对 0x84 的受理与固件有关，
        // 反复重试会在每次下拉刷新时都撞一次可能的 Nack，没有必要。
        if !didAttemptVersionRead {
            didAttemptVersionRead = true
            if let frame = try? await request(
                PumpMessage.request(characteristic: .currentStatus, opCode: 0x84),
                expecting: 0x85
            ) {
                snapshot.rawCargo[0x85] = frame.cargo
                if let v = StatusDecoder.pumpVersionB(frame.cargo) {
                    snapshot.pumpSoftwareName = v.softwareName
                    snapshot.pumpModelNumber = v.modelNumber
                    snapshot.pumpSerialNumber = v.serialNumber
                    snapshot.pumpRevision = v.pumpRevision
                }
            }
        }

        // 以下每条都是「先问、再解析、并留下原始字节」。
        // 解析交给 StatusDecoder，偏移量在那里有抓包向量对上，这里只负责搬运。

        // 药筒余量（InsulinStatus，0x24 → 0x25）
        if let frame = try? await request(PumpMessage.request(characteristic: .currentStatus,
                                                              opCode: 0x24),
                                          expecting: 0x25) {
            snapshot.rawCargo[0x25] = frame.cargo
            if let s = StatusDecoder.insulinStatus(frame.cargo) {
                snapshot.insulinUnits = s.units
                snapshot.insulinIsEstimate = s.isEstimate
                snapshot.insulinLowAmount = s.lowAmount
            }
        }

        // 血糖（CurrentEGVGuiData，0x22 → 0x23）
        if let frame = try? await request(PumpMessage.request(characteristic: .currentStatus,
                                                              opCode: 0x22),
                                          expecting: 0x23) {
            snapshot.rawCargo[0x23] = frame.cargo
            if let e = StatusDecoder.egv(frame.cargo) {
                // 0 和夹紧边界都不能当成真读数：0 是「没有 CGM」，夹紧值是 40/400
                snapshot.glucoseMgdl = e.mgdl > 0 ? e.mgdl : nil
                snapshot.glucoseTrend = e.trend
                snapshot.glucoseStatus = e.status
                snapshot.glucoseTimestamp = e.timestamp
            }
        }

        // 活性胰岛素（ControlIQIOB，0x6C → 0x6D）
        if let frame = try? await request(PumpMessage.request(characteristic: .currentStatus,
                                                              opCode: 0x6C),
                                          expecting: 0x6D) {
            snapshot.rawCargo[0x6D] = frame.cargo
            if let iob = StatusDecoder.controlIQIOB(frame.cargo) {
                snapshot.iobUnits = iob.displayed
                snapshot.iobTypeName = iob.typeName
                snapshot.iobMudaliar = iob.mudaliar
                snapshot.iobSwan6hr = iob.swan6hr
            }
        }

        // 电量（CurrentBatteryV1，0x34 → 0x35）
        if let frame = try? await request(PumpMessage.request(characteristic: .currentStatus,
                                                              opCode: 0x34),
                                          expecting: 0x35) {
            snapshot.rawCargo[0x35] = frame.cargo
            if let p = StatusDecoder.batteryPercent(frame.cargo) {
                snapshot.batteryPercent = p
            }
        }

        // 基础率（CurrentBasalStatus，0x28 → 0x29）
        if let frame = try? await request(PumpMessage.request(characteristic: .currentStatus,
                                                              opCode: 0x28),
                                          expecting: 0x29) {
            snapshot.rawCargo[0x29] = frame.cargo
            if let b = StatusDecoder.currentBasal(frame.cargo) {
                snapshot.basalRate = b.current
                snapshot.basalProfile = b.profile
                snapshot.basalModified = b.isModified
            }
        }

        // 泵自带闭环状态（ControlIQInfo，0x68 → 0x69；运动模式再补 0xB2 → 0xB3）
        // 这条是「泵的算法现在在干嘛」，不是我们在控泵。读失败不影响其他读数。
        _ = try? await readControlIQ()

        // 当前大剂量（CurrentBolusStatus，0x2C → 0x2D）
        // 有进行中的大剂量时，界面和「最近一次输注」都以这条为准，
        // 而不是靠我们本地记的意图——泵才是事实来源。
        if let frame = try? await request(BolusMessages.currentBolusStatusRequest(), expecting: 0x2D) {
            snapshot.rawCargo[0x2D] = frame.cargo
            if let b = BolusMessages.parseCurrentBolus(frame.cargo) {
                snapshot.currentBolus = b
            }
        }

        // 泵计时（TimeSinceReset，0x36 → 0x37）：currentTime(4) + sinceReset(4)
        if let frame = try? await request(PumpMessage.request(characteristic: .currentStatus,
                                                              opCode: 0x36),
                                          expecting: 0x37),
           frame.cargo.count >= 8 {
            snapshot.rawCargo[0x37] = frame.cargo
            let sinceReset = u32(frame.cargo, 4)
            pumpTimeSinceReset = sinceReset
            snapshot.pumpTimeSinceReset = UInt64(sinceReset)
            // CGM 读数的年龄 = 泵计时 − 读数时间戳。两者同源（都是泵的秒计数），
            // 所以这条差值才是「这条血糖是几分钟前测的」，而不是「我们多久没刷新」
            if let ts = snapshot.glucoseTimestamp, sinceReset >= ts {
                snapshot.glucoseAgeSeconds = Int(sinceReset - ts)
            }
        }
        snapshot.lastUpdated = Date()
    }

    // MARK: 大剂量

    /// 申请一次输注许可。泵回一个 bolusId，后续 `InitiateBolus` 必须带着它。
    ///
    /// 这一步本身不输注。它的作用是让泵知道「这台设备要打，先占住这次输注」，
    /// 避免两台手机同时下发。拿到号却不用，必须 `releaseBolusPermission`，
    /// 否则泵那边会一直认为许可在被占用（另一处再来要，会收到 nackReason=3）。
    public func requestBolusPermission() async throws -> BolusMessages.Permission {
        guard authKey != nil else { throw ProtocolError.notAuthenticated }
        let frame = try await request(BolusMessages.permissionRequest(), expecting: 0xA3,
                                      timeout: .seconds(12))
        snapshot.rawCargo[0xA3] = frame.cargo
        guard let permission = BolusMessages.parsePermission(frame.cargo) else {
            throw ProtocolError.truncated
        }
        link.note("bolus: 授权 status=\(permission.status) bolusId=\(permission.bolusId)"
                  + " nack=\(permission.nackReason)（\(permission.nackDescription)）")
        guard permission.granted else {
            throw BolusMessages.BolusError.permissionDenied(reason: permission.nackDescription)
        }
        return permission
    }

    /// 真正下发输注。返回泵的受理结果；`accepted == false` 表示泵没有接受。
    ///
    /// 这条报文会改变胰岛素输注，签名与泵计时必须都对：签名密钥错、
    /// 或者 4 字节泵计时字节序错，泵都会直接拒。
    public func initiateBolus(units: Double,
                              permission: BolusMessages.Permission,
                              typeBitmask: UInt8 = BolusMessages.TypeMask.now,
                              carbsGrams: Int = 0,
                              bgMgdl: Int = 0,
                              iobUnits: Double = 0) async throws -> BolusMessages.InitiateResult {
        guard authKey != nil else { throw ProtocolError.notAuthenticated }
        let message = try BolusMessages.initiateBolus(units: units,
                                                      bolusId: permission.bolusId,
                                                      typeBitmask: typeBitmask,
                                                      carbsGrams: carbsGrams,
                                                      bgMgdl: bgMgdl,
                                                      iobUnits: iobUnits)
        link.note("bolus: 发起 \(units) U，bolusId=\(permission.bolusId)，"
                  + "报文 \(message.cargo.count)B 载荷 + 24B 签名")
        // 泵受理后会立刻开始推注，回包可能比写完还快，所以用较短超时；
        // 超时也不能当成「没打」——剂量可能已经进去，界面上必须写「状态未知，去泵上核对」。
        let frame = try await request(message, expecting: 0x9F, timeout: .seconds(12))
        snapshot.rawCargo[0x9F] = frame.cargo
        guard let result = BolusMessages.parseInitiate(frame.cargo) else {
            throw ProtocolError.truncated
        }
        link.note("bolus: 泵受理结果 status=\(result.status) type=\(result.statusType)"
                  + " bolusId=\(result.bolusId)（accepted=\(result.accepted)）")
        return result
    }

    /// 取消一次进行中的大剂量。泵上的取消同样是大剂量报文，需要签名。
    public func cancelBolus(bolusId: Int) async throws -> BolusMessages.CancelResult {
        guard authKey != nil else { throw ProtocolError.notAuthenticated }
        let message = try BolusMessages.cancelBolus(bolusId: bolusId)
        link.note("bolus: 取消 bolusId=\(bolusId)")
        let frame = try await request(message, expecting: 0xA1, timeout: .seconds(10))
        snapshot.rawCargo[0xA1] = frame.cargo
        guard let result = BolusMessages.parseCancel(frame.cargo) else {
            throw ProtocolError.truncated
        }
        link.note("bolus: 取消结果 status=\(result.status) reason=\(result.reason)"
                  + "（cancelled=\(result.cancelled)）")
        return result
    }

    /// 把没用掉的输注许可还给泵。失败不致命，只留日志。
    public func releaseBolusPermission(bolusId: Int) async throws {
        guard authKey != nil else { throw ProtocolError.notAuthenticated }
        let message = try BolusMessages.releasePermission(bolusId: bolusId)
        let frame = try await request(message, expecting: 0xF1, timeout: .seconds(8))
        let status = BolusMessages.parseRelease(frame.cargo)
        link.note("bolus: 释放许可 bolusId=\(bolusId) status=\(status.map(String.init) ?? "解析失败")")
    }

    /// 读泵自己记的最近一针：实际输注量。台账只认这个数。
    public func readLastBolusStatusV2() async throws -> StatusDecoder.LastBolusStatus {
        guard authKey != nil else { throw ProtocolError.notAuthenticated }
        let frame = try await request(PumpMessage.request(characteristic: .currentStatus, opCode: 0xA4),
                                      expecting: 0xA5, timeout: .seconds(8))
        snapshot.rawCargo[0xA5] = frame.cargo
        guard let status = StatusDecoder.lastBolusStatusV2(frame.cargo) else {
            throw ProtocolError.truncated
        }
        return status
    }

    /// 读当前大剂量状态。输注过程中每 2 秒调一次，用来判断已经开始/已经结束。
    public func readCurrentBolus() async throws -> BolusMessages.BolusState {
        let frame = try await request(BolusMessages.currentBolusStatusRequest(), expecting: 0x2D,
                                      timeout: .seconds(8))
        snapshot.rawCargo[0x2D] = frame.cargo
        guard let state = BolusMessages.parseCurrentBolus(frame.cargo) else {
            throw ProtocolError.truncated
        }
        snapshot.currentBolus = state
        return state
    }

    /// 基础率计划（只读）。三段：0x3E 问「当前是哪个计划」→ 0x40 问这个计划的
    /// 名称与段数 → 0x42 逐段问参数。
    ///
    /// 段索引必须落在 `0..<segmentCount`。越界时泵回 ErrorResponse 并主动断开蓝牙，
    /// 所以这里宁可少读几段，也不按下标猜着发。段数上限 16 是兜底：正常计划不会
    /// 超过十几段，读到异常大的值说明解析偏了，继续发只会把链路搞断。
    public func readBasalProfile() async throws -> BasalProfile {
        guard authKey != nil else { throw ProtocolError.notAuthenticated }

        let statusFrame = try await request(ProfileMessages.profileStatusRequest(),
                                            expecting: 0x3F, timeout: .seconds(8))
        snapshot.rawCargo[0x3F] = statusFrame.cargo
        guard let status = ProfileMessages.parseStatus(statusFrame.cargo) else {
            throw ProtocolError.truncated
        }
        guard let idpId = status.activeIdpId else {
            throw ProfileMessages.ProfileError.noActiveProfile
        }

        let settingsFrame = try await request(ProfileMessages.settingsRequest(idpId: idpId),
                                             expecting: 0x41, timeout: .seconds(8))
        snapshot.rawCargo[0x41] = settingsFrame.cargo
        guard let settings = ProfileMessages.parseSettings(settingsFrame.cargo) else {
            throw ProfileMessages.ProfileError.badSettingsCargo
        }

        let count = min(max(settings.segmentCount, 0), 16)
        var segments: [ProfileMessages.Segment] = []
        for index in 0..<count {
            let frame = try await request(ProfileMessages.segmentRequest(idpId: idpId, index: index),
                                          expecting: 0x43, timeout: .seconds(8))
            snapshot.rawCargo[0x43] = frame.cargo
            guard let segment = ProfileMessages.parseSegment(frame.cargo) else {
                throw ProfileMessages.ProfileError.badSegmentCargo
            }
            segments.append(segment)
        }
        // 段按开始时间排序再展示：泵是按索引返回的，索引不等于时钟顺序
        segments.sort { $0.startMinutes < $1.startMinutes }

        let profile = BasalProfile(idpId: idpId,
                                   name: settings.name,
                                   insulinDurationMinutes: settings.insulinDurationMinutes,
                                   maxBolusUnits: settings.maxBolusUnits,
                                   carbEntry: settings.carbEntry,
                                   segments: segments,
                                   activeSegmentIndex: status.activeSegmentIndex)
        snapshot.basalProfileSchedule = profile
        link.note("基础率: 计划「\(settings.name)」idpId=\(idpId) \(segments.count) 段"
                  + " 单次上限 \(settings.maxBolusUnits) U")
        return profile
    }

    // MARK: Control-IQ 监视（只读）

    /// 读泵自带 Control-IQ 的状态。
    ///
    /// 先发 V1（0x68）。V1 是所有带 Control-IQ 的 X2 固件都认的；只有在泵报告
    /// 「正处在运动模式」时才去问 V2（0xB2）拿剩余时间——老固件不认 0xB2，
    /// 会回 Nack，没必要每次刷新都去撞一次。V2 失败就保留 V1 的结果，不抛错。
    public func readControlIQ() async throws -> ControlIQMessages.Info {
        guard authKey != nil else { throw ProtocolError.notAuthenticated }

        let frame = try await request(ControlIQMessages.infoV1Request(),
                                      expecting: 0x69, timeout: .seconds(8))
        snapshot.rawCargo[0x69] = frame.cargo
        guard var info = ControlIQMessages.parseInfoV1(frame.cargo) else {
            throw ControlIQMessages.ControlIQError.badInfoCargo
        }

        if info.userMode == .exercise,
           let v2 = try? await request(ControlIQMessages.infoV2Request(),
                                       expecting: 0xB3, timeout: .seconds(8)),
           let parsed = ControlIQMessages.parseInfoV2(v2.cargo) {
            snapshot.rawCargo[0xB3] = v2.cargo
            info = parsed
        }

        snapshot.controlIQ = info
        link.note("Control-IQ: 闭环\(info.closedLoopEnabled ? "开" : "关") 模式=\(info.userModeText)")
        return info
    }

    /// 读 Control-IQ 的四条睡眠时段（0x6A → 0x6B）。比刷新重，推荐和基础率计划一起按需读。
    public func readSleepSchedule() async throws -> ControlIQMessages.SleepSchedule {
        guard authKey != nil else { throw ProtocolError.notAuthenticated }
        let frame = try await request(ControlIQMessages.sleepScheduleRequest(),
                                      expecting: 0x6B, timeout: .seconds(8))
        snapshot.rawCargo[0x6B] = frame.cargo
        guard let schedule = ControlIQMessages.parseSleepSchedule(frame.cargo) else {
            throw ControlIQMessages.ControlIQError.badSleepCargo
        }
        snapshot.controlIQSleep = schedule
        return schedule
    }

    private func u16(_ b: [UInt8], _ o: Int) -> UInt16 {        UInt16(b[o]) | UInt16(b[o + 1]) << 8
    }

    private func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    private func readApiVersion() async throws -> ApiVersion {
        // cargo 必须为空。pumpX2 的 `ApiVersionRequest()` 无参构造就是 `cargo = EMPTY`，
        // 注释写着「empty cargo is ok」。原来发的是 `[1, 0]` 两字节，泵不认这条请求，
        // 回一条 `0x04` Nack（reason=2）后主动断开——现场日志里
        // 「auth 2: ok -> 4 已收 → TX 0x20 → RX 9B 0x04 → 63ms 后 CBErrorDomain 7」
        // 就是这条路径：认证明明已经成功了，第一条读状态的报文把链路发断。
        let req = PumpMessage.request(characteristic: .currentStatus, opCode: 0x20)
        let frame = try await request(req, expecting: 0x21)
        guard frame.cargo.count >= 4 else { throw ProtocolError.truncated }
        let major = Int(frame.cargo[0]) | Int(frame.cargo[1]) << 8
        let minor = Int(frame.cargo[2]) | Int(frame.cargo[3]) << 8
        let v = ApiVersion(major: major, minor: minor)
        state = .ready(v)
        return v
    }
}
