import SwiftUI
import X2Advisor

/// 一条"发生过的事"，把 NS 的治疗记录和本机闭环台账合成一条时间线。
///
/// 为什么合并：用户真正关心的是"那一刻往身体里进了什么"，而不是"这条数据来自哪个系统"。
/// 分成两栏会让"2.45 U 是手动推的、0.15 U 是闭环补的"这种事实被拆散。
struct HistoryEvent: Identifiable, Equatable {

    enum Kind: Equatable {
        case bolus      // NS 里的手动大剂量
        case carbs      // NS 里的碳水
        case loopDose   // 本机闭环发出去的微剂量
        case loopHold   // 闭环这一拍被拦下
    }

    /// 这条记录是谁写的。本机 = 在这台手机上按下去的；Nightscout = 从 NS treatments 读来的
    enum Source: Equatable { case local, nightscout }

    let id: String
    let date: Date
    let kind: Kind
    /// 剂量（U）或碳水（g）
    let amount: Double
    let detail: String
    var source: Source = .local

    var symbol: String {
        switch kind {
        case .bolus: return "syringe"
        case .carbs: return "fork.knife"
        case .loopDose: return "arrow.down.circle"
        case .loopHold: return "pause.circle"
        }
    }

    var tint: Color {
        switch kind {
        case .bolus: return .blue
        case .carbs: return .orange
        case .loopDose: return .green
        case .loopHold: return .secondary
        }
    }

    var title: String {
        switch kind {
        case .bolus:
            return source == .nightscout
                ? String(format: "NS 注射 %.2f U", amount)
                : String(format: "大剂量 %.2f U", amount)
        case .carbs:
            return source == .nightscout
                ? String(format: "NS 碳水 %.0f g", amount)
                : String(format: "碳水 %.0f g", amount)
        case .loopDose: return String(format: "闭环微剂量 %.2f U", amount)
        case .loopHold: return "闭环未发针"
        }
    }

    var shortLabel: String {
        switch kind {
        case .bolus: return String(format: "%.2fU", amount)
        case .carbs: return String(format: "%.0fg", amount)
        case .loopDose: return String(format: "%.2fU", amount)
        case .loopHold: return "—"
        }
    }
}

extension AppModel {

    /// 本机台账里的针：大剂量 + 闭环微剂量。都是在这台手机上按下去、发出去的。
    private var localInsulinEvents: [HistoryEvent] {
        var list: [HistoryEvent] = []
        // 大剂量台账只留 24 小时，跟最长的时间跨度对齐
        for r in ledger.records {
            list.append(HistoryEvent(id: "local-bolus-\(r.at.timeIntervalSince1970)",
                                     date: r.at,
                                     kind: .bolus,
                                     amount: r.units,
                                     detail: "本机大剂量"))
        }
        for r in loopRecords {
            let key = "loop-\(r.timestamp.timeIntervalSince1970)"
            if r.units > 0 {
                list.append(HistoryEvent(id: key,
                                         date: r.timestamp,
                                         kind: .loopDose,
                                         amount: r.units,
                                         detail: r.accepted == true ? r.summary : "结果未知"))
            } else if let hold = r.holdReason, hold != ClosedLoop.Hold.doseBelowStep.rawValue {
                list.append(HistoryEvent(id: key,
                                         date: r.timestamp,
                                         kind: .loopHold,
                                         amount: 0,
                                         detail: r.summary))
            }
        }
        return list
    }

    /// 记录列表：本机的针 + NS 的碳水，按时间倒序。
    ///
    /// NS 的 insulin 字段不进来。它记的是这台泵这段时间打进去的全部胰岛素——
    /// 泵自己的微剂量、别的 App 补的记录都混在里面。照着列，一屏几十条 0.0x U 的
    /// 「注射」，跟自己按的那几针糊在一起，分不出哪些是本机干的。
    var historyEvents: [HistoryEvent] {
        var list = localInsulinEvents
        for t in nsTreatments where !t.isIgnoredType && t.isCarbs {
            list.append(HistoryEvent(id: "ns-\(t.id)-c",
                                     date: t.date,
                                     kind: .carbs,
                                     amount: t.carbGrams,
                                     detail: t.eventType,
                                     source: .nightscout))
        }
        return list.sorted { $0.date > $1.date }
    }

    // MARK: 后台静音保活

    func setBackgroundAudio(_ on: Bool) {
        backgroundAudioEnabled = on
        UserDefaults.standard.set(on, forKey: "backgroundAudioEnabled")
        if on {
            let error = AudioKeepAlive.shared.start()
            backgroundAudioMessage = error ?? "静音保活已开启：锁屏后闭环仍会按 5 分钟一拍运行。耗电会增加，退出 App 时请在这里关掉。"
        } else {
            AudioKeepAlive.shared.stop()
            backgroundAudioMessage = "静音保活已关闭：App 进入后台后会被 iOS 挂起，闭环随之停摆。"
        }
    }
}

// MARK: - 曲线

/// 首页的最近记录。
///
/// 曲线那一块已经从首页拿掉了：能拖能看，但它占掉一屏，而此刻真正要看的数在主卡里。
/// 历史留在「记录」页，首页只留最近几条，翻得到就行。
struct RecentRecordsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "最近记录", subtitle: nil, padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("本机打的针与闭环")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("共 \(model.historyEvents.count) 条")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                if model.historyEvents.isEmpty {
                    Text("还没有记录。本机打的针、闭环的每一针会汇总到这里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 13) {
                        ForEach(Array(model.historyEvents.prefix(5))) { event in
                            HistoryRow(event: event)
                        }
                    }
                }

                NavigationLink { HistoryView() } label: {
                    HStack(spacing: 4) {
                        Text("全部记录")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }
}

struct HistoryRow: View {
    let event: HistoryEvent

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: event.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(event.tint)
                .frame(width: 28, height: 28)
                .background(event.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                Text(event.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(event.date, style: .time)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }
}

/// 全部记录。按日期分组，同一天的事件收在一张卡里——
/// 时间线本来就是一串，翻页式的长列表会让人分不清"这是今天还是上周"。
struct HistoryView: View {
    @EnvironmentObject var model: AppModel

    private struct DayGroup: Identifiable {
        let id: Date
        var events: [HistoryEvent]
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        var result: [DayGroup] = []
        for event in model.historyEvents {
            let day = calendar.startOfDay(for: event.date)
            if let index = result.lastIndex(where: { calendar.isDate($0.id, inSameDayAs: day) }) {
                result[index].events.append(event)
            } else {
                result.append(DayGroup(id: day, events: [event]))
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.gap) {
                if groups.isEmpty {
                    Card {
                        Text("还没有记录。本机打的针、闭环的每一针会出现在这里；Nightscout 只往里补碳水。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(groups) { group in
                    Card(padding: 18) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(dayTitle(group.id))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            VStack(spacing: 13) {
                                ForEach(group.events) { event in
                                    HistoryRow(event: event)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, DS.pagePadding)
            .padding(.vertical, 8)
        }
        .background(PageBackground())
        .navigationTitle("记录")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.maybeRefreshNightscout(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新 NS")
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        return day.formatted(.dateTime.month().day().weekday(.wide))
    }
}

// MARK: - 后台保活

/// 后台静音播放的设置页。
///
/// 这个开关不是"性能选项"，它是闭环能不能在锁屏后继续跑的前提——
/// iOS 不给普通 App 后台定时权限，只有"正在播放音频"这一条路能稳定维持节拍。
struct BackgroundKeepAliveView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("后台静音播放（保活）", isOn: Binding(
                    get: { model.backgroundAudioEnabled },
                    set: { model.setBackgroundAudio($0) }))
                if let message = model.backgroundAudioMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                LabeledContent("播放状态") {
                    Text(AudioKeepAlive.shared.isRunning ? "正在播放静音" : "未播放")
                        .foregroundStyle(AudioKeepAlive.shared.isRunning ? Color.green : Color.secondary)
                }
            } header: {
                Text("保活")
            } footer: {
                Text("开启后 App 在后台/锁屏状态下仍按 5 分钟一拍运行，NS 也继续拉取。代价是耗电增加，锁屏可能显示「正在播放」。关掉后 App 一进后台就会被挂起，闭环停摆。")
            }

            Section {
                Text("1. 这不是为了绕过限制而做的优化，是 iOS 的机制：普通 App 进后台后定时器和网络都会被挂起，闭环会静默停摆，而泵那边仍按自己的基础率输注。")
                Text("2. 保活只解决「App 不被挂起」，不解决「蓝牙断了怎么办」。链路断了闭环会记错误并连续三拍后自动卸武装；泵上留的那点安全基础率就是为这种时刻准备的。")
                Text("3. 这个用途不在 App Store 的允许范围内，只适合自签/侧载。别把它上传到商店。")
            } header: {
                Text("要知道的事")
            }
            .font(.footnote)
        }
        .scrollContentBackground(.hidden)
        .background(PageBackground())
        .navigationTitle("后台保活")
    }
}
