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
        XCTAssertEqual(entries.last?.date.timeIntervalSince1970, 1730000600, accuracy: 1)
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
}
