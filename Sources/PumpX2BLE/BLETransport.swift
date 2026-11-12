#if canImport(CoreBluetooth)
import Foundation
import CoreBluetooth
import PumpX2Kit

/// CoreBluetooth 传输实现。
///
/// 与 Android 侧的差异（必须由上层适配）：
/// - iOS 拿不到 MAC 地址，只能按广播名 + Service UUID 过滤，并持久化 `CBPeripheral.identifier`
/// - 没有常驻后台服务，`bluetooth-central` 后台模式只能延长而非保证连接存活
/// - 写操作需要串行化：`canSendWriteWithoutResponse` 为 false 时必须等待 `peripheralIsReady`
public final class BLETransport: NSObject, PumpLink {

    public enum TransportError: Error {
        case poweredOff, unauthorized, notFound, disconnected, timeout, writeFailed
    }

    public struct DiscoveredPump: Identifiable, Hashable {
        public let id: UUID
        public let name: String
        public let rssi: Int
    }

    private let queue = DispatchQueue(label: "controlx2.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristics: [Characteristic: CBCharacteristic] = [:]
    private var assembler = PacketAssembler()
    private var pendingWrites: [([UInt8], Characteristic)] = []
    private var writeContinuations: [CheckedContinuation<Void, Error>] = []

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
            guard let p = self.central.retrievePeripherals(withIdentifiers: [id]).first else { return }
            self.peripheral = p
            p.delegate = self
            self.central.connect(p, options: nil)
            p.discoverServices([CBUUID(string: ServiceUUID.pump)])
        }
    }

    public func disconnect() {
        queue.async {
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            self.peripheral = nil
            self.characteristics.removeAll()
        }
    }

    public func updateAuthenticationKey(_ key: [UInt8]?) {
        queue.async { self.assembler.authKey = key }
    }

    // MARK: 写入

    public func write(_ packets: [[UInt8]], to characteristic: Characteristic) async throws {
        for packet in packets {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                queue.async {
                    guard let ch = self.characteristics[characteristic], let p = self.peripheral else {
                        cont.resume(throwing: TransportError.disconnected); return
                    }
                    self.writeContinuations.append(cont)
                    self.pendingWrites.append((packet, characteristic))
                    self.drainWrites(ch, p)
                }
            }
        }
    }

    private func drainWrites(_ ch: CBCharacteristic, _ p: CBPeripheral) {
        guard !pendingWrites.isEmpty else { return }
        guard p.canSendWriteWithoutResponse else { return }
        let (data, _) = pendingWrites.removeFirst()
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse
        p.writeValue(Data(data), for: ch, type: type)
        if type == .withoutResponse, !writeContinuations.isEmpty {
            writeContinuations.removeFirst().resume()
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
        onDiscover?(DiscoveredPump(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: ServiceUUID.pump)])
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        characteristics.removeAll()
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
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        queue.async {
            do {
                if let frame = try self.assembler.ingest([UInt8](data)) {
                    self.frameContinuation.yield(frame)
                }
            } catch {
                // 坏包直接丢弃，交给上层超时处理；不在此处重试以免打乱事务 ID
            }
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let p = self.peripheral else { return }
        for (_, c) in characteristics where c.properties.contains(.writeWithoutResponse) {
            drainWrites(c, p)
            break
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if error == nil, !writeContinuations.isEmpty {
            writeContinuations.removeFirst().resume()
        } else if let error {
            if !writeContinuations.isEmpty { writeContinuations.removeFirst().resume(throwing: error) }
        }
        if let ch = characteristics.first(where: { $0.value === characteristic })?.value {
            drainWrites(ch, peripheral)
        }
    }
}
#endif
