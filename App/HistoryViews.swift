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

    private let low: Double = 40
    private let high: Double = 350

    var body: some View {
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
                let label: String
                if unit == .mmol {
                    label = String(format: "%.1f", value / 18.0182)
                } else {
                    label = String(format: "%.0f", value)
                }
                context.draw(Text(label).font(.system(size: 9)).foregroundColor(Color.secondary),
                             at: CGPoint(x: plot.minX - 8, y: y(value)), anchor: .trailing)
            }

            // 曲线
            let visible = samples.filter { $0.timestamp >= start }
            if visible.count >= 2 {
                var path = Path()
                path.move(to: CGPoint(x: x(visible[0].timestamp), y: y(Double(visible[0].mgdl))))
                for s in visible.dropFirst() {
                    path.addLine(to: CGPoint(x: x(s.timestamp), y: y(Double(s.mgdl))))
                }
                context.stroke(path, with: .color(Color.green.opacity(0.85)), lineWidth: 1.5)
            }
            for s in visible {
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
                let bgValue = nearestValue(to: m.date, in: visible, windowMinutes: windowMinutes) ?? 180
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
        }
        .frame(height: 168)
    }

    private func nearestValue(to date: Date, in samples: [GlucoseSample],
                              windowMinutes: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        var best: GlucoseSample?
        var bestGap = Double.greatestFiniteMagnitude
        for s in samples {
            let gap = abs(s.timestamp.timeIntervalSince(date))
            if gap < bestGap { bestGap = gap; best = s }
        }
        // 24 小时窗口里一个点是 5 分钟，20 分钟阈值不变；但窗口很短时点更密，
        // 这里只判断"有没有点"，距离交给三角本身的位置表达
        _ = windowMinutes
        return best.map { Double($0.mgdl) }
    }
}

/// 首页血糖下方的整块：曲线 + 最近记录 + 全部记录入口
struct GlucoseTrendSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("血糖曲线").font(.subheadline.weight(.semibold))
                Spacer()
                Text("最近 3 小时").font(.caption).foregroundStyle(.secondary)
            }

            GlucoseChartView(samples: model.samples,
                             markers: model.historyEvents,
                             windowMinutes: 180,
                             unit: model.effectiveGlucoseUnit)

            if model.samples.isEmpty {
                Text("还没有血糖采样。NS 来源需要先拉取一次，泵来源需要 CGM 连上。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if model.cgmSource == .nightscout, let age = model.nsAgeMinutes, age > 15 {
                Text("NS 血糖已经 \(Int(age)) 分钟没有更新。后台保活没开时这是正常现象——回到 App 会立刻补拉。")
                    .font(.caption).foregroundStyle(.orange)
            }

            Divider()

            HStack {
                Text("最近记录").font(.subheadline.weight(.semibold))
                Spacer()
                NavigationLink("全部记录") { HistoryView() }
                    .font(.caption)
            }

            if model.historyEvents.isEmpty {
                Text("还没有记录。NS 里的注射/碳水，以及本机闭环的每一针，都会出现在这里。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.historyEvents.prefix(4))) { event in
                    HistoryRow(event: event)
                }
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct HistoryRow: View {
    let event: HistoryEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(event.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.footnote.weight(.medium))
                Text(event.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(event.date, style: .time).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// 全部记录。按时间倒序，日期变化处插入分组标题。
struct HistoryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            if model.historyEvents.isEmpty {
                Text("还没有记录").foregroundStyle(.secondary)
            }
            ForEach(model.historyEvents) { event in
                HistoryRow(event: event)
            }
        }
        .navigationTitle("记录")
        .toolbar {
            Button("刷新 NS") {
                Task { await model.maybeRefreshNightscout(force: true) }
            }
        }
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
        .navigationTitle("后台保活")
    }
}
