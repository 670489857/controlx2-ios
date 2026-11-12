import Foundation

/// 泵会话：事务 ID 管理、请求/响应配对、配对流程、只读状态刷新。
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

    private let link: PumpLink
    private var txId: UInt8 = 0
    private var authKey: [UInt8]?
    private var pending: [UInt8: CheckedContinuation<AssembledFrame, Error>] = [:]
    private var pumpTimeSinceReset: UInt32 = 0
    private var readerTask: Task<Void, Never>?

    public private(set) var state: SessionState = .idle
    public private(set) var snapshot = Snapshot()

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
        txId = txId &+ 1
        return txId
    }

    private func request(_ message: PumpMessage, expecting opCode: UInt8,
                         timeout: Duration = .seconds(8)) async throws -> AssembledFrame {
        let id = nextTxId()
        let packets = try Packetize.encode(message, txId: id, authKey: authKey ?? [],
                                           pumpTimeSinceReset: pumpTimeSinceReset)
        try await link.write(packets, to: message.characteristic)
        return try await withCheckedThrowingContinuation { cont in
            if pending[opCode] != nil {
                cont.resume(throwing: ProtocolError.truncated)
                return
            }
            pending[opCode] = cont
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                if let c = await self?.takePending(opCode) {
                    c.resume(throwing: ProtocolError.truncated)
                }
            }
        }
    }

    private func takePending(_ opCode: UInt8) -> CheckedContinuation<AssembledFrame, Error>? {
        pending.removeValue(forKey: opCode)
    }

    // MARK: 配对

    /// 6 位泵配对码。成功后 `authKey` 生效，后续签名报文可校验。
    public func pair(code: String, progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws {
        state = .pairing(progress: 0)
        var completed = false
        defer { if !completed, case .pairing = state { state = .failed("配对未完成") } }

        let challenge = (0..<8).map { _ in UInt8.random(in: 0...255) }
        let central = try await request(AuthMessages.centralChallengeRequest(challenge: challenge),
                                        expecting: AuthMessages.centralChallengeResponseOp)
        let parsed = try AuthMessages.parseCentralChallengeResponse(central.cargo)

        let challengeReq = AuthMessages.pumpChallengeRequest(hmacKey: parsed.hmacKey)
        let challengeResp = try await request(challengeReq,
                                              expecting: AuthMessages.pumpChallengeResponseOp)
        let (_, ok) = try AuthMessages.parsePumpChallengeResponse(challengeResp.cargo)
        guard ok else { throw JPAKEAuth.AuthError.rejected }
        progress(10)

        let auth = try JPAKEAuth(pairingCode: code)
        while let next = try auth.nextRequest() {
            let expected = next.opCode &+ 1
            let frame = try await request(next, expecting: expected)
            try auth.process(opCode: frame.opCode, cargo: frame.cargo)
            progress(min(90, auth.step.rawValue * 6))
        }
        guard auth.isComplete, let key = auth.authenticationKey else {
            throw JPAKEAuth.AuthError.badConfirmation
        }
        authKey = key
        link.updateAuthenticationKey(key)
        completed = true
        progress(100)
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
