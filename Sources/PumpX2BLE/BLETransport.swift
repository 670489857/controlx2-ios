#if canImport(CoreBluetooth)
import Foundation
import CoreBluetooth
import PumpX2Kit

/// CoreBluetooth 传输实现。
///
/// 与 Android 侧的差异（必须由上层适配）：
/// - iOS 拿不到 MAC 地址，只能按广播名 + Service UUID 过滤，并持久化 `CBPeripheral.identifier`
/// - 没有常驻后台服务，`bluetooth-central` 后台模式只能延长而非保证连接存活
/// - 写操作必须串行：一个包写完（或确认已入队）再发下一个，否则泵侧会丢包
public final class BLETransport: NSObject, PumpLink {

    public enum TransportError: Error, LocalizedError {
        case poweredOff, unauthorized, notFound, disconnected, timeout, writeFailed
        /// 连上了但没凑齐可写通道。带上计数，把"超时"变成可诊断的信息。
        case notReady(services: Int, characteristics: Int)
        /// 链路没建立起来，或者建立了但不可用。reason 直接面向用户。
        case linkFailed(String)

        public var errorDescription: String? {
            switch self {
            case .poweredOff: return "蓝牙未开启"
            case .unauthorized: return "未获得蓝牙权限"
            case .notFound: return "未找到该设备，请重新扫描"
            case .disconnected: return "设备已断开"
            case .timeout: return "等待设备就绪超时"
            case .writeFailed: return "写入失败"
            case let .notReady(s, c):
                return "已连接，但没找到可用的数据通道（服务 \(s) 个，特征值 \(c) 个）。若服务数为 0，通常是固件版本过旧、没有开放手机控制接口。"
            case let .linkFailed(reason):
                return reason
            }
        }
    }

    /// 链路阶段。iOS 的系统配对弹窗没有 API 可监听，只能由「订阅请求发出后迟迟不回调」
    /// 推断，这个枚举就是把那个推断显式化，让界面能提示用户去点弹窗。
    public enum LinkPhase: Equatable, Sendable {
        case idle
        case connecting
        case discovering
        /// 已发出需要加密的请求，等用户点系统弹窗
        case waitingForPairing
        case ready
        /// 断了但在自动重连。属于可恢复状态，界面应显示进度而不是弹错误框。
        case reconnecting(attempt: Int, reason: String)
        case failed(String)

        public var text: String {
            switch self {
            case .idle: return "未连接"
            case .connecting: return "正在连接泵…"
            case .discovering: return "正在发现服务…"
            case .waitingForPairing: return "等待蓝牙配对，请在 iPhone 弹窗上点「配对」"
            case .ready: return "链路已就绪"
            case let .reconnecting(attempt, reason): return "\(reason)，正在重连 \(attempt)/2…"
            case let .failed(m): return m
            }
        }

        public var isWaitingForUser: Bool {
            if case .waitingForPairing = self { return true }
            return false
        }

        public var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    public struct DiscoveredPump: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let name: String
        public let rssi: Int
        /// 广播包里带 Tandem 服务 UUID，或名字像泵。为 false 时是"其他蓝牙设备"，
        /// 只在用户打开「显示全部设备」时出现，用于区分"蓝牙没工作"和"泵没在广播"。
        public let isPumpCandidate: Bool

        public init(id: UUID, name: String, rssi: Int, isPumpCandidate: Bool = true) {
            self.id = id
            self.name = name
            self.rssi = rssi
            self.isPumpCandidate = isPumpCandidate
        }
    }

    private let queue = DispatchQueue(label: "controlx2.ble", qos: .userInitiated)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var discovered: [UUID: CBPeripheral] = [:]
    private var characteristics: [Characteristic: CBCharacteristic] = [:]
    private var assembler = PacketAssembler()

    private var isReady = false
    private var isConnected = false
    private var serviceCount = 0
    private var characteristicCount = 0

    /// 已提交、尚未回调的订阅请求数。iOS 在等用户点配对弹窗时不会回调，
    /// 所以这个数字 > 0 就等价于「系统正在等用户确认配对」。
    private var pendingSubscribe = 0
    private var subscribedCount = 0
    private var sawNotifiableCharacteristic = false
    private var lastSubscribeError: String?
    private var sawEncryptionError = false

    private var lastConnectedID: UUID?
    private var reconnectAttempts = 0
    private var autoReconnect = false

    /// 授权进行中由上层关掉自动重连。
    ///
    /// 泵的配对码与当次连接绑定：链路一断，屏幕上那个码基本就作废了。若这里静默重连，
    /// 界面会停在配对页、用户以为还在等回包，实际上重连后泵已经换了一个码——
    /// 于是「输对了码却永远卡在密钥确认」。宁可直接报错让用户重新读码。
    public func setAutoReconnect(_ on: Bool) {
        queue.async { self.autoReconnect = on }
    }

    public private(set) var phase: LinkPhase = .idle

    /// 收发记录。排障用，正常路径不读它。
    public let trace = ProtocolTrace()
    private var pendingWrites: [PendingWrite] = []
    private var currentWrite: CheckedContinuation<Void, Error>?
    private var isWriting = false

    private let frameContinuation: AsyncStream<AssembledFrame>.Continuation
    public let frames: AsyncStream<AssembledFrame>

    /// 发现泵（扫描期间可用）
    public var onDiscover: ((DiscoveredPump) -> Void)?
    public var onStateChange: ((CBManagerState) -> Void)?
    public var onDisconnect: (() -> Void)?
    /// 链路阶段变化。界面据此提示「去点系统配对弹窗」，而不是干等一个 timeout。
    public var onPhase: ((LinkPhase) -> Void)?

    public override init() {
        var c: AsyncStream<AssembledFrame>.Continuation!
        frames = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { c = $0 }
        frameContinuation = c
        super.init()
        central = CBCentralManager(delegate: self, queue: queue,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    deinit {
        frameContinuation.finish()
    }

    /// 是否把非泵设备也报给上层
    private var includeNonPumps = false

    // MARK: 扫描与连接

    /// 开始扫描。
    ///
    /// 刻意不按服务 UUID 过滤：泵的广播包里不一定带 `FDFB`，按它过滤的后果是
    /// "明明泵就在旁边，列表里一个都没有"，而且看不出是权限问题还是泵没广播。
    /// 这里改成全量扫描 + 回调里按 UUID 和广播名双重分类，
    /// 至少能区分"扫到了 12 个设备但没有泵"和"一个都没扫到"。
    public func startScan(includeNonPumps: Bool = false) {
        queue.async {
            guard self.central.state == .poweredOn else { return }
            self.includeNonPumps = includeNonPumps
            // allowDuplicates 必须为 true：iOS 首次回调常常拿不到 LocalName，
            // 名字要等 scan response 补上。只报一次的话会一直显示 "Tandem"。
            self.central.scanForPeripherals(withServices: nil,
                                            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    public func stopScan() {
        queue.async { self.central.stopScan() }
    }

    public func connect(_ id: UUID) {
        queue.async {
            guard let p = self.discovered[id]
                ?? self.central.retrievePeripherals(withIdentifiers: [id]).first else {
                self.setPhase(.failed("找不到这台设备，请重新扫描"))
                return
            }
            self.autoReconnect = true
            self.lastConnectedID = id
            self.resetLinkState()
            self.peripheral = p
            p.delegate = self
            self.setPhase(.connecting)
            self.central.connect(p, options: nil)
        }
    }

    public func disconnect() {
        queue.async {
            self.autoReconnect = false
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            self.resetConnectionState()
            self.setPhase(.idle)
        }
    }

    private func setPhase(_ p: LinkPhase) {
        guard phase != p else { return }
        phase = p
        trace.add(.note, "phase: \(p.text)")
        onPhase?(p)
    }

    /// 只清链路状态，保留设备标识与重连意图
    private func resetLinkState() {
        characteristics.removeAll()
        isReady = false
        isConnected = false
        serviceCount = 0
        characteristicCount = 0
        pendingSubscribe = 0
        subscribedCount = 0
        sawNotifiableCharacteristic = false
        lastSubscribeError = nil
        sawEncryptionError = false
    }

    private func resetConnectionState() {
        peripheral = nil
        resetLinkState()
        isWriting = false
        let waiting = pendingWrites
        pendingWrites.removeAll()
        for w in waiting { w.cont.resume(throwing: TransportError.disconnected) }
        if let c = currentWrite { c.resume(throwing: TransportError.disconnected) }
        currentWrite = nil
    }

    public func updateAuthenticationKey(_ key: [UInt8]?) {
        queue.async { self.assembler.authKey = key }
    }

    /// 供上层往诊断日志里写一行。故障排查最缺的就是「谁在哪一步报了什么」，
    /// 而这行信息只有上层知道，transport 自己写不出来。
    public func log(_ note: String) {
        trace.add(.note, note)
    }

    /// PumpLink 要求：把会话层的事件也写进同一份日志
    public func note(_ text: String) {
        trace.add(.note, text)
    }

    /// 轮询等待链路可用。
    ///
    /// 默认给 45 秒：iOS 的蓝牙配对弹窗需要用户手动点，等 8 秒必然超时，
    /// 而超时后界面报"配对失败"，用户会误以为是配对码错了。
    private func waitUntilReady(timeout: Duration = .seconds(45)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let (ready, phase) = queue.sync { (self.isReady, self.phase) }
            if ready { return }
            if case let .failed(reason) = phase {
                throw TransportError.linkFailed(reason)
            }
            try await Task.sleep(for: .milliseconds(80))
        }
        let (connected, s, c, phase) = queue.sync {
            (self.isConnected, self.serviceCount, self.characteristicCount, self.phase)
        }
        if phase.isWaitingForUser {
            throw TransportError.linkFailed("蓝牙配对没有完成：系统弹窗上没有点「配对」，或点了取消")
        }
        // 还没连上和服务发现了但没特征值，是两种完全不同的故障，不能共用一条文案
        if !connected { throw TransportError.timeout }
        throw TransportError.notReady(services: s, characteristics: c)
    }

    /// 供上层在进入配对界面之前显式确认链路可用。
    /// 不这样做的话，连接失败时界面会停在"输入配对码"，用户输完才看到超时。
    public func waitReady(timeout: Duration = .seconds(45)) async throws {
        try await waitUntilReady(timeout: timeout)
    }

    // MARK: 写入

    public func write(_ packets: [[UInt8]], to characteristic: Characteristic) async throws {
        // 一旦断开就快速失败：这里再等 45 秒只会让用户对着转圈发呆
        try await waitUntilReady(timeout: .seconds(5))
        for (index, packet) in packets.enumerated() {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                queue.async {
                    self.pendingWrites.append(PendingWrite(data: packet,
                                                           characteristic: characteristic,
                                                           // 只有首片带 opCode，续片的第三个字节是载荷
                                                           isFirst: index == 0,
                                                           cont: cont))
                    self.drain()
                }
            }
        }
    }

    private struct PendingWrite {
        let data: [UInt8]
        let characteristic: Characteristic
        let isFirst: Bool
        let cont: CheckedContinuation<Void, Error>
    }

    /// 串行出队：一次只发一个包，收到 `didWriteValueFor`（或已交给系统）后再发下一个。
    private func drain() {
        guard !isWriting, let p = peripheral, !pendingWrites.isEmpty else { return }
        let item = pendingWrites.removeFirst()
        guard let ch = characteristics[item.characteristic] else {
            item.cont.resume(throwing: TransportError.notFound)
            return
        }
        isWriting = true
        currentWrite = item.cont
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        // 包布局是 [remaining, txId] + 帧体，帧体前三字节是 [opCode, txId, len]。
        // 只有首片的第三字节才是 opCode；续片那是载荷，按 opCode 打印会显示成
        // 0x71、0x0f 这类假值，排障时极易被当成「发错了命令」。
        let head = item.isFirst && item.data.count > 2
            ? String(format: "0x%02x ", item.data[2]) : ""
        trace.addPacket(.tx, item.data,
                        note: "\(head)r=\(item.data.first ?? 0) \(item.characteristic.rawValue.prefix(8)) \(type == .withResponse ? "resp" : "noresp")")
        p.writeValue(Data(item.data), for: ch, type: type)
        if type == .withoutResponse {
            // 无响应写没有系统回调，交给系统即视为完成
            isWriting = false
            currentWrite = nil
            item.cont.resume()
            drain()
        }
    }
}

extension BLETransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onStateChange?(central.state)
        if central.state != .poweredOn { stopScan() }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        // 名字可能来自广播、scan response 或缓存，三者优先级依次降低
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? "(未命名)"

        // 服务 UUID 可能出现在广播包，也可能只在 scan response 的 overflow 列表里
        var services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        services += (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
        let hasPumpService = services.contains {
            let s = $0.uuidString.uppercased()
            return s == ServiceUUID.pump.uppercased() || s == ServiceUUID.pumpShort
        }

        // 兜底：泵的广播名形如 "tslim X2 12345678"、"t:slim X2"、"Tandem Mobi"
        let lower = name.lowercased()
        let nameLooksLikePump = ["tslim", "t:slim", "tandem", "mobi", "x2"].contains {
            lower.contains($0)
        }

        let isPump = hasPumpService || nameLooksLikePump

        discovered[peripheral.identifier] = peripheral
        guard isPump || includeNonPumps else { return }

        onDiscover?(DiscoveredPump(id: peripheral.identifier, name: name,
                                   rssi: RSSI.intValue, isPumpCandidate: isPump))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        isConnected = true
        reconnectAttempts = 0
        setPhase(.discovering)
        // 不指定服务列表：留空才会枚举全部。指定错一个 UUID 的代价是
        // "连接成功但没有任何特征值"，这条路径没有可观测的报错，只有超时。
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        handleLinkLoss(reason: error.map { "连接失败：\(describe($0))" } ?? "连接失败")
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // 原始码要留下：同一个 "泵主动断开" 文案可能对应泵删了配对信息、
        // 连接超限、或单纯的对端关闭，三者的处理方式完全不同。
        if let ns = error as NSError? {
            trace.add(.note, "disconnect code: \(ns.domain) \(ns.code)")
        } else {
            trace.add(.note, "disconnect: no error (对端关闭或系统回收)")
        }
        let reason: String
        if let error {
            reason = "连接中断：\(describe(error))"
        } else if sawEncryptionError || phase.isWaitingForUser {
            // iOS 在 SMP 未完成时会直接断开且 error 为 nil，这是最容易误判成"配对码错"的一条路径
            reason = "蓝牙配对没有完成，泵断开了连接"
        } else {
            reason = "连接已断开"
        }
        handleLinkLoss(reason: reason)
    }

    /// 链路丢失的统一出口：先决定能否自动重连，再决定报什么。
    ///
    /// iOS 在系统配对完成后常会断开一次再重连成功，所以这里必须重连，
    /// 否则第一次配对永远走不过去。
    private func handleLinkLoss(reason: String) {
        let id = lastConnectedID
        trace.add(.note, "link lost: \(reason)")
        resetConnectionState()
        onDisconnect?()

        guard autoReconnect, let id, reconnectAttempts < 2 else {
            let hint = autoReconnect
                ? "\(reason)。若反复失败：iOS 设置 → 蓝牙 → 忽略「tslim X2」，泵上删除已配对设备，再重试。"
                : reason
            setPhase(.failed(hint))
            return
        }
        reconnectAttempts += 1
        let attempt = reconnectAttempts
        setPhase(.reconnecting(attempt: attempt, reason: reason))
        queue.asyncAfter(deadline: .now() + 1.5) {
            guard self.autoReconnect, self.lastConnectedID == id else { return }
            self.connect(id)
        }
    }

    /// 把 CoreBluetooth 的错误码翻成人能读的原因，尤其是加密相关的几条。
    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == CBErrorDomain, let code = CBError.Code(rawValue: ns.code) {
            switch code {
            case .peerRemovedPairingInformation: return "泵上没有保留这台手机的配对信息"
            case .connectionTimeout: return "连接超时"
            case .peripheralDisconnected: return "泵主动断开"
            case .connectionLimitReached: return "泵已连满（另一台设备正占着）"
            default: break
            }
        }
        if ns.domain == CBATTErrorDomain, let code = CBATTError.Code(rawValue: ns.code) {
            if code == .insufficientEncryption { return "链路未加密（系统配对未完成）" }
            if code == .insufficientAuthentication { return "链路未认证（系统配对未完成）" }
        }
        return error.localizedDescription
    }
}

extension BLETransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        serviceCount = services.count
        if services.isEmpty {
            setPhase(.failed("泵没有暴露任何服务，通常是固件版本过旧、未开放手机控制接口"))
            return
        }
        for s in services {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        characteristicCount += chars.count
        for ch in chars {
            guard let known = Characteristic(rawValue: ch.uuid.uuidString.uppercased()) else { continue }
            characteristics[known] = ch
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                // 这一句就是系统配对弹窗的触发点：订阅需要加密的特征值时，
                // iOS 自己弹「蓝牙配对请求」，我们无法预先控制，只能等回调。
                sawNotifiableCharacteristic = true
                pendingSubscribe += 1
                peripheral.setNotifyValue(true, for: ch)
            }
        }
        evaluateReadiness()
    }

    /// 订阅结果即加密结果。回调 nil 才代表 SMP 完成、链路可用。
    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        pendingSubscribe = max(0, pendingSubscribe - 1)
        if let error {
            lastSubscribeError = describe(error)
        } else {
            subscribedCount += 1
        }
        evaluateReadiness()
    }

    /// 就绪判定：拿到 authorization 特征，且所有订阅请求都有回调。
    /// 订阅全失败说明加密没建立，此时不能放行——否则后面每个写都会以失败告终，
    /// 用户看到的却是"配对码错误"。
    private func evaluateReadiness() {
        guard characteristics[.authorization] != nil || characteristics[.currentStatus] != nil else { return }
        guard pendingSubscribe == 0 else {
            setPhase(.waitingForPairing)
            return
        }
        if sawNotifiableCharacteristic && subscribedCount == 0 {
            let reason = lastSubscribeError ?? "订阅失败"
            setPhase(.failed("蓝牙配对未完成（\(reason)）"))
            return
        }
        isReady = true
        setPhase(.ready)
        drain()
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        let bytes = [UInt8](data)
        trace.addPacket(.rx, bytes, note: String(characteristic.uuid.uuidString.prefix(8)))
        queue.async {
            do {
                if let frame = try self.assembler.ingest(bytes) {
                    self.frameContinuation.yield(frame)
                }
            } catch {
                // 坏包仍要丢弃（重试会打乱事务号），但**必须留下证据**。
                // 原来是空 catch：0x21 若因长度/CRC 不匹配被丢掉，日志里只剩一行
                // RX，随后静默等满 8 秒超时，现场看起来就是「泵回了但我们没反应」。
                self.trace.add(.note, "收包丢弃 \(bytes.count)B r=\(bytes.first ?? 0)：\(error)")
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let cont = currentWrite
        currentWrite = nil
        isWriting = false
        if let error {
            // 写操作也可能成为加密的触发点（订阅没过但读写在先时）。这类失败不是
            // 协议错误，把它标出来，界面才不会引导用户去怀疑配对码。
            let ns = error as NSError
            trace.add(.note, "write failed: \(describe(error)) [\(ns.domain) \(ns.code)]")
            if ns.domain == CBATTErrorDomain,
               let code = CBATTError.Code(rawValue: ns.code),
               code == .insufficientEncryption || code == .insufficientAuthentication {
                sawEncryptionError = true
                isReady = false
                setPhase(.waitingForPairing)
            }
            cont?.resume(throwing: error)
        } else {
            cont?.resume()
        }
        drain()
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        drain()
    }
}
#endif
