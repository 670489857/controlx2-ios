import Foundation
import PumpX2Kit
import X2Advisor

/// Nightscout 血糖来源的接线层。
///
/// 这里只接「血糖」这一件事。胰岛素相关的所有数（IOB、基础率、Control-IQ 状态）
/// 仍然只认泵——因为 NS 里的 IOB 是别的 App 按它自己的参数算的，
/// 拿来做本机的闸门判断，等于用别人的假设决定这一针打不打。
extension AppModel {

    private static let nsConfigKey = "nightscoutConfig"
    private static let cgmSourceKey = "cgmSource"

    nonisolated static func loadNightscoutConfig() -> NightscoutConfig {
        guard let data = UserDefaults.standard.data(forKey: nsConfigKey),
              let c = try? JSONDecoder().decode(NightscoutConfig.self, from: data)
        else { return NightscoutConfig() }
        return c
    }

    func saveNightscoutConfig() {
        if let data = try? JSONEncoder().encode(nsConfig) {
            UserDefaults.standard.set(data, forKey: Self.nsConfigKey)
        }
        UserDefaults.standard.set(cgmSource.rawValue, forKey: Self.cgmSourceKey)
    }

    func setCGMSource(_ source: CGMSource) {
        cgmSource = source
        UserDefaults.standard.set(source.rawValue, forKey: Self.cgmSourceKey)
        nsError = nil
        if source == .nightscout {
            Task { await refreshNightscout() }
        } else {
            // 切回泵时把 NS 的显示状态清掉，避免卡片上留着一个不再更新的数字
            nsStatus = nil
            Task {
                if (try? await session.refresh()) != nil {
                    await refreshFromSession()
                }
            }
        }
    }

    /// 最新一条 NS 读数的趋势码
    var nsTrendCode: Int? {
        guard let date = nsLatestDate else { return nil }
        // 趋势只用于显示箭头，用相邻两条的差值估一下就够；NS 的 direction 在拉取时已解析过
        _ = date
        return nsEntryTrend
    }

    /// 拉取的最近一批里，最新那条的趋势码
    var nsEntryTrend: Int? { nsLastEntries.last?.trendCode }

    /// `3 分钟前` 这样的文本
    var nsAgeText: String {
        guard let date = nsLatestDate else { return "无数据" }
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes <= 0 { return "刚刚" }
        return "\(minutes) 分钟前"
    }

    /// NS 读数的年龄（分钟）。闭环用它判断"这条血糖是不是新的"
    var nsAgeMinutes: Double? {
        nsLatestDate.map { Date().timeIntervalSince($0) / 60 }
    }

    /// 轮询里调用：NS 每 5 分钟才更新一次，没必要每 60 秒打一次请求
    func maybeRefreshNightscout() async {
        guard cgmSource == .nightscout, nsConfig.enabled else { return }
        if let last = nsLastFetchAt, Date().timeIntervalSince(last) < 120 { return }
        await refreshNightscout()
    }

    func refreshNightscout() async {
        guard cgmSource == .nightscout else { return }
        guard nsConfig.enabled else {
            nsError = "Nightscout 没启用：在「血糖来源」页打开它并填地址"
            return
        }
        guard nsConfig.isConfigured else {
            nsError = NightscoutError.badBaseURL.errorDescription
            return
        }
        nsLoading = true
        defer { nsLoading = false }
        do {
            let entries = try await NightscoutClient(config: nsConfig).entries(count: 24)
            nsLastFetchAt = Date()
            nsLastEntries = entries
            let latest = entries[entries.count - 1]
            nsLatestMgdl = latest.sgv
            nsLatestDate = latest.date
            nsStatus = "\(entries.count) 条 · 最新 \(latest.sgv) mg/dL · \(nsAgeText)"
            nsError = nil

            // 只写比历史里更新的点，避免每轮把同一批重复追加成锯齿
            let newestKnown = glucoseStore.latest?.timestamp ?? .distantPast
            for e in entries where e.date > newestKnown {
                glucoseStore.append(GlucoseSample(timestamp: e.date,
                                                  mgdl: e.sgv,
                                                  trendCode: e.trendCode))
            }
            samples = glucoseStore.recent(minutes: 180)
            applyNightscoutDisplay()

            // 用新血糖重算预测与建议；IOB 仍来自泵的最后一次刷新
            let snap = await session.snapshot
            updateAdvisor(with: snap)
        } catch {
            nsError = error.localizedDescription
        }
    }

    /// 只更新显示，不动历史
    func applyNightscoutDisplay() {
        guard let ns = nsLatestMgdl else { return }
        applyGlucoseDisplay(mgdl: ns)
        hasLiveData = true
        trendSymbol = Self.trendSymbol(for: nsTrendCode)
        glucoseSourceHint = "mmol/L · Nightscout " + nsAgeText
    }
}
