import SwiftUI
import PumpX2Kit
import PumpX2BLE

@main
struct ControlX2App: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(model) }
    }
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
    @Published var pairingCode = ""
    @Published var pairingProgress = 0
    @Published var errorText: String?
    @Published var connectedName: String?
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

    private let transport = BLETransport()
    private lazy var session = PumpSession(link: transport)
    private let store: CredentialStore = KeychainCredentialStore()
    private var currentPumpID: UUID?
    private var pollTask: Task<Void, Never>?

    init() {
        // 已接受过免责声明就直接进扫描页；未接受则每次启动都要求确认
        if UserDefaults.standard.bool(forKey: "disclaimerAccepted") {
            phase = .discovery
        }
        transport.onDiscover = { [weak self] pump in
            Task { @MainActor in
                guard let self else { return }
                if !self.pumps.contains(where: { $0.id == pump.id }) { self.pumps.append(pump) }
            }
        }
        transport.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.connectedName = nil
                self?.errorText = "泵连接已断开"
            }
        }
        transport.onStateChange = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .poweredOff: self?.errorText = "蓝牙已关闭，请在控制中心打开"
                case .unauthorized: self?.errorText = "未授权蓝牙访问，请到「设置 → ControlX2」开启"
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
        transport.startScan()
        Task {
            try? await Task.sleep(for: .seconds(12))
            await MainActor.run { self.isScanning = false }
        }
    }

    func connect(_ pump: BLETransport.DiscoveredPump) {
        transport.stopScan()
        isScanning = false
        connectedName = pump.name
        currentPumpID = pump.id
        transport.connect(pump.id)
        phase = .pairing
        pairingProgress = 0
        Task {
            await session.start()
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
        Task {
            do {
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
                errorText = "配对失败：\(error)"
            }
        }
    }

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
            Button("知道了", role: .cancel) { model.errorText = nil }
        } message: {
            Text(model.errorText ?? "")
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

    var body: some View {
        List {
            Section("附近的泵") {
                if model.pumps.isEmpty {
                    HStack(spacing: 12) {
                        if model.isScanning { ProgressView() }
                        Text(model.isScanning ? "正在扫描…" : "未发现设备")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(model.pumps) { pump in
                    Button {
                        model.connect(pump)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(pump.name)
                                Text(pump.id.uuidString.prefix(8)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(pump.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                        }
                    }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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
            Text("**6 位**：t:slim X2 固件 v7.7 及以上、t:slim Mobi。\n**16 位**：更早的 t:slim X2 固件，泵上常以 4 位一组显示，连字符可保留。")
                .font(.caption).foregroundStyle(.secondary)
            Text("配对会进行 EC-JPAKE 密钥协商，约需数秒。若泵提示失败，请在泵上重新生成配对码。")
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

                NavigationLink("安全说明与已知限制") { SafetyView() }
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
            }
            .padding()
        }
        .navigationTitle("状态")
        .refreshable { model.refresh() }
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
