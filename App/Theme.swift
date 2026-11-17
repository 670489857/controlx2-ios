import SwiftUI

/// 全局视觉基调。
///
/// 取色思路：不用品牌蓝当主色——满屏蓝色按钮会显得像系统设置面板，而不是一台医疗设备。
/// 主色定为偏冷的青绿（贴近血糖在正常区间的颜色），强调色只在"需要动手"的地方出现。
/// 中性色全部交给系统的 `secondarySystemGroupedBackground` 与 material，
/// 这样深色模式下不用维护第二套色板。
enum Theme {

    /// 主色（青绿）
    static let accent = Color(red: 0.055, green: 0.522, blue: 0.549)
    /// 主色的柔和底（浅色模式接近白，深色模式下压暗）
    static let accentWash = Color(red: 0.055, green: 0.522, blue: 0.549).opacity(0.10)

    static let warn = Color(red: 0.86, green: 0.55, blue: 0.10)
    static let danger = Color(red: 0.83, green: 0.26, blue: 0.24)

    static let cardRadius: CGFloat = 24
    static let innerRadius: CGFloat = 16
    static let cardSpacing: CGFloat = 12

    /// 血糖区间色：低 → 红，目标 → 主色，高 → 琥珀。
    /// 只用在数字、趋势线和小圆点上，不铺大面积背景——整块变色在锁屏上像报警横幅。
    static func glucose(_ mgdl: Double?) -> Color {
        guard let mgdl else { return .secondary }
        if mgdl < 70 { return danger }
        if mgdl > 180 { return warn }
        return accent
    }

    static func glucoseLabel(_ mgdl: Double?) -> String {
        guard let mgdl else { return "等待数据" }
        if mgdl < 70 { return "偏低" }
        if mgdl > 250 { return "偏高" }
        if mgdl > 180 { return "略高" }
        return "在范围内"
    }
}

// MARK: - 卡片

extension View {
    /// 统一卡片：圆角 + 极轻的描边 + 柔和投影。
    /// 阴影只在浅色模式下明显，深色模式靠描边分层，避免灰雾。
    func appCard(padding: CGFloat = 20, radius: CGFloat = DS.radiusCard, tint: Color? = nil) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(
                                    LinearGradient(colors: [tint.opacity(0.14), tint.opacity(0.02)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.045), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.045), radius: 14, y: 6)
    }

    /// 小节标题：小字号 + 字距，比系统默认的加粗标题更安静
    func sectionLabel() -> some View {
        self
            .font(.caption.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

/// 指标小格。四格共用一张卡，比四张独立卡少三条边、安静很多。
struct StatCell: View {
    let title: String
    let value: String
    var note: String? = nil
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let note {
                Text(note).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 首页的主动作块。三个并排，图标在上、标题在下，比一列 bordered 按钮好扫。
struct ActionTile: View {
    let title: String
    let systemImage: String
    var caption: String? = nil
    var filled: Bool = false

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
            Text(title).font(.footnote.weight(.semibold))
            if let caption {
                Text(caption).font(.caption2).opacity(0.75)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .foregroundStyle(filled ? Color.white : Theme.accent)
        .background {
            RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
                .fill(filled ? Theme.accent : Theme.accentWash)
        }
    }
}

/// 首页主卡里的迷你趋势线。只描线，不用 Canvas：小组件与低电量模式下更稳。
struct MiniSpark: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        let span = max(0.001, high - low)
        for (index, value) in values.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1)
            let y = rect.maxY - rect.height * CGFloat((value - low) / span)
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}
