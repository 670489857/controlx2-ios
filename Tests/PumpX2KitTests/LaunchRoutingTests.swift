import XCTest
@testable import PumpX2Kit

/// 启动落地决策。
///
/// 这一组只钉一件事：**什么情况下该直接进状态页**。判断错了的代价不是崩溃，
/// 而是用户又被扔回那份设备列表手动点一下——正是这次要消掉的那一步。
final class LaunchRoutingTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "controlx2.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testSaveLoadRoundTrip() {
        let store = UserDefaultsLastPumpStore(defaults: defaults)
        XCTAssertNil(store.load())

        let id = UUID()
        store.save(LastPump(id: id, name: "tslim X2 1234"))
        XCTAssertEqual(store.load(), LastPump(id: id, name: "tslim X2 1234"))

        store.clear()
        XCTAssertNil(store.load(), "忘记此泵之后不能再自动连回去")
    }

    /// 名字丢了不该连累连接：UUID 才是能连回去的那个信息。
    func testMissingNameFallsBackButKeepsID() {
        let id = UUID()
        defaults.set(id.uuidString, forKey: "controlx2.lastPumpID")
        let store = UserDefaultsLastPumpStore(defaults: defaults)

        XCTAssertEqual(store.load()?.id, id)
        XCTAssertEqual(store.load()?.name, "泵")
    }

    /// 存的值被外部改坏（迁机、手改备份）时当作没有，而不是崩或连错设备。
    func testCorruptedIdentifierIsTreatedAsAbsent() {
        defaults.set("not-a-uuid", forKey: "controlx2.lastPumpID")
        defaults.set("tslim X2", forKey: "controlx2.lastPumpName")
        XCTAssertNil(UserDefaultsLastPumpStore(defaults: defaults).load())
    }

    func testDestination() {
        let pump = LastPump(id: UUID(), name: "tslim X2")

        XCTAssertEqual(LaunchRouter.destination(lastPump: pump, hasCredentials: true),
                       .dashboard(pump: pump))
        XCTAssertEqual(LaunchRouter.destination(lastPump: nil, hasCredentials: true),
                       .discovery, "有凭据但不知道连哪台，只能扫描")
        XCTAssertEqual(LaunchRouter.destination(lastPump: pump, hasCredentials: false),
                       .discovery, "记得设备但没有凭据，进去也只能停在配对页")
        XCTAssertEqual(LaunchRouter.destination(lastPump: nil, hasCredentials: false),
                       .discovery)
    }
}
