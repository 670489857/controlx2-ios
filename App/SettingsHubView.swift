import SwiftUI
import X2Advisor

/// 设置总入口。
///
/// 之前每个功能都是首页上的一个按钮，功能一多就变成一排按钮墙。
/// 这里改成"分组列表 + 每行一句状态"：用户不用点进去就知道现在开没开、连没连。
struct SettingsHubView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                deviceCard
                therapyCard
                backgroundCard
                safetyCard
                aboutCard
            }
            .padding(.horizontal, DS.pagePadding)
            .padding(.top, 6)
            .padding(.bottom, 34)
        }
        .background(PageBackground())
        .navigationTitle("设置")
        .onAppear {
            if model.backgroundAudioEnabled, !AudioKeepAlive.shared.isRunning {
                _ = AudioKeepAlive.shared.start()
            }
        }
    }

    // MARK: 设备

    /// 设备类设置：连了哪台泵、血糖从哪来、基础率计划是什么、读数和泵屏幕对没对上。
    private var deviceCard: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "设备与数据", icon: "dot.radiowaves.left.and.right")
            Card(padding: 18) {
                VStack(spacing: 0) {
                    NavigationLink { PairingView() } label: {
                        SettingRow(icon: "drop.fill",
                                   title: "胰岛素泵",
                                   subtitle: model.linkPhase.text,
                                   status: model.linkPhase.isReady ? (model.connectedName ?? "已连接") : "未连接",
                                   statusTint: model.linkPhase.isReady ? DS.ok : .secondary)
                    }
                    .buttonStyle(.plain)
                    RowRule()
                    NavigationLink { CGMSourceView() } label: {
                        SettingRow(icon: "antenna.radiowaves.left.and.right",
                                   tint: .teal,
                                   title: "血糖来源与单位",
                                   subtitle: "Nightscout 或泵 CGM",
                                   status: sourceSummary)
                    }
                    .buttonStyle(.plain)
                    RowRule()
                    NavigationLink { BasalProfileView() } label: {
                        SettingRow(icon: "chart.bar.fill",
                                   tint: .indigo,
                                   title: "基础率计划",
                                   subtitle: "只读，改不了泵",
                                   status: model.basalProfile == nil ? "未读取" : "已读取")
                    }
                    .buttonStyle(.plain)
                    RowRule()
                    NavigationLink { ReadingsCheckView() } label: {
                        SettingRow(icon: "checkmark.seal",
                                   tint: .gray,
                                   title: "读数核对",
                                   subtitle: "与泵屏幕逐项对一遍",
                                   status: nil)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var sourceSummary: String {
        let unit = model.effectiveGlucoseUnit == .mmol ? "mmol/L" : "mg/dL"
        let source = model.cgmSource == .nightscout ? "Nightscout" : "泵 CGM"
        return source + " · " + unit
    }

    // MARK: 控糖

    /// 控糖参数只有这一个入口。闭环的开关在首页的「闭环」里——
    /// 那是会往身体里送胰岛素的动作，不该和参数设置混在同一页。
    private var therapyCard: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "控糖与安全", icon: "slider.horizontal.3")
            Card(padding: 18) {
                VStack(spacing: 0) {
                    NavigationLink { AdvisorSettingsView() } label: {
                        SettingRow(icon: "shield.lefthalf.filled",
                                   tint: .orange,
                                   title: "剂量闸门与建议参数",
                                   subtitle: "单次 / 24h / 间隔 / 低血糖线")
                    }
                    .buttonStyle(.plain)
                    RowRule()
                    NavigationLink { SafetyView() } label: {
                        SettingRow(icon: "shield.lefthalf.filled",
                                   tint: DS.danger,
                                   title: "安全说明与边界",
                                   subtitle: "能做什么、为什么不能做什么")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 后台与显示

    private var backgroundCard: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "后台与显示", icon: "moon.stars")
            Card(padding: 18) {
                VStack(spacing: 0) {
                    NavigationLink { BackgroundKeepAliveView() } label: {
                        SettingRow(icon: "waveform",
                                   tint: .orange,
                                   title: "后台保活",
                                   subtitle: "锁屏后闭环还能继续跑的前提",
                                   status: model.backgroundAudioEnabled ? "已开启" : "未开启",
                                   statusTint: model.backgroundAudioEnabled ? DS.ok : .secondary)
                    }
                    .buttonStyle(.plain)
                    RowRule()
                    NavigationLink { LiveActivityView() } label: {
                        SettingRow(icon: "lock.rectangle.stack",
                                   tint: .teal,
                                   title: "锁屏显示",
                                   subtitle: "血糖、趋势、最近一针",
                                   status: model.liveActivityEnabled ? "已开启" : "未开启")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 安全与诊断

    private var safetyCard: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "诊断", icon: "cross.case")
            Card(padding: 18) {
                NavigationLink { DiagnosticView() } label: {
                    SettingRow(icon: "stethoscope",
                               tint: .gray,
                               title: "诊断日志",
                               subtitle: "报文收发与链路状态")
                }
                .buttonStyle(.plain)
            }
            Text("闭环开关、设定档、「接管自检」都在首页的「闭环」里——那里是唯一会往身体里送胰岛素的地方，不和参数混在一层。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.top, 6)
        }
    }

    // MARK: 关于

    private var aboutCard: some View {
        VStack(spacing: 0) {
            SectionTitle(text: "关于", icon: "info.circle")
            Card(padding: 18) {
                VStack(spacing: 12) {
                    HStack {
                        Text("版本").font(.system(size: 14))
                        Spacer()
                        Text(BuildInfo.version + " · b" + BuildInfo.build)
                            .font(.system(size: 14, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    RowRule(leading: 0)
                    Text("实验性工具，未经监管批准。任何治疗决定以泵屏幕与医嘱为准。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 闭环的高级参数。主页面只留"开关、体重、每日量、上限"，细节收在这里。
/// 把 ISF、单针上限这些挪到二级页，是为了让第一次用的人不至于一上来就面对十几个输入框。
struct LoopAdvancedView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("血糖单位", selection: Binding(get: { model.glucoseUnit },
                                                    set: { model.setGlucoseUnit($0) })) {
                    ForEach(GlucoseDisplayUnit.allCases.filter { $0 != .auto }) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("显示")
            } footer: {
                Text("只改显示，闸门和闭环一直按 mg/dL 算。默认 mmol/L。")
            }

            Section {
                glucoseRow("目标上限", $model.loopSettings.targetHigh)
                glucoseRow("目标下限", $model.loopSettings.targetLow)
                isfRow
                row("胰岛素作用时长（分钟）", $model.loopSettings.insulinDurationMinutes)
                row("单针上限 U", $model.loopSettings.maxSingleMicroBolus, step: 0.05)
                row("每小时上限 U", $model.loopSettings.maxHourlyMicroBolus, step: 0.05)
                row("IOB 上限 U", $model.loopSettings.maxIobUnits, step: 0.1)
                glucoseRow("停止线", $model.loopSettings.lowSuspendThreshold)
                if let invalid = model.loopSettings.invalidReason {
                    Text(invalid).font(.footnote).foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("单拍追加上限（倍基础量）").font(.footnote)
                        Spacer()
                        TextField("4", value: $model.loopSettings.maxCorrectionMultipleOfBasal,
                                  format: .number.precision(.fractionLength(0...1)))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .monospacedDigit()
                            .font(.footnote)
                            .frame(width: 70)
                    }
                    Text("这一项才是「一拍最多能打多少」的真正天花板。追加量 ≤ 这段基础量的 N 倍，"
                         + "4 倍够日常纠高；想让一拍多打就往上调，代价是参数填错时一针冲得更狠。"
                         + perTickHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("参数")
            } footer: {
                Text("目标、ISF 应与你泵里个人计划一致。默认值只是保守起点，不是处方。阈值按「血糖单位」显示：mmol 保留 1 位小数，存进去仍是 mg/dL 整数。")
            }

            Section {
                Toggle("低血糖停手后自动重新闭环", isOn: $model.loopSettings.autoResumeAfterLow)
            } header: {
                Text("低血糖之后")
            } footer: {
                Text("停手后每 5 分钟读一次血糖，回到停止线以上并连续两拍确认，就按原来的形态重新开始（原来演练就还是演练，原来真发就还是真发）。")
            }

            Section {
                row("泵自己在跑的基础率 U/h", $model.loopSettings.pumpBasalUnitsPerHour, step: 0.05)
                Toggle("已确认泵的基础率已按上面的值设置", isOn: $model.loopZeroBasalConfirmed)
            } header: {
                Text("接管模式")
            } footer: {
                Text("填 0 = 泵基础率已设成 0，全部基础胰岛素由 App 补（断链就没有基础量，风险最高）。填 0.2–0.4 = 泵留安全下限，App 只补差额。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(PageBackground())
        .navigationTitle("高级参数")
        .onChange(of: model.loopSettings) { _ in model.saveLoopSettings() }
    }

    /// 把当前参数折算成一句话：「这一拍最多能打多少」。
    /// 用户改数字时最想知道的就是这个结果，而不是去心算基础率 ÷ 12 × 倍数。
    private var perTickHint: String {
        let basal = model.basalProfile?.currentSegment?.basalRateUnitsPerHour ?? 0
        guard basal > 0 else { return "" }
        let tickBasal = basal * model.loopSettings.tickSeconds / 3600
        let capByMultiple = tickBasal * model.loopSettings.maxCorrectionMultipleOfBasal
        let cap = min(model.loopSettings.maxSingleMicroBolus, capByMultiple)
        return String(format: " 按当前基础率 %.2f U/h 算，这一拍最多约 %.2f U（再受单针上限与 IOB 余量约束）。", basal, cap)
    }

    private func row(_ title: String, _ value: Binding<Double>, step: Double = 1) -> some View {
        LabeledContent(title) {
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .monospacedDigit()
        }
    }

    /// 血糖阈值这类字段：内部一律存 mg/dL，显示跟着全局单位走。
    /// 切到 mmol 时输入 5.5，存下去是 99 mg/dL——闭环判断永远用 mg/dL，不会因为显示单位改变行为。
    /// ISF 的单位是「每 1 U 降多少血糖」。切到 mmol 时显示成 mmol/L per U，
    /// 存进去仍然是 mg/dL per U。
    private var isfRow: some View {
        let mmol = model.effectiveGlucoseUnit == .mmol
        let display = Binding<Double>(
            get: { mmol ? (model.loopSettings.isf / 18.0182 * 10).rounded() / 10 : model.loopSettings.isf },
            set: { input in model.loopSettings.isf = mmol ? (input * 18.0182 * 10).rounded() / 10 : input })
        return LabeledContent(mmol ? "敏感系数 ISF（mmol/L per U）" : "敏感系数 ISF（mg/dL per U）") {
            TextField("", value: display, format: .number.precision(.fractionLength(0...1)))
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .monospacedDigit()
        }
    }

    private func glucoseRow(_ title: String, _ value: Binding<Double>) -> some View {
        let mmol = model.effectiveGlucoseUnit == .mmol
        let display = Binding<Double>(
            get: {
                mmol ? (value.wrappedValue / 18.0182 * 10).rounded() / 10
                     : value.wrappedValue.rounded()
            },
            set: { input in
                value.wrappedValue = mmol ? (input * 18.0182).rounded() : input.rounded()
            })
        return LabeledContent("\(title) \(mmol ? "mmol/L" : "mg/dL")") {
            TextField("", value: display, format: .number.precision(.fractionLength(0...1)))
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .monospacedDigit()
        }
    }
}

/// 锁屏即时动态的开关页。
struct LiveActivityView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("锁屏显示（即时动态）", isOn: Binding(
                    get: { model.liveActivityEnabled },
                    set: { model.setLiveActivity($0) }))
                if let message = model.liveActivityMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("锁屏")
            } footer: {
                Text("开启后锁屏和灵动岛上会显示血糖、趋势、IOB、闭环状态和最近一针。这里只显示，不能发针——发针仍然只能在 App 里经过闸门。")
            }

            Section {
                Text("1. 动态在 App 每分钟刷新时更新一次；系统对刷新频率有限制，锁屏上的数字可能比 App 里慢一两分钟。")
                Text("2. 如果系统里关掉了「实时活动」，这里打开会失败，并提示你去 设置 → ControlX2 → 实时活动。")
                Text("3. 锁屏内容可能在他人可见的位置——不想让别人看到血糖，就别开。")
            } header: {
                Text("要知道的事")
            }
            .font(.footnote)
        }
        .scrollContentBackground(.hidden)
        .background(PageBackground())
        .navigationTitle("锁屏显示")
    }
}

/// 编辑一套设定档。
struct LoopPresetEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LoopPreset
    @State private var confirmDelete = false

    init(preset: LoopPreset) {
        _draft = State(initialValue: preset)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("名称") {
                    TextField("设定档名称", text: $draft.name)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section {
                row("体重", $draft.settings.weightKg)
                row("每日胰岛素 U", $draft.settings.totalDailyInsulinUnits, step: 0.5)
                row("24h 累计上限 U", $draft.settings.maxDailyUnits)
            } header: {
                Text("基础")
            }

            Section {
                glucoseRow("目标下限", $draft.settings.targetLow)
                glucoseRow("目标上限", $draft.settings.targetHigh)
                row("敏感系数 ISF", $draft.settings.isf)
                row("胰岛素作用时长（分钟）", $draft.settings.insulinDurationMinutes)
            } header: {
                Text("目标与敏感度")
            }

            Section {
                row("单针上限 U", $draft.settings.maxSingleMicroBolus, step: 0.05)
                row("每小时上限 U", $draft.settings.maxHourlyMicroBolus, step: 0.05)
                row("IOB 上限 U", $draft.settings.maxIobUnits, step: 0.1)
                glucoseRow("停止线", $draft.settings.lowSuspendThreshold)
                row("泵自己在跑的基础率 U/h", $draft.settings.pumpBasalUnitsPerHour, step: 0.05)
                if let invalid = draft.settings.invalidReason {
                    Text(invalid).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("闸门")
            }

            Section {
                Button("保存这套参数") {
                    draft.updatedAt = Date()
                    model.updatePreset(draft)
                    dismiss()
                }
                .disabled(draft.settings.invalidReason != nil || draft.name.isEmpty)
                Button("删除此设定档", role: .destructive) { confirmDelete = true }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PageBackground())
        .navigationTitle("编辑设定档")
        .confirmationDialog("删除这套设定档？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                model.deletePreset(draft.id)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除只影响这套参数，当前运行中的闭环不会因此停止。")
        }
    }

    private func row(_ title: String, _ value: Binding<Double>, step: Double = 1) -> some View {
        LabeledContent(title) {
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .monospacedDigit()
        }
    }

    private func glucoseRow(_ title: String, _ value: Binding<Double>) -> some View {
        let mmol = model.effectiveGlucoseUnit == .mmol
        let display = Binding<Double>(
            get: {
                mmol ? (value.wrappedValue / 18.0182 * 10).rounded() / 10
                     : value.wrappedValue.rounded()
            },
            set: { input in
                value.wrappedValue = mmol ? (input * 18.0182).rounded() : input.rounded()
            })
        return LabeledContent("\(title) \(mmol ? "mmol/L" : "mg/dL")") {
            TextField("", value: display, format: .number.precision(.fractionLength(0...1)))
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .monospacedDigit()
        }
    }
}

/// 接管自检页。
///
/// 顺序是刻意的：先刷新泵、再判定、最后才允许签发凭证。
/// 界面只把"哪一条没过"摆到最上面，不替用户做判断。
struct TakeoverCheckView: View {
    @EnvironmentObject var model: AppModel

    private var report: TakeoverCheck.Report? { model.takeoverReport }

    private var clearanceText: String {
        guard let verified = model.takeoverVerifiedAt else { return "未通过" }
        let minutes = Int(Date().timeIntervalSince(verified) / 60)
        return minutes < 1 ? "已通过 · 刚刚" : "已通过 · \(minutes) 分钟前签发"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.gap) {
                headerCard
                if let report {
                    if let reason = report.firstBlockReason {
                        blockCard(reason)
                    }
                    checksCard(report)
                    if !report.warnings.isEmpty {
                        warningAckCard(report)
                    }
                } else {
                    Card {
                        Text("还没跑过自检。点上面的「重新自检」——它会先刷新泵状态，再逐条判定。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, DS.pagePadding)
            .padding(.top, 6)
            .padding(.bottom, 34)
        }
        .background(PageBackground())
        .navigationTitle("接管自检")
        .task {
            if model.takeoverReport == nil { await model.runTakeoverCheck() }
        }
    }

    private var headerCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("凭证").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(clearanceText)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(model.takeoverVerifiedAt == nil ? Color.secondary : DS.ok)
                    }
                    Spacer()
                    if model.takeoverChecking { ProgressView().controlSize(.small) }
                }

                if let checked = model.takeoverCheckedAt {
                    Text("上次自检 " + checked.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                GhostButton(title: model.takeoverChecking ? "正在自检…" : "重新自检",
                            systemImage: "arrow.clockwise") {
                    Task { await model.runTakeoverCheck() }
                }
                .disabled(model.takeoverChecking)

                Text("自检全绿就自动生效，不用点确认。凭证一直有效，只有改参数才会作废；泵的电量、药筒、Control-IQ 状态变了，建议重跑一次。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func blockCard(_ reason: String) -> some View {
        Card(tint: DS.danger, padding: 16) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(DS.danger)
                VStack(alignment: .leading, spacing: 3) {
                    Text("先修这一条").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.danger)
                    Text(reason)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func checksCard(_ report: TakeoverCheck.Report) -> some View {
        Card(title: "逐条核对", subtitle: "硬性项必须先修，警告项可以确认后放行", padding: 18) {
            VStack(spacing: 0) {
                ForEach(report.items) { item in
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: item.passed ? "checkmark.circle.fill"
                                                      : (item.severity == .blocker ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"))
                            .font(.system(size: 14))
                            .foregroundStyle(item.passed ? DS.ok : (item.severity == .blocker ? DS.danger : DS.warn))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 13, weight: .medium))
                            Text(item.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)
                    if item.id != report.items.last?.id { RowRule(leading: 29) }
                }
            }
        }
    }

    private func warningAckCard(_ report: TakeoverCheck.Report) -> some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $model.takeoverWarningsAcknowledged) {
                    Text("我确认以上 \(report.warnings.count) 条警告，仍要真发")
                        .font(.system(size: 14, weight: .medium))
                }
                .tint(DS.warn)
                Text("警告项不是「必须修」，但每一条都对应一个真实的失效场景——断链后没有基础胰岛素、泵自身报警不会响、或者 App 进后台就停摆。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func ctaCard(_ report: TakeoverCheck.Report) -> some View {
        VStack(spacing: 10) {
            PrimaryButton(title: "自检通过，允许真发",
                          systemImage: "checkmark.shield",
                          disabled: !report.canProceed(warningsAcknowledged: model.takeoverWarningsAcknowledged)) {
                model.grantTakeoverClearance()
            }
            if !report.blockers.isEmpty {
                Text("还有 \(report.blockers.count) 条硬性项没过")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
