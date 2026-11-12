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

        public var errorDescription: String? {
            switch self {
            case .poweredOff: return "蓝牙未开启"
            case .unauthorized: return "未获得蓝牙权限"
            case .notFound: return "未找到该设备，请重新扫描"
            case .disconnected: return "设备已断开"
            case .timeout: return "等待设备就绪超时"
            case .writeFailed: return "写入失败"
            }
        }
    }

    public struct DiscoveredPump: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let name: String
        public let rssi: Int
    }

    private let queue = DispatchQueue(label: "controlx2.ble", qos: .userInitiated)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var discovered: [UUID: CBPeripheral] = [:]
    private var characteristics: [Characteristic: CBCharacteristic] = [:]
    private var assembler = PacketAssembler()

    private var isReady = false
    private var pendingWrites: [(data: [UInt8], characteristic: Characteristic,
                                 cont: CheckedContinuation<Void, Error>)] = []
    private var currentWrite: CheckedContinuation<Void, Error>?
    private var isWriting = false

    private let frameContinuation: AsyncStream<AssembledFrame>.Continuation
    public let frames: AsyncStream<AssembledFrame>

    /// 发现泵（扫描期间可用）
    public var onDiscover: ((DiscoveredPump) -> Void)?
    public var onStateChange: ((CBManagerState) -> Void)?
    public var onDisconnect: (() -> Void)?

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

    // MARK: 扫描与连接

    public func startScan() {
        queue.async {
            guard self.central.state == .poweredOn else { return }
            let service = CBUUID(string: ServiceUUID.pump)
            self.central.scanForPeripherals(withServices: [service],
                                            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    public func stopScan() {
        queue.async { self.central.stopScan() }
    }

    public func connect(_ id: UUID) {
        queue.async {
            guard let p = self.discovered[id]
                ?? self.central.retrievePeripherals(withIdentifiers: [id]).first else { return }
            self.isReady = false
            self.peripheral = p
            p.delegate = self
            self.central.connect(p, options: nil)
        }
    }

    public func disconnect() {
        queue.async {
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            self.resetConnectionState()
        }
    }

    private func resetConnectionState() {
        peripheral = nil
        characteristics.removeAll()
        isReady = false
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

    /// 轮询等待服务发现完成。连接后特征值可能还没齐，此时写入会失败。
    private func waitUntilReady(timeout: Duration = .seconds(8)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let ready = queue.sync { self.isReady }
            if ready { return }
            try await Task.sleep(for: .milliseconds(80))
        }
        throw TransportError.timeout
    }

    // MARK: 写入

    public func write(_ packets: [[UInt8]], to characteristic: Characteristic) async throws {
        try await waitUntilReady()
        for packet in packets {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                queue.async {
                    self.pendingWrites.append((packet, characteristic, cont))
                    self.drain()
                }
            }
        }
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
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "Tandem"
        discovered[peripheral.identifier] = peripheral
        onDiscover?(DiscoveredPump(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: ServiceUUID.pump)])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        resetConnectionState()
        onDisconnect?()
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        resetConnectionState()
        onDisconnect?()
    }
}

extension BLETransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            guard let known = Characteristic(rawValue: ch.uuid.uuidString.uppercased()) else { continue }
            characteristics[known] = ch
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: ch)
            }
        }
        // currentStatus 与 authorization 都出现过就算就绪；缺一个也放行，让上层超时报错而不是永久卡住
        if characteristics[.currentStatus] != nil {
            isReady = true
            drain()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        let bytes = [UInt8](data)
        queue.async {
            do {
                if let frame = try self.assembler.ingest(bytes) {
                    self.frameContinuation.yield(frame)
                }
            } catch {
                // 坏包丢弃，由上层请求超时兜底；不在此处重试，避免打乱事务 ID
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let cont = currentWrite
        currentWrite = nil
        isWriting = false
        if let error {
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
