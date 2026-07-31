import XCTest
@testable import AppCore

final class ServerNodeStoreTests: XCTestCase {
    private let nodes = [
        AppConfig.ServerNode(name: "上海节点", host: "sh.example.cn"),
        AppConfig.ServerNode(name: "主节点", host: "main.example.cn"),
        AppConfig.ServerNode(name: "备节点 S2", host: "s2.example.cn"),
    ]
    private var defaults: UserDefaults!
    private var store: ServerNodeStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ServerNodeStoreTests-\(UUID().uuidString)")
        store = ServerNodeStore(defaults: defaults)
    }

    func test_neverPinned_isAutoAndReturnsAllHostsJoined() {
        XCTAssertNil(store.pinnedHost(nodes: nodes))
        XCTAssertEqual(store.currentHostSpec(nodes: nodes), "sh.example.cn:main.example.cn:s2.example.cn")
    }

    func test_pin_returnsThatSingleHostOnly() {
        store.pin("s2.example.cn")

        XCTAssertEqual(store.pinnedHost(nodes: nodes), "s2.example.cn")
        XCTAssertEqual(store.currentHostSpec(nodes: nodes), "s2.example.cn")
    }

    func test_unpin_restoresAutoRoundRobin() {
        store.pin("s2.example.cn")
        store.unpin()

        XCTAssertNil(store.pinnedHost(nodes: nodes))
        XCTAssertEqual(store.currentHostSpec(nodes: nodes), "sh.example.cn:main.example.cn:s2.example.cn")
    }

    func test_pinnedHostNoLongerInNodeTable_degradesToAuto() {
        store.pin("retired.example.cn")

        XCTAssertNil(store.pinnedHost(nodes: nodes))
        XCTAssertEqual(store.currentHostSpec(nodes: nodes), "sh.example.cn:main.example.cn:s2.example.cn")
    }

    func test_pin_persistsAcrossStoreInstances() {
        store.pin("main.example.cn")

        let secondStore = ServerNodeStore(defaults: defaults)
        XCTAssertEqual(secondStore.pinnedHost(nodes: nodes), "main.example.cn")
    }

    func test_productionConfig_imHostsIsDerivedFromNodeTableInOrder() {
        XCTAssertEqual(
            AppConfig.production.imHosts,
            "sh-backend-tcp.fsharechat.cn:backend-tcp.fsharechat.cn:backend-tcp-s2.fsharechat.cn"
        )
        XCTAssertEqual(AppConfig.production.serverNodes.map(\.name), ["上海节点", "主节点", "备节点 S2"])
    }
}
