import Foundation

/// 一条 CGM 采样。
///
/// 泵上报的是 mg/dL 整数 + Dexcom 趋势码，两者都要留：趋势码是泵自己算的，
/// 与"用相邻两点反推斜率"相比更抗噪，但也更粗。预测同时用得上。
public struct GlucoseSample: Codable, Equatable, Sendable {
    public let timestamp: Date
    /// mg/dL
    public let mgdl: Int
    /// 原始趋势码 0...9，未知时为 nil
    public let trendCode: Int?

    public init(timestamp: Date, mgdl: Int, trendCode: Int? = nil) {
        self.timestamp = timestamp
        self.mgdl = mgdl
        self.trendCode = trendCode
    }

    public var trend: GlucoseTrend? { trendCode.flatMap(GlucoseTrend.init(rawValue:)) }
}

/// Dexcom / Tandem 的九档趋势，数值为该档代表的斜率（mg/dL/min）。
///
/// 这些常数不是猜测，是 Dexcom 公开的 rate-of-change 定义，泵屏幕上的
/// 单箭头/双箭头就是它。用来判断"是否正在快速下降"比差分更可靠，
/// 因为差分会被单个跳变的采样点带偏。
public enum GlucoseTrend: Int, CaseIterable, Sendable {
    case none = 0
    case upUpUp = 1
    case upUp = 2
    case up = 3
    case upSlow = 4
    case flat = 5
    case downSlow = 6
    case down = 7
    case downDown = 8
    case downDownDown = 9

    /// mg/dL/min
    public var mgdlPerMinute: Double {
        switch self {
        case .none: return 0
        case .upUpUp: return 3.0
        case .upUp: return 2.0
        case .up: return 1.0
        case .upSlow: return 0.5
        case .flat: return 0
        case .downSlow: return -0.5
        case .down: return -1.0
        case .downDown: return -2.0
        case .downDownDown: return -3.0
        }
    }

    /// 是否属于"需要抑制追加剂量"的下降档
    public var isFalling: Bool { mgdlPerMinute <= -1.0 }
}

/// 内存环形缓冲 + 磁盘持久化。
///
/// 只保留最近 N 条，因为预测最多回溯 6 小时，历史图表另有存储。
/// 写入用原子替换，避免 App 被杀在写一半时留下坏文件。
public final class GlucoseHistoryStore: @unchecked Sendable {

    public static let defaultCapacity = 720  // 5 分钟一条 ≈ 60 小时

    private let fileURL: URL?
    private let capacity: Int
    private var samples: [GlucoseSample] = []
    private let lock = NSLock()

    public init(fileURL: URL?, capacity: Int = GlucoseHistoryStore.defaultCapacity) {
        self.fileURL = fileURL
        self.capacity = max(capacity, 2)
        load()
    }

    /// 追加一条，返回是否真的新增（同一时间戳的重复上报会被丢弃）
    @discardableResult
    public func append(_ sample: GlucoseSample) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let last = samples.last {
            // 泵会重复上报同一条读数；允许 10 秒内的修正，更早的重复直接丢
            if abs(sample.timestamp.timeIntervalSince(last.timestamp)) < 10 {
                return false
            }
            // 时钟回拨导致的乱序数据直接丢弃，不重排（重排会掩盖问题）
            if sample.timestamp < last.timestamp {
                return false
            }
        }
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
        persist()
        return true
    }

    public var all: [GlucoseSample] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    public var latest: GlucoseSample? {
        lock.lock(); defer { lock.unlock() }
        return samples.last
    }

    /// 最近 `minutes` 分钟内的采样，升序
    public func recent(minutes: Int, now: Date = Date()) -> [GlucoseSample] {
        let cutoff = now.addingTimeInterval(-Double(minutes) * 60)
        return all.filter { $0.timestamp >= cutoff }
    }

    /// 用最近 15 分钟的采样拟合斜率（mg/dL/min），点数不足时返回 nil
    public func recentSlope(now: Date = Date()) -> Double? {
        let pts = recent(minutes: 15, now: now).map {
            (x: $0.timestamp.timeIntervalSince1970 / 60, y: Double($0.mgdl))
        }
        guard pts.count >= 3 else { return nil }
        let n = Double(pts.count)
        let sx = pts.reduce(0) { $0 + $1.x }
        let sy = pts.reduce(0) { $0 + $1.y }
        let sxy = pts.reduce(0) { $0 + $1.x * $1.y }
        let sxx = pts.reduce(0) { $0 + $1.x * $1.x }
        let denom = n * sxx - sx * sx
        guard abs(denom) > 1e-9 else { return nil }
        return (n * sxy - sx * sy) / denom
    }

    private func load() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([GlucoseSample].self, from: data)
        else { return }
        samples = Array(decoded.suffix(capacity))
    }

    private func persist() {
        guard let url = fileURL, let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
