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
