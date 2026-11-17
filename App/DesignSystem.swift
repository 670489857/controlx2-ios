import SwiftUI

/// 视觉系统（0.8.0 重做）。
///
/// 三条约束，写在前面免得后面又走回系统设置面板的样子：
/// 1. **少边框、多留白**。卡片靠留白和极浅投影分层，不靠描边和分割线。
/// 2. **一个页面只有一处重点**。字号差距拉开，别让六个元素都喊自己重要。
/// 3. **颜色只表达状态**。青绿=在范围内、琥珀=偏高、红=偏低或阻断，其余全是中性灰。
enum DS {

    // MARK: 颜色

    static let accent = Color(red: 0.04, green: 0.52, blue: 0.55)
    static let accentLight = Color(red: 0.10, green: 0.68, blue: 0.62)
    static let warn = Color(red: 0.88, green: 0.56, blue: 0.10)
    static let danger = Color(red: 0.84, green: 0.27, blue: 0.24)
    static let ok = Color(red: 0.16, green: 0.60, blue: 0.38)

    /// 主色渐变。只用在"最该按的那一个"按钮和主卡边缘，别铺满整页
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accentLight], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func glucoseTint(_ mgdl: Double?) -> Color {
        guard let mgdl else { return .secondary }
        if mgdl < 70 { return danger }
        if mgdl > 180 { return warn }
        return accent
    }

    // MARK: 尺寸

    static let radiusCard: CGFloat = 26
    static let radiusInner: CGFloat = 18
    static let gap: CGFloat = 16
    static let pagePadding: CGFloat = 18
}

// MARK: - 页面背景

/// 页面底色：分组灰 + 顶部一层极淡的主色光。
/// 不加噪点、不加网格——医疗读数页上任何纹理都在跟数字抢注意力。
struct PageBackground: View {
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
            RadialGradient(colors: [DS.accent.opacity(0.10), .clear],
                           center: .init(x: 0.5, y: -0.05),
                           startRadius: 0,
                           endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// 给任意 scroll/form 页面套统一底色
    func pageBackground() -> some View {
        self.background(PageBackground())
    }
}

// MARK: - 卡片

/// 主卡片容器：可选标题行 + 内容。
struct Card<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    var tint: Color? = nil
    var padding: CGFloat = 20
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay {
                    if let tint {
                        RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                            .fill(LinearGradient(colors: [tint.opacity(0.13), tint.opacity(0.015)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.045), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.045), radius: 14, y: 6)
    }
}

// MARK: - 小标题

/// 区块小标题：全大写、宽字距、灰色。
/// 它比内容轻两档，所以扫页面时不会和数值打架。
struct SectionTitle: View {
    let text: String
    var icon: String?

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
            }
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .tracking(1.4)
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .padding(.horizontal, 6)
        .padding(.top, 10)
    }
}

// MARK: - 图标徽标

/// 设置列表用的图标块：浅色底 + 同色图标，比调色盘式的实心块克制。
struct IconBadge: View {
    let systemName: String
    var tint: Color = DS.accent
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
    }
}

// MARK: - 设置行

/// 列表行。状态文字限宽、可换行两行，长状态（比如"开 · 真发"）不会被挤成省略号。
struct SettingRow: View {
    let icon: String
    var tint: Color = DS.accent
    let title: String
    var subtitle: String?
    var status: String?
    var statusTint: Color = .secondary
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: 13) {
            IconBadge(systemName: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .medium))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let status {
                Text(status)
                    .font(.system(size: 13))
                    .foregroundStyle(statusTint)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// 卡片内部的行分隔线：比 Divider 淡，且左右缩进对齐文字而不是对齐图标
struct RowRule: View {
    var leading: CGFloat = 47
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.05))
            .frame(height: 0.8)
            .padding(.leading, leading)
    }
}

// MARK: - 指标

/// 指标块：标题小、数值大、脚注更小。三层字号差保证一眼能读出主值。
struct MetricTile: View {
    let title: String
    let value: String
    var note: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 药丸 / 标签

struct Pill: View {
    let text: String
    var tint: Color = DS.accent
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(filled ? Color.white : tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.13)))
            }
    }
}

// MARK: - 按钮

/// 主按钮：整行、52 高、渐变底。一页只允许出现一个。
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var tint: Color?
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
                }
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background {
                RoundedRectangle(cornerRadius: DS.radiusInner, style: .continuous)
                    .fill(disabled ? AnyShapeStyle(Color.gray.opacity(0.35))
                                   : (tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(DS.accentGradient)))
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// 次按钮：描边胶囊，语气压低
struct GhostButton: View {
    let title: String
    var systemImage: String?
    var tint: Color = DS.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 13)) }
                Text(title).font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(0.10))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 快捷入口（首页用）

/// 首页快捷入口：图标在上、标题居中、脚注说明状态。
/// 高度统一，三个并排时视觉重心一致。
struct QuickAction: View {
    let title: String
    let systemImage: String
    var caption: String?
    var tint: Color = DS.accent
    var emphasized: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(emphasized ? Color.white : tint)
                .frame(width: 38, height: 38)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(emphasized ? AnyShapeStyle(Color.white.opacity(0.18)) : AnyShapeStyle(tint.opacity(0.12)))
                }
            VStack(spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(emphasized ? Color.white : Color.primary)
                if let caption {
                    Text(caption).font(.system(size: 10))
                        .foregroundStyle(emphasized ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: DS.radiusInner, style: .continuous)
                .fill(emphasized ? AnyShapeStyle(DS.accentGradient)
                                 : AnyShapeStyle(Color(.secondarySystemGroupedBackground)))
        }
        .overlay {
            if !emphasized {
                RoundedRectangle(cornerRadius: DS.radiusInner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.045), lineWidth: 0.8)
            }
        }
    }
}
