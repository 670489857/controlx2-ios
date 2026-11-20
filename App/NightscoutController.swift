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

    private static let nsSecretAccount = "ns.secret"
    private static let nsTokenAccount = "ns.token"

    /// 读配置。旧版本把 secret / token 明文写在 UserDefaults 的 JSON 里，
    /// 这里顺手迁移进 Keychain，并把明文从 plist 里抹掉——迁移只跑一次。
    nonisolated static func loadNightscoutConfig() -> NightscoutConfig {
        guard let data = UserDefaults.standard.data(forKey: nsConfigKey),
              var c = try? JSONDecoder().decode(NightscoutConfig.self, from: data)
        else { return NightscoutConfig() }

        let hasLegacySecret = !c.secret.isEmpty
        let hasLegacyToken = !c.token.isEmpty

        if Keychain.read(account: nsSecretAccount) == nil, hasLegacySecret {
            Keychain.write(c.secret, account: nsSecretAccount)
        }
        if Keychain.read(account: nsTokenAccount) == nil, hasLegacyToken {
            Keychain.write(c.token, account: nsTokenAccount)
        }
        c.secret = Keychain.read(account: nsSecretAccount) ?? c.secret
        c.token = Keychain.read(account: nsTokenAccount) ?? c.token

        if hasLegacySecret || hasLegacyToken {
            // 把 plist 里的明文换成空串。地址、认证模式这些不敏感，仍留在 JSON 里。
            var cleaned = c
            cleaned.secret = ""
            cleaned.token = ""
            if let cleanData = try? JSONEncoder().encode(cleaned) {
                UserDefaults.standard.set(cleanData, forKey: nsConfigKey)
            }
        }
        return c
    }

    func saveNightscoutConfig() {
        Keychain.write(nsConfig.secret, account: Self.nsSecretAccount)
        Keychain.write(nsConfig.token, account: Self.nsTokenAccount)

        // 落盘的 JSON 永远不含 secret / token。哪怕用户导出备份，也拿不到这两串。
        var persisted = nsConfig
        persisted.secret = ""
        persisted.token = ""
        if let data = try? JSONEncoder().encode(persisted) {
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

    /// 按当前窗口重建曲线采样。窗口切到 24 小时时要能从本地历史里取满 24 小时
    func refreshChartSamples() {
        chartSamples = glucoseStore.recent(minutes: chartWindowHours * 60)
    }

    /// 切曲线窗口：换了跨度要立刻重算采样；NS 来源还要把远端的历史一起拉进来，
    /// 否则 24 小时窗口只能看到 App 自己开机以后的那点数据
    func setChartWindow(_ hours: Int) {
        guard hours != chartWindowHours else { return }
        chartWindowHours = hours
        UserDefaults.standard.set(hours, forKey: "chartWindowHours")
        refreshChartSamples()
        if cgmSource == .nightscout, nsConfig.enabled {
            Task { await refreshNightscout() }
        }
    }

    /// 轮询里调用：NS 每 5 分钟才更新一次，没必要每 60 秒打一次请求。
    /// `force` 用在后台上限被挂起之后、或者用户手动点「拉取」时——那时节流没有意义。
    func maybeRefreshNightscout(force: Bool = false) async {
        guard cgmSource == .nightscout, nsConfig.enabled else { return }
        if !force, let last = nsLastFetchAt, Date().timeIntervalSince(last) < 120 { return }
        await refreshNightscout()
    }

    /// 回到前台/重新激活时要做的事：补 NS、把静音播放续上
    func onAppForeground() async {
        if backgroundAudioEnabled { _ = AudioKeepAlive.shared.start() }
        await maybeRefreshNightscout(force: true)
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
            let client = NightscoutClient(config: nsConfig)
            // NS 一条 5 分钟：24 小时窗口要 288 条才画得满
            let entryCount = min(400, max(24, chartWindowHours * 12 + 6))
            let entries = try await client.entries(count: entryCount)
            nsLastFetchAt = Date()
            // 治疗记录单独拉：它失败不该让血糖也显示不出来。
            // 窗口越长要的记录越多，否则 24 小时曲线上只剩最近几条注射标记
            let treatmentCount = chartWindowHours >= 12 ? 200 : 48
            if let t = try? await client.treatments(count: treatmentCount) {
                nsTreatments = t
            }
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
    }
}
