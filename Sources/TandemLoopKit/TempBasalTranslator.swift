import Foundation

/// Tandem 泵的基础率计划段。与 IDPSegmentResponse 一一对应。
public struct BasalSegment: Equatable, Sendable {
    /// 该段生效的分钟偏移（0..1439），从泵的午夜算起
    public let startMinute: Int
    /// 该段的 profile 基础率，U/hr
    public let rate: Double

    public init(startMinute: Int, rate: Double) {
        self.startMinute = startMinute
        self.rate = rate
    }
}

/// 基础率计划，按段起点升序。用于把 Loop 的绝对速率换算成泵接受的百分比。
public struct BasalSchedule: Equatable, Sendable {
    public let segments: [BasalSegment]

    public init(segments: [BasalSegment]) throws {
        guard !segments.isEmpty else { throw TempBasalTranslationError.emptySchedule }
        let sorted = segments.sorted { $0.startMinute < $1.startMinute }
        guard sorted.first!.startMinute == 0 else {
            throw TempBasalTranslationError.scheduleMustStartAtMidnight
        }
        for (a, b) in zip(sorted, sorted.dropFirst()) where a.startMinute >= b.startMinute {
            throw TempBasalTranslationError.duplicateSegmentStart
        }
        guard sorted.allSatisfy({ $0.rate >= 0 && $0.rate.isFinite }) else {
            throw TempBasalTranslationError.invalidSegmentRate
        }
        self.segments = sorted
    }

    /// 取给定时刻生效的段
    public func segment(atMinuteOfDay minute: Int) -> BasalSegment {
        let m = ((minute % 1440) + 1440) % 1440
        var current = segments[0]
        for s in segments where s.startMinute <= m { current = s }
        return current
    }

    /// 下一个段边界距给定时刻的分钟数，没有后续段时返回 1440
    public func minutesUntilNextBoundary(afterMinuteOfDay minute: Int) -> Int {
        let m = ((minute % 1440) + 1440) % 1440
        let later = segments.map(\.startMinute).filter { $0 > m }
        if let next = later.min() { return next - m }
        return 1440 - m
    }
}

public enum TempBasalTranslationError: Error, Equatable {
    case emptySchedule
    case scheduleMustStartAtMidnight
    case duplicateSegmentStart
    case invalidSegmentRate
    /// 当前段基础率为 0，百分比换算无意义（0 的任意百分比仍为 0）
    case zeroProfileBasalRate
    /// 泵硬限制：15 分钟 ≤ 时长 ≤ 72 小时
    case durationOutOfRange
    case invalidRequestedRate
}

/// 泵端的百分比饱和情况。出现 saturation 说明泵执行的速率与请求值不同。
public enum TempBasalSaturation: String, Equatable, Sendable {
    /// 未触及边界
    case none
    /// 请求超过 250%，泵最多按 250% 执行
    case highLimit
    /// 换算后四舍五入造成的轻微偏差，未触及硬限制
    case rounding
}

/// 一条可直接下发到 SetTempRateRequest 的指令。
public struct TempBasalCommand: Equatable, Sendable {
    /// 发给泵的百分比，0...250
    public let percent: Int
    /// 泵实际会执行的速率，U/hr
    public let effectiveRate: Double
    /// Loop 请求的速率，U/hr
    public let requestedRate: Double
    /// 实际下发的时长（秒）
    public let duration: TimeInterval
    /// 下发的时长是否被段边界截短
    public let truncatedAtSegmentBoundary: Bool
    public let saturation: TempBasalSaturation

    /// 实际与请求的偏差，正值表示多输
    public var rateError: Double { effectiveRate - requestedRate }

    /// 偏差占请求值的比例；请求为 0 时返回 0
    public var relativeError: Double {
        requestedRate == 0 ? 0 : rateError / requestedRate
    }
}

/// 把 Loop 的绝对速率（U/hr）翻译成 Tandem 的百分比临时基础率。
///
/// 背景：LoopKit 的 `enactTempBasal(unitsPerHour:for:)` 传绝对速率，而 Tandem 的
/// `SetTempRateRequest(minutes:percent:)` 只接受相对当前 profile 基础率的整数百分比，
/// 上限 250%。这个换算不是等价的，误差必须先算清楚再交给算法，否则闭环会持续少给。
public enum TempBasalTranslator {

    /// 泵的硬限制，与 pumpX2 的 SetTempRateRequest 常量一致
    public static let minimumDuration: TimeInterval = 15 * 60
    public static let maximumDuration: TimeInterval = 72 * 60 * 60
    public static let maximumPercent = 250

    public static func translate(
        requestedRate: Double,
        duration: TimeInterval,
        schedule: BasalSchedule,
        minuteOfDay: Int
    ) throws -> TempBasalCommand {

        guard requestedRate.isFinite, requestedRate >= 0 else {
            throw TempBasalTranslationError.invalidRequestedRate
        }
        guard duration >= minimumDuration, duration <= maximumDuration else {
            throw TempBasalTranslationError.durationOutOfRange
        }

        let segment = schedule.segment(atMinuteOfDay: minuteOfDay)
        let base = segment.rate
        guard base > 0 else { throw TempBasalTranslationError.zeroProfileBasalRate }

        let rawPercent = requestedRate / base * 100
        var percent = Int(rawPercent.rounded())
        var saturation: TempBasalSaturation = .none

        if percent > maximumPercent {
            percent = maximumPercent
            saturation = .highLimit
        } else if percent < 0 {
            percent = 0
        } else if abs(Double(percent) - rawPercent) > 1e-9 {
            saturation = .rounding
        }

        let effective = Double(percent) / 100 * base

        // 泵在临时基础率期间若跨过 profile 段边界，会按新段的 base 重新计算相同百分比，
        // 实际速率随之改变。这里把时长截到边界前，保证一条指令只作用于一个段。
        let minutesRequested = duration / 60
        let minutesToBoundary = Double(schedule.minutesUntilNextBoundary(afterMinuteOfDay: minuteOfDay))
        var minutes = minutesRequested
        var truncated = false
        if minutesToBoundary < minutesRequested {
            if minutesToBoundary >= minimumDuration / 60 {
                minutes = minutesToBoundary
                truncated = true
            } else {
                // 距边界不足 15 分钟，泵不接受更短的时长，只能接受跨段的不精确
                truncated = true
            }
        }

        return TempBasalCommand(
            percent: percent,
            effectiveRate: effective,
            requestedRate: requestedRate,
            duration: minutes * 60,
            truncatedAtSegmentBoundary: truncated,
            saturation: saturation
        )
    }
}
