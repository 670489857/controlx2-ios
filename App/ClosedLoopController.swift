import Foundation
import PumpX2Kit
import PumpX2BLE
import X2Advisor

/// 闭环的执行层。算法在 `ClosedLoop.decide`，这里只负责三件事：
/// 攒输入 → 调用判断 → 真发的时候把针发出去、并记账。
///
/// # 武装 / 演练 / 真发 三个开关是分开的
///
/// - 未武装：什么都不跑。
/// - 已武装 + 演练：每 5 分钟算一次、记账，**不发针**。这是默认形态，用来验证
///   算法在这套参数下给的量是不是你想要的。
/// - 已武装 + 真发：真的每 5 分钟向泵申请一次许可并发起微剂量。
///   需要单独打开，且自动卸武装的条件比演练更严。
///
/// 三道自动卸武装：血糖连续两拍低于停止线、连续三拍通讯出错、Control-IQ 被打开
/// （最后这条在判断里就会被拦住，但武装也一并卸掉，避免一直空转）。
extension AppModel {

    // MARK: 参数持久化

    private static let loopSettingsKey = "loopSettings"

    nonisolated static func loadLoopSettings() -> ClosedLoop.Settings {
        guard let data = UserDefaults.standard.data(forKey: loopSettingsKey),
              let s = try? JSONDecoder().decode(ClosedLoop.Settings.self, from: data)
        else { return ClosedLoop.Settings() }
        return s
    }

    func saveLoopSettings() {
        if let data = try? JSONEncoder().encode(loopSettings) {
            UserDefaults.standard.set(data, forKey: Self.loopSettingsKey)
        }
    }

    // MARK: 武装

    /// 不能武装的具体原因。返回 nil 才允许武装。
    /// 把理由写成字符串而不是 Bool，是因为「按钮点不动」这类问题必须能说清是缺了哪一步。
    func loopArmBlockReason(live: Bool) -> String? {
        if let invalid = loopSettings.invalidReason { return invalid }
        guard bolusEnabled && bolusRiskAccepted else {
            return "先在「大剂量」页打开输注开关并完成风险确认——闭环发针走的就是这条链路"
        }
        guard linkPhase.isReady else { return "链路未就绪" }
        if live {
            if let ciq = controlIQ?.closedLoopEnabled, ciq {
                return "泵的 Control-IQ 开着。两个控制器同时调胰岛素会叠加，必须先在泵上关掉它"
            }
            if controlIQ == nil {
                return "还没读到 Control-IQ 状态。真发之前必须确认它在关着"
            }
            if let maxBolus = basalProfile?.maxBolusUnits,
               maxBolus < loopSettings.maxSingleMicroBolus {
                return "泵上单次上限 \(maxBolus) U 小于闭环单次上限 \(loopSettings.maxSingleMicroBolus) U"
            }
            // 泵的基础率如果没有被降下来，App 补的每一段都会和泵自己的基础率叠加
            if loopSettings.pumpBasalUnitsPerHour < 0.05 && !loopZeroBasalConfirmed {
                return "泵的基础率还在跑：先到泵上把基础率设成 0（或把 App 里「泵自己在跑的」填成实际值），再勾选确认。否则 App 补的会和泵叠加"
            }
            // 真发必须先把「接管自检」跑通并签发凭证：
            // 泵在跑什么、Control-IQ 关没关、药筒还剩多少，都是会在几十分钟内变化的状态
            if let reason = takeoverClearanceBlockReason { return reason }
        }
        return nil
    }

    func armLoop(live: Bool) {
        if let reason = loopArmBlockReason(live: live) {
            loopError = reason
            return
        }
        loopError = nil
        loopCarried = 0
        loopLowTicks = 0
        loopErrorTicks = 0
        loopLiveDosing = live
        loopArmed = true
        startLoopTask()
        // 武装后立刻跑一拍，别让人对着「下一拍 5:00」等
        Task { await loopTick() }
    }

    /// 卸武装。所有停止路径都走这里，保证只有一处状态被改。
    func disarmLoop(note: String? = nil) {
        loopTask?.cancel()
        loopTask = nil
        loopArmed = false
        loopLiveDosing = false
        loopNextTickAt = nil
        if let note { loopError = note }
    }

    private func startLoopTask() {
        loopTask?.cancel()
        loopNextTickAt = Date().addingTimeInterval(loopSettings.tickSeconds)
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                let tick = self?.loopSettings.tickSeconds ?? 300
                try? await Task.sleep(for: .seconds(tick))
                guard !Task.isCancelled else { return }
                await self?.loopTick()
            }
        }
    }

    // MARK: 一拍

    func loopTick() async {
        guard loopArmed else { return }
        loopTickCount += 1
        loopNextTickAt = Date().addingTimeInterval(loopSettings.tickSeconds)

        guard linkPhase.isReady else {
            registerLoopError("链路断开，这一拍跳过")
            return
        }

        await resumeAfterReconnectIfNeeded()
        if (try? await session.refresh()) == nil {
            registerLoopError("读泵状态失败")
            return
        }
        await refreshFromSession()
        let snap = await session.snapshot

        if loopLiveDosing, controlIQ?.closedLoopEnabled == true {
            disarmLoop(note: "泵的 Control-IQ 被重新打开了。闭环已自动停止，避免两个控制器同时调胰岛素。")
            return
        }

        let decision = ClosedLoop.decide(loopSettings, loopInputs(snap))
        loopLastDecision = decision
        loopCarried = decision.carriedOut

        // 拦在「低血糖」时连着两拍就卸武装。这不是算法判断，是这层必须有的兜底：
        // 泵上的基础率还在跑，软件这边只能停手，人得知道。
        if decision.hold == .glucoseLow {
            loopLowTicks += 1
            if loopLowTicks >= 2 {
                disarmLoop(note: "血糖连续 10 分钟低于 \(Int(loopSettings.lowSuspendThreshold)) mg/dL，闭环已自动停止。请立刻处理低血糖，泵上的基础率仍在走。")
                return
            }
        } else {
            loopLowTicks = 0
        }

        var accepted: Bool?
        var errorText: String?
        if decision.willDose, loopLiveDosing {
            (accepted, errorText) = await deliverMicroBolus(units: decision.units, snap: snap)
            if accepted != true { registerLoopError(errorText ?? "泵未受理") } else { loopErrorTicks = 0 }
        }

        let record = LoopRecord(timestamp: Date(),
                                units: decision.willDose ? decision.units : 0,
                                accepted: decision.willDose ? accepted : nil,
                                holdReason: decision.hold?.rawValue,
                                bg: glucoseValue ?? snap.glucoseMgdl,
                                iob: snap.iobUnits ?? 0,
                                basalEquiv: decision.basalEquiv,
                                correction: decision.correction,
                                eventualBg: prediction?.eventualBg,
                                summary: decision.summary,
                                errorText: errorText)
        loopLedger.append(record)
        refreshLoopTotals()
        syncLiveActivity()
        if loopLiveDosing, errorText == nil, !decision.willDose { loopErrorTicks = 0 }
    }

    private func loopInputs(_ snap: PumpSession.Snapshot) -> ClosedLoop.Inputs {
        // 血糖从「用户选定的来源」取。闭环如果一边用 NS 的值做判断、
        // 一边拿泵的 EGV 做显示，就会在两边差 10 mg/dL 时没人说得清为什么停针。
        let useNS = cgmSource == .nightscout && nsLatestMgdl != nil
        let cgmAgeMinutes = useNS ? nsAgeMinutes : snap.glucoseAgeSeconds.map { Double($0) / 60 }
        let status = snap.glucoseStatus
        // 状态不是 1（有效）就当没有读数据：0 无 CGM、2 低、3 高、4 不可用。
        // NS 没有这个概念，用年龄闸门兜底（超过 maxCgmAgeMinutes 直接停拍）。
        let bg: Double? = useNS
            ? nsLatestMgdl.map(Double.init)
            : ((status == nil || status == 1) ? snap.glucoseMgdl.map(Double.init) : nil)

        return ClosedLoop.Inputs(
            cgmMgdl: bg,
            cgmAgeMinutes: cgmAgeMinutes,
            iobUnits: snap.iobUnits ?? 0,
            basalProfileUnitsPerHour: snap.basalProfile ?? snap.basalRate,
            deliveredTodayUnits: loopLedger.deliveredToday(),
            deliveredLastHourUnits: loopLedger.deliveredLastHour(),
            eventualBg: prediction?.eventualBg,
            minutesToLow: prediction?.minutesToLow,
            trendPerMinute: currentTrendPerMinute(),
            controlIQEnabled: snap.controlIQ?.closedLoopEnabled,
            carriedUnits: loopCarried,
            pumpBusy: loopPumpBusy || (snap.currentBolus?.bolusId ?? 0) != 0
        )
    }

    /// 用最近三条读数估斜率（mg/dL/min）。不够三点就当 0：
    /// 用两点估斜率会被单点噪声放大成「正在暴跌」，那会让闸门乱拦。
    private func currentTrendPerMinute() -> Double {
        let tail = samples.suffix(3)
        guard tail.count == 3,
              let first = tail.first, let last = tail.last,
              last.timestamp > first.timestamp
        else { return 0 }
        let minutes = last.timestamp.timeIntervalSince(first.timestamp) / 60
        guard minutes > 0 else { return 0 }
        return (Double(last.mgdl) - Double(first.mgdl)) / minutes
    }

    private func registerLoopError(_ text: String) {
        loopErrorTicks += 1
        loopError = text
        if loopErrorTicks >= 3 {
            disarmLoop(note: "连续三拍通讯失败，闭环已自动停止：\(text)")
        }
    }

    // MARK: 发针

    /// 一针微剂量。返回 (泵是否受理, 错误文本)。
    ///
    /// 超时不能当成「没打」——报文可能已经到了泵。所以 `accepted == nil` 会原样进账，
    /// 界面和 CSV 里都能看到这一笔「状态未知」。
    private func deliverMicroBolus(units: Double, snap: PumpSession.Snapshot) async -> (Bool?, String?) {
        loopPumpBusy = true
        defer { loopPumpBusy = false }
        var granted: BolusMessages.Permission?
        do {
            let permission = try await session.requestBolusPermission()
            granted = permission
            let result = try await session.initiateBolus(
                units: units,
                permission: permission,
                carbsGrams: 0,
                bgMgdl: snap.glucoseMgdl ?? 0,
                iobUnits: snap.iobUnits ?? 0
            )
            // 等这一针推完再往下走。微剂量本身几秒就完，但许可没释放前下一拍会撞 Nack
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(2))
                if let state = try? await session.readCurrentBolus(),
                   state.bolusId == 0 || state.statusId == 0 { break }
            }
            try? await session.releaseBolusPermission(bolusId: permission.bolusId)
            if !result.accepted {
                return (false, "泵未受理：status=\(result.status) type=\(result.statusType)")
            }
            return (true, nil)
        } catch {
            if let g = granted { try? await session.releaseBolusPermission(bolusId: g.bolusId) }
            return (nil, error.localizedDescription)
        }
    }

    // MARK: 账与展示

    func refreshLoopTotals() {
        loopHourUnits = loopLedger.deliveredLastHour()
        loopTodayUnits = loopLedger.deliveredToday()
        loopRecords = Array(loopLedger.readAll().suffix(60))
    }

    func clearLoopLedger() {
        loopLedger.reset()
        refreshLoopTotals()
    }

    /// 台账导出成 CSV 文本，交给 `ShareLink` 或复制
    func loopCSV() -> String { loopLedger.exportCSV() }
}

extension AppModel {
    /// 从泵里读体重和每日胰岛素总量，填进闭环参数。
    /// 这两项泵里本来就有（Control-IQ 用它们算总剂量），让用户手抄一遍既没必要也容易抄错。
    func adoptPumpProfileNumbers() {
        guard let info = controlIQ else {
            loopError = "还没读到泵里的 Control-IQ 参数，先刷新一次泵状态"
            return
        }
        if info.weight > 0 { loopSettings.weightKg = Double(info.weight) }
        if info.totalDailyInsulinUnits > 0 {
            loopSettings.totalDailyInsulinUnits = Double(info.totalDailyInsulinUnits)
        }
        saveLoopSettings()
        loopError = nil
    }
}
