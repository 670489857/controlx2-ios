import ActivityKit
import SwiftUI
import WidgetKit

/// 锁屏 / 灵动岛上的血糖卡片。
///
/// 这里只做展示，不做任何判断：锁屏上不能发针，也不该出现"可以点一下打药"的入口。
/// 所有动作仍然只能在 App 里、并且经过闸门。
struct LoopLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LoopActivityAttributes.self) { context in
            LockScreenCard(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    GlucoseBadge(state: context.state, big: true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.state.iobText).font(.caption).bold()
                        Text(context.state.loopText).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Text(context.state.lastDoseText).font(.caption2)
                        Spacer()
                        Text(context.state.sourceText).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "drop.fill").foregroundStyle(.green)
            } compactTrailing: {
                Text(context.state.glucoseText).font(.caption).bold().monospacedDigit()
            } minimal: {
                Text(context.state.glucoseText).font(.caption2).bold().monospacedDigit()
            }
        }
    }
}

private struct GlucoseBadge: View {
    let state: LoopActivityAttributes.ContentState
    let big: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(state.glucoseText)
                .font(.system(size: big ? 34 : 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if !state.trendSymbol.isEmpty {
                Image(systemName: state.trendSymbol).font(.system(size: big ? 20 : 16))
            }
            Text(state.glucoseUnit).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct LockScreenCard: View {
    let state: LoopActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            GlucoseBadge(state: state, big: true)
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(state.loopText).font(.caption).bold()
                Text("IOB " + state.iobText).font(.caption2).foregroundStyle(.secondary)
                Text(state.lastDoseText).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

@main
struct LoopLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        LoopLiveActivityWidget()
    }
}
