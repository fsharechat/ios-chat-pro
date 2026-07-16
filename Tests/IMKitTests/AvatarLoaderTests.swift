import XCTest
@testable import IMKit

final class AvatarLoaderTests: XCTestCase {
    private var loader: AvatarLoader!
    private var requestCount: Int!
    private var diskDirectory: URL!

    override func setUp() {
        super.setUp()
        requestCount = 0
        diskDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AvatarLoaderTests-\(UUID().uuidString)", isDirectory: true)
        loader = AvatarLoader(session: MockURLProtocol.makeSession(), diskDirectory: diskDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: diskDirectory)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func respond(statusCode: Int, data: Data) {
        MockURLProtocol.requestHandler = { [weak self] request in
            self?.requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
    }

    func test_loadAvatarData_onSuccess_returnsTheBody() async {
        respond(statusCode: 200, data: Data([0x01, 0x02, 0x03]))

        let data = await loader.loadAvatarData(from: "https://example.com/a.png")

        XCTAssertEqual(data, Data([0x01, 0x02, 0x03]))
    }

    func test_loadAvatarData_onNon200Status_returnsNil() async {
        respond(statusCode: 404, data: Data())

        let data = await loader.loadAvatarData(from: "https://example.com/missing.png")

        XCTAssertNil(data)
    }

    func test_loadAvatarData_withInvalidURLString_returnsNilWithoutNetworkCall() async {
        let data = await loader.loadAvatarData(from: "")

        XCTAssertNil(data)
        XCTAssertEqual(requestCount, 0)
    }

    func test_loadAvatarData_calledTwiceForSameURL_onlyHitsTheNetworkOnce() async {
        respond(statusCode: 200, data: Data([0x01]))

        _ = await loader.loadAvatarData(from: "https://example.com/a.png")
        _ = await loader.loadAvatarData(from: "https://example.com/a.png")

        XCTAssertEqual(requestCount, 1)
    }

    // 模拟冷启动：新实例（内存缓存为空）、同磁盘目录、无网络应答也应命中磁盘缓存
    func test_loadAvatarData_freshLoaderWithSameDiskDirectory_readsFromDiskWithoutNetwork() async {
        respond(statusCode: 200, data: Data([0x0A, 0x0B]))
        _ = await loader.loadAvatarData(from: "https://example.com/a.png")
        XCTAssertEqual(requestCount, 1)

        MockURLProtocol.requestHandler = nil
        let freshLoader = AvatarLoader(session: MockURLProtocol.makeSession(), diskDirectory: diskDirectory)

        let data = await freshLoader.loadAvatarData(from: "https://example.com/a.png")

        XCTAssertEqual(data, Data([0x0A, 0x0B]))
        XCTAssertEqual(requestCount, 1)
    }

    func test_loadAvatarData_onNon200Status_doesNotWriteDiskCache() async {
        respond(statusCode: 404, data: Data())
        _ = await loader.loadAvatarData(from: "https://example.com/missing.png")

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: diskDirectory.path)) ?? []
        XCTAssertTrue(contents.isEmpty)
    }
}
