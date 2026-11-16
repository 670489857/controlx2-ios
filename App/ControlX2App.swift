import SwiftUI
import Charts
import PumpX2Kit
import PumpX2BLE
import X2Advisor
#if canImport(UIKit)
import UIKit
#endif

@main
struct ControlX2App: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(model) }
    }
}

/// 构建信息。版本号来自仓库根的 VERSION 文件，由 CI 注入到
/// MARKETING_VERSION / CURRENT_PROJECT_VERSION / BuildGitSHA。
/// 目的很实际：手上同时有几个 IPA 时，能一眼确认装的是哪一版、对应哪个提交。
enum BuildInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    static var gitSHA: String {
        let sha = Bundle.main.object(forInfoDictionaryKey: "BuildGitSHA") as? String ?? ""
        // 未替换的 $(BUILD_GIT_SHA) 说明是不带注入的本地构建，别把它当提交号显示
        return sha.isEmpty || sha.hasPrefix("$(") ? "local" : sha
    }

    static var display: String { "\(version) (\(build))" }

    static var full: String { gitSHA == "local" ? display : "\(display) · \(gitSHA)" }
}

/// UI 层状态机。只负责展示与用户动作，协议细节全部在 PumpX2Kit。
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case disclaimer
        case discovery
        case pairing
        case dashboard
    }

    @Published var phase: Phase = .disclaimer
    @Published var pumps: [BLETransport.DiscoveredPump] = []
    @Published var isScanning = false
    /// 打开后连非泵设备也列出来，用于区分「蓝牙没工作」和「泵没在广播」
    @Published var showAllDevices = false
    /// 配对页上发生过断链 → 泵屏幕上的码大概率已作废，界面要提示重新读
    @Published var codeLikelyStale = false
    @Published var pairingCode = ""
    @Published var pairingProgress = 0
    @Published var errorText: String?
    @Published var connectedName: String?
    /// 链路阶段，来自 BLETransport。用来把"等系统配对弹窗"这件事显示出来，
    /// 而不是让用户对着一个不动的进度条猜。
    @Published var linkPhase: BLETransport.LinkPhase = .idle
    @Published var apiVersion: String?
    @Published var insulinUnits: String = "—"
    @Published var lastUpdated: String = "—"
    @Published var glucoseText: String = "—"
    @Published var glucoseSub: String = ""
    @Published var trendSymbol: String = ""
    @Published var iobText: String = "—"
    @Published var batteryText: String = "—"
    @Published var basalText: String = "—"
    @Published var hasLiveData = false

    // 预测与建议
    @Published var samples: [GlucoseSample] = []
    @Published var prediction: PredictionResult?
    @Published var advice: DoseAdvice?
    @Published var advisorSettings: AdvisorSettings
    @Published var shadowCount: Int = 0
    /// IOB 读不到时预测无意义，UI 需要据此降级而不是显示 0
    @Published var iobUnavailable = false

    private let transport = BLETransport()
    private lazy var session = PumpSession(link: transport)
    private let store: CredentialStore = KeychainCredentialStore()
    private let glucoseStore: GlucoseHistoryStore
    private let shadowLog: ShadowLog
    private var currentPumpID: UUID?
    private var pollTask: Task<Void, Never>?
    private var lastShadowAt: Date?

    private static let settingsKey = "advisorSettings"

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        glucoseStore = GlucoseHistoryStore(fileURL: docs.appendingPathComponent("glucose.json"))
        shadowLog = ShadowLog(fileURL: docs.appendingPathComponent("shadow.jsonl"))
        advisorSettings = Self.loadSettings()
        samples = glucoseStore.recent(minutes: 180)
        shadowCount = shadowLog.summarize().total

        // 已接受过免责声明就直接进扫描页；未接受则每次启动都要求确认
        if UserDefaults.standard.bool(forKey: "disclaimerAccepted") {
            phase = .discovery
        }
        transport.onDiscover = { [weak self] pump in
            Task { @MainActor in
                guard let self else { return }
                // 同一个 peripheral 会因 scan response 补全名字而多次回调，按 id 覆盖而不是只去重
                if let idx = self.pumps.firstIndex(where: { $0.id == pump.id }) {
                    self.pumps[idx] = pump
                } else {
                    self.pumps.append(pump)
                }
            }
        }
        transport.onDisconnect = { [weak self] in
            Task { @MainActor in
                // 断开本身不弹框：要不要报错由 linkPhase 决定，
                // 否则自动重连的每一次断开都会打断用户一次
                self?.connectedName = nil
                // 配对页上断过链：泵那边的码基本已经换了，得提醒重新读，
                // 否则用户会拿着旧码一直重试，每次都在第 6 条报文被拒
                if self?.phase == .pairing { self?.codeLikelyStale = true }
            }
            // 会话级状态（instanceId、密钥）必须一起清掉，否则重连后会沿用旧值
            Task { await self?.session.resetSession() }
        }
        transport.onPhase = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                self.linkPhase = p
                if case let .failed(message) = p {
                    self.phase = .discovery
                    self.errorText = message
                }
                // 链路就绪后**不**自动发授权帧。新版固件（v7.7+）只认 JPAKE，
                // 先发 0x10 会被当成不认识的报文并立刻断链；旧固件的 0x10 也要
                // 等用户输完 16 位码才有意义。授权一律由用户点「开始配对」触发。
            }
        }
        transport.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .poweredOn: self.errorText = nil
                case .poweredOff: self.errorText = "蓝牙已关闭，请在控制中心打开"
                case .unauthorized: self.errorText = "未授权蓝牙访问，请到「设置 → ControlX2」开启"
                case .unsupported: self.errorText = "此设备不支持蓝牙低功耗"
                case .resetting: self.errorText = "蓝牙正在重置，请稍候"
                default: break
                }
            }
        }
    }

    func acceptDisclaimer() {
        UserDefaults.standard.set(true, forKey: "disclaimerAccepted")
        phase = .discovery
        startScan()
    }

    func startScan() {
        pumps = []
        isScanning = true
        transport.startScan(includeNonPumps: showAllDevices)
        Task {
            // 泵的广播间隔可能到 1–2 秒，12 秒太短；给 30 秒
            try? await Task.sleep(for: .seconds(30))
            await MainActor.run { self.isScanning = false }
        }
    }

    func toggleShowAll(_ on: Bool) {
        showAllDevices = on
        startScan()
    }

    func connect(_ pump: BLETransport.DiscoveredPump) {
        transport.stopScan()
        isScanning = false
        connectedName = pump.name
        currentPumpID = pump.id
        linkPhase = .connecting
        transport.connect(pump.id)
        phase = .pairing
        pairingProgress = 0
        Task {
            await session.start()
            do {
                // 先确认链路真的可用再让用户输码。iOS 的系统配对弹窗需要用户手动
                // 点一下，这期间链路是"连上但未加密"的状态，写什么都失败。
                try await transport.waitReady()
            } catch {
                await MainActor.run {
                    self.errorText = "\(pump.name) 未能建立连接：\(error.localizedDescription)"
                    self.phase = .discovery
                    self.connectedName = nil
                    self.currentPumpID = nil
                    self.transport.disconnect()
                    self.startScan()
                }
                return
            }
            // 有保存的凭据就先做 JPAKE 确认（不需要配对码）；
            // 没有就停在配对页，等用户从泵屏幕上读出 6 位码。
            await attemptResume()
        }
    }

    /// 连接后优先用已保存的凭据恢复会话；泵不认才退回输入配对码。
    private func attemptResume() async {
        guard let id = currentPumpID, let saved = store.load(for: id.uuidString) else { return }
        do {
            let result = try await session.resume(with: saved) { p in
                Task { @MainActor in self.pairingProgress = p }
            }
            switch result {
            case .resumed:
                try? await session.refresh()
                await refreshFromSession()
                phase = .dashboard
                startPolling()
            case .needsPairing:
                store.delete(for: id.uuidString)
                errorText = "泵未认可已保存的凭据（可能重置过或换了泵），请重新输入配对码"
            }
        } catch {
            errorText = "自动恢复失败：\(error)"
        }
    }

    /// 删除本机保存的配对凭据，并断开当前连接
    func forgetPump() {
        if let id = currentPumpID { store.delete(for: id.uuidString) }
        pollTask?.cancel()
        transport.disconnect()
        connectedName = nil
        currentPumpID = nil
        hasLiveData = false
        glucoseText = "—"
        phase = .discovery
        startScan()
    }

    func pair() {
        // 旧固件 16 位（字母数字），v7.7+ 与 Mobi 为 6 位数字；分隔符在归一化时去掉
        let code = JPAKEAuth.normalize(pairingCode)
        guard code.count == 6 || code.count == 16 else {
            errorText = "配对码应为 6 位数字（v7.7+ / Mobi）或 16 位字母数字（更早固件）"
            return
        }
        errorText = nil
        pairingProgress = 0
        codeLikelyStale = false
        // 授权期间关掉自动重连：泵的配对码跟当次连接绑定，静默重连会让六位数字
        // 悄悄失效，而界面还停在配对页等着，看起来就像"码对了还是不认"。
        transport.setAutoReconnect(false)
        Task {
            defer { transport.setAutoReconnect(true) }
            do {
                // 链路可能在输码期间断掉（系统配对未完成时泵会主动断开），
                // 这里再确认一次，避免把"链路已断"报成"配对码错误"
                try await transport.waitReady()
                try await session.pair(code: code) { p in
                    Task { @MainActor in self.pairingProgress = p }
                }
                // 配对成功即刻落盘：下次连接用 derivedSecret 做快速确认
                if let creds = await session.credentials, let id = currentPumpID {
                    store.save(creds, for: id.uuidString)
                }
                try await session.refresh()
                await refreshFromSession()
                phase = .dashboard
                startPolling()
            } catch {
                errorText = pairingFailureText(error)
            }
        }
    }

    /// 配对失败文案。
    ///
    /// 第 5 条报文（0x28 密钥确认）被拒是唯一有明确含义的失败：泵算出的会话密钥
    /// 和我们不同，也就是两边手里不是同一个 6 位码。其它步骤失败多半是链路问题，
    /// 提示必须分开写，否则用户只会反复重输同一个已经作废的码。
    private func pairingFailureText(_ error: Error) -> String {
        if let pe = error as? ProtocolError,
           case let .authStepFailed(step, opCode, _) = pe, step == 5, opCode == 0x28 {
            return """
            泵在最后一步「密钥确认」拒绝了这次配对。

            含义：泵算出的会话密钥和我们发过去的不一致，说明两边手里不是同一个 6 位码，最常见的原因是码已经作废。

            请按这个顺序重来（顺序很关键）：
            1. 留在本页，等上面显示「链路已就绪」；若已断开，先连回去
            2. 这时再去泵上点「配对设备 / Pair Device」，读新出现的 6 位数字
            3. 不要离开 App，直接输入、点「开始配对」

            别复用上一次的数字：泵每失败一次就会换码，重连也会换。

            这一版起，失败原因写在「诊断日志」里了（哪一步、哪个 opCode、解析到哪一字节）。
            点诊断页右上角的分享按钮可以导出成文件。
            """
        }
        return """
        配对失败：\(error.localizedDescription)

        请逐项确认：泵上「移动连接」已开、泵上原有的配对设备已解除、t:connect 已彻底退出、输入的是泵屏幕当前显示的码。

        「诊断日志」里有每一步的细节（发到哪条、收到什么、解析结果），
        右上角分享按钮可导出成文件。
        """
    }

    /// 诊断日志：把最近几百条收发原样导出。排障时这是唯一能区分
    /// 「报文没发出去」「泵没回」「回了个不相干的」的依据。
    func traceDump() -> String {
        let body = transport.trace.dump()
        return body.isEmpty ? "（还没有收发记录，先连接一次泵）" : body
    }

    func clearTrace() { transport.trace.clear() }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                try? await session.refresh()
                await refreshFromSession()
            }
        }
    }

    func refresh() {
        Task {
            try? await session.refresh()
            await refreshFromSession()
        }
    }

    private func refreshFromSession() async {
        let snap = await session.snapshot
        apiVersion = snap.apiVersion?.description

        if let units = snap.insulinUnits {
            insulinUnits = String(format: "%.0f U", units)
        }
        if let g = snap.glucoseMgdl, let mmol = snap.glucoseMmol {
            glucoseText = "\(g)"
            glucoseSub = String(format: "%.1f mmol/L", mmol)
            hasLiveData = true
        }
        trendSymbol = Self.trendSymbol(for: snap.glucoseTrend)
        if let iob = snap.iobUnits {
            iobText = String(format: "%.2f U", iob)
        }
        if let b = snap.batteryPercent {
            batteryText = "\(b)%"
        }
        if let rate = snap.basalRate {
            basalText = String(format: "%.2f U/h", rate)
        }
        if let t = snap.lastUpdated {
            lastUpdated = t.formatted(date: .omitted, time: .standard)
        }
        updateAdvisor(with: snap)
    }

    /// 把一次快照喂给预测与建议层。
    ///
    /// 这里做的事情全部是"算"，没有一条指令会发给泵。影子记录也在这里落盘，
    /// 目的是两周后能拿真实数据回答"如果自动，会不会做蠢事"。
    private func updateAdvisor(with snap: PumpSession.Snapshot) {
        let now = Date()

        // 采样时间用快照的抓取时刻。EGV 报文里虽然带时间戳，但那是泵自己的
        // 时钟起点，未与 Unix 纪元对齐，直接用会把所有点挪到 1970 年。
        if let g = snap.glucoseMgdl {
            glucoseStore.append(GlucoseSample(
                timestamp: snap.lastUpdated ?? now,
                mgdl: g,
                trendCode: snap.glucoseTrend
            ))
        }
        samples = glucoseStore.recent(minutes: 180, now: now)

        // IOB 读不到就不预测。用 0 顶替等于假设"体内没有活性胰岛素"，
        // 这正是最容易导致过量建议的错误假设。
        guard let iob = snap.iobUnits else {
            iobUnavailable = true
            prediction = nil
            advice = nil
            return
        }
        iobUnavailable = false

        guard let latest = glucoseStore.latest else {
            prediction = nil
            advice = nil
            return
        }

        let predictor = BGPPredictor()
        let pred = predictor.predict(.init(
            currentBg: Double(latest.mgdl),
            now: now,
            iob: iob,
            isf: advisorSettings.isf,
            carbsOnBoard: 0,
            carbRatio: advisorSettings.carbRatio,
            horizonMinutes: 240,
            lowThreshold: advisorSettings.lowThreshold,
            highThreshold: 180
        ))
        prediction = pred

        let advisor = DoseAdvisor(settings: advisorSettings, predictor: predictor)
        let decision = advisor.advise(.init(
            now: now,
            latest: latest,
            iob: iob,
            carbsOnBoard: 0,
            lastBolusAt: nil,
            measuredSlope: glucoseStore.recentSlope(now: now)
        ))
        advice = decision

        // 影子记录按 CGM 节奏写，不用轮询节奏——轮询是 60 秒一次，
        // 按它写会把同一个读数记四遍，统计出来的"建议频率"会虚高四倍。
        if lastShadowAt.map({ now.timeIntervalSince($0) >= 270 }) ?? true {
            lastShadowAt = now
            var capped = false
            if case let .correct(_, _, c) = decision { capped = c }
            shadowLog.append(ShadowRecord(
                timestamp: now,
                bg: latest.mgdl,
                trendCode: latest.trendCode,
                iob: iob,
                carbsOnBoard: 0,
                eventualBg: pred.eventualBg,
                suggestedUnits: decision.suggestedUnits,
                holdReason: decision.holdReason?.rawValue,
                capped: capped
            ))
            shadowCount = shadowLog.summarize().total
        }
    }

    // MARK: 设置

    static func loadSettings() -> AdvisorSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let s = try? JSONDecoder().decode(AdvisorSettings.self, from: data)
        else { return AdvisorSettings() }
        return s
    }

    func saveSettings() {
        guard let data = try? JSONEncoder().encode(advisorSettings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
        // 参数一改就要重算，否则界面还挂着旧参数算出来的剂量
        Task {
            let snap = await session.snapshot
            updateAdvisor(with: snap)
        }
    }

    func clearShadowLog() {
        shadowLog.reset()
        shadowCount = 0
    }

    /// 趋势码沿用 Dexcom 的 0–9 编码（Tandem 未在协议里另行定义），实际箭头以泵屏幕为准。
    static func trendSymbol(for code: Int?) -> String {
        switch code {
        case 1, 2: return "arrow.up.up"
        case 3: return "arrow.up.right"
        case 4: return "arrow.right"
        case 5: return "arrow.down.right"
        case 6, 7: return "arrow.down.down"
        default: return ""
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var showDiag = false

    var body: some View {
        NavigationStack {
            switch model.phase {
            case .disclaimer: DisclaimerView()
            case .discovery: DiscoveryView()
            case .pairing: PairingView()
            case .dashboard: DashboardView()
            }
        }
        .alert("提示", isPresented: Binding(get: { model.errorText != nil },
                                          set: { if !$0 { model.errorText = nil } })) {
            // 失败后最需要的是「这一秒到底收发了什么」，把入口直接放在弹窗上，
            // 不让用户再去翻菜单。很多故障只在这一刻可复现。
            Button("查看收发日志") {
                showDiag = true
            }
            Button("知道了", role: .cancel) { model.errorText = nil }
        } message: {
            Text(model.errorText ?? "")
        }
        .sheet(isPresented: $showDiag) {
            NavigationStack {
                DiagnosticView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("关闭") { showDiag = false }
                        }
                    }
            }
        }
    }
}

struct DisclaimerView: View {
    @EnvironmentObject var model: AppModel
    @State private var accepted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("控制胰岛素泵是一个高风险操作").font(.title2).bold()
                Group {
                    Text("本应用是实验性研究工具，未经任何监管机构批准，与 Tandem、Dexcom 无关联。")
                    Text("本版本只提供「配对」与「读取状态」，不包含任何输注指令（大剂量、基础率）。")
                    Text("读数可能滞后或错误，任何治疗决定都必须以泵屏幕为准。")
                    Text("继续使用即表示你理解并自担全部风险。")
                }
                .font(.callout)

                Toggle("我已阅读并理解上述风险", isOn: $accepted)
                Button("继续") { model.acceptDisclaimer() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!accepted)
            }
            .padding()
        }
    }
}

struct DiscoveryView: View {
    @EnvironmentObject var model: AppModel

    private var candidates: [BLETransport.DiscoveredPump] {
        model.pumps.filter(\.isPumpCandidate)
    }
    private var others: [BLETransport.DiscoveredPump] {
        model.pumps.filter { !$0.isPumpCandidate }
    }

    var body: some View {
        List {
            Section("附近的泵") {
                if candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            if model.isScanning { ProgressView() }
                            Text(model.isScanning ? "正在扫描…" : "没有发现泵")
                                .foregroundStyle(.secondary)
                        }
                        if !model.isScanning {
                            if model.showAllDevices {
                                Text("扫到了 \(others.count) 个其他蓝牙设备，但没有一个像泵。蓝牙本身是通的，问题在泵那一端。")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("打开下面的开关，可以看到附近所有蓝牙设备——用来判断是蓝牙没工作还是泵没广播。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                ForEach(candidates) { pump in
                    Button {
                        model.connect(pump)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(pump.name)
                                Text(pump.id.uuidString.prefix(8))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(pump.rssi) dBm")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if model.showAllDevices {
                Section("全部蓝牙设备") {
                    if others.isEmpty {
                        Text("没有其他设备").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(others) { device in
                        HStack {
                            Text(device.name).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(device.rssi) dBm")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Toggle("显示全部蓝牙设备", isOn: Binding(
                    get: { model.showAllDevices },
                    set: { model.toggleShowAll($0) }
                ))
            } footer: {
                Text("用来判断是「蓝牙没工作」还是「泵没在广播」。如果打开后能看到一堆设备但列表里没有泵，问题在泵那一端，不在 App。")
            }

            Section("扫不到泵时依次确认") {
                ForEach([
                    "① 泵上：设置 → 蓝牙 → 打开，屏幕顶部出现蓝牙图标",
                    "② 泵上：设置 → 蓝牙 → 添加设备，泵这时才主动广播",
                    "③ 官方 t:connect 或另一台手机占着连接，先在那边断开",
                    "④ iOS 设置 → ControlX2 → 蓝牙，必须为开启",
                ], id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("选择泵")
        .toolbar {
            Button("重新扫描") { model.startScan() }
        }
        .onAppear { if model.pumps.isEmpty { model.startScan() } }
    }
}

struct PairingView: View {
    @EnvironmentObject var model: AppModel

    private var linkColor: Color {
        switch model.linkPhase {
        case .ready: return .green
        case .waitingForPairing, .reconnecting: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 第一屏先说清链路状态。iOS 的系统配对弹窗与这里的配对码是两件事，
            // 不分开讲，用户会把"系统弹窗没点"当成"配对码错"。
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(linkColor).frame(width: 8, height: 8)
                    Text(model.linkPhase.text).font(.footnote)
                    if !model.linkPhase.isReady { ProgressView().controlSize(.mini) }
                }
                if model.linkPhase.isWaitingForUser {
                    Text("iPhone 上弹出了「蓝牙配对请求 tslim X2」，点「配对」。如果随后还要输入 PIN，就输泵屏幕上那 6 位码。这一步不做完，下面的配对码发了也没用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 8) {
                Text("按这个顺序做").font(.headline)
                Label("设置 → 蓝牙：打开「移动连接 / Mobile Connection」", systemImage: "1.circle.fill")
                Label("同一页里若显示已配对的手机，先「解除配对」（泵只记一台）", systemImage: "2.circle.fill")
                Label("先让本页显示「链路已就绪」，再点泵上的「配对设备 / Pair Device」", systemImage: "3.circle.fill")
                Label("读泵屏幕上的 6 位数字，30 秒内输入并开始配对", systemImage: "4.circle.fill")
                Text("顺序尽量别颠倒：泵的码通常只对当次连接有效，先读码再连、或者中途断线重连，这个码可能就作废了。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("另外：如果装着 t:connect，先彻底退出（后台也要杀掉），它和本 App 会抢同一台泵。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

            if model.codeLikelyStale {
                Label("刚才链路断过一次，泵上的码很可能已经换了。请回泵上重按「配对设备」读新码再输入。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("输入泵屏幕上显示的配对码").font(.headline)
            TextField("000000 或 A1B2-C3D4-E5F6-7890", text: $model.pairingCode)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .onChange(of: model.pairingCode) { _, new in
                    let filtered = new.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                    model.pairingCode = String(filtered.prefix(19))
                }
            if model.pairingProgress > 0 {
                ProgressView(value: Double(model.pairingProgress), total: 100)
                Text("配对进度 \(model.pairingProgress)%").font(.caption).foregroundStyle(.secondary)
            }
            Button("开始配对") { model.pair() }
                .buttonStyle(.borderedProminent)
                .disabled(!(JPAKEAuth.normalize(model.pairingCode).count == 6
                            || JPAKEAuth.normalize(model.pairingCode).count == 16))
            Text("**6 位数字**：t:slim X2 固件 v7.7 及以上、t:slim Mobi，走 EC-JPAKE。\n**16 位字母数字**：更早的 X2 固件，泵上常以 4 位一组显示。")
                .font(.caption).foregroundStyle(.secondary)
            Text("6 位码的配对全程约 3–5 秒，期间会连发 6 条报文，请让 App 保持在前台。失败后泵上会换一个新码，重新读一次。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .navigationTitle("配对")
    }
}

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @State private var showForget = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // 血糖主卡
                VStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(model.glucoseText)
                            .font(.system(size: 76, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(model.hasLiveData ? .primary : .secondary)
                        if !model.trendSymbol.isEmpty {
                            Image(systemName: model.trendSymbol)
                                .font(.system(size: 34, weight: .semibold))
                        }
                    }
                    Text(model.glucoseSub.isEmpty ? "等待 CGM 数据" : model.glucoseSub)
                        .font(.callout).foregroundStyle(.secondary)
                    Text("mg/dL · 以泵屏幕为准")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                PredictionCard()
                AdviceCard()

                HStack(spacing: 12) {
                    MetricCard(title: "活性胰岛素", value: model.iobText, caption: "IOB")
                    MetricCard(title: "药筒余量", value: model.insulinUnits, caption: "reservoir")
                }
                HStack(spacing: 12) {
                    MetricCard(title: "基础率", value: model.basalText, caption: "basal")
                    MetricCard(title: "电量", value: model.batteryText, caption: "battery")
                }

                HStack {
                    Label(model.connectedName ?? "未连接", systemImage: "dot.radiowaves.left.and.right")
                        .font(.footnote)
                    Spacer()
                    Text("API \(model.apiVersion ?? "—") · \(model.lastUpdated)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                Button {
                    model.refresh()
                } label: {
                    Label("立即刷新", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                HStack(spacing: 16) {
                    NavigationLink("安全说明") { SafetyView() }
                    NavigationLink("诊断日志") { DiagnosticView() }
                }
                .font(.footnote)

                Button(role: .destructive) {
                    showForget = true
                } label: {
                    Label("忘记此泵", systemImage: "trash")
                        .font(.footnote)
                }
                .confirmationDialog("删除本机保存的配对凭据？", isPresented: $showForget,
                                    titleVisibility: .visible) {
                    Button("删除，下次重新输入配对码", role: .destructive) { model.forgetPump() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("凭据只存在本机 Keychain，删除后不影响泵上的其他配对设备。")
                }

                Text("本版本只读取状态，不含任何输注指令。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.top, 4)

                Text("版本 \(BuildInfo.full)")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding()
        }
        .navigationTitle("状态")
        .refreshable { model.refresh() }
        .toolbar {
            NavigationLink {
                AdvisorSettingsView()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
        }
    }
}

// MARK: - 预测与建议

struct PredictionCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("预测").font(.subheadline.weight(.semibold))
                Spacer()
                if let p = model.prediction {
                    Text("4 小时后 \(Int(p.eventualBg.rounded())) mg/dL")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            if model.iobUnavailable {
                Text("未读到活性胰岛素。预测缺了这一项就会系统性高估血糖，所以这里不做预测。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let p = model.prediction, !p.points.isEmpty {
                Chart {
                    ForEach(model.samples, id: \.timestamp) { s in
                        LineMark(
                            x: .value("时间", s.timestamp),
                            y: .value("血糖", s.mgdl),
                            series: .value("系列", "历史")
                        )
                        .foregroundStyle(.primary)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    ForEach(p.points, id: \.date) { point in
                        LineMark(
                            x: .value("时间", point.date),
                            y: .value("血糖", point.mgdl),
                            series: .value("系列", "预测")
                        )
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    }
                    RuleMark(y: .value("低血糖", model.advisorSettings.lowThreshold))
                        .foregroundStyle(.red.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                }
                .chartYScale(domain: yDomain(p))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .frame(height: 150)

                if let low = p.minutesToLow {
                    Label("预测 \(low) 分钟后跌破 \(Int(model.advisorSettings.lowThreshold))", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            } else {
                Text("等待血糖数据").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func yDomain(_ p: PredictionResult) -> ClosedRange<Double> {
        var values = model.samples.map { Double($0.mgdl) } + p.points.map(\.mgdl)
        values.append(model.advisorSettings.lowThreshold)
        let lo = max(40, (values.min() ?? 70) - 20)
        let hi = min(400, (values.max() ?? 250) + 20)
        return lo...max(hi, lo + 40)
    }
}

struct AdviceCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("此刻建议").font(.subheadline.weight(.semibold))
                Spacer()
                Text("影子模式")
                    .font(.caption2)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.orange.opacity(0.16), in: Capsule())
            }

            if let advice = model.advice {
                switch advice {
                case let .correct(units, _, capped):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(String(format: "%.2f", units))
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("U").font(.headline).foregroundStyle(.secondary)
                        Spacer()
                    }
                    if capped {
                        Text("已按单次上限截断").font(.caption).foregroundStyle(.orange)
                    }
                case let .hold(reason):
                    HStack(spacing: 6) {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        Text(reason.explanation).font(.callout)
                    }
                }
            } else {
                Text("等待数据").font(.caption).foregroundStyle(.secondary)
            }

            Text("本版本不发送任何指令，只记录判断结果。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct AdvisorSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var showClearShadow = false

    var body: some View {
        Form {
            Section {
                LabeledContent("敏感系数 ISF") {
                    TextField("50", value: $model.advisorSettings.isf, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
                LabeledContent("碳水比 CR") {
                    TextField("10", value: $model.advisorSettings.carbRatio, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
                LabeledContent("目标血糖") {
                    TextField("110", value: $model.advisorSettings.targetBg, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
            } header: {
                Text("胰岛素参数")
            } footer: {
                Text("单位：ISF 为 mg/dL per U，CR 为 g per U。这些值应与医嘱一致，不是默认值。")
            }

            Section {
                LabeledContent("单次上限") {
                    TextField("2.0", value: $model.advisorSettings.maxSingleDoseUnits, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
                LabeledContent("追加阈值") {
                    TextField("120", value: $model.advisorSettings.minBgToCorrect, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
                LabeledContent("低血糖阈值") {
                    TextField("70", value: $model.advisorSettings.lowThreshold, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
                LabeledContent("给药最小间隔（分）") {
                    TextField("45", value: $model.advisorSettings.minMinutesBetweenDoses, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
                Toggle("下降时仍允许建议", isOn: $model.advisorSettings.allowCorrectionWhileFalling)
            } header: {
                Text("安全边界")
            } footer: {
                Text("下降时允许建议会显著提高低血糖风险，默认关闭。")
            }

            Section {
                LabeledContent("影子记录条数", value: "\(model.shadowCount)")
                Button("清空记录", role: .destructive) { showClearShadow = true }
            } header: {
                Text("影子模式")
            } footer: {
                Text("每个周期记录一次「如果自动会给多少」，但不发送。攒够两周再回看，判断这套判断逻辑值不值得打开执行。")
            }
        }
        .navigationTitle("建议参数")
        .toolbar {
            Button("保存") { model.saveSettings() }
        }
        .confirmationDialog("清空全部影子记录？", isPresented: $showClearShadow,
                            titleVisibility: .visible) {
            Button("清空", role: .destructive) { model.clearShadowLog() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这条不可撤销，两周的数据会一起没。")
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(caption).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct SafetyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("为什么只读").font(.headline)
                Text("输注指令必须在真实泵上逐条验证（配对、权限握手、签名、剂量边界、断连恢复）。在这些验证完成前开放给药，风险不可接受。")
                Text("已知限制").font(.headline)
                Text("• iOS 无长驻后台服务，息屏后连接可能被系统挂起\n• 泵若在另一台手机上配对，需先解绑\n• 固件升级可能改变报文长度与语义")
            }
            .font(.callout)
            .padding()
        }
        .navigationTitle("安全说明")
    }
}

// MARK: - 诊断

struct DiagnosticView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @State private var copied = false
    /// 导出用的临时文件。截图受屏幕宽度限制，长报文会被截断、字也会糊，
    /// 排障时经常只能看到半行十六进制；弄成文件后可以直接整份发出来。
    @State private var exportURL: URL?

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .navigationTitle("诊断日志")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                Button(copied ? "已复制" : "复制") {
                    UIPasteboard.general.string = document
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                Button("刷新") { load() }
            }
        }
        .onAppear(perform: load)
    }

    /// 文件头带上版本号：排障时最怕收到一份不知道来自哪个构建的日志
    private var document: String {
        """
        ControlX2 诊断日志
        版本：\(BuildInfo.full)
        导出：\(ISO8601DateFormatter().string(from: Date()))
        ────────────────────────────
        \(text)
        """
    }

    private func load() {
        text = model.traceDump()
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = "ControlX2-\(BuildInfo.version)-\(stamp).txt"
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "_")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        if (try? document.write(to: url, atomically: true, encoding: .utf8)) != nil {
            exportURL = url
        }
    }
}
