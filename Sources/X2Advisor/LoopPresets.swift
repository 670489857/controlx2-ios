import Foundation

/// 一套控糖设定档：名字 + 一整组闭环参数。
///
/// 做成"多套并存"而不是"改了就覆盖"，是因为参数会随季节、作息、生理周期变：
/// 想试新的 ISF 时不该把原来那套能用的直接冲掉，改坏了要能切回去。
public struct LoopPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var settings: ClosedLoop.Settings
    public var updatedAt: Date

    public init(id: UUID = UUID(),
                name: String,
                settings: ClosedLoop.Settings,
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.settings = settings
        self.updatedAt = updatedAt
    }

    /// 一行摘要，给列表用
    public var summary: String {
        var parts: [String] = []
        parts.append(String(format: "目标 %.0f–%.0f", settings.targetLow, settings.targetHigh))
        if settings.totalDailyInsulinUnits > 0 {
            parts.append(String(format: "每日 %.0f U", settings.totalDailyInsulinUnits))
        }
        if settings.pumpBasalUnitsPerHour > 0 {
            parts.append(String(format: "泵底 %.2f", settings.pumpBasalUnitsPerHour))
        }
        return parts.joined(separator: " · ")
    }
}

/// 设定档集合的编解码与查找。故意做成纯函数，好在 Linux 上单测。
public enum LoopPresetLibrary {

    public static func decode(_ data: Data?) -> [LoopPreset] {
        guard let data,
              let list = try? JSONDecoder().decode([LoopPreset].self, from: data)
        else { return [] }
        return list.sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func encode(_ presets: [LoopPreset]) -> Data? {
        try? JSONEncoder().encode(presets)
    }

    public static func apply(presetID: UUID?, to presets: [LoopPreset]) -> ClosedLoop.Settings? {
        guard let presetID else { return nil }
        return presets.first { $0.id == presetID }?.settings
    }

    /// 覆盖同一 id 的档；不存在就插进去。返回新数组（不原地改，便于测试）
    public static func upsert(_ preset: LoopPreset, in presets: [LoopPreset]) -> [LoopPreset] {
        var list = presets
        if let index = list.firstIndex(where: { $0.id == preset.id }) {
            list[index] = preset
        } else {
            list.append(preset)
        }
        return list.sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func remove(_ id: UUID, from presets: [LoopPreset]) -> [LoopPreset] {
        presets.filter { $0.id != id }
    }

    /// 给"复制当前参数"起一个不撞名的名字
    public static func nextDefaultName(for presets: [LoopPreset]) -> String {
        let base = "设定档"
        var n = presets.count + 1
        var candidate = "\(base) \(n)"
        let existing = Set(presets.map(\.name))
        while existing.contains(candidate) {
            n += 1
            candidate = "\(base) \(n)"
        }
        return candidate
    }
}
