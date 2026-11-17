import XCTest
@testable import X2Advisor

/// 设定档集合的纯逻辑测试。这里测的不是界面，而是"切档不会丢档、删档不会改运行参数"。
final class LoopPresetTests: XCTestCase {

    private func makeSettings(isf: Double, targetHigh: Double = 130) -> ClosedLoop.Settings {
        var s = ClosedLoop.Settings()
        s.isf = isf
        s.targetHigh = targetHigh
        return s
    }

    func testEncodeDecodeRoundTrip() throws {
        let a = LoopPreset(name: "A", settings: makeSettings(isf: 50))
        let b = LoopPreset(name: "B", settings: makeSettings(isf: 40))
        let data = try XCTUnwrap(LoopPresetLibrary.encode([a, b]))
        let decoded = LoopPresetLibrary.decode(data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(Set(decoded.map(\.name)), ["A", "B"])
        XCTAssertEqual(decoded.first(where: { $0.name == "A" })?.settings.isf, 50)
    }

    func testDecodeGarbageReturnsEmpty() {
        XCTAssertTrue(LoopPresetLibrary.decode(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(LoopPresetLibrary.decode(nil).isEmpty)
    }

    func testApplyReturnsWholeSettings() throws {
        let a = LoopPreset(name: "A", settings: makeSettings(isf: 45))
        let b = LoopPreset(name: "B", settings: makeSettings(isf: 35, targetHigh: 120))
        let settings = try XCTUnwrap(LoopPresetLibrary.apply(presetID: b.id, to: [a, b]))
        XCTAssertEqual(settings.isf, 35)
        XCTAssertEqual(settings.targetHigh, 120, "切档是整组替换，不是只换 ISF")
    }

    func testApplyUnknownIDReturnsNil() {
        XCTAssertNil(LoopPresetLibrary.apply(presetID: UUID(), to: []))
    }

    func testUpsertReplacesSameID() {
        var preset = LoopPreset(name: "A", settings: makeSettings(isf: 50))
        var list = LoopPresetLibrary.upsert(preset, in: [])
        XCTAssertEqual(list.count, 1)

        preset.settings.isf = 60
        list = LoopPresetLibrary.upsert(preset, in: list)
        XCTAssertEqual(list.count, 1, "同 id 是编辑，不该变成两条")
        XCTAssertEqual(list[0].settings.isf, 60)
    }

    func testRemoveOnlyTargetsOnePreset() {
        let a = LoopPreset(name: "A", settings: makeSettings(isf: 50))
        let b = LoopPreset(name: "B", settings: makeSettings(isf: 40))
        let list = LoopPresetLibrary.remove(a.id, from: [a, b])
        XCTAssertEqual(list.map(\.name), ["B"])
    }

    func testDefaultNamesDoNotCollide() {
        let a = LoopPreset(name: "设定档 1", settings: makeSettings(isf: 50))
        let name = LoopPresetLibrary.nextDefaultName(for: [a])
        XCTAssertFalse(["设定档 1"].contains(name))
    }
}
