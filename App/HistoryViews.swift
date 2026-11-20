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

    let id: String
    let date: Date
    let kind: Kind
    /// 剂量（U）或碳水（g）
    let amount: Double
    let detail: String

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
        case .bolus: return String(format: "大剂量 %.2f U", amount)
        case .carbs: return String(format: "碳水 %.0f g", amount)
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

    /// NS 治疗记录 + 本机闭环台账，按时间倒序
    var historyEvents: [HistoryEvent] {
        var list: [HistoryEvent] = []
        for t in nsTreatments where !t.isIgnoredType {
            if t.isInsulin {
                list.append(HistoryEvent(id: "ns-\(t.id)-i",
                                         date: t.date,
                                         kind: .bolus,
                                         amount: t.insulinUnits,
                                         detail: t.eventType))
            }
            if t.isCarbs {
                list.append(HistoryEvent(id: "ns-\(t.id)-c",
                                         date: t.date,
                                         kind: .carbs,
                                         amount: t.carbGrams,
                                         detail: t.eventType))
            }
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

/// 血糖曲线 + 事件标记。用 Canvas 画，避免引入图表库。
///
/// 纵轴固定 40–350 mg/dL：如果按数据自适应，同一段血糖在两次打开之间会"跳形状"，
/// 读数本身的绝对值反而更难比较。
struct GlucoseChartView: View {

    let samples: [GlucoseSample]
    let markers: [HistoryEvent]
    var windowMinutes: Double = 180
    /// 显示单位（只影响纵轴标签，不影响绘制坐标——坐标永远是 mg/dL）
    var unit: GlucoseDisplayUnit = .mgdl

    /// 拖动时被按住的那个点。nil = 没在拖，曲线回到"只看形状"的状态
    @State private var scrubIndex: Int?

    private let low: Double = 40
    private let high: Double = 350

    private var unitLabel: String { unit == .mmol ? "mmol/L" : "mg/dL" }

    private func valueText(_ mgdl: Int) -> String {
        unit == .mmol
            ? String(format: "%.1f", Double(mgdl) / 18.0182)
            : "\(mgdl)"
    }

    private func visible(_ now: Date) -> [GlucoseSample] {
        let start = now.addingTimeInterval(-windowMinutes * 60)
        return samples.filter { $0.timestamp >= start }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let now = Date()
                    let start = now.addingTimeInterval(-windowMinutes * 60)
                    let plot = CGRect(x: 26,
                                      y: 12,
                                      width: max(1, size.width - 26 - 12),
                                      height: max(1, size.height - 12 - 22))

                    func y(_ value: Double) -> CGFloat {
                        plot.maxY - CGFloat((value - low) / (high - low)) * plot.height
                    }
                    func x(_ date: Date) -> CGFloat {
                        plot.minX + CGFloat(date.timeIntervalSince(start) / (windowMinutes * 60)) * plot.width
                    }

                    // 目标带参考线：70 / 180 mg/dL
                    for value in [70.0, 180.0] {
                        var line = Path()
                        line.move(to: CGPoint(x: plot.minX, y: y(value)))
                        line.addLine(to: CGPoint(x: plot.maxX, y: y(value)))
                        context.stroke(line, with: .color(Color.secondary.opacity(0.35)),
                                       style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }

                    // 纵轴刻度
                    for value in [70.0, 180.0, 250.0] {
                        let label = unit == .mmol
                            ? String(format: "%.1f", value / 18.0182)
                            : String(format: "%.0f", value)
                        context.draw(Text(label).font(.system(size: 9)).foregroundColor(Color.secondary),
                                     at: CGPoint(x: plot.minX - 8, y: y(value)), anchor: .trailing)
                    }

                    let shown = visible(now)

                    // 曲线
                    if shown.count >= 2 {
                        var path = Path()
                        path.move(to: CGPoint(x: x(shown[0].timestamp), y: y(Double(shown[0].mgdl))))
                        for s in shown.dropFirst() {
                            path.addLine(to: CGPoint(x: x(s.timestamp), y: y(Double(s.mgdl))))
                        }
                        context.stroke(path, with: .color(Color.green.opacity(0.85)), lineWidth: 1.5)
                    }
                    for s in shown {
                        let r: CGFloat = 2.4
                        let rect = CGRect(x: x(s.timestamp) - r, y: y(Double(s.mgdl)) - r,
                                          width: r * 2, height: r * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(Color.green.opacity(0.75)))
                    }

                    // 事件标记：三角 + 数值，画在对应时间的曲线上。
                    // 同一条曲线上一串追加针常挤在一分钟里，标签会叠成一团文字——这里按像素间距丢标签，只留三角
                    var lastLabelX: CGFloat = -.greatestFiniteMagnitude
                    for m in markers where m.date >= start && m.kind != .loopHold {
                        let px = x(m.date)
                        let bgValue = nearestValue(to: m.date, in: shown) ?? 180
                        let py = y(bgValue)
                        let color: Color = m.kind == .carbs ? .orange : (m.kind == .bolus ? .blue : .green)

                        var tri = Path()
                        tri.move(to: CGPoint(x: px, y: py - 6))
                        tri.addLine(to: CGPoint(x: px - 4.5, y: py - 14))
                        tri.addLine(to: CGPoint(x: px + 4.5, y: py - 14))
                        tri.closeSubpath()
                        context.fill(tri, with: .color(color))

                        guard px - lastLabelX >= 26 else { continue }
                        lastLabelX = px
                        context.draw(Text(m.shortLabel).font(.system(size: 9, weight: .semibold)).foregroundColor(color),
                                     at: CGPoint(x: px, y: py - 22), anchor: .bottom)
                    }

                    // 时间轴：起始、中点、现在
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm"
                    for fraction in [0.0, 0.5, 1.0] {
                        let date = start.addingTimeInterval(windowMinutes * 60 * fraction)
                        let text = fraction == 1.0 ? "现在" : formatter.string(from: date)
                        context.draw(Text(text).font(.system(size: 8)).foregroundColor(Color.secondary),
                                     at: CGPoint(x: x(date), y: plot.maxY + 10))
                    }

                    // 拖动指示：竖线 + 高亮那个点。
                    // 竖线用虚线而不是实线——实线会被误读成"现在是这个值"。
                    if let index = scrubIndex, shown.indices.contains(index) {
                        let s = shown[index]
                        let px = x(s.timestamp)
                        let py = y(Double(s.mgdl))

                        var rule = Path()
                        rule.move(to: CGPoint(x: px, y: plot.minY))
                        rule.addLine(to: CGPoint(x: px, y: plot.maxY))
                        context.stroke(rule, with: .color(Color.primary.opacity(0.35)),
                                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                        context.fill(Path(ellipseIn: CGRect(x: px - 7, y: py - 7, width: 14, height: 14)),
                                     with: .color(Theme.glucose(Double(s.mgdl))))
                        context.stroke(Path(ellipseIn: CGRect(x: px - 3.5, y: py - 3.5, width: 7, height: 7)),
                                       with: .color(.white), lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(
                    // 只处理横向拖动：竖向留给外层的 ScrollView，否则整页会滚不动
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard abs(drag.translation.width) >= abs(drag.translation.height) else { return }
                            let plotMinX: CGFloat = 26
                            let plotMaxX = max(27, geo.size.width - 12)
                            let width = plotMaxX - plotMinX
                            let px = min(max(drag.location.x, plotMinX), plotMaxX)
                            let start = Date().addingTimeInterval(-windowMinutes * 60)
                            let target = start.addingTimeInterval(Double((px - plotMinX) / width) * windowMinutes * 60)
                            let shown = visible(Date())
                            if let index = nearestIndex(to: target, in: shown) {
                                scrubIndex = index
                            }
                        }
                        .onEnded { _ in
                            scrubIndex = nil
                        }
                )

                if let index = scrubIndex {
                    let shown = visible(Date())
                    if shown.indices.contains(index) {
                        let s = shown[index]
                        scrubBubble(sample: s, size: geo.size, now: Date())
                    }
                }
            }
        }
        .frame(height: 168)
    }

    /// 小气泡：时间 + 读数。横向位置跟着手指走，但贴边时向内收，
    /// 不让文字跑出卡片。
    private func scrubBubble(sample: GlucoseSample, size: CGSize, now: Date) -> some View {
        let plotMinX: CGFloat = 26
        let plotMaxX = max(27, size.width - 12)
        let start = now.addingTimeInterval(-windowMinutes * 60)
        let ratio = CGFloat(sample.timestamp.timeIntervalSince(start) / (windowMinutes * 60))
        let rawX = plotMinX + ratio * (plotMaxX - plotMinX)
        let bubbleWidth: CGFloat = 118
        let clampedX = min(max(rawX, bubbleWidth / 2 + 2), size.width - bubbleWidth / 2 - 2)

        let time = sample.timestamp.formatted(date: .omitted, time: .shortened)
        return VStack(spacing: 1) {
            Text("\(valueText(sample.mgdl)) \(unitLabel)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(time)
                .font(.system(size: 9))
                .opacity(0.7)
        }
        .foregroundStyle(.white)
        .frame(width: bubbleWidth)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.82), in: Capsule())
        .position(x: clampedX, y: 22)
        .allowsHitTesting(false)
    }

    private func nearestIndex(to date: Date, in list: [GlucoseSample]) -> Int? {
        guard !list.isEmpty else { return nil }
        var best = 0
        var bestGap = Double.greatestFiniteMagnitude
        for (index, s) in list.enumerated() {
            let gap = abs(s.timestamp.timeIntervalSince(date))
            if gap < bestGap { bestGap = gap; best = index }
        }
        // 拖到离最近一个点太远的地方就不显示：否则空白处会吸附到一个很远的值，看着像"这个时刻有数"
        return bestGap <= 15 * 60 ? best : nil
    }

    private func nearestValue(to date: Date, in samples: [GlucoseSample]) -> Double? {
        guard let index = nearestIndex(to: date, in: samples) else { return nil }
        return Double(samples[index].mgdl)
    }
}

/// 首页血糖下方的整块：曲线 + 最近记录。
///
/// 曲线跨度的入口只留这里一个分段控件。之前标题右侧还挂过一个同名菜单，
/// 两个控件指向同一个状态，本质是同一个东西画了两遍。
struct GlucoseTrendSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "血糖曲线", subtitle: nil, padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("时间跨度", selection: Binding(get: { model.chartWindowHours },
                                                    set: { model.setChartWindow($0) })) {
                    Text("3 小时").tag(3)
                    Text("6 小时").tag(6)
                    Text("12 小时").tag(12)
                    Text("24 小时").tag(24)
                }
                .pickerStyle(.segmented)
                .tint(DS.accent)

                GlucoseChartView(samples: model.chartSamples,
                                 markers: model.historyEvents,
                                 windowMinutes: Double(model.chartWindowHours * 60),
                                 unit: model.effectiveGlucoseUnit)

                if model.chartSamples.isEmpty {
                    Text("还没有采样。Nightscout 需要先拉一次；泵来源需要 CGM 连上。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("按住曲线左右拖动，可以看任意时间点的读数")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                if model.cgmSource == .nightscout, let age = model.nsAgeMinutes, age > 15 {
                    Label("Nightscout 已经 \(Int(age)) 分钟没更新", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(DS.warn)
                }

                RowRule(leading: 0).padding(.top, 2)

                HStack {
                    Text("最近记录")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("共 \(model.historyEvents.count) 条")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                if model.historyEvents.isEmpty {
                    Text("还没有记录。Nightscout 的注射与碳水、本机闭环的每一针都会汇总到这里。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 12) {
                        ForEach(Array(model.historyEvents.prefix(4))) { event in
                            HistoryRow(event: event)
                        }
                    }
                }
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
                        Text("还没有记录。Nightscout 的注射与碳水、本机闭环的每一针都会汇总到这里。")
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
