import ActivityKit
import Foundation
import SwiftUI
import X2Advisor

/// 锁屏即时动态的开关与刷新。
///
/// 契约：这里只推「现在是什么状态」，不接受任何操作。
/// 锁屏上不能发针——真发针必须回到 App 里、过闸门、二次确认。
extension AppModel {

    private static let liveActivityKey = "liveActivityEnabled"

    func setLiveActivity(_ on: Bool) {
        liveActivityEnabled = on
        UserDefaults.standard.set(on, forKey: Self.liveActivityKey)
        if on {
            startLiveActivity()
        } else {
            endLiveActivity()
            liveActivityMessage = "锁屏即时动态已关闭。"
        }
    }

    /// 把当前状态拼成 ContentState。字符串格式化在这里一次做完，小组件只负责显示
    func liveActivityState() -> LoopActivityAttributes.ContentState {
        let unitText = effectiveGlucoseUnit == .mmol ? "mmol/L" : "mg/dL"
        var lastDose = "最近无针"
        if let record = loopRecords.last(where: { $0.units > 0 }) {
            let minutes = Int(Date().timeIntervalSince(record.timestamp) / 60)
            lastDose = String(format: "%d 分钟前 %.2f U", minutes, record.units)
        }
        let loopText: String
        if loopArmed {
            loopText = loopLiveDosing ? "闭环 · 真发针" : "闭环 · 演练"
        } else {
            loopText = "闭环 · 未启动"
        }
        // 锁屏小趋势线：最近一小时的点，抽到 12 个左右就够画形状了
        let recent = chartSamples.suffix(12).map { Double($0.mgdl) }
        return LoopActivityAttributes.ContentState(
            glucoseText: glucoseText,
            glucoseUnit: unitText,
            trendSymbol: trendSymbol,
            iobText: String(format: "%.2f U", iobValue ?? 0),
            loopText: loopText,
            lastDoseText: lastDose,
            sourceText: cgmSource == .nightscout ? "Nightscout" : "泵 CGM",
            spark: recent,
            glucoseValue: Double(glucoseValue ?? 0),
            updatedAt: Date()
        )
    }

    func startLiveActivity() {
        guard #available(iOS 16.2, *) else {
            liveActivityMessage = "系统版本低于 16.2，不支持锁屏即时动态"
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            liveActivityMessage = "系统里把「实时活动」关掉了：设置 → ControlX2 → 实时活动"
            return
        }
        let state = liveActivityState()
        // 已经有在跑的就不重复开，直接更新
        if let existing = Activity<LoopActivityAttributes>.activities.first {
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(900))
            Task { await existing.update(content) }
            liveActivityMessage = "锁屏即时动态在运行"
            return
        }
        do {
            let attributes = LoopActivityAttributes(startedAt: Date())
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(900))
            _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            liveActivityMessage = "锁屏即时动态已开启"
        } catch {
            liveActivityMessage = "开不了即时动态：\(error.localizedDescription)"
        }
    }

    /// 每拍刷新后调用。没开就什么都不做
    func syncLiveActivity() {
        guard liveActivityEnabled else { return }
        guard #available(iOS 16.2, *) else { return }
        guard let activity = Activity<LoopActivityAttributes>.activities.first else {
            startLiveActivity()
            return
        }
        let content = ActivityContent(state: liveActivityState(),
                                     staleDate: Date().addingTimeInterval(900))
        Task { await activity.update(content) }
    }

    func endLiveActivity() {
        guard #available(iOS 16.2, *) else { return }
        let final = ActivityContent(state: liveActivityState(), staleDate: nil)
        for activity in Activity<LoopActivityAttributes>.activities {
            Task { await activity.end(final, dismissalPolicy: .immediate) }
        }
    }

    // MARK: 设定档

    func savePresets() {
        UserDefaults.standard.set(LoopPresetLibrary.encode(loopPresets), forKey: "loopPresets")
        if let id = activePresetID {
            UserDefaults.standard.set(id.uuidString, forKey: "activePresetID")
        } else {
            UserDefaults.standard.removeObject(forKey: "activePresetID")
        }
    }

    /// 把当前参数另存成一套新档
    @discardableResult
    func createPresetFromCurrent(name: String? = nil) -> LoopPreset {
        let preset = LoopPreset(name: name ?? LoopPresetLibrary.nextDefaultName(for: loopPresets),
                                settings: loopSettings)
        loopPresets = LoopPresetLibrary.upsert(preset, in: loopPresets)
        activePresetID = preset.id
        savePresets()
        return preset
    }

    /// 切换档：换的是整组参数，不是单项
    func applyPreset(_ id: UUID) {
        guard let settings = LoopPresetLibrary.apply(presetID: id, to: loopPresets) else { return }
        loopSettings = settings
        activePresetID = id
        saveLoopSettings()
        savePresets()
    }

    /// 编辑某一档。若它是当前生效的，顺便把运行参数也换掉
    func updatePreset(_ preset: LoopPreset) {
        loopPresets = LoopPresetLibrary.upsert(preset, in: loopPresets)
        if activePresetID == preset.id {
            loopSettings = preset.settings
            saveLoopSettings()
        }
        savePresets()
    }

    func deletePreset(_ id: UUID) {
        loopPresets = LoopPresetLibrary.remove(id, from: loopPresets)
        if activePresetID == id { activePresetID = nil }
        savePresets()
    }
}
