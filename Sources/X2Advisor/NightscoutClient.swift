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
/// Nightscout 的两种认证方式。
///
/// - `secret`：网址 + 密码（就是 NS 后台那个 API Secret）。密码原文不上网，
///   客户端先算 `sha1(密码)` 放进 `api-secret` 头——这是 NS 的约定，
///   不是我们额外发明的。
/// - `token`：NS 后台生成的访问令牌，走 `?token=`。留着是给已经建过只读令牌的人，
///   默认不用。
public enum NightscoutAuthMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case secret
    case token

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .secret: return "密码（API Secret）"
        case .token: return "访问令牌（token）"
        }
    }
}

public struct NightscoutConfig: Codable, Equatable, Sendable {
    /// 站点根地址，例如 `https://ns.example.com` 或 `https://ns.example.com/ns`
    public var baseURL: String
    public var authMode: NightscoutAuthMode
    /// NS 后台的 API Secret（密码原文，本地保存）
    public var secret: String
    /// 可选的访问令牌
    public var token: String
    /// 是否启用。关掉时完全不请求网络
    public var enabled: Bool

    public init(baseURL: String = "",
                authMode: NightscoutAuthMode = .secret,
                secret: String = "",
                token: String = "",
                enabled: Bool = false) {
        self.baseURL = baseURL
        self.authMode = authMode
        self.secret = secret
        self.token = token
        self.enabled = enabled
    }

    /// 旧版只存了 baseURL / token / enabled，读老配置时不能让缺字段直接解码失败
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        authMode = try c.decodeIfPresent(NightscoutAuthMode.self, forKey: .authMode) ?? .secret
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? ""
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
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

    public var trimmedSecret: String { secret.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

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

/// 一条 NS treatment（注射 / 碳水 / 临时基础率……）。
///
/// NS 的 treatments 是个混杂集合：bolus、carbs、temp basal、profile switch 都在这里。
/// 只把「胰岛素」和「碳水」当事件展示，其余类型保留但界面不画——
/// 比如 Temp Basal 在 t:slim X2 上根本写不进去，显示它只会让人误以为泵在改基础率。
public struct NightscoutTreatment: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let eventType: String
    public let insulin: Double?
    public let carbs: Double?
    public let glucose: Double?
    public let dateMs: Int
    public let notes: String?
    public let enteredBy: String?

    public init(id: String,
                eventType: String,
                insulin: Double? = nil,
                carbs: Double? = nil,
                glucose: Double? = nil,
                dateMs: Int,
                notes: String? = nil,
                enteredBy: String? = nil) {
        self.id = id
        self.eventType = eventType
        self.insulin = insulin
        self.carbs = carbs
        self.glucose = glucose
        self.dateMs = dateMs
        self.notes = notes
        self.enteredBy = enteredBy
    }

    public var date: Date { Date(timeIntervalSince1970: Double(dateMs) / 1000) }
    public var insulinUnits: Double { insulin ?? 0 }
    public var carbGrams: Double { carbs ?? 0 }
    public var isInsulin: Bool { insulinUnits > 0 }
    public var isCarbs: Bool { carbGrams > 0 }
    /// 泵里写不进去的类型，界面不当作"输注记录"
    public var isIgnoredType: Bool {
        ["Temp Basal", "Temp Target", "Profile Switch", "Announcement", "Note", "DAD Strike"].contains(eventType)
    }
}

public enum NightscoutError: Error, Equatable, LocalizedError {
    case badBaseURL
    case emptyPayload
    case badPayload
    case unauthorized

    public var errorDescription: String? {
        switch self {
        case .badBaseURL: return "Nightscout 地址不正确（要带 https:// 和主机名）"
        case .emptyPayload: return "Nightscout 没有返回血糖记录"
        case .badPayload: return "Nightscout 返回的数据解析失败"
        case .unauthorized: return "密码不对（Nightscout 拒绝了：401）。确认后台的 API Secret，注意大小写和末尾空格"
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
        guard let url = Self.entriesURL(base: config.normalizedBase,
                                      token: config.authMode == .token ? config.trimmedToken : nil,
                                      count: count) else {
            throw NightscoutError.badBaseURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        // NS 常见部署在反代后面，缓存会让「最新血糖」变成十分钟前那条
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if config.authMode == .secret {
            // 密码原文不发出去，发的是 sha1(密码) 的十六进制
            let secret = config.trimmedSecret
            if !secret.isEmpty {
                request.setValue(SHA1.hex(secret), forHTTPHeaderField: "api-secret")
            }
        }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw NightscoutError.unauthorized
            }
            throw NightscoutError.badPayload
        }
        return try Self.parseEntries(data)
    }

    /// 拉最近的治疗记录
    public func treatments(count: Int = 48) async throws -> [NightscoutTreatment] {
        guard let url = Self.treatmentsURL(base: config.normalizedBase,
                                           token: config.authMode == .token ? config.trimmedToken : nil,
                                           count: count) else {
            throw NightscoutError.badBaseURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if config.authMode == .secret {
            let secret = config.trimmedSecret
            if !secret.isEmpty {
                request.setValue(SHA1.hex(secret), forHTTPHeaderField: "api-secret")
            }
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw (http.statusCode == 401 || http.statusCode == 403)
                ? NightscoutError.unauthorized
                : NightscoutError.badPayload
        }
        return try Self.parseTreatments(data)
    }

    /// 治疗记录的 URL（`/api/v1/treatments.json`）
    public static func treatmentsURL(base: String, token: String?, count: Int) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty,
              let baseURL = URL(string: trimmed),
              baseURL.host != nil,
              var comps = URLComponents(url: baseURL.appendingPathComponent("api/v1/treatments.json"),
                                        resolvingAgainstBaseURL: false)
        else { return nil }
        var items = [URLQueryItem(name: "count", value: String(max(1, count)))]
        if let token, !token.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: "token", value: token.trimmingCharacters(in: .whitespaces)))
        }
        comps.queryItems = items
        return comps.url
    }

    /// 解析治疗记录。空数组是**合法结果**（用户可能从没手动记过碳水），
    /// 所以这里和血糖不同：不抛 emptyPayload，返回空列表。
    public static func parseTreatments(_ data: Data) throws -> [NightscoutTreatment] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NightscoutError.badPayload
        }
        let list: [NightscoutTreatment] = raw.compactMap { obj in
            let ms: Int
            if let d = (obj["date"] as? NSNumber)?.intValue {
                ms = d
            } else if let cs = obj["created_at"] as? String, let parsed = parseISO8601(cs) {
                ms = Int(parsed.timeIntervalSince1970 * 1000)
            } else {
                return nil
            }
            let id = (obj["_id"] as? String) ?? "\(ms)-\(obj["eventType"] as? String ?? "?")"
            let eventType = (obj["eventType"] as? String) ?? "Bolus"
            let insulin = (obj["insulin"] as? NSNumber)?.doubleValue
            let carbs = (obj["carbs"] as? NSNumber)?.doubleValue
            let glucose = (obj["glucose"] as? NSNumber)?.doubleValue
            guard (insulin ?? 0) > 0 || (carbs ?? 0) > 0 || glucose != nil else { return nil }
            return NightscoutTreatment(id: id,
                                       eventType: eventType,
                                       insulin: insulin,
                                       carbs: carbs,
                                       glucose: glucose,
                                       dateMs: ms,
                                       notes: obj["notes"] as? String,
                                       enteredBy: obj["enteredBy"] as? String)
        }
        return list.sorted { $0.dateMs < $1.dateMs }
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
        var items = [URLQueryItem(name: "count", value: String(max(1, count)))]
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
            } else if let ds = obj["dateString"] as? String, let parsed = Self.parseISO8601(ds) {
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

    /// Nightscout 的 `dateString` 是 `2024-10-27T04:10:00.000Z`——**带毫秒**。
    /// 默认的 `ISO8601DateFormatter` 不认小数秒，直接解析会得到 nil，
    /// 于是整条记录被当成坏数据丢掉。先试带毫秒的，再退回不带毫秒的。
    static func parseISO8601(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: text) { return d }
        return ISO8601DateFormatter().date(from: text)
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
