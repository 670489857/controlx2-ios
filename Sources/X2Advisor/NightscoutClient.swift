import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Nightscout 血糖接入。
///
/// # 为什么要做这个
///
/// 泵自带的 CGM（Dexcom 直连泵）只给泵自己用；很多人真正维护的 CGM 数据在 Nightscout
/// 里——或者泵这条链路暂时没接传感器。把 NS 当成一个可选的血糖来源，比"只能等泵给数"现实。
///
/// # 只做读
///
/// 只调 `GET /api/v1/entries/sgv.json`。不写、不发 treatment、不碰 NS 的 IOB 计算。
/// 原因是这套 App 的胰岛素参数、闸门、台账全在本机，和 NS 的循环互不同步，
/// 两边都写会变成两个事实来源。
///
/// # 认证
///
/// 走 `?token=` 的只读 token（Nightscout 的 read-only token），不要求用户去算 SHA1。
/// 支持在 base URL 里带路径前缀（很多人把 NS 挂在 `https://xxx/ns/` 下）。
public struct NightscoutConfig: Codable, Equatable, Sendable {
    /// 站点根地址，例如 `https://ns.example.com` 或 `https://ns.example.com/ns`
    public var baseURL: String
    /// 只读访问 token。留空表示站点不需要认证（不建议）
    public var token: String
    /// 是否启用。关掉时完全不请求网络
    public var enabled: Bool

    public init(baseURL: String = "", token: String = "", enabled: Bool = false) {
        self.baseURL = baseURL
        self.token = token
        self.enabled = enabled
    }

    /// 用户可能把整条 API 地址粘进来，这里统一裁到站点根
    public var normalizedBase: String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        for suffix in ["/api/v1/entries/sgv.json", "/api/v1/entries.json", "/api/v1"] where s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    public var isConfigured: Bool {
        guard let url = URL(string: normalizedBase) else { return false }
        return (url.scheme == "https" || url.scheme == "http") && url.host != nil
    }
}

/// 一条 SGV（传感器血糖）记录
public struct NightscoutEntry: Equatable, Sendable, Codable {
    public let sgv: Int
    /// NS 的时间戳，毫秒
    public let dateMs: Int
    /// 趋势字符串，例如 `FortyFiveUp`
    public let direction: String?

    public init(sgv: Int, dateMs: Int, direction: String?) {
        self.sgv = sgv
        self.dateMs = dateMs
        self.direction = direction
    }

    public var date: Date { Date(timeIntervalSince1970: Double(dateMs) / 1000) }

    /// 换算成泵的趋势码，界面和预测用的是同一套（1/2 双上、3 四十五上、4 平、5 四十五下、6/7 双下）
    public var trendCode: Int? { NightscoutClient.trendCode(for: direction) }
}

public enum NightscoutError: Error, Equatable, LocalizedError {
    case badBaseURL
    case emptyPayload
    case badPayload

    public var errorDescription: String? {
        switch self {
        case .badBaseURL: return "Nightscout 地址不正确（要带 https:// 和主机名）"
        case .emptyPayload: return "Nightscout 没有返回血糖记录"
        case .badPayload: return "Nightscout 返回的数据解析失败"
        }
    }
}

public struct NightscoutClient: Sendable {
    public let config: NightscoutConfig
    private let session: URLSession

    public init(config: NightscoutConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// 拉最近 N 条记录（5 分钟一条，24 条 ≈ 2 小时）
    public func entries(count: Int = 24) async throws -> [NightscoutEntry] {
        guard let url = Self.entriesURL(base: config.normalizedBase, token: config.token, count: count) else {
            throw NightscoutError.badBaseURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        // NS 常见部署在反代后面，缓存会让「最新血糖」变成十分钟前那条
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NightscoutError.badPayload
        }
        return try Self.parseEntries(data)
    }

    /// 拼 URL。抽成静态函数是为了能在不联网的情况下测：地址拼错是这里最常见的故障。
    public static func entriesURL(base: String, token: String?, count: Int) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty,
              let baseURL = URL(string: trimmed),
              baseURL.host != nil
        else { return nil }

        guard var comps = URLComponents(url: baseURL.appendingPathComponent("api/v1/entries/sgv.json"),
                                        resolvingAgainstBaseURL: false)
        else { return nil }
        var items = [URLQueryItem(name: "count", value: String(max(1, count))]
        if let token, !token.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: "token", value: token.trimmingCharacters(in: .whitespaces)))
        }
        comps.queryItems = items
        return comps.url
    }

    /// 解析 SGV JSON 数组。NS 的字段类型不总是稳定的（`direction` 可能是字符串也可能缺失），
    /// 所以这里用宽松解码：单条坏了跳过，不整体失败——一条坏记录不该让整屏血糖消失。
    public static func parseEntries(_ data: Data) throws -> [NightscoutEntry] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NightscoutError.badPayload
        }
        let entries: [NightscoutEntry] = raw.compactMap { obj in
            guard let sgv = (obj["sgv"] as? NSNumber)?.intValue, sgv > 0 else { return nil }
            let ms: Int
            if let d = (obj["date"] as? NSNumber)?.intValue {
                ms = d
            } else if let ds = obj["dateString"] as? String, let parsed = ISO8601DateFormatter().date(from: ds) {
                ms = Int(parsed.timeIntervalSince1970 * 1000)
            } else {
                return nil
            }
            let direction = obj["direction"] as? String
            return NightscoutEntry(sgv: sgv, dateMs: ms, direction: direction)
        }
        guard !entries.isEmpty else { throw NightscoutError.emptyPayload }
        return entries.sorted { $0.dateMs < $1.dateMs }
    }

    /// NS 的 8 档方向 → 泵的 7 个趋势码
    public static func trendCode(for direction: String?) -> Int? {
        switch direction?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "doubleup": return 2
        case "singleup": return 1
        case "fortyfiveup": return 3
        case "flat": return 4
        case "fortyfivedown": return 5
        case "singledown": return 6
        case "double down", "doubledown": return 7
        default: return nil
        }
    }
}
