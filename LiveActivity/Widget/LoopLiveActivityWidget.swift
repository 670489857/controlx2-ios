import ActivityKit
import SwiftUI
import WidgetKit

/// 锁屏 / 灵动岛上的血糖卡片。
///
/// 这里只做展示：锁屏上不能发针，也不该出现"点一下打药"的入口。
///
/// 配色必须显式指定。锁屏上的实时活动会被系统做一次「vibrant」渲染，
/// 之前用 `.primary` / `.secondary` 的默认色，在自绘的深色背景上直接变成黑字黑底——
/// 血糖大数字在截图里"消失"就是这个原因。现在所有文字都写死成白色系。
struct LoopLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LoopActivityAttributes.self) { context in
            LockScreenCard(state: context.state)
                .activityBackgroundTint(Palette.background)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    GlucoseBadge(state: context.state, size: 34)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.state.iobText)
                            .font(.caption).bold().foregroundStyle(Palette.primary)
                        Text(context.state.loopText)
                            .font(.caption2).foregroundStyle(Palette.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Text(context.state.lastDoseText)
                            .font(.caption2).foregroundStyle(Palette.secondary)
                        Spacer()
                        Text(context.state.sourceText)
                            .font(.caption2).foregroundStyle(Palette.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "drop.fill").foregroundStyle(Palette.accent)
            } compactTrailing: {
                Text(context.state.glucoseText)
                    .font(.caption).bold().monospacedDigit()
                    .foregroundStyle(Palette.primary)
            } minimal: {
                Text(context.state.glucoseText)
                    .font(.caption2).bold().monospacedDigit()
                    .foregroundStyle(Palette.primary)
            }
        }
    }
}

/// 一套显式颜色。深色卡片上只用这几个值，避免再被系统的 vibrant 渲染吃掉对比度。
private enum Palette {
    static let background = Color(red: 0.055, green: 0.06, blue: 0.08)
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let accent = Color(red: 0.36, green: 0.86, blue: 0.52)
}

private struct GlucoseBadge: View {
    let state: LoopActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(state.glucoseText)
                    .font(.system(size: size, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.primary)
                if !state.trendSymbol.isEmpty {
                    Image(systemName: state.trendSymbol)
                        .font(.system(size: size * 0.62, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                }
            }
            Text(state.glucoseUnit)
                .font(.caption2)
                .foregroundStyle(Palette.secondary)
        }
    }
}

private struct LockScreenCard: View {
    let state: LoopActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            GlucoseBadge(state: state, size: 36)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(state.loopText)
                    .font(.caption).bold()
                    .foregroundStyle(Palette.accent)
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
