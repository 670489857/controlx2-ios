import XCTest
@testable import X2Advisor

/// Nightscout 接入的纯逻辑测试：地址拼装、解析、趋势映射。
/// 不联网——网络失败是环境问题，地址拼错和字段解析错是代码问题，两者必须能分开看。
final class NightscoutClientTests: XCTestCase {

    func testEntriesURLBasic() throws {
        let url = try XCTUnwrap(NightscoutClient.entriesURL(base: "https://ns.example.com", token: nil, count: 24))
        XCTAssertEqual(url.host, "ns.example.com")
        XCTAssertEqual(url.path, "/api/v1/entries/sgv.json")
        XCTAssertEqual(url.query, "count=24")
    }

    func testEntriesURLKeepsPathPrefixAndTrimsSlash() throws {
        let url = try XCTUnwrap(NightscoutClient.entriesURL(base: "https://ns.example.com/ns/", token: nil, count: 24))
        XCTAssertEqual(url.path, "/ns/api/v1/entries/sgv.json")
    }

    func testEntriesURLAddsToken() throws {
        let url = try XCTUnwrap(NightscoutClient.entriesURL(base: "https://ns.example.com", token: "abc123", count: 12))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let token = comps.queryItems?.first { $0.name == "token" }?.value
        XCTAssertEqual(token, "abc123")
    }

    func testEntriesURLRejectsGarbage() {
        XCTAssertNil(NightscoutClient.entriesURL(base: "", token: nil, count: 24))
        XCTAssertNil(NightscoutClient.entriesURL(base: "不是地址", token: nil, count: 24))
    }

    /// 用户常把整条 API 地址粘进来，必须还原成站点根
    func testNormalizedBaseStripsEntryPath() {
        var c = NightscoutConfig()
        c.baseURL = "https://ns.example.com/api/v1/entries/sgv.json"
        XCTAssertEqual(c.normalizedBase, "https://ns.example.com")
        XCTAssertTrue(c.isConfigured)

        c.baseURL = "https://ns.example.com/ns/api/v1/"
        XCTAssertEqual(c.normalizedBase, "https://ns.example.com/ns")
    }

    func testConfigRejectsMissingScheme() {
        var c = NightscoutConfig()
        c.baseURL = "ns.example.com"
        // URL(string:) 认为这合法但 host 为空，属于典型填错
        XCTAssertFalse(c.isConfigured)
    }

    func testParseTypicalPayload() throws {
        let json = """
        [
          {"_id":"a","sgv":180,"date":1730000000000,"direction":"FortyFiveUp","type":"sgv"},
          {"_id":"b","sgv":150,"date":1730000300000,"direction":"Flat","type":"sgv"},
          {"_id":"c","sgv":120,"date":1730000600000,"direction":"SingleDown","type":"sgv"}
        ]
        """
        let entries = try NightscoutClient.parseEntries(Data(json.utf8))
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first?.sgv, 180)
        XCTAssertEqual(entries.last?.sgv, 120, "按时间升序排，最后一条是最新的")
        XCTAssertEqual(entries.last?.trendCode, 6)
        let lastDate = try XCTUnwrap(entries.last?.date.timeIntervalSince1970)
        XCTAssertEqual(lastDate, 1730000600, accuracy: 1)
    }

    func testParseSkipsBadRecords() throws {
        let json = """
        [
          {"sgv":180,"date":1730000000000},
          {"sgv":null,"date":1730000300000},
          {"date":1730000600000},
          {"sgv":150,"dateString":"2024-10-27T04:10:00.000Z"}
        ]
        """
        let entries = try NightscoutClient.parseEntries(Data(json.utf8))
        XCTAssertEqual(entries.count, 2, "缺 sgv / 缺时间的那两条跳过，不整体失败")
    }

    func testParseEmptyThrows() {
        XCTAssertThrowsError(try NightscoutClient.parseEntries(Data("[]".utf8))) { error in
            XCTAssertEqual(error as? NightscoutError, .emptyPayload)
        }
    }

    func testParseNotJSONThrows() {
        XCTAssertThrowsError(try NightscoutClient.parseEntries(Data("<html>".utf8))) { error in
            XCTAssertEqual(error as? NightscoutError, .badPayload)
        }
    }

    func testTrendMappingCoversAllEightDirections() {
        XCTAssertEqual(NightscoutClient.trendCode(for: "DoubleUp"), 2)
        XCTAssertEqual(NightscoutClient.trendCode(for: "SingleUp"), 1)
        XCTAssertEqual(NightscoutClient.trendCode(for: "FortyFiveUp"), 3)
        XCTAssertEqual(NightscoutClient.trendCode(for: "Flat"), 4)
        XCTAssertEqual(NightscoutClient.trendCode(for: "FortyFiveDown"), 5)
        XCTAssertEqual(NightscoutClient.trendCode(for: "SingleDown"), 6)
        XCTAssertEqual(NightscoutClient.trendCode(for: "DoubleDown"), 7)
        XCTAssertNil(NightscoutClient.trendCode(for: "NOT COMPUTED"))
        XCTAssertNil(NightscoutClient.trendCode(for: nil))
    }

    // MARK: 密码（API Secret）模式

    /// NS 的标准向量：sha1("abc")
    func testSHA1KnownVectors() {
        XCTAssertEqual(SHA1.hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(SHA1.hex(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(SHA1.hex("MyV3ry53cr37"), SHA1.hex("MyV3ry53cr37"),
                       "同一个密码算两次必须一样")
        XCTAssertNotEqual(SHA1.hex("MyV3ry53cr37"), SHA1.hex("myv3ry53cr37"),
                          "API Secret 区分大小写，哈希也必须区分")
        // 长度跨 64 字节分组边界的情形
        let long = String(repeating: "a", count: 1000)
        XCTAssertEqual(SHA1.hex(long).count, 40)
    }

    func testSecretModeDoesNotPutPasswordInURL() throws {
        let cfg = NightscoutConfig(baseURL: "https://ns.example.com", authMode: .secret,
                                   secret: "MyV3ry53cr37", enabled: true)
        let url = try XCTUnwrap(NightscoutClient.entriesURL(base: cfg.normalizedBase, token: nil, count: 24))
        XCTAssertFalse(url.absoluteString.contains("MyV3ry53cr37"), "密码原文不应该出现在 URL 里")
        XCTAssertEqual(SHA1.hex(cfg.trimmedSecret).count, 40)
    }

    func testTokenModeStillUsesQueryToken() throws {
        let cfg = NightscoutConfig(baseURL: "https://ns.example.com", authMode: .token,
                                   token: "abc123", enabled: true)
        let url = try XCTUnwrap(NightscoutClient.entriesURL(base: cfg.normalizedBase, token: cfg.trimmedToken, count: 24))
        XCTAssertTrue(url.absoluteString.contains("token=abc123"))
    }

    func testSecretTrimsWhitespace() {
        let cfg = NightscoutConfig(baseURL: "https://ns.example.com", secret: "  MyV3ry53cr37\n")
        XCTAssertEqual(cfg.trimmedSecret, "MyV3ry53cr37", "从 NS 后台复制常带空格/换行，必须裁掉")
    }

    func testOldConfigDecodesWithDefaults() throws {
        // 0.4.1 之前只存了 baseURL / token / enabled
        let json = #"{"baseURL":"https://ns.example.com","token":"old","enabled":true}"#
        let cfg = try JSONDecoder().decode(NightscoutConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.baseURL, "https://ns.example.com")
        XCTAssertEqual(cfg.authMode, .secret)
        XCTAssertEqual(cfg.token, "old")
        XCTAssertTrue(cfg.enabled)
    }

    // MARK: 治疗记录（NS 里的注射 / 碳水）

    func testTreatmentsURLPointsToTreatmentsJSON() throws {
        let url = try XCTUnwrap(NightscoutClient.treatmentsURL(base: "https://ns.example.com", token: nil, count: 48))
        XCTAssertEqual(url.path, "/api/v1/treatments.json")
        XCTAssertEqual(url.query, "count=48")
    }

    func testParseTreatmentsKeepsInsulinAndCarbs() throws {
        let json = """
        [
          {"_id":"t1","eventType":"Bolus","insulin":2.45,"created_at":"2026-11-17T05:10:00.000Z"},
          {"_id":"t2","eventType":"Carbs","carbs":15,"created_at":"2026-11-17T05:20:00.000Z"},
          {"_id":"t3","eventType":"Bolus","insulin":1.65,"date":1730000000000},
          {"_id":"t4","eventType":"Temp Basal","absolute":0.5,"created_at":"2026-11-17T05:30:00.000Z"}
        ]
        """
        let list = try NightscoutClient.parseTreatments(Data(json.utf8))
        XCTAssertEqual(list.count, 3, "Temp Basal 没有胰岛素/碳水/血糖数值，直接跳过")
        XCTAssertEqual(list.last?.eventType, "Carbs")
        XCTAssertEqual(list.map { $0.eventType }, ["Bolus", "Bolus", "Carbs"], "按时间升序")
        let insulin = list.filter { $0.isInsulin }.map { $0.insulinUnits }
        XCTAssertEqual(insulin, [1.65, 2.45], "按时间升序")
        XCTAssertEqual(list.filter { $0.isCarbs }.map { $0.carbGrams }, [15])
    }

    func testParseTreatmentsEmptyIsValid() throws {
        let list = try NightscoutClient.parseTreatments(Data("[]".utf8))
        XCTAssertTrue(list.isEmpty, "从没记过碳水也必须算成功，不能报错")
    }

    func testParseTreatmentsSkipsRowsWithoutAmountOrTime() throws {
        let json = """
        [
          {"_id":"a","eventType":"Bolus","created_at":"2026-11-17T05:10:00.000Z"},
          {"_id":"b","eventType":"Bolus","insulin":1.0}
        ]
        """
        let list = try NightscoutClient.parseTreatments(Data(json.utf8))
        XCTAssertTrue(list.isEmpty)
    }
}
