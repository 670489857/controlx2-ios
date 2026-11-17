import ActivityKit
import Foundation

/// 锁屏即时动态的数据契约。
///
/// App 和小组件扩展是两个进程，靠这个结构传状态。字段刻意只用字符串：
/// 单位换了（mmol / mg/dL）不需要两套渲染逻辑，格式在 App 侧一次性决定。
struct LoopActivityAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        /// 主数字，例如 "8.8" 或 "158"
        var glucoseText: String
        /// 单位后缀，例如 "mmol/L"
        var glucoseUnit: String
        /// 趋势箭头（SF Symbol 名），空字符串表示没有
        var trendSymbol: String
        /// 活性胰岛素，例如 "1.2 U"
        var iobText: String
        /// "真发针 / 演练 / 已停止"
        var loopText: String
        /// 最近一针的说明，例如 "3 分钟前 0.15 U"
        var lastDoseText: String
        /// 数据来源标签
        var sourceText: String
        var updatedAt: Date
    }

    /// 这次动态是什么时候开始的，用于锁屏上显示"已运行"
    var startedAt: Date
}
