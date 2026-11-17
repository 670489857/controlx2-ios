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
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                // 启动即连：有「上次那台泵 + 凭据」就直接连回去
                .task { model.autoConnectIfPossible() }
        }
        .onChange(of: scenePhase) { phase in
            // 从后台回来也一样。iOS 会让 App 在挂起期间丢掉链路，
            // 回来时如果不主动补一次，界面就停在「未连接」等用户点。
            if phase == .active {
                model.autoConnectIfPossible()
                // 后台期间 NS 拉不到数（除非保活开着），回前台必须立刻补一次，
                // 不能让界面继续挂着十分钟前的血糖
                Task { await model.onAppForeground() }
            }
        }
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

/// 一行读数核对。「泵就这么报的」和「我们解析错了」的分界线全在 `hex` 这一列。
struct ReadingRow: Identifiable {
    let id = UUID()
    let opCode: String
    let name: String
    let value: String
    let hex: String
    let note: String
}

/// 血糖显示单位。只影响界面上的数字，所有计算永远是 mg/dL。
enum GlucoseDisplayUnit: String, CaseIterable, Identifiable {
    case auto
    case mgdl
    case mmol

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "跟随来源"
        case .mgdl: return "mg/dL"
        case .mmol: return "mmol/L"
        }
    }
}

/// 血糖来源。只影响"读哪里的数"，不影响任何输注逻辑——
/// 泵的 IOB、基础率、Control-IQ 状态永远来自泵，不会因为换了 CGM 来源就变。
enum CGMSource: String, CaseIterable, Codable, Identifiable {
    case pump
    case nightscout

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pump: return "泵自带 CGM（Dexcom 直连）"
        case .nightscout: return "Nightscout"
        }
    }
}

/// 输注界面状态机。只描述「界面走到了哪一步」，不代表泵那边的真实状态——
/// 泵的真实状态永远以 0x2D 与泵屏幕为准。
enum BolusPhase: Equatable {
    case idle
    case requesting
    case delivering
    case cancelling
    case done
    case failed

    var isBusy: Bool {
        switch self {
        case .requesting, .delivering, .cancelling: return true
        case .idle, .done, .failed: return false
        }
    }
}

/// UI 层状态机。只负责展示与用户动作，协议细节全部在 PumpX2Kit。
@MainActor
final class AppModel: ObservableObject {    enum Phase: Equatable {
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

    // MARK: 血糖来源
    @Published var cgmSource: CGMSource =
        CGMSource(rawValue: UserDefaults.standard.string(forKey: "cgmSource") ?? "pump") ?? .pump
    @Published var nsConfig: NightscoutConfig = AppModel.loadNightscoutConfig()
    @Published var nsStatus: String?
    @Published var nsError: String?
    @Published var nsLatestMgdl: Int?
    @Published var nsLatestDate: Date?
    @Published var nsLoading = false
    /// NS 里的注射/碳水记录，首页「最近记录」和曲线标记都用它
    @Published var nsTreatments: [NightscoutTreatment] = []

    // MARK: 后台保活
    @Published var backgroundAudioEnabled: Bool =
        UserDefaults.standard.bool(forKey: "backgroundAudioEnabled")
    @Published var backgroundAudioMessage: String?

    /// 已确认「泵的基础率已经降下来」，闭环才允许真发
    @Published var loopZeroBasalConfirmed = false
    /// 血糖卡片下面那行小字，明确写出这个数是从哪来的
    @Published var glucoseSourceHint: String = "mg/dL · 以泵屏幕为准"
    @Published var glucoseUnit: GlucoseDisplayUnit =
        GlucoseDisplayUnit(rawValue: UserDefaults.standard.string(forKey: "glucoseUnit") ?? "auto") ?? .auto
    /// 上一次成功拉 NS 的时间。轮询靠它做 2 分钟节流
    var nsLastFetchAt: Date?
    /// 最近一批 NS 记录，界面和趋势码都从这里取
    var nsLastEntries: [NightscoutEntry] = []

    // 预测与建议
    @Published var samples: [GlucoseSample] = []
    @Published var prediction: PredictionResult?
    @Published var advice: DoseAdvice?
    @Published var advisorSettings: AdvisorSettings
    @Published var shadowCount: Int = 0
    /// IOB 读不到时预测无意义，UI 需要据此降级而不是显示 0
    @Published var iobUnavailable = false

    /// 泵自带 Control-IQ 的状态（只读）。这里刻意不叫「闭环」：
    /// 跑算法的是泵，App 不改任何输注参数，叫闭环会让人以为是我们控的。
    @Published var controlIQ: ControlIQMessages.Info?
    @Published var controlIQSleep: ControlIQMessages.SleepSchedule?
    @Published var controlIQError: String?
    @Published var controlIQLoading = false

    // MARK: 闭环（微剂量模拟基础率）
    @Published var loopSettings: ClosedLoop.Settings = ClosedLoop.Settings()
    /// 武装 = 每 5 分钟跑一拍、算一次。演练模式下只记账不发针
    @Published var loopArmed = false
    /// 真发针。必须单独打开，且在武装之后
    @Published var loopLiveDosing = false
    @Published var loopCarried: Double = 0
    @Published var loopLastDecision: ClosedLoop.Decision?
    @Published var loopRecords: [LoopRecord] = []
    @Published var loopError: String?
    @Published var loopTickCount = 0
    @Published var loopHourUnits: Double = 0
    @Published var loopTodayUnits: Double = 0
    @Published var loopNextTickAt: Date?

    /// 基础率卡片的副标题：当前值与配置值不一致时把配置值写出来
    @Published var basalHint: String = "basal"
    /// 读数核对表
    @Published var readingRows: [ReadingRow] = []

    /// 正在自动连回上次那台泵。状态页顶部据此显示一条进度，而不是空白等 20 秒。
    @Published var autoConnecting = false
    /// 自动连接没成功的原因。只挂在页面上，不弹框——刚打开 App 就被弹窗挡住，
    /// 比多等几秒更难受。
    @Published var connectionNote: String?

    // MARK: 大剂量（输注）
    /// 输注总开关，默认关。第一次打开要走一遍风险确认。
    @Published var bolusEnabled: Bool = UserDefaults.standard.bool(forKey: "bolusEnabled")
    /// 是否已确认过「这是真泵、真会打进去」的那段说明
    @Published var bolusRiskAccepted: Bool = UserDefaults.standard.bool(forKey: "bolusRiskAccepted")
    /// 输入框里的剂量（U）。实际下发前会向下取整到 0.05 U。
    @Published var bolusUnits: Double = 0.5
    @Published var bolusPhase: BolusPhase = .idle
    /// 面向用户的一句话，成功与失败都写在这里
    @Published var bolusMessage: String?
    /// 当前输入对应的闸门结论，界面逐条显示
    @Published var bolusDecision: BolusDecision?
    /// 泵报告的进行中大剂量（0x2D）
    @Published var activeBolus: BolusMessages.BolusState?
    /// 本机台账：只记这个 App 发出去的针
    @Published var ledger: BolusLedger = BolusLedger.decode(UserDefaults.standard.data(forKey: "bolusLedger"))
    @Published var bolusPolicy: BolusPolicy = AppModel.loadBolusPolicy()

    // MARK: 基础率计划（只读）
    /// 当前生效的基础率计划。只有读——写入侧在 X2 是 MOBI_ONLY，泵不收。
    @Published var basalProfile: BasalProfile?
    @Published var basalProfileLoading = false
    @Published var basalProfileError: String?

    /// 数值型读数：闸门要用数，不能拿格式化后的字符串去比
    @Published var reservoirValue: Double?
    @Published var glucoseValue: Int?
    @Published var iobValue: Double?

    private let transport = BLETransport()
    lazy var session = PumpSession(link: transport)
    private let store: CredentialStore = KeychainCredentialStore()
    /// 上次连上的泵，用来在启动时直接连回去
    private let lastPumpStore: LastPumpStore = UserDefaultsLastPumpStore()
    let glucoseStore: GlucoseHistoryStore
    private let shadowLog: ShadowLog
    /// 闭环每一拍的去向。额度从这里算，不从内存计数器算
    let loopLedger: LoopLedger
    private var currentPumpID: UUID?
    private var pollTask: Task<Void, Never>?
    private var lastShadowAt: Date?
    /// 闭环定时任务。武装时启动，卸下武装立刻取消
    var loopTask: Task<Void, Never>?
    /// 上一针是否还在推。推注没结束就叠下一针，是最容易出错的地方
    var loopPumpBusy = false
    /// 连续几拍血糖过低。两拍（10 分钟）就自动卸武装
    var loopLowTicks = 0
    /// 连续几拍出错
    var loopErrorTicks = 0
    /// 重连后补认证的状态。连续失败两次就停下，不留在一个「一直重连、一直失败」的循环里。
    private var isResuming = false
    private var resumeAttempts = 0

    private static let settingsKey = "advisorSettings"

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        glucoseStore = GlucoseHistoryStore(fileURL: docs.appendingPathComponent("glucose.json"))
        shadowLog = ShadowLog(fileURL: docs.appendingPathComponent("shadow.jsonl"))
        loopLedger = LoopLedger(fileURL: docs.appendingPathComponent("loop.jsonl"))
        advisorSettings = Self.loadSettings()
        samples = glucoseStore.recent(minutes: 180)
        shadowCount = shadowLog.summarize().total

        // 已接受过免责声明时：有「上次那台泵 + 凭据」就直接落到状态页，连接在后台补；
        // 只有确实没法自动连（没记设备、或凭据被删）才退回扫描页。
        if UserDefaults.standard.bool(forKey: "disclaimerAccepted") {
            let saved = lastPumpStore.load()
            let hasCredentials = saved.map { store.load(for: $0.id.uuidString) != nil } ?? false
            switch LaunchRouter.destination(lastPump: saved, hasCredentials: hasCredentials) {
            case let .dashboard(pump):
                currentPumpID = pump.id
                connectedName = pump.name
                phase = .dashboard
                autoConnecting = true
            case .discovery:
                phase = .discovery
            }
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
                // 否则自动重连的每一次断开都会打断用户一次。
                // 状态页上连名字都留着——它仍然是「目标泵」，只是暂时没连上。
                if self?.phase != .dashboard {
                    self?.connectedName = nil
                }
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
                if self.phase == .dashboard {
                    // 状态页上只把「传输层正在自己重连」画成进度；失败则收起进度、写原因。
                    // 这里不处理 .failed 以外的跳转——状态页不因为一次断链就把人赶回列表。
                    switch p {
                    case .reconnecting:
                        self.autoConnecting = true
                    case let .failed(message):
                        self.autoConnecting = false
                        self.connectionNote = message
                    default:
                        break
                    }
                } else if case let .failed(message) = p {
                    self.phase = .discovery
                    self.errorText = message
                }
                // 链路就绪后**不**自动发授权帧。新版固件（v7.7+）只认 JPAKE，
                // 先发 0x10 会被当成不认识的报文并立刻断链；旧固件的 0x10 也要
                // 等用户输完 16 位码才有意义。授权一律由用户点「开始配对」触发。
                //
                // 但「重连」是另一回事：链路恢复不等于会话恢复，`resetSession()`
                // 已经把 authKey 清掉了。这里补一次自动认证，否则重连后的第一条
                // 状态请求会被泵拒绝并断开，然后重连、再发，形成永远连不上的循环。
                if p.isReady {
                    Task { await self.resumeAfterReconnectIfNeeded() }
                }
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

    /// 手动从列表里选了一台泵
    func connect(_ pump: BLETransport.DiscoveredPump) {
        transport.stopScan()
        isScanning = false
        connectedName = pump.name
        currentPumpID = pump.id
        linkPhase = .connecting
        phase = .pairing
        pairingProgress = 0
        autoConnecting = false
        connectionNote = nil
        Task { await performConnect(id: pump.id, name: pump.name, isAuto: false) }
    }

    /// 启动 / 回到前台时自动连回上次那台泵。
    ///
    /// 之前每次打开 App 都停在「选择泵」列表，必须手点一下设备名才继续——
    /// 可那一下不传递任何新信息：设备是同一台，凭据早就在 Keychain 里。
    /// 更要命的是列表要等广播，泵的广播间隔 1–2 秒，经常是空白几秒之后
    /// 才发现自己还得再点一次。现在打开就是状态页，连接在后台补。
    func autoConnectIfPossible() {
        guard phase == .dashboard, let id = currentPumpID else { return }
        if linkPhase.isReady {
            autoConnecting = false
            return
        }
        // 已经在连（含传输层自己的自动重连）就别叠第二次 connect
        switch linkPhase {
        case .connecting, .discovering, .waitingForPairing, .reconnecting:
            autoConnecting = true
            return
        case .idle, .ready, .failed:
            break
        }
        connectionNote = nil
        autoConnecting = true
        Task { await performConnect(id: id, name: connectedName ?? "泵", isAuto: true) }
    }

    /// 自动连接失败后回到扫描页（用户主动要求时才走这条）
    func goToDiscovery() {
        connectionNote = nil
        autoConnecting = false
        phase = .discovery
        startScan()
    }

    private func performConnect(id: UUID, name: String, isAuto: Bool) async {
        await session.start()
        // 用 UUID 直连，不需要先扫描：iOS 保留了见过的设备，
        // retrievePeripherals(withIdentifiers:) 能直接拿到它。
        transport.connect(id)
        do {
            // 自动连接给 20 秒：等不到就该把「没连上」写出来，
            // 而不是让用户盯着一个转圈以为还在努力。手动连接沿用 45 秒，
            // 那时用户正在系统弹窗上点配对，急不得。
            try await transport.waitReady(timeout: isAuto ? .seconds(20) : .seconds(45))
        } catch {
            let detail = error.localizedDescription
            transport.disconnect()
            autoConnecting = false
            if isAuto {
                // 留在状态页，只挂一条提示 + 两个按钮
                connectionNote = "没连上 \(name)：\(detail)"
            } else {
                errorText = "\(name) 未能建立连接：\(detail)"
                phase = .discovery
                connectedName = nil
                currentPumpID = nil
                startScan()
            }
            return
        }
        await attemptResume()
    }

    /// 连上之后优先用已保存的凭据恢复会话；泵不认才退回输入配对码。
    ///
    /// 与 `resumeAfterReconnectIfNeeded` 互斥：链路刚就绪时两个入口会同时被触发
    /// （一个是这里，一个是 `onPhase(.ready)`）。并发跑两次 JPAKE，泵会当成
    /// 两个客户端抢同一台设备，直接断链。
    private func attemptResume() async {
        guard !isResuming else { return }
        guard let id = currentPumpID, let saved = store.load(for: id.uuidString) else {
            // 没有凭据：只能让用户从泵屏幕上读码
            autoConnecting = false
            if phase == .dashboard { phase = .pairing }
            return
        }
        do {
            isResuming = true
            defer { isResuming = false }
            let result = try await session.resume(with: saved) { p in
                Task { @MainActor in self.pairingProgress = p }
            }
            switch result {
            case .resumed:
                resumeAttempts = 0
                rememberCurrentPump()
                autoConnecting = false
                connectionNote = nil
                try? await session.refresh()
                await refreshFromSession()
                phase = .dashboard
                startPolling()
            case .needsPairing:
                store.delete(for: id.uuidString)
                lastPumpStore.clear()
                autoConnecting = false
                connectionNote = nil
                errorText = "泵未认可已保存的凭据（可能重置过或换了泵），请重新输入配对码"
                phase = .pairing
            }
        } catch {
            autoConnecting = false
            if phase == .dashboard {
                // 自动连接途中失败：页面上写一句，别弹框
                connectionNote = "自动恢复会话失败：\(error.localizedDescription)"
            } else {
                errorText = "自动恢复失败：\(error)"
            }
        }
    }

    /// 记住这台泵，下次启动直接连回去
    private func rememberCurrentPump() {
        guard let id = currentPumpID else { return }
        lastPumpStore.save(LastPump(id: id, name: connectedName ?? "泵"))
    }

    /// 重连后自动补认证。
    ///
    /// 链路恢复不等于会话恢复：泵对每条新连接都要求重新确认密钥，而
    /// `resetSession()` 已经把 authKey 清空。之前这里什么都不做，于是重连后的
    /// 第一条状态请求被泵回 Nack 并断开——日志里「链路已就绪 → TX 0x24 →
    /// 749ms 后 CBErrorDomain 7 → 重连 1/2」反复出现，表现就是「划掉 App
    /// 再进来就再也连不上」。
    func resumeAfterReconnectIfNeeded() async {
        guard phase == .dashboard, !isResuming else { return }
        if await session.isAuthenticated {
            resumeAttempts = 0
            return
        }
        guard let id = currentPumpID, let saved = store.load(for: id.uuidString) else { return }

        isResuming = true
        defer { isResuming = false }
        do {
            let result = try await session.resume(with: saved) { p in
                Task { @MainActor in self.pairingProgress = p }
            }
            if case .resumed = result {
                resumeAttempts = 0
                autoConnecting = false
                connectionNote = nil
                try? await session.refresh()
                await refreshFromSession()
                // 启动路径上会先走到这里（onPhase(.ready) 比 waitReady 返回得早），
                // 所以轮询也必须在这儿拉起来，否则这一路连上是「只刷一次」
                startPolling()
            } else {
                await giveUpSession(reason: "泵不再认可这台设备保存的配对凭据")
            }
        } catch {
            await giveUpSession(reason: "重连后恢复会话失败（\(error.localizedDescription)）")
        }
    }

    /// 连续两次恢复失败就停下。凭据失效（泵重置、换泵、固件升级）不会因为
    /// 多试几次而变好，继续重连只会让用户看着「连接中…」反复跳。
    private func giveUpSession(reason: String) async {
        resumeAttempts += 1
        guard resumeAttempts >= 2 else { return }
        resumeAttempts = 0
        pollTask?.cancel()
        transport.setAutoReconnect(false)
        autoConnecting = false
        connectionNote = nil
        errorText = "\(reason)。请回到配对页，重新输入泵屏幕上的 6 位码"
        phase = .pairing
    }

    /// 删除本机保存的配对凭据，并断开当前连接
    func forgetPump() {
        if let id = currentPumpID { store.delete(for: id.uuidString) }
        // 「上次是哪台」也要一起清：只删凭据不清它，下次启动会去连一台没有凭据的泵，
        // 连上也只能停在配对页，白等 20 秒
        lastPumpStore.clear()
        pollTask?.cancel()
        transport.disconnect()
        connectedName = nil
        currentPumpID = nil
        autoConnecting = false
        connectionNote = nil
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
                    // 只有拿到凭据才记「上次是哪台」，否则下次启动会去连一台连上也进不去的泵
                    rememberCurrentPump()
                }
                resumeAttempts = 0
                autoConnecting = false
                connectionNote = nil
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
                // 链路可能在两个 cycle 之间断过又自动连回来，那时 onPhase 的
                // ready 回调早过去了。每轮先确认会话还在，再读数据。
                if !linkPhase.isReady {
                    // 传输层的自动重连只试两次，放弃之后不会自己再起。
                    // 放在这里补一次：泵走远再回来、或者 App 在后台待了很久，
                    // 都靠这个周期自己长回来，不用用户手动点。
                    autoConnectIfPossible()
                    continue
                }
                await resumeAfterReconnectIfNeeded()
                try? await session.refresh()
                await refreshFromSession()
                await maybeRefreshNightscout()
            }
        }
    }

    func refresh() {
        // 链路本身没通时，读数据是空转：先连回去，连上后 attemptResume 会刷新一次
        guard linkPhase.isReady else {
            autoConnectIfPossible()
            return
        }
        Task {
            // 断线重连后 authKey 已被清空，此时直接 refresh 一条报文都发不出去
            //（会话层会拦下未认证的状态请求）。先补认证，再读。
            await resumeAfterReconnectIfNeeded()
            try? await session.refresh()
            await refreshFromSession()
            await maybeRefreshNightscout()
        }
    }

    /// 血糖的显示格式跟着来源走：
    /// - 泵 CGM：主数字 mg/dL（和泵屏幕一致，方便逐位核对）
    /// - Nightscout：主数字 mmol/L（NS 用户看的就是这个单位）
    /// `glucoseValue` 永远存 mg/dL——闸门、预测、闭环全都按 mg/dL 算，
    /// 显示单位只在最后一层换，绝不参与计算。
    func applyGlucoseDisplay(mgdl: Int) {
        glucoseValue = mgdl
        let unit = effectiveGlucoseUnit
        switch unit {
        case .mmol:
            glucoseText = String(format: "%.1f", Double(mgdl) / 18.0182)
            glucoseSub = "\(mgdl) mg/dL"
        default:
            glucoseText = "\(mgdl)"
            glucoseSub = String(format: "%.1f mmol/L", Double(mgdl) / 18.0182)
        }
        glucoseSourceHint = (unit == .mmol ? "mmol/L" : "mg/dL") + " · " + glucoseSourceName
    }

    /// 实际生效的单位：手动指定优先；`跟随来源` 时 NS → mmol、泵 → mg/dL
    var effectiveGlucoseUnit: GlucoseDisplayUnit {
        glucoseUnit == .auto ? (cgmSource == .nightscout ? .mmol : .mgdl) : glucoseUnit
    }

    var glucoseSourceName: String {
        cgmSource == .nightscout ? "Nightscout " + nsAgeText : "以泵屏幕为准"
    }

    func setGlucoseUnit(_ unit: GlucoseDisplayUnit) {
        glucoseUnit = unit
        UserDefaults.standard.set(unit.rawValue, forKey: "glucoseUnit")
        // 立刻用现有读数重画，不必等下一次泵报文
        if let mgdl = glucoseValue { applyGlucoseDisplay(mgdl: mgdl) }
    }

    func refreshFromSession() async {
        let snap = await session.snapshot
        apiVersion = snap.apiVersion?.description

        if let units = snap.insulinUnits {
            // 泵在换筒/回抽途中会把剩余量标成估算，直接显示成精确值会误导
            insulinUnits = String(format: snap.insulinIsEstimate ? "≈%.0f U" : "%.0f U", units)
            reservoirValue = units
        }
        if let g = snap.glucoseMgdl {
            applyGlucoseDisplay(mgdl: g)
            hasLiveData = true
        }
        trendSymbol = Self.trendSymbol(for: snap.glucoseTrend)

        // Nightscout 作为来源时，界面上的血糖必须换成 NS 的：泵的 EGV 可能根本没数据，
        // 也可能比 NS 旧。以「用户选定的来源」为唯一准星，避免两个数字打架。
        if cgmSource == .nightscout, let ns = nsLatestMgdl {
            applyGlucoseDisplay(mgdl: ns)
            hasLiveData = true
            trendSymbol = Self.trendSymbol(for: nsTrendCode)
        }
        if let iob = snap.iobUnits {
            iobText = String(format: "%.2f U", iob)
            iobValue = iob
        }
        activeBolus = snap.currentBolus
        if snap.lastUpdated != nil { reviewBolus() }
        if let b = snap.batteryPercent {
            batteryText = "\(b)%"
        }
        if let rate = snap.basalRate {
            basalText = String(format: "%.2f U/h", rate)
            // 「当前 0」和「配置 0」是两件事：前者多半是 Control-IQ 把它压到 0 了，
            // 光看 0.00 会以为泵停了。把配置值并排写出来。
            if snap.basalModified, let p = snap.basalProfile, abs(p - rate) > 0.001 {
                basalHint = String(format: "basal · 配置 %.2f", p)
            } else {
                basalHint = "basal"
            }
        }
        controlIQ = snap.controlIQ
        if let t = snap.lastUpdated {
            lastUpdated = t.formatted(date: .omitted, time: .standard)
        }
        readingRows = Self.buildReadingRows(snap)
        updateAdvisor(with: snap)
    }

    /// 读数核对表：一行一个字段，附原始字节。
    ///
    /// 界面上的数字和泵屏幕不一致时，需要能立刻分清三种情况：泵就这么报的、
    /// 我们解析错了、报文根本没回来（没回来的那一行整行缺席）。
    static func buildReadingRows(_ snap: PumpSession.Snapshot) -> [ReadingRow] {
        var rows: [ReadingRow] = []

        if let cargo = snap.rawCargo[0x25] {
            let s = StatusDecoder.insulinStatus(cargo)
            rows.append(ReadingRow(
                opCode: "0x25",
                name: "药筒余量",
                value: s.map { String(format: "%.3f U", $0.units) } ?? "解析失败",
                hex: Hex.encode(cargo),
                note: s.map { st in
                    "第 1–2 字节：0.001 U 整数；第 3 字节 isEstimate=\(st.isEstimate ? 1 : 0)；"
                    + String(format: "第 4 字节低余量阈值=%.0f U", st.lowAmount)
                } ?? "载荷 \(cargo.count) 字节，期望 4"
            ))
        }

        if let cargo = snap.rawCargo[0x23] {
            let e = StatusDecoder.egv(cargo)
            rows.append(ReadingRow(
                opCode: "0x23",
                name: "血糖",
                value: e.map { "\($0.mgdl) mg/dL · 趋势 \($0.trend) · \($0.statusName)" } ?? "解析失败",
                hex: Hex.encode(cargo),
                note: e.map { ev in
                    "时间戳 \(ev.timestamp)（泵自身计时，非 Unix）"
                    + (ev.isClamped ? "；读数被泵夹在边界上，不是真实测量值" : "")
                } ?? "载荷 \(cargo.count) 字节，期望 8"
            ))
        }

        if let cargo = snap.rawCargo[0x6D] {
            let iob = StatusDecoder.controlIQIOB(cargo)
            rows.append(ReadingRow(
                opCode: "0x6D",
                name: "活性胰岛素",
                value: iob.map { String(format: "%.3f U（%@）", $0.displayed, $0.typeName) } ?? "解析失败",
                hex: Hex.encode(cargo),
                note: iob.map { v in
                    String(format: "Mudaliar %.3f U · Swan 6hr %.3f U；泵屏幕显示的是当前曲线那个",
                           v.mudaliar, v.swan6hr)
                } ?? "载荷 \(cargo.count) 字节，期望 17"
            ))
        }

        if let cargo = snap.rawCargo[0x35] {
            rows.append(ReadingRow(
                opCode: "0x35",
                name: "电量",
                value: StatusDecoder.batteryPercent(cargo).map { "\($0)%" } ?? "解析失败",
                hex: Hex.encode(cargo),
                note: "第 2 字节（ibc）才是泵屏幕上的百分比，第 1 字节是另一个口径"
            ))
        }

        if let cargo = snap.rawCargo[0x29] {
            let b = StatusDecoder.currentBasal(cargo)
            rows.append(ReadingRow(
                opCode: "0x29",
                name: "基础率",
                value: b.map { String(format: "当前 %.3f · 配置 %.3f U/h", $0.current, $0.profile) } ?? "解析失败",
                hex: Hex.encode(cargo),
                note: b.map { v in
                    "modified=\(v.modified)"
                    + (v.isModified ? "（正被 Control-IQ / 临时率调整，所以当前值与配置值可能不等）"
                                    : "（配置原样执行）")
                } ?? "载荷 \(cargo.count) 字节，期望 9"
            ))
        }

        if let cargo = snap.rawCargo[0x37], cargo.count >= 8 {
            let since = StatusDecoder.readU32(cargo, 4)
            let days = since / 86400, hours = (since % 86400) / 3600
            rows.append(ReadingRow(
                opCode: "0x37",
                name: "泵计时",
                value: "\(days) 天 \(hours) 小时",
                hex: Hex.encode(cargo),
                note: "sinceReset=\(since) 秒；签名报文要用它，值不对会导致所有写操作被拒"
            ))
        }

        return rows
    }

    /// 把一次快照喂给预测与建议层。
    ///
    /// 这里做的事情全部是"算"，没有一条指令会发给泵。影子记录也在这里落盘，
    /// 目的是两周后能拿真实数据回答"如果自动，会不会做蠢事"。
    func updateAdvisor(with snap: PumpSession.Snapshot) {
        let now = Date()

        // 采样时间用快照的抓取时刻。EGV 报文里虽然带时间戳，但那是泵自己的
        // 时钟起点，未与 Unix 纪元对齐，直接用会把所有点挪到 1970 年。
        if cgmSource == .pump, let g = snap.glucoseMgdl {
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

    // MARK: 大剂量

    // MARK: 基础率计划（只读）

    /// 读当前基础率计划。要 3 + N 条报文（N 是段数），比普通刷新重，
    /// 所以只在用户进入「基础率计划」页时读，不并进每次刷新。
    func loadBasalProfile() async {
        guard linkPhase.isReady else {
            basalProfileError = "链路未就绪，先等连接恢复"
            return
        }
        basalProfileLoading = true
        defer { basalProfileLoading = false }
        do {
            basalProfile = try await session.readBasalProfile()
            basalProfileError = nil
        } catch {
            basalProfileError = error.localizedDescription
        }
    }

    // MARK: 闭环状态（只读，读泵自带 Control-IQ）

    func loadControlIQ() async {
        guard linkPhase.isReady else {
            controlIQError = "链路未就绪，先等连接恢复"
            return
        }
        controlIQLoading = true
        defer { controlIQLoading = false }
        do {
            controlIQ = try await session.readControlIQ()
            // 睡眠表是 2 条报文，读失败不影响主状态
            controlIQSleep = try? await session.readSleepSchedule()
            controlIQError = nil
        } catch {
            controlIQError = error.localizedDescription
        }
    }

    nonisolated static func loadBolusPolicy() -> BolusPolicy {
        guard let data = UserDefaults.standard.data(forKey: "bolusPolicy"),
              let p = try? JSONDecoder().decode(BolusPolicy.self, from: data)
        else { return BolusPolicy() }
        return p
    }

    func saveBolusPolicy() {
        if let data = try? JSONEncoder().encode(bolusPolicy) {
            UserDefaults.standard.set(data, forKey: "bolusPolicy")
        }
        reviewBolus()
    }

    func bolusContext() -> BolusContext {
        let now = Date()
        return BolusContext(requestedUnits: bolusUnits,
                            now: now,
                            policy: bolusPolicy,
                            lastBolusAt: ledger.last(now: now)?.at,
                            delivered24h: ledger.delivered(now: now),
                            reservoirUnits: reservoirValue,
                            glucoseMgdl: glucoseValue,
                            iobUnits: iobValue)
    }

    /// 重新算一遍闸门。剂量、读数、参数任一变化都要调。
    func reviewBolus() {
        bolusDecision = BolusGuard.evaluate(bolusContext())
    }

    func setBolusEnabled(_ on: Bool) {
        bolusEnabled = on
        UserDefaults.standard.set(on, forKey: "bolusEnabled")
        if !on { bolusUnits = 0.5 }
        reviewBolus()
    }

    func acceptBolusRisk() {
        bolusRiskAccepted = true
        UserDefaults.standard.set(true, forKey: "bolusRiskAccepted")
    }

    func adjustBolusUnits(by delta: Double) {
        bolusUnits = min(max(0, ((bolusUnits + delta) * 1000).rounded() / 1000), 20)
        reviewBolus()
    }

    private func persistLedger() {
        if let data = ledger.jsonData() {
            UserDefaults.standard.set(data, forKey: "bolusLedger")
        }
    }

    /// 输注：授权 → 发起 → 轮询状态。任何一步出错都要把已拿到的许可还回去。
    func startBolus() {
        let decision = BolusGuard.evaluate(bolusContext())
        bolusDecision = decision
        guard bolusEnabled, bolusRiskAccepted else {
            bolusMessage = "请先打开「允许输注」并确认风险说明"
            return
        }
        guard decision.allowed else {
            bolusMessage = decision.blocks
                .map { "\($0.reason.explanation)：\($0.detail)" }
                .joined(separator: "\n")
            return
        }
        guard linkPhase.isReady else {
            bolusMessage = "链路未就绪，先等连接恢复再试"
            return
        }
        let units = decision.units
        bolusPhase = .requesting
        bolusMessage = "正在向泵申请输注授权…"
        Task {
            // 声明放在 Task 里面：拿到授权后要跨 catch 复用，放在外面会被并发闭包捕获
            var granted: BolusMessages.Permission?
            do {
                // 重连后 authKey 会被清掉，没补认证就发控制报文，泵会直接 Nack
                await resumeAfterReconnectIfNeeded()
                let permission = try await session.requestBolusPermission()
                granted = permission
                bolusMessage = "泵已给出 bolusId=\(permission.bolusId)，正在下发输注…"

                let result = try await session.initiateBolus(
                    units: units,
                    permission: permission,
                    carbsGrams: 0,
                    bgMgdl: glucoseValue ?? 0,
                    iobUnits: iobValue ?? 0
                )
                guard result.accepted else {
                    bolusPhase = .failed
                    bolusMessage = "泵没有接受这次输注：status=\(result.status)，statusType=\(result.statusType)。剂量没有下发。"
                    try? await session.releaseBolusPermission(bolusId: permission.bolusId)
                    return
                }
                bolusPhase = .delivering
                bolusMessage = "泵已受理 \(String(format: "%.2f", units)) U，开始输注"
                ledger.append(units: units, at: Date())
                persistLedger()
                reviewBolus()
                await pollBolus(bolusId: permission.bolusId)
            } catch {
                bolusPhase = .failed
                // 超时不能断言「没打」：报文可能已经到了泵，剂量正在进。
                bolusMessage = "输注没有走完：\(error.localizedDescription)。请立刻到泵屏幕核对实际输注量。"
                if let g = granted {
                    try? await session.releaseBolusPermission(bolusId: g.bolusId)
                }
            }
        }
    }

    /// 每 2 秒读一次当前大剂量状态。连续三次读不到进行中的大剂量才算结束，
    /// 因为泵在受理后要先切状态，第一次读很可能还是旧的空值。
    private func pollBolus(bolusId: Int) async {
        var emptyReads = 0
        for _ in 0..<300 {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            guard let state = try? await session.readCurrentBolus() else { continue }
            activeBolus = state
            let idle = state.bolusId == 0 || state.statusId == 0
            emptyReads = idle ? emptyReads + 1 : 0
            if emptyReads >= 3 {
                activeBolus = nil
                bolusPhase = .done
                bolusMessage = "泵已不再报告进行中的大剂量，本次输注结束"
                try? await session.releaseBolusPermission(bolusId: bolusId)
                return
            }
        }
        bolusMessage = "10 分钟内没等到结束。请到泵屏幕核对剩余量，不要凭界面判断。"
    }

    /// 取消进行中的输注。取消是另一条签名报文，泵不认就只能在泵屏幕上按。
    func cancelActiveBolus() {
        guard let id = activeBolus?.bolusId, id > 0 else {
            bolusMessage = "没有正在进行的输注（泵没有报告 bolusId）"
            return
        }
        guard linkPhase.isReady else {
            bolusMessage = "链路已断，取消发不出去。立即在泵屏幕上按「取消」"
            return
        }
        bolusPhase = .cancelling
        bolusMessage = "正在请求泵取消 bolusId=\(id)…"
        Task {
            do {
                let result = try await session.cancelBolus(bolusId: id)
                if result.cancelled {
                    bolusPhase = .done
                    bolusMessage = "泵已取消，剩余剂量不会再进。已经进到体内的部分收不回来。"
                    activeBolus = nil
                } else {
                    bolusPhase = .delivering
                    bolusMessage = "泵没有确认取消（status=\(result.status)，reason=\(result.reason)），立即在泵屏幕上按取消"
                }
            } catch {
                bolusPhase = .delivering
                bolusMessage = "取消失败：\(error.localizedDescription)。立即在泵屏幕上按取消"
            }
        }
    }

    func resetBolusState() {
        bolusPhase = .idle
        bolusMessage = nil
        activeBolus = nil
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
        // 大剂量的边界也在这里落盘：它在设置页上与 ISF/CR 同一屏，用户按一次「保存」
        // 就该把这一屏的改动全部记住，不该分两次。
        saveBolusPolicy()
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
                    Text("本版本提供「配对」「读取状态」与「大剂量输注」。大剂量会真的把胰岛素打进体内；基础率、暂停、闭环仍然不可用。")
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
                ConnectionBanner()

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
                    Text(model.glucoseSourceHint)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                GlucoseTrendSection()

                PredictionCard()
                AdviceCard()

                NavigationLink {
                    ControlIQView()
                } label: {
                    ControlIQSummaryCard()
                }
                .buttonStyle(.plain)

                NavigationLink {
                    BolusView()
                } label: {
                    Label(model.bolusEnabled && model.bolusRiskAccepted ? "大剂量 · 输注已启用" : "大剂量",
                          systemImage: "drop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                HStack(spacing: 12) {
                    MetricCard(title: "活性胰岛素", value: model.iobText, caption: "IOB")
                    MetricCard(title: "药筒余量", value: model.insulinUnits, caption: "reservoir")
                }
                HStack(spacing: 12) {
                    MetricCard(title: "基础率", value: model.basalText, caption: model.basalHint)
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
                    NavigationLink("基础率计划") { BasalProfileView() }
                    NavigationLink("读数核对") { ReadingsCheckView() }
                    NavigationLink("安全说明") { SafetyView() }
                    NavigationLink("诊断日志") { DiagnosticView() }
                }
                .font(.footnote)

                NavigationLink {
                    ClosedLoopView()
                } label: {
                    Label(model.loopArmed ? (model.loopLiveDosing ? "闭环运行中（真发）" : "闭环演练中（不发针）") : "闭环 · 微剂量模拟基础率",
                          systemImage: "gearshape.2.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                NavigationLink {
                    BackgroundKeepAliveView()
                } label: {
                    Label(model.backgroundAudioEnabled ? "后台保活 · 已开启" : "后台保活 · 未开启",
                          systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                NavigationLink {
                    CGMSourceView()
                } label: {
                    Label(model.cgmSource == .nightscout ? "血糖来源 · Nightscout" : "血糖来源 · 泵 CGM",
                          systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

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

                Text("本版本包含大剂量输注；基础率与暂停仍由泵固件拒绝写入。闭环状态只读——跑 Control-IQ 的是泵，不是本 App。")
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

/// 状态页顶部的连接条。
///
/// 打开 App 就落到这一页，所以这里必须能回答两个问题：「现在连到哪一步了」
/// 和「我该做什么」。连上之后整条都不显示，不留一行常驻噪音。
struct ConnectionBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.autoConnecting {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在连接 \(model.connectedName ?? "泵")")
                        .font(.footnote.weight(.semibold))
                    Text(model.linkPhase.text)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if let note = model.connectionNote {
            VStack(alignment: .leading, spacing: 10) {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    Button("重试连接") { model.autoConnectIfPossible() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("选择其他泵") { model.goToDiscovery() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Spacer()
                }

                Text("泵不在附近、被 t:connect 占着、或者泵上的蓝牙关掉了，都会这样。数据停在断开前那一刻，请以泵屏幕为准。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
                LabeledContent("单次上限（U）") {
                    TextField("5", value: $model.bolusPolicy.maxSingleUnits, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .disabled(model.bolusPolicy.maxSingleUnits <= 0)
                }
                Toggle("单次上限不限", isOn: Binding(
                    get: { model.bolusPolicy.maxSingleUnits <= 0 },
                    set: { on in model.bolusPolicy.maxSingleUnits = on ? 0 : 5 }
                ))

                LabeledContent("24 小时上限（U）") {
                    TextField("12", value: $model.bolusPolicy.max24hUnits, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .disabled(model.bolusPolicy.max24hUnits <= 0)
                }
                Toggle("24 小时累计不限", isOn: Binding(
                    get: { model.bolusPolicy.max24hUnits <= 0 },
                    set: { on in model.bolusPolicy.max24hUnits = on ? 0 : 12 }
                ))

                LabeledContent("最小间隔（分）") {
                    TextField("60", value: $model.bolusPolicy.minIntervalMinutes, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .disabled(model.bolusPolicy.minIntervalMinutes <= 0)
                }
                Toggle("不要求给药间隔", isOn: Binding(
                    get: { model.bolusPolicy.minIntervalMinutes <= 0 },
                    set: { on in model.bolusPolicy.minIntervalMinutes = on ? 0 : 60 }
                ))
                LabeledContent("低血糖阈值") {
                    TextField("80", value: $model.bolusPolicy.lowGlucoseThreshold, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
            } header: {
                Text("大剂量边界")
            } footer: {
                Text("这几条是 App 侧闸门，命中任一条就不发输注报文。上限填 0 或打开「不限」等于关掉这条闸门——泵自己的单次上限仍然有效，那是泵那边的事。改完点右上角「保存」。")
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

/// 状态页上的闭环状态卡。只回答一个问题：泵自带的 Control-IQ 现在是什么状态。
/// 刻意不叫「闭环」——叫闭环会让人以为是本 App 在自动调剂量。
struct ControlIQSummaryCard: View {
    @EnvironmentObject var model: AppModel

    private var tint: Color {
        guard let info = model.controlIQ else { return .secondary }
        return info.closedLoopEnabled ? .green : .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text("Control-IQ（泵自带）").font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            if let info = model.controlIQ {
                Text(info.headline).font(.callout)
                HStack(spacing: 16) {
                    Text("每日总量 \(info.totalDailyInsulinUnits) U")
                    Text("体重 \(info.weight) \(info.weightUnit?.text ?? "")")
                    if info.version == 2, let remain = info.exerciseRemainingSeconds {
                        Text("运动剩 \(remain / 60) 分")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()

                if !info.closedLoopEnabled {
                    Text("算法关着时，血糖往下掉泵不会自己减量——只剩基础率在走。")
                        .font(.caption2).foregroundStyle(.orange)
                }
            } else {
                Text(model.controlIQError ?? "还没读到 Control-IQ 状态，进来看详情或下拉刷新。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// 闭环状态详情：Control-IQ 的读数 + 睡眠时段表 + 这条边界到底在哪。
///
/// 这一页的全部内容是**只读**的。页面上没有任何开关能改闭环参数，
/// 因为 X2 固件不接受第三方改基础率（见 SafetyView 与 README 的证据）。
struct ControlIQView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let info = model.controlIQ {
                    infoSection(info)
                } else {
                    Text(model.controlIQError ?? "还没读到。点下面的「重新读取」。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                sleepSection
                boundarySection

                Button {
                    Task { await model.loadControlIQ() }
                } label: {
                    Label(model.controlIQLoading ? "读取中…" : "重新读取",
                          systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.controlIQLoading)
            }
            .padding(16)
        }
        .navigationTitle("闭环状态（只读）")
        .task { await model.loadControlIQ() }
    }

    @ViewBuilder
    private func infoSection(_ info: ControlIQMessages.Info) -> some View {
        VStack(spacing: 0) {
            row("闭环算法", info.closedLoopEnabled ? "开启" : "关闭",
                info.closedLoopEnabled ? .green : .orange)
            Divider()
            row("当前模式", info.userModeText, .primary)
            Divider()
            row("控制状态码", "\(info.controlStateRaw)", .secondary)
            Divider()
            row("每日胰岛素总量", "\(info.totalDailyInsulinUnits) U", .primary)
            Divider()
            row("体重", "\(info.weight) \(info.weightUnit?.text ?? "")", .primary)
            if info.version == 2 {
                Divider()
                row("运动剩余", "\((info.exerciseRemainingSeconds ?? 0) / 60) 分钟", .primary)
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))

        Text("读到的是 V\(info.version) 报文。控制状态码是泵自己报的数字，公开资料里没有确证含义，所以这里原样显示、不翻译成「正在减量」之类的结论。")
            .font(.caption2).foregroundStyle(.secondary)
    }

    private var sleepSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("睡眠时段（泵上设的）").font(.subheadline.weight(.semibold))
            if let schedule = model.controlIQSleep {
                ForEach(Array(schedule.windows.enumerated()), id: \.offset) { _, w in
                    HStack {
                        Text("\(w.startText) – \(w.endText)").monospacedDigit()
                        Spacer()
                        Text(w.daysText).foregroundStyle(.secondary)
                        Text(w.enabled ? "启用" : "未用")
                            .font(.caption2)
                            .foregroundStyle(w.enabled ? Color.green : Color.secondary)
                    }
                    .font(.callout)
                    if w != schedule.windows.last { Divider() }
                }
            } else {
                Text("还没读到睡眠表。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var boundarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("为什么这一页只能看").font(.subheadline.weight(.semibold))
            Text("""
            Control-IQ 跑在泵里。改它的目标、体重、睡眠表，以及改基础率、临时率、暂停，\
            在 t:slim X2 上都是固件拒绝的写入路径（pumpX2 标 MOBI_ONLY，controlX2 的\
            功能表写着 Temp Basal / Profile 仅 Mobi）。所以本 App 不提供这些按钮：\
            放一个按下去没反应、或者按下去把泵发断线的键，比没有这个键更糟。
            """)
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func row(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.weight(.medium)).foregroundStyle(color).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
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
                Text("现在能做什么").font(.headline)
                Text("""
                读取：血糖、趋势、IOB、药筒余量、基础率、电量、泵计时。
                写入：只有大剂量（bolus），走「申请授权 → 发起 → 轮询状态 → 可取消」。
                不能写入：基础率（0xA4/0xA6）、暂停与恢复（0x9C/0x9A）——这些在 X2 固件里是 MOBI_ONLY，泵不接受。
                """)
                Text("打药前拦六道").font(.headline)
                Text("""
                • 剂量小于 0.05 U：不发
                • 超过单次上限（默认 5 U，可改）：不发
                • 与上次间隔不足（默认 60 分钟）：不发
                • 24 小时累计超上限（默认 12 U）：不发
                • 当前血糖低于阈值（默认 80 mg/dL）：不发
                • 药筒余量不够，或余量读不到：不发

                IOB 偏高、没有血糖读数只会提示，不会拦住——因为它们是推断，不是事实。
                """)
                Text("已知限制").font(.headline)
                Text("""
                • iOS 无长驻后台服务，息屏后连接可能被系统挂起；挂起期间泵会照常推完，App 看不到进度
                • 「24 小时累计」只统计这个 App 发出的针，泵上直接按的不在内
                • 授权与发起的报文已按抓包逐字节核对，但泵是否受理、推注速度、取消时序仍需真机确认
                • 固件升级可能改变报文长度与语义
                """)
            }
            .font(.callout)
            .padding()
        }
        .navigationTitle("安全说明")
    }
}

// MARK: - 大剂量

/// 输注页。
///
/// 这一页和「建议」是两件不同的事：建议页算的是「该不该补」，这一页做的是
/// 「把剂量真的送进泵」。所以这里没有推荐值，只有用户自己输的数，
/// 加闸门、加二次确认、加取消，每一步都把「泵说的」和「我们以为的」分开写。
struct BolusView: View {
    @EnvironmentObject var model: AppModel
    @State private var showConfirm = false
    @State private var showCancelConfirm = false

    private var decision: BolusDecision {
        model.bolusDecision ?? BolusGuard.evaluate(model.bolusContext())
    }

    /// 闸门现状的一句话。上限为 0 时显示「不限」，而不是显示 0.00 U 让人以为被卡死。
    private var boundaryText: String {
        let p = model.bolusPolicy
        let single = p.maxSingleUnits > 0
            ? String(format: "单次上限 %.2f U", p.maxSingleUnits) : "单次不限"
        let daily = p.max24hUnits > 0
            ? String(format: "24 小时上限 %.2f U", p.max24hUnits) : "24 小时不限"
        let interval = p.minIntervalMinutes > 0
            ? String(format: "最小间隔 %.0f 分钟", p.minIntervalMinutes) : "不要求间隔"
        let low = String(format: "低血糖阈值 %.0f mg/dL", p.lowGlucoseThreshold)
        return "\(single) · \(daily) · \(interval) · \(low)。在「建议参数」里改。"
    }

    private var canDeliver: Bool {
        model.bolusEnabled && model.bolusRiskAccepted && decision.allowed
            && !model.bolusPhase.isBusy && model.linkPhase.isReady
    }

    var body: some View {
        Form {
            if !model.bolusRiskAccepted {
                riskSection
            } else {
                enableSection
                doseSection
                gateSection
                actionSection
                ledgerSection
            }
        }
        .navigationTitle("大剂量")
        .onAppear { model.reviewBolus() }
        .confirmationDialog(
            "确认输注 \(String(format: "%.2f", decision.units)) U？",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("输注 \(String(format: "%.2f", decision.units)) U", role: .destructive) {
                model.startBolus()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("泵收到后立刻开始推注，App 断线也不会停。要停只能在泵屏幕上按取消，或在本页点「取消输注」。")
        }
    }

    private var riskSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("这一段会真的把胰岛素打进身体里", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("""
                大剂量报文已按 pumpX2 的抓包向量逐字节核对（含签名与泵计时），但「泵在真机上是否受理、推注速度是否符合预期」只能由你自己确认。

                第一次使用请按这个顺序：
                • 手边备好急救糖，别在无人看护时试
                • 先打 0.05 U 最小剂量，核对泵屏幕上的大剂量记录与这里一致
                • 任何一次出现「输注没有走完」「没有确认取消」，立刻到泵屏幕核对实际输注量，不要凭界面判断

                这不是医疗器械，未经任何监管批准。
                """)
                .font(.callout)
                Button("我已理解，启用输注") { model.acceptBolusRisk() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        }
    }

    private var enableSection: some View {
        Section {
            Toggle("允许输注", isOn: Binding(get: { model.bolusEnabled },
                                          set: { model.setBolusEnabled($0) }))
            LabeledContent("链路", value: model.linkPhase.text)
            LabeledContent("泵回报的当前大剂量", value: model.activeBolus?.statusName ?? "无")
        } footer: {
            Text("关掉后界面不会再发 0x9E / 0xA0 这类会改变输注的报文。")
        }
    }

    private var doseSection: some View {
        Section {
            HStack {
                Button { model.adjustBolusUnits(by: -0.05) } label: {
                    Image(systemName: "minus.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!model.bolusEnabled || model.bolusPhase.isBusy)

                Spacer()
                Text(String(format: "%.2f U", model.bolusUnits))
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Spacer()

                Button { model.adjustBolusUnits(by: 0.05) } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!model.bolusEnabled || model.bolusPhase.isBusy)
            }
            .padding(.vertical, 6)

            HStack(spacing: 10) {
                ForEach([0.5, 1.0, 2.0, 3.0], id: \.self) { preset in
                    Button(String(format: "%.1f", preset)) {
                        model.bolusUnits = preset
                        model.reviewBolus()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!model.bolusEnabled || model.bolusPhase.isBusy)
                }
            }
        } header: {
            Text("剂量")
        } footer: {
            Text("步进 0.05 U。实际下发前会再向下取整一次，只会少不会多。")
        }
    }

    private var gateSection: some View {
        Section {
            if decision.allowed {
                Label("全部闸门通过，将下发 \(String(format: "%.2f", decision.units)) U",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            ForEach(decision.blocks, id: \.detail) { block in
                VStack(alignment: .leading, spacing: 2) {
                    Label(block.reason.explanation, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(block.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(decision.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button("重新检查") { model.refresh(); model.reviewBolus() }
                .font(.footnote)
        } header: {
            Text("输注前检查")
        } footer: {
            Text(boundaryText)
        }
    }

    private var actionSection: some View {
        Section {
            if let message = model.bolusMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(model.bolusPhase == .failed ? Color.red : Color.secondary)
            }

            if model.bolusPhase == .delivering || model.bolusPhase == .cancelling {
                if let active = model.activeBolus {
                    LabeledContent("正在输注", value: String(format: "%.2f U", active.requestedUnits))
                }
                Button(role: .destructive) {
                    showCancelConfirm = true
                } label: {
                    Label("取消输注", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.bolusPhase == .cancelling)
            } else if model.bolusPhase == .requesting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在与泵交互…").font(.footnote)
                }
            } else {
                Button {
                    showConfirm = true
                } label: {
                    Label("请求授权并输注", systemImage: "drop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canDeliver)
            }

            if model.bolusPhase == .done || model.bolusPhase == .failed {
                Button("回到初始状态") { model.resetBolusState() }
                    .font(.footnote)
            }
        }
        .confirmationDialog("取消这次输注？", isPresented: $showCancelConfirm,
                            titleVisibility: .visible) {
            Button("取消输注", role: .destructive) { model.cancelActiveBolus() }
            Button("继续输注", role: .cancel) {}
        } message: {
            Text("只能取消还没推进去的部分；已经进到体内的收不回来。泵若没有回应取消，必须去泵屏幕上按。")
        }
    }

    private var ledgerSection: some View {
        Section {
            LabeledContent("本机 24 小时累计",
                           value: String(format: "%.2f U", model.ledger.delivered(now: Date())))
            if model.ledger.records.isEmpty {
                Text("还没有记录").font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(model.ledger.records.suffix(5).reversed(), id: \.at) { record in
                    HStack {
                        Text(record.at.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.2f U", record.units))
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
        } header: {
            Text("台账")
        } footer: {
            Text("只记这个 App 发出去的针。在泵上直接按的大剂量不在这里，所以 24 小时累计只是下限，不是总量。")
        }
    }
}

// MARK: - 诊断

/// 读数核对。
///
/// 唯一目的：拿泵屏幕上的数字逐项对照。每一项都同时给出「解析结果」和「原始字节」，
/// 这样数字对不上时不用猜——字节一致就是泵这么报的，字节不一样就是解析偏了，
/// 而整行缺席意味着这条报文压根没回来。
struct ReadingsCheckView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section {
                if model.readingRows.isEmpty {
                    Text("还没有读数。先连上泵，再点「立即刷新」。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.readingRows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.name).font(.subheadline.weight(.semibold))
                            Text(row.opCode)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text(row.value)
                                .font(.system(.subheadline, design: .monospaced))
                        }
                        Text(row.hex)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(row.note)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("最近一次读取")
            } footer: {
                Text("这是小端字节序，前面两位是帧头，已去掉。数字与泵屏幕不一致时，把这一行整条发出来即可定位。")
            }

            Section("对照泵屏幕的顺序") {
                ForEach([
                    "① 泵上先看药筒：屏幕上那个「剩余 xx U」应与「药筒余量」一致（估值时会显示 ≈）",
                    "② 泵上的基础率是「当前」值；若与配置值不同，说明 Control-IQ 或临时率正在调整，属正常",
                    "③ 泵上活性胰岛素取当前曲线的数（Mudaliar / Swan 6hr），两者相差可达 0.03 U",
                    "④ 电量按泵屏幕百分比核对；泵重启后的短时间读数会跳",
                ], id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    model.refresh()
                } label: {
                    Label("重新读取", systemImage: "arrow.clockwise")
                }
            } footer: {
                Text("刷新会依次发 0x20 / 0x24 / 0x22 / 0x6C / 0x34 / 0x28 / 0x36，全部是只读请求。")
            }
        }
        .navigationTitle("读数核对")
    }
}

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

// MARK: - 基础率计划（只读）

/// 只读的基础率计划页。
///
/// 页面上不放任何可编辑控件，这不是偷懒：X2 固件把「设临时基础率 / 暂停 / 恢复 /
/// 改计划」划给了 MOBI（pumpX2 里对应报文全部标 `MOBI_ONLY`），泵收到会回 Nack。
/// 能改而没做，和压根改不了，是两件事，界面上必须区分清楚。
struct BasalProfileView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                if let profile = model.basalProfile {
                    LabeledContent("计划名", value: profile.name)
                    LabeledContent("时段数", value: "\(profile.segments.count)")
                    LabeledContent("24 小时基础量",
                                   value: String(format: "%.2f U", profile.totalDailyBasalUnits))
                    LabeledContent("泵设的单次上限",
                                   value: String(format: "%.2f U", profile.maxBolusUnits))
                    LabeledContent("胰岛素作用时长", value: "\(profile.insulinDurationMinutes) 分钟")
                    LabeledContent("碳水录入", value: profile.carbEntry ? "开" : "关")
                } else {
                    Text("还没读到。连上泵后点下面的「读取计划」。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("当前计划")
            } footer: {
                Text("「泵设的单次上限」和「大剂量」页里的闸门是两道独立的口子，谁小谁生效。")
            }

            if let profile = model.basalProfile, !profile.segments.isEmpty {
                Section {
                    ForEach(profile.segments, id: \.index) { segment in
                        HStack(spacing: 8) {
                            Text(segment.startText)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(String(format: "%.2f U/h", segment.basalRateUnitsPerHour))
                                .monospacedDigit()
                            Text(String(format: "1:%.1f", segment.carbRatioGramsPerUnit))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(segment.targetBgMgdl)/\(segment.isfMgdlPerUnit)")
                                .font(.caption).foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text("时段")
                } footer: {
                    Text("依次是：开始时间 · 基础率 · 碳水比（1 单位抵多少克）· 目标血糖/敏感系数（mg/dL）。")
                }
            }

            Section {
                Button {
                    Task { await model.loadBasalProfile() }
                } label: {
                    HStack {
                        Label("读取计划", systemImage: "arrow.down.circle")
                        Spacer()
                        if model.basalProfileLoading { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(!model.linkPhase.isReady || model.basalProfileLoading)

                if let error = model.basalProfileError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text("只能读。基础率写入、临时基础率、暂停与恢复在 X2 固件属于 MOBI 专属指令，泵会直接拒绝，所以没有实现。")
            }
        }
        .navigationTitle("基础率计划")
        .onAppear {
            if model.basalProfile == nil, model.linkPhase.isReady {
                Task { await model.loadBasalProfile() }
            }
        }
    }
}

// MARK: - 闭环（微剂量模拟基础率）

/// 闭环页。这一页是全 App 唯一会「自己往身体里送胰岛素」的地方，
/// 所以它的形状是：先把边界写在最上面，再给两个分开的开关，最后才是参数和账。
struct ClosedLoopView: View {
    @EnvironmentObject var model: AppModel
    @State private var showLiveConfirm = false
    @State private var showClearConfirm = false

    private var tickText: String {
        guard let next = model.loopNextTickAt else { return "—" }
        let left = max(0, Int(next.timeIntervalSinceNow))
        return String(format: "%d:%02d", left / 60, left % 60)
    }

    var body: some View {
        Form {
            boundarySection
            statusSection
            paramsSection
            decisionSection
            ledgerSection
        }
        .navigationTitle("闭环")
        .onChange(of: model.loopSettings) { _ in model.saveLoopSettings() }
        .onAppear { model.refreshLoopTotals() }
        .confirmationDialog("真的让它自己发针？", isPresented: $showLiveConfirm,
                            titleVisibility: .visible) {
            Button("开始真发", role: .destructive) { model.armLoop(live: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("每 5 分钟最多一针，单针上限 \(String(format: "%.2f", model.loopSettings.maxSingleMicroBolus)) U，每小时上限 \(String(format: "%.2f", model.loopSettings.maxHourlyMicroBolus)) U。打出去的收不回来，血糖低了软件只能停手，不能把胰岛素抽回去。")
        }
    }

    // MARK: 边界

    private var boundarySection: some View {
        Section {
            Text("这里做的是**微剂量模拟基础率**：每 5 分钟，把这 5 分钟本该缓慢滴入的量，用一针小额大剂量补进去。")
            Text("三条代价，写在这里而不是藏在文档里：")
            Text("1. 只能加不能减。血糖要往下掉时，软件只能停止后续针，已经进去的收不回来。所以它比 AAPS 那种能设临时基础率的闭环更依赖你盯着。")
            Text("2. 每针都会进泵的大剂量历史，泵按大剂量算 IOB。这是这套方案的固有形状。")
            Text("3. 泵自带 Control-IQ 必须关掉。两边同时调胰岛素就是叠加给药，读不到它的状态时这一拍也不出针。")
            Text("X2 固件不接受基础率写入（SetTempRate/Suspend/Resume 全是 MOBI_ONLY），上面这三条不是选择，是这台泵剩下的唯一路径。")
        } header: {
            Text("先读这段")
        }
        .font(.footnote)
    }

    // MARK: 状态

    private var statusSection: some View {
        Section {
            LabeledContent("状态") {
                if model.loopArmed {
                    Text(model.loopLiveDosing ? "运行中 · 真发针" : "演练中 · 只记账")
                        .foregroundStyle(model.loopLiveDosing ? Color.orange : Color.green)
                } else {
                    Text("未启动").foregroundStyle(.secondary)
                }
            }
            if model.loopArmed {
                LabeledContent("下一拍", value: tickText)
                LabeledContent("已跑", value: "\(model.loopTickCount) 拍")
            }
            LabeledContent("Control-IQ（泵）") {
                if let info = model.controlIQ {
                    Text(info.closedLoopEnabled ? "开着 · 闭环不能同时跑" : "关着 · 允许")
                        .foregroundStyle(info.closedLoopEnabled ? Color.red : Color.green)
                } else {
                    Text("未读到 · 不出针").foregroundStyle(.orange)
                }
            }
            if let error = model.loopError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }

            if model.loopArmed {
                Button("停止闭环", role: .destructive) {
                    model.disarmLoop(note: "你手动停止了闭环")
                }
            } else {
                Button("开始演练（不发针）") { model.armLoop(live: false) }
                Button("开始真发针") { showLiveConfirm = true }
                    .foregroundStyle(.red)
            }
        } header: {
            Text("开关")
        } footer: {
            Text("演练和真发是两个按钮。演练跑够一轮、看记录里算出来的量合不合理，再考虑真发。")
        }
    }

    // MARK: 参数

    private var paramsSection: some View {
        Section {
            numberRow("目标下限 mg/dL", value: $model.loopSettings.targetLow)
            numberRow("目标上限 mg/dL", value: $model.loopSettings.targetHigh)
            numberRow("敏感系数 ISF", value: $model.loopSettings.isf)
            numberRow("胰岛素作用时长（分钟）", value: $model.loopSettings.insulinDurationMinutes)
            numberRow("单针上限 U", value: $model.loopSettings.maxSingleMicroBolus, step: 0.05)
            numberRow("每小时上限 U", value: $model.loopSettings.maxHourlyMicroBolus, step: 0.05)
            numberRow("IOB 上限 U", value: $model.loopSettings.maxIobUnits, step: 0.1)
            numberRow("停止线 mg/dL", value: $model.loopSettings.lowSuspendThreshold)
            numberRow("泵自己在跑的基础率 U/h", value: $model.loopSettings.pumpBasalUnitsPerHour, step: 0.05)
            if model.loopSettings.pumpBasalUnitsPerHour >= 0.05 {
                Text("泵留在 \(String(format: "%.2f", model.loopSettings.pumpBasalUnitsPerHour)) U/h 上自己跑，App 只补差额。蓝牙断了也不会一点基础胰岛素都没有——这是推荐的安全下限做法。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("0 表示泵的基础率已被设成 0：全部基础胰岛素都由 App 用微剂量补。断链时会完全没有基础胰岛素，风险最高。")
                    .font(.caption).foregroundStyle(.orange)
            }
            Toggle("已确认泵的基础率已按上面的值设置", isOn: $model.loopZeroBasalConfirmed)
            if let invalid = model.loopSettings.invalidReason {
                Text(invalid).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("参数")
        } footer: {
            Text("目标、ISF 应与你泵里个人计划一致。默认值只是保守起点，不是处方。")
        }
    }

    private func numberRow(_ title: String, value: Binding<Double>, step: Double = 1) -> some View {
        LabeledContent(title) {
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .monospacedDigit()
        }
    }

    // MARK: 最近一拍

    private var decisionSection: some View {
        Section {
            if let d = model.loopLastDecision {
                Text(d.summary).font(.callout)
                LabeledContent("基础率折算") { Text(String(format: "%.3f U", d.basalEquiv)) }
                if d.correction > 0 {
                    LabeledContent("高血糖追加") { Text(String(format: "%.2f U", d.correction)) }
                }
                if d.carriedOut > 0 {
                    LabeledContent("攒到下一拍") { Text(String(format: "%.3f U", d.carriedOut)) }
                }
            } else {
                Text("还没跑过一拍").foregroundStyle(.secondary)
            }
            LabeledContent("近一小时已发", value: String(format: "%.2f U", model.loopHourUnits))
            LabeledContent("今日已发", value: String(format: "%.2f U", model.loopTodayUnits))
        } header: {
            Text("最近一拍")
        }
    }

    // MARK: 台账

    private var ledgerSection: some View {
        Section {
            ForEach(Array(model.loopRecords.reversed().prefix(20)), id: \.timestamp) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(r.timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        if r.accepted == true {
                            Text(String(format: "%.2f U", r.units))
                                .font(.caption.weight(.semibold)).foregroundStyle(.green)
                        } else if let hold = r.holdReason {
                            Text(hold).font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text("未发 / 未知").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Text(r.summary).font(.caption2).foregroundStyle(.secondary)
                    if let e = r.errorText {
                        Text(e).font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            if model.loopRecords.isEmpty { Text("还没有记录").foregroundStyle(.secondary) }

            Button("清空台账", role: .destructive) { showClearConfirm = true }
                .confirmationDialog("清空闭环台账？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                    Button("清空", role: .destructive) { model.clearLoopLedger() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("清空后「近一小时已发」会从 0 重算，等于放弃这道额度。一般不要清。")
                }
        } header: {
            Text("台账 · 最近 20 条")
        } footer: {
            Text("额度从台账算，不从内存计数。App 被杀掉重开，额度不会归零。")
        }
    }
}

// MARK: - 血糖来源

/// 血糖来源页。只切「读哪里的血糖」，泵侧的 IOB / 基础率 / Control-IQ 一律不变。
struct CGMSourceView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("血糖来源", selection: Binding(get: { model.cgmSource },
                                                     set: { model.setCGMSource($0) })) {
                    ForEach(CGMSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.inline)
            } footer: {
                Text("换来源只影响血糖、趋势、预测和闭环的输入。胰岛素相关数据永远来自泵。")
            }

            Section {
                Picker("显示单位", selection: Binding(get: { model.glucoseUnit },
                                                    set: { model.setGlucoseUnit($0) })) {
                    ForEach(GlucoseDisplayUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("血糖单位")
            } footer: {
                Text("「跟随来源」= Nightscout 用 mmol/L、泵用 mg/dL。手动选一项就固定不动，换来源也保持。单位只改显示，闸门和闭环一直按 mg/dL 算。")
            }

            if model.cgmSource == .nightscout {
                nightscoutSection
                currentSection
            }

            Section {
                Text("1. 只读血糖。不写 treatment、不读 NS 的 IOB——NS 的 IOB 是别的 App 按它自己的参数算的，拿来做本机闸门等于用别人的假设决定打不打针。")
                Text("2. NS 的延迟是真实存在的：手机上传、桥接、服务器，任何一段卡住都会让「最新血糖」变成十分钟前那条。闭环按读数时间戳算年龄，超过 12 分钟直接停拍。")
                Text("3. 闭环真发之前，先确认 NS 的数值和指尖血 / 泵屏幕对得上。对不上就退回泵 CGM，不要带着一个偏高的读数跑自动。")
            } header: {
                Text("边界")
            }
            .font(.footnote)
        }
        .navigationTitle("血糖来源")
        .onChange(of: model.nsConfig) { _ in model.saveNightscoutConfig() }
    }

    private var nightscoutSection: some View {
        Section {
            Toggle("启用 Nightscout", isOn: $model.nsConfig.enabled)

            LabeledContent("站点地址") {
                TextField("https://ns.example.com", text: $model.nsConfig.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
            }
            Picker("认证方式", selection: $model.nsConfig.authMode) {
                ForEach(NightscoutAuthMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.inline)

            if model.nsConfig.authMode == .secret {
                LabeledContent("密码") {
                    SecureField("API Secret", text: $model.nsConfig.secret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
            } else {
                LabeledContent("访问令牌") {
                    SecureField("token", text: $model.nsConfig.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
            }

            Button {
                model.saveNightscoutConfig()
                Task { await model.refreshNightscout() }
            } label: {
                Label(model.nsLoading ? "正在拉取…" : "保存并拉取一次", systemImage: "arrow.down.circle")
            }
            .disabled(model.nsLoading)

            if let status = model.nsStatus {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
            if let error = model.nsError {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Nightscout")
        } footer: {
            Text("地址填站点根即可（例如 https://ns.example.com 或 https://ns.example.com/ns），把整条 API 地址粘进来也能识别。密码就是 NS 后台的 API Secret：App 只发送它的 SHA1，不发明文。密码存在本机 UserDefaults，不是 Keychain。")
        }
    }

    private var currentSection: some View {
        Section {
            if let mgdl = model.nsLatestMgdl {
                LabeledContent("最新血糖", value: "\(mgdl) mg/dL")
                LabeledContent("数据时间", value: model.nsAgeText)
                if let age = model.nsAgeMinutes, age > 12 {
                    Text("这条读数已经 \(Int(age)) 分钟了，闭环会停拍。检查桥接是否在跑。")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } else {
                Text("还没拉到数据").foregroundStyle(.secondary)
            }
        } header: {
            Text("当前数据")
        }
    }
}
