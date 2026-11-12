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

    private let transport = BLETransport()
    private lazy var session = PumpSession(link: transport)
    private var pollTask: Task<Void, Never>?

    init() {
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
        transport.connect(pump.id)
        phase = .pairing
        Task { await session.start() }
    }

    func pair() {
        guard pairingCode.count == 6 else {
            errorText = "配对码为 6 位数字"
            return
        }
        errorText = nil
        pairingProgress = 0
        Task {
            do {
                try await session.pair(code: pairingCode) { p in
                    Task { @MainActor in self.pairingProgress = p }
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
                try? await Task.sleep(for: .seconds(15))
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
            insulinUnits = String(format: "%.2f U", units)
        }
        if let t = snap.lastUpdated {
            lastUpdated = t.formatted(date: .omitted, time: .standard)
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
            Text("输入泵屏幕上显示的 6 位配对码").font(.headline)
            TextField("000000", text: $model.pairingCode)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 34, design: .monospaced))
                .onChange(of: model.pairingCode) { _, new in
                    model.pairingCode = String(new.filter(\.isNumber).prefix(6))
                }
            if model.pairingProgress > 0 {
                ProgressView(value: Double(model.pairingProgress), total: 100)
                Text("配对进度 \(model.pairingProgress)%").font(.caption).foregroundStyle(.secondary)
            }
            Button("开始配对") { model.pair() }
                .buttonStyle(.borderedProminent)
                .disabled(model.pairingCode.count != 6)
            Text("配对过程会进行 EC-JPAKE 密钥协商，约需数秒。若泵提示配对失败，请在泵上重新生成配对码。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .navigationTitle("配对")
    }
}

struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section("泵") {
                LabeledContent("设备", value: model.connectedName ?? "—")
                LabeledContent("API 版本", value: model.apiVersion ?? "—")
                LabeledContent("药筒余量", value: model.insulinUnits)
                LabeledContent("最近刷新", value: model.lastUpdated)
            }
            Section {
                Button("立即刷新") { model.refresh() }
                NavigationLink("安全说明") { SafetyView() }
            }
            Section("尚未启用") {
                Text("大剂量、基础率、暂停输注等指令未包含在本版本中。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("状态")
        .refreshable { model.refresh() }
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
