import Foundation

/// 认证阶段的消息构造与解析（opcode 16-41，AUTHORIZATION 特征值）。
public enum AuthMessages {
    public static let centralChallengeRequestOp: UInt8 = 0x10
    public static let centralChallengeResponseOp: UInt8 = 0x11
    public static let pumpChallengeRequestOp: UInt8 = 0x12
    public static let pumpChallengeResponseOp: UInt8 = 0x13

    public static func centralChallengeRequest(appInstanceId: UInt16 = 1,
                                              challenge: [UInt8]) -> PumpMessage {
        precondition(challenge.count == 8)
        var cargo = AppInstance.bytes(appInstanceId)
        cargo += challenge
        return PumpMessage.request(characteristic: .authorization,
                                   opCode: centralChallengeRequestOp, cargo: cargo)
    }

    public struct CentralChallengeResult {
        public let appInstanceId: UInt16
        public let hash: [UInt8]
        public let hmacKey: [UInt8]
    }

    public static func parseCentralChallengeResponse(_ cargo: [UInt8]) throws -> CentralChallengeResult {
        guard cargo.count >= 30 else { throw ProtocolError.truncated }
        return CentralChallengeResult(
            appInstanceId: AppInstance.value(cargo),
            hash: Array(cargo[2..<22]),
            hmacKey: Array(cargo[22..<30])
        )
    }

    /// 泵校对配对码：HMAC-SHA1(key: hmacKey, message: empty)
    public static func pumpChallengeRequest(appInstanceId: UInt16 = 1,
                                            hmacKey: [UInt8]) -> PumpMessage {
        var cargo = AppInstance.bytes(appInstanceId)
        cargo += HMAC.sha1(key: hmacKey, message: [])
        return PumpMessage.request(characteristic: .authorization,
                                   opCode: pumpChallengeRequestOp, cargo: cargo)
    }

    public static func parsePumpChallengeResponse(_ cargo: [UInt8]) throws -> (UInt16, Bool) {
        guard cargo.count >= 3 else { throw ProtocolError.truncated }
        return (AppInstance.value(cargo), cargo[2] == 1)
    }

    // JPAKE 各轮的请求体都是 2 字节 appInstanceId + 原始载荷
    public static func jpake(_ opCode: UInt8, payload: [UInt8],
                             appInstanceId: UInt16 = 1) -> PumpMessage {
        PumpMessage.request(characteristic: .authorization, opCode: opCode,
                            cargo: AppInstance.bytes(appInstanceId) + payload)
    }

    public static func payload(_ cargo: [UInt8]) throws -> [UInt8] {
        guard cargo.count >= 2 else { throw ProtocolError.truncated }
        return Array(cargo.dropFirst(2))
    }

    public static func nonceAndDigest(_ cargo: [UInt8]) throws -> (nonce: [UInt8], digest: [UInt8]) {
        guard cargo.count >= 50 else { throw ProtocolError.truncated }
        return (Array(cargo[2..<10]), Array(cargo[18..<50]))
    }
}

enum AppInstance {
    static func bytes(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func value(_ cargo: [UInt8]) -> UInt16 {
        UInt16(cargo[0]) | UInt16(cargo[1]) << 8
    }
}

/// 配对状态机，对应 pumpX2 `JpakeAuthBuilder`（客户端角色）。
public final class JPAKEAuth {
    public enum Step: Int, Sendable {
        case bootstrapInitial = 0
        case round1aSent, round1aReceived, round1bSent, round1bReceived
        case round2Sent, round2Received
        case confirmInitial, confirm3Sent, confirm3Received, confirm4Sent, confirm4Received
        case complete, invalid
    }

    public enum AuthError: Error { case invalidPairingCode, invalidState, rejected, badConfirmation }

    public private(set) var step: Step
    public private(set) var derivedSecret: [UInt8]?
    public private(set) var authenticationKey: [UInt8]?

    public let appInstanceId: UInt16
    private let pairingCode: String
    private let jpake: ECJPAKE
    private let random: RandomSource

    private var clientRound1: [UInt8] = []
    private var serverRound1: [UInt8] = []
    private var clientRound2: [UInt8] = []
    private var serverNonce3: [UInt8] = []
    private var serverNonce4: [UInt8] = []
    private var serverDigest4: [UInt8] = []
    private var clientNonce4: [UInt8] = []

    public init(pairingCode: String, derivedSecret: [UInt8]? = nil,
                appInstanceId: UInt16 = 1,
                random: RandomSource = SystemRandomSource()) throws {
        let normalized = JPAKEAuth.normalize(pairingCode)
        // t:slim X2 固件 < v7.7 为 16 位字母数字；v7.7+ 与 Mobi 为 6 位数字
        guard normalized.count == 6 || normalized.count == 16 else {
            throw AuthError.invalidPairingCode
        }
        self.appInstanceId = appInstanceId
        self.pairingCode = normalized
        self.random = random
        self.derivedSecret = derivedSecret
        self.jpake = ECJPAKE(role: .client,
                             secret: JPAKEAuth.codeToBytes(normalized),
                             random: random)
        self.step = (derivedSecret?.isEmpty ?? true) ? .bootstrapInitial : .confirmInitial
    }

    /// 快速重连：跳过 1a/1b/2，用已保存的派生密钥直接做第 3、4 步确认。
    /// 此时 JPAKE 计算不参与，pairingCode 为空串。
    public init(derivedSecret: [UInt8], appInstanceId: UInt16 = 1,
                random: RandomSource = SystemRandomSource()) throws {
        guard derivedSecret.count == 32 else { throw AuthError.invalidState }
        self.appInstanceId = appInstanceId
        self.pairingCode = ""
        self.random = random
        self.derivedSecret = derivedSecret
        // confirm 流程不会调用 jpake，此处的 secret 内容无意义
        self.jpake = ECJPAKE(role: .client,
                             secret: [UInt8](repeating: 0, count: 6),
                             random: random)
        self.step = .confirmInitial
    }

    /// 去掉分隔符与空白，保留字母数字（16 位码在泵上常带 `-` 分组）
    public static func normalize(_ code: String) -> String {
        code.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// 与 pumpX2 `JpakeAuthBuilder.charCode` 保持一致：
    /// 只有 '0'–'9' 映射为 ASCII 48–57，字母等其他字符返回 `(byte) -1`，即 0xFF。
    /// 若直接用 UTF-8 编码，含字母的 16 位码会算出完全不同的密钥。
    public static func codeToBytes(_ code: String) -> [UInt8] {
        code.map { ch in
            if let ascii = ch.asciiValue, ascii >= 48, ascii <= 57 { return ascii }
            return 0xFF
        }
    }

    /// 发送下一帧；返回 nil 表示流程已结束（成功或失败）
    public func nextRequest() throws -> PumpMessage? {
        switch step {
        case .bootstrapInitial:
            clientRound1 = try jpake.round1()
            step = .round1aSent
            return AuthMessages.jpake(0x20, payload: Array(clientRound1[0..<165]))

        case .round1aReceived:
            step = .round1bSent
            return AuthMessages.jpake(0x22, payload: Array(clientRound1[165..<330]))

        case .round1bReceived:
            clientRound2 = try jpake.round2()
            step = .round2Sent
            return AuthMessages.jpake(0x24, payload: clientRound2)

        case .round2Received:
            derivedSecret = try jpake.deriveSecret()
            authenticationKey = derivedSecret
            step = .confirm3Sent
            return AuthMessages.jpake(0x26, payload: [])

        case .confirmInitial, .confirm3Received:
            if step == .confirmInitial {
                step = .confirm3Sent
                return AuthMessages.jpake(0x26, payload: [])
            }
            // 第 4 步：nonce4 + reserved + HMAC(nonce4, HKDF(nonce3, secret))
            guard let secret = derivedSecret else { throw AuthError.invalidState }
            clientNonce4 = random.bytes(8)
            let digest = HMAC.sha256(key: HKDF.build(nonce: serverNonce3, keyMaterial: secret),
                                     message: clientNonce4)
            step = .confirm4Sent
            let cargo = AppInstance.bytes(appInstanceId) + clientNonce4 + [UInt8](repeating: 0, count: 8) + digest
            return AuthMessages.jpake(0x28, payload: Array(cargo.dropFirst(2)))

        case .confirm4Received:
            guard let secret = derivedSecret, serverDigest4.count == 32 else { throw AuthError.invalidState }
            let expected = HMAC.sha256(key: HKDF.build(nonce: serverNonce3, keyMaterial: secret),
                                       message: serverNonce4)
            if ByteUtil.constantTimeEquals(expected, serverDigest4) {
                step = .complete
            } else {
                step = .invalid
                throw AuthError.badConfirmation
            }
            return nil

        default:
            return nil
        }
    }

    public func process(opCode: UInt8, cargo: [UInt8]) throws {
        switch opCode {
        case 0x21: // Jpake1aResponse（第 1 轮前半段）
            serverRound1 = try AuthMessages.payload(cargo)
            step = .round1aReceived

        case 0x23: // Jpake1bResponse（第 1 轮后半段）
            serverRound1 += try AuthMessages.payload(cargo)
            guard serverRound1.count >= 330 else { throw ProtocolError.truncated }
            try jpake.readRound1(Array(serverRound1[0..<330]))
            step = .round1bReceived

        case 0x25: // Jpake2Response
            let r2 = try AuthMessages.payload(cargo)
            try jpake.readRound2(r2)
            step = .round2Received

        case 0x27: // Jpake3SessionKeyResponse
            guard cargo.count >= 18 else { throw ProtocolError.truncated }
            serverNonce3 = Array(cargo[2..<10])
            step = .confirm3Received

        case 0x29: // Jpake4KeyConfirmationResponse
            let (nonce, digest) = try AuthMessages.nonceAndDigest(cargo)
            serverNonce4 = nonce
            serverDigest4 = digest
            step = .confirm4Received

        default:
            break
        }
    }

    public func processCentralChallenge(_ cargo: [UInt8]) throws -> PumpMessage {
        let result = try AuthMessages.parseCentralChallengeResponse(cargo)
        return AuthMessages.pumpChallengeRequest(hmacKey: result.hmacKey)
    }

    public var isComplete: Bool { step == .complete }
}
