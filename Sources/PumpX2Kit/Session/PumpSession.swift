import Foundation

/// 泵会话：事务 ID 管理、请求/响应配对、配对流程、只读状态刷新。
///
/// 配对成功后 `credentials` 会带上派生密钥；把它持久化（App 侧用 Keychain），
/// 下次连接时调用 `resume(with:)` 即可跳过完整 JPAKE，不必再在泵上输配对码。
/// 目前只实现「配对 + 读取」；给药指令（bolus / 基础率）在硬件验证通过前不启用。
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
        public var pumpTimeSinceReset: UInt64?
        /// 最近一次 CGM 读数（mg/dL），来自 CurrentEGVGuiData
        public var glucoseMgdl: Int?
        /// 趋势方向原始码（0–9），与泵屏幕箭头对应
        public var glucoseTrend: Int?
        /// 活性胰岛素（U）
        public var iobUnits: Double?
        public var batteryPercent: Int?
        /// 当前基础率（U/h）
        public var basalRate: Double?
        public var lastUpdated: Date?

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
    /// 仅在完整配对成功后才有值；持久化它即可免去下次输入配对码
    public private(set) var credentials: PumpCredentials?

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

        // 药筒余量（InsulinStatus，0x24 → 0x25）：前 2 字节是 0.001 U 为单位的 i16
        let insulin = PumpMessage.request(characteristic: .currentStatus, opCode: 0x24)
        if let frame = try? await request(insulin, expecting: 0x25), frame.cargo.count >= 4 {
            let raw = Int16(bitPattern: UInt16(frame.cargo[0]) | UInt16(frame.cargo[1]) << 8)
            snapshot.insulinUnits = Double(raw) / 1000.0
            snapshot.insulinIsEstimate = frame.cargo[2] != 0
        }

        // 血糖（CurrentEGVGuiData，0x22 → 0x23）：u32 时间戳 + i16 mg/dL + 状态 + i8 趋势
        let egv = PumpMessage.request(characteristic: .currentStatus, opCode: 0x22)
        if let frame = try? await request(egv, expecting: 0x23), frame.cargo.count >= 8 {
            let mgdl = Int16(bitPattern: u16(frame.cargo, 4))
            snapshot.glucoseMgdl = mgdl > 0 ? Int(mgdl) : nil
            snapshot.glucoseTrend = Int(Int8(bitPattern: frame.cargo[7]))
        }

        // 活性胰岛素（ControlIQIOB，0x6C → 0x6D）：mudaliarIOB 为 0.001 U
        let iob = PumpMessage.request(characteristic: .currentStatus, opCode: 0x6C)
        if let frame = try? await request(iob, expecting: 0x6D), frame.cargo.count >= 17 {
            snapshot.iobUnits = Double(u32(frame.cargo, 0)) / 1000.0
        }

        // 电量（CurrentBatteryV1，0x34 → 0x35）：第 2 字节为泵屏幕显示的百分比
        let battery = PumpMessage.request(characteristic: .currentStatus, opCode: 0x34)
        if let frame = try? await request(battery, expecting: 0x35), frame.cargo.count >= 2 {
            snapshot.batteryPercent = Int(frame.cargo[1])
        }

        // 基础率（CurrentBasalStatus，0x28 → 0x29）：当前基础率 u32 @4，单位 0.001 U/h
        let basal = PumpMessage.request(characteristic: .currentStatus, opCode: 0x28)
        if let frame = try? await request(basal, expecting: 0x29), frame.cargo.count >= 9 {
            snapshot.basalRate = Double(u32(frame.cargo, 4)) / 1000.0
        }

        // 泵计时（TimeSinceReset，0x36 → 0x37）：currentTime(4) + sinceReset(4)
        let time = PumpMessage.request(characteristic: .currentStatus, opCode: 0x36)
        if let frame = try? await request(time, expecting: 0x37), frame.cargo.count >= 8 {
            let sinceReset = u32(frame.cargo, 4)
            pumpTimeSinceReset = sinceReset
            snapshot.pumpTimeSinceReset = UInt64(sinceReset)
        }
        snapshot.lastUpdated = Date()
    }

    private func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | UInt16(b[o + 1]) << 8
    }

    private func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    private func readApiVersion() async throws -> ApiVersion {
        let req = PumpMessage.request(characteristic: .currentStatus, opCode: 0x20, cargo: [1, 0])
        let frame = try await request(req, expecting: 0x21)
        guard frame.cargo.count >= 4 else { throw ProtocolError.truncated }
        let major = Int(frame.cargo[0]) | Int(frame.cargo[1]) << 8
        let minor = Int(frame.cargo[2]) | Int(frame.cargo[3]) << 8
        let v = ApiVersion(major: major, minor: minor)
        state = .ready(v)
        return v
    }
}
