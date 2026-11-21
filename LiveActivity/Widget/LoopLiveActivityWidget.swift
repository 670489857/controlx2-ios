import ActivityKit
import SwiftUI
import WidgetKit

/// 锁屏 / 灵动岛上的血糖卡。
///
/// 设计取向：深色卡片、巨大数字、右侧一条最近一小时的小趋势线。
/// 参考过几个同类 App 的锁屏卡，共同点是「一眼只读一件事」——血糖。
/// 所以这里把 IOB、闭环状态、最近一针全部压到右侧小字，不做并列展示。
///
/// 颜色必须显式指定：锁屏实时活动会被系统做 vibrant 渲染，
/// 用 `.primary` 之类的默认色画在自绘深色背景上会变成黑字黑底。
struct LoopLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LoopActivityAttributes.self) { context in
            LockScreenCard(state: context.state)
                .activityBackgroundTint(Palette.card)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(context.state.glucoseText)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Palette.primary)
                        if !context.state.trendSymbol.isEmpty {
                            Image(systemName: context.state.trendSymbol)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Palette.accent(for: context.state.glucoseValue))
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.state.iobText)
                            .font(.caption).bold().monospacedDigit()
                            .foregroundStyle(Palette.primary)
                        Text(context.state.loopText)
                            .font(.caption2).bold()
                            .foregroundStyle(Palette.accentGreen)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        Sparkline(values: context.state.spark)
                            .stroke(Palette.accent(for: context.state.glucoseValue), lineWidth: 1.5)
                            .frame(height: 18)
                            .frame(maxWidth: 120)
                        Spacer()
                        Text(context.state.lastDoseText)
                            .font(.caption2).foregroundStyle(Palette.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "drop.fill")
                    .foregroundStyle(Palette.accent(for: context.state.glucoseValue))
            } compactTrailing: {
                HStack(spacing: 2) {
                    Text(context.state.glucoseText)
                        .font(.caption).bold().monospacedDigit()
                        .foregroundStyle(Palette.primary)
                    if !context.state.trendSymbol.isEmpty {
                        Image(systemName: context.state.trendSymbol)
                            .font(.caption2)
                            .foregroundStyle(Palette.accent(for: context.state.glucoseValue))
                    }
                }
            } minimal: {
                Text(context.state.glucoseText)
                    .font(.caption2).bold().monospacedDigit()
                    .foregroundStyle(Palette.primary)
            }
        }
    }
}

/// 显式配色。血糖偏离目标区间时只换强调色，不动背景——
/// 整张卡跟着变红，在锁屏上比数字本身更吓人，也更容易看错。
private enum Palette {
    static let card = Color(red: 0.05, green: 0.07, blue: 0.09)
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.60)
    static let accentGreen = Color(red: 0.42, green: 0.90, blue: 0.62)
    static let accentAmber = Color(red: 1.00, green: 0.78, blue: 0.35)
    static let accentRed = Color(red: 1.00, green: 0.45, blue: 0.45)

    static func accent(for mgdl: Double) -> Color {
        switch mgdl {
        case ..<70: return accentRed
        case ..<180: return accentGreen
        default: return accentAmber
        }
    }
}

/// 最近一小时的小趋势线。用 Shape 而不是 Canvas：
/// 小组件快照对复杂绘制的支持有限，Path 是这里最稳的形式。
private struct Sparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count >= 2 else { return path }
        let lo = values.min() ?? 70
        let hi = values.max() ?? 180
        let span = max(hi - lo, 1)
        for (index, value) in values.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1)
            let y = rect.maxY - rect.height * CGFloat((value - lo) / span)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

private struct LockScreenCard: View {
    let state: LoopActivityAttributes.ContentState

    private var timeText: String {
        state.updatedAt.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(state.glucoseText)
                        .font(.system(size: 50, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.primary)
                    if !state.trendSymbol.isEmpty {
                        Image(systemName: state.trendSymbol)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Palette.accent(for: state.glucoseValue))
                    }
                }
                HStack(spacing: 8) {
                    Text(state.glucoseUnit)
                        .font(.caption).foregroundStyle(Palette.secondary)
                    Text(state.loopText)
                        .font(.caption2).bold()
                        .foregroundStyle(Palette.accentGreen)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.accentGreen.opacity(0.18),
                                    in: Capsule())
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 6) {
                    Sparkline(values: state.spark)
                        .stroke(Palette.accent(for: state.glucoseValue).opacity(0.85), lineWidth: 2)
                        .frame(width: 84, height: 22)
                    Text(timeText)
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(Palette.secondary)
                }
                Text("IOB " + state.iobText)
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(Palette.primary)
                Text(state.lastDoseText)
                    .font(.caption2)
                    .foregroundStyle(Palette.secondary)
                Text(state.sourceText)
                    .font(.caption2)
                    .foregroundStyle(Palette.secondary.opacity(0.8))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@main
struct LoopLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        LoopLiveActivityWidget()
    }
}
