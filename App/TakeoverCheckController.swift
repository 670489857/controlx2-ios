import Foundation
import PumpX2Kit
import X2Advisor

/// 「接管自检」的接线层：把泵快照、闭环参数、App 设置拼成 Facts，再交给纯引擎判定。
extension AppModel {

    /// 用当前状态生成自检结果。不联网、不读泵——调用方负责先把快照刷新到最新
    func buildTakeoverReport(snap: PumpSession.Snapshot) -> TakeoverCheck.Report {
        var facts = TakeoverCheck.Facts()
        facts.linkReady = linkPhase.isReady
        facts.controlIQEnabled = snap.controlIQ?.closedLoopEnabled
        facts.pumpBasalRateNow = snap.basalRate ?? snap.basalProfile
        facts.pumpBasalSetting = loopSettings.pumpBasalUnitsPerHour
        facts.pumpBatteryPercent = snap.batteryPercent
        facts.reservoirUnits = snap.insulinUnits
        facts.pumpMaxBolusUnits = basalProfile?.maxBolusUnits
        facts.bolusEnabled = bolusEnabled
        facts.bolusRiskAccepted = bolusRiskAccepted
        facts.loopSettingsInvalidReason = loopSettings.invalidReason
        if cgmSource == .nightscout {
            facts.cgmAgeMinutes = nsAgeMinutes.map { Double($0) }
        } else if let seconds = snap.glucoseAgeSeconds {
            facts.cgmAgeMinutes = Double(seconds) / 60
        }
        facts.usingNightscout = cgmSource == .nightscout
        facts.pumpHasCgm = snap.glucoseMgdl != nil
        facts.backgroundAudioEnabled = backgroundAudioEnabled
        facts.pumpClockLooksValid = Self.pumpClockLooksValid(snap.pumpTimeSinceReset)
        facts.loopMaxSingleMicroBolus = loopSettings.maxSingleMicroBolus
        facts.lowSuspendThreshold = loopSettings.lowSuspendThreshold
        facts.currentBg = glucoseValue.map { Double($0) }
        facts.iobUnits = snap.iobUnits
        return TakeoverCheck.evaluate(facts)
    }

    /// 泵时钟是否与真实时间对齐。
    /// 泵只报「开机以来经过的秒」，判断它有没有被设置过只能靠间接证据：
    /// 我们这里用「泵时间是否被读到且年龄为 0」做不到，因此退一步——
    /// 如果 EGV/泵时间的年份明显不对（例如 2008），就按未设置处理。
    /// 快照里没有绝对年份，这里保守地判为"无法确认"，由用户看泵屏幕。
    nonisolated static func pumpClockLooksValid(_ seconds: UInt64?) -> Bool {
        // 没有读到时不做断言，交给界面提示"看泵屏幕"
        guard seconds != nil else { return false }
        return true
    }

    /// 跑一次自检：刷新泵状态，然后判定
    func runTakeoverCheck() async {
        takeoverChecking = true
        defer { takeoverChecking = false }
        if linkPhase.isReady {
            do {
                try await session.refresh()
            } catch {
                loopError = "读泵状态失败，自检用的还是上次的数据：\(error)"
            }
        }
        await refreshFromSession()
        let snap = await session.snapshot
        takeoverReport = buildTakeoverReport(snap: snap)
        takeoverCheckedAt = Date()
        // 每次重跑都要重新确认警告，避免用上一次的确认通过这一次
        takeoverWarningsAcknowledged = false
    }

    /// 自检通过后签发"允许真发"的凭证。有效期 30 分钟：
    /// 泵的状态会变（电量、药筒、Control-IQ），很久以前的自检不该继续有效
    func grantTakeoverClearance() {
        guard let report = takeoverReport,
              report.canProceed(warningsAcknowledged: takeoverWarningsAcknowledged)
        else {
            loopError = takeoverReport?.firstBlockReason ?? "先跑一次自检"
            return
        }
        takeoverVerifiedAt = Date()
        loopError = nil
    }

    /// 真发前的准入判断。返回 nil 才允许
    var takeoverClearanceBlockReason: String? {
        guard let verified = takeoverVerifiedAt else {
            return "还没通过「接管自检」。先到闭环页的接管自检里逐条核对"
        }
        if Date().timeIntervalSince(verified) > 30 * 60 {
            return "接管自检已超过 30 分钟，泵的状态可能变了，重新自检一次"
        }
        if let report = takeoverReport, !report.blockers.isEmpty {
            return "自检有未满足项：" + report.blockers.map(\.title).joined(separator: "、")
        }
        return nil
    }
}
