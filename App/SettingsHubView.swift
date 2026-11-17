import SwiftUI
import X2Advisor

/// 设置总入口。
///
/// 之前每个功能都是首页上的一个按钮，功能一多就变成一排按钮墙。
/// 这里改成"分组列表 + 每行一句状态"：用户不用点进去就知道现在开没开、连没连。
struct SettingsHubView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("血糖单位", selection: Binding(get: { model.glucoseUnit },
                                                    set: { model.setGlucoseUnit($0) })) {
                    Text("mg/dL").tag(GlucoseDisplayUnit.mgdl)
                    Text("mmol/L").tag(GlucoseDisplayUnit.mmol)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("血糖单位")
            } footer: {
                Text("这里手动选的会覆盖「跟随来源」。单位只影响显示，闸门和闭环一直按 mg/dL 算。")
            }

            Section {
                NavigationLink {
                    PairingView()
                } label: {
                    settingRow(icon: "drop.fill", color: .blue, title: "胰岛素泵",
                               status: model.linkPhase.isReady ? "已连接" : "未连接",
                               statusColor: model.linkPhase.isReady ? .green : .secondary)
                }
                NavigationLink {
                    CGMSourceView()
                } label: {
                    settingRow(icon: "antenna.radiowaves.left.and.right", color: .green, title: "血糖来源",
                               status: model.cgmSource == .nightscout ? "Nightscout" : "泵 CGM",
                               statusColor: model.cgmSource == .nightscout ? .blue : .green)
                }
                NavigationLink {
                    ClosedLoopView()
                } label: {
                    settingRow(icon: "arrow.triangle.2.circlepath", color: .purple, title: "闭环控糖",
                               status: model.loopArmed
                                    ? (model.loopLiveDosing ? "开 · 真发针" : "开 · 演练")
                                    : "关",
                               statusColor: model.loopArmed ? .green : .secondary)
                }
                NavigationLink {
                    BolusView()
                } label: {
                    settingRow(icon: "syringe.fill", color: .red, title: "大剂量",
                               status: model.bolusEnabled ? "已启用" : "未启用",
                               statusColor: model.bolusEnabled ? .green : .secondary)
                }
            } header: {
                Text("核心设备与控糖")
            }

            Section {
                NavigationLink {
                    BackgroundKeepAliveView()
                } label: {
                    settingRow(icon: "waveform", color: .orange, title: "后台保活",
                               status: model.backgroundAudioEnabled ? "已开启" : "未开启",
                               statusColor: model.backgroundAudioEnabled ? .green : .secondary)
                }
                NavigationLink {
                    LiveActivityView()
                } label: {
                    settingRow(icon: "lock.rectangle.stack.fill", color: .purple, title: "锁屏显示",
                               status: model.liveActivityEnabled ? "已开启" : "未开启",
                               statusColor: model.liveActivityEnabled ? .green : .secondary)
                }
                NavigationLink {
                    BasalProfileView()
                } label: {
                    settingRow(icon: "chart.bar.fill", color: .teal, title: "基础率计划",
                               status: model.basalProfile == nil ? "未读取" : "已读取",
                               statusColor: model.basalProfile == nil ? .secondary : .green)
                }
                NavigationLink {
                    AdvisorSettingsView()
                } label: {
                    settingRow(icon: "slider.horizontal.3", color: .indigo, title: "剂量闸门",
                               status: "查看", statusColor: .secondary)
                }
                NavigationLink {
                    ControlIQView()
                } label: {
                    settingRow(icon: "waveform.path.ecg", color: .pink, title: "泵 Control-IQ",
                               status: model.controlIQ?.closedLoopEnabled == true ? "泵内已开启" : "未开启",
                               statusColor: model.controlIQ?.closedLoopEnabled == true ? .orange : .secondary)
                }
            } header: {
                Text("保活与显示")
            }

            Section {
                LabeledContent("版本", value: BuildInfo.version)
                LabeledContent("构建", value: BuildInfo.build)
                NavigationLink("诊断信息") { DiagnosticView() }
            } header: {
                Text("关于")
            }
        }
        .navigationTitle("设置")
        .onAppear {
            if model.backgroundAudioEnabled, !AudioKeepAlive.shared.isRunning {
                _ = AudioKeepAlive.shared.start()
            }
        }
    }

    private func settingRow(icon: String, color: Color, title: String,
                            status: String, statusColor: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color, in: RoundedRectangle(cornerRadius: 7))
            Text(title)
            Spacer()
            Text(status).font(.footnote).foregroundStyle(statusColor)
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
                row("目标下限 mg/dL", $model.loopSettings.targetLow)
                row("目标上限 mg/dL", $model.loopSettings.targetHigh)
                row("敏感系数 ISF", $model.loopSettings.isf)
                row("胰岛素作用时长（分钟）", $model.loopSettings.insulinDurationMinutes)
                row("单针上限 U", $model.loopSettings.maxSingleMicroBolus, step: 0.05)
                row("每小时上限 U", $model.loopSettings.maxHourlyMicroBolus, step: 0.05)
                row("IOB 上限 U", $model.loopSettings.maxIobUnits, step: 0.1)
                row("停止线 mg/dL", $model.loopSettings.lowSuspendThreshold)
                if let invalid = model.loopSettings.invalidReason {
                    Text(invalid).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("参数")
            } footer: {
                Text("目标、ISF 应与你泵里个人计划一致。默认值只是保守起点，不是处方。")
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
        .navigationTitle("高级参数")
        .onChange(of: model.loopSettings) { _ in model.saveLoopSettings() }
    }

    private func row(_ title: String, _ value: Binding<Double>, step: Double = 1) -> some View {
        LabeledContent(title) {
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
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
                row("目标下限 mg/dL", $draft.settings.targetLow)
                row("目标上限 mg/dL", $draft.settings.targetHigh)
                row("敏感系数 ISF", $draft.settings.isf)
                row("胰岛素作用时长（分钟）", $draft.settings.insulinDurationMinutes)
            } header: {
                Text("目标与敏感度")
            }

            Section {
                row("单针上限 U", $draft.settings.maxSingleMicroBolus, step: 0.05)
                row("每小时上限 U", $draft.settings.maxHourlyMicroBolus, step: 0.05)
                row("IOB 上限 U", $draft.settings.maxIobUnits, step: 0.1)
                row("停止线 mg/dL", $draft.settings.lowSuspendThreshold)
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
}

/// 接管自检页。
///
/// 顺序是刻意的：先刷新泵、再判定、最后才允许签发凭证。
/// 界面只负责把「哪一条没过」摆到最上面，不替用户做判断。
struct TakeoverCheckView: View {
    @EnvironmentObject var model: AppModel

    private var report: TakeoverCheck.Report? { model.takeoverReport }

    private var clearanceText: String {
        guard let verified = model.takeoverVerifiedAt else { return "未签发" }
        let minutes = Int(Date().timeIntervalSince(verified) / 60)
        return minutes <= 30 ? "有效（\(minutes) 分钟前签发）" : "已过期（\(minutes) 分钟前）"
    }

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await model.runTakeoverCheck() }
                } label: {
                    Label(model.takeoverChecking ? "正在自检…" : "重新自检", systemImage: "arrow.clockwise")
                }
                .disabled(model.takeoverChecking)

                LabeledContent("凭证", value: clearanceText)

                if let checked = model.takeoverCheckedAt {
                    Text("上次自检 " + checked.formatted(date: .omitted, time: .standard))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } header: {
                Text("自检")
            } footer: {
                Text("凭证有效期 30 分钟。泵的电量、药筒、Control-IQ 状态都会变，过期就重新核对一次。")
            }

            if let report {
                if let reason = report.firstBlockReason {
                    Section {
                        Text(reason).font(.footnote).foregroundStyle(.red)
                    } header: {
                        Text("先修这一条")
                    }
                }

                Section {
                    ForEach(report.items) { item in
                        checkRow(item)
                    }
                } header: {
                    Text("逐条核对")
                }

                if !report.warnings.isEmpty {
                    Section {
                        Toggle("我确认以上警告，仍要真发", isOn: $model.takeoverWarningsAcknowledged)
                    } footer: {
                        Text("警告项不是「必须修」，但每一条都对应一个真实的失效场景——例如断链后没有基础胰岛素、或泵自身报警不会响。")
                    }
                }

                Section {
                    Button {
                        model.grantTakeoverClearance()
                    } label: {
                        Label("自检通过，允许真发 30 分钟", systemImage: "checkmark.shield")
                    }
                    .disabled(!report.canProceed(warningsAcknowledged: model.takeoverWarningsAcknowledged))
                }
            } else {
                Section {
                    Text("还没跑过自检。点上面的「重新自检」——它会先刷新泵状态，再逐条判定。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("接管自检")
        .task {
            if model.takeoverReport == nil { await model.runTakeoverCheck() }
        }
    }

    private func checkRow(_ item: TakeoverCheck.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.passed ? "checkmark.circle.fill"
                                          : (item.severity == .blocker ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"))
                .foregroundStyle(item.passed ? Color.green
                                             : (item.severity == .blocker ? Color.red : Color.orange))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline.weight(.medium))
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
