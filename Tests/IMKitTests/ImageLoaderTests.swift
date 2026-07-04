import XCTest
@testable import IMKit

final class ImageLoaderTests: XCTestCase {
    private var loader: ImageLoader!
    private var requestCount: Int!
    private var diskDirectory: URL!

    override func setUp() {
        super.setUp()
        requestCount = 0
        diskDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageLoaderTests-\(UUID().uuidString)", isDirectory: true)
        loader = ImageLoader(session: MockURLProtocol.makeSession(), diskDirectory: diskDirectory)
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

    func test_loadImageData_onSuccess_returnsTheBody() async {
        respond(statusCode: 200, data: Data([0x01, 0x02, 0x03]))

        let data = await loader.loadImageData(from: "https://example.com/a.jpg")

        XCTAssertEqual(data, Data([0x01, 0x02, 0x03]))
    }

    func test_loadImageData_onNon200Status_returnsNilAndDoesNotCache() async {
        respond(statusCode: 404, data: Data())

        let first = await loader.loadImageData(from: "https://example.com/missing.jpg")
        let second = await loader.loadImageData(from: "https://example.com/missing.jpg")

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(requestCount, 2) // 失败不落缓存，第二次仍走网络
    }

    func test_loadImageData_withInvalidURLString_returnsNilWithoutNetworkCall() async {
        let data = await loader.loadImageData(from: "")

        XCTAssertNil(data)
        XCTAssertEqual(requestCount, 0)
    }

    func test_loadImageData_calledTwiceForSameURL_onlyHitsTheNetworkOnce() async {
        respond(statusCode: 200, data: Data([0x01]))

        _ = await loader.loadImageData(from: "https://example.com/a.jpg")
        _ = await loader.loadImageData(from: "https://example.com/a.jpg")

        XCTAssertEqual(requestCount, 1)
    }

    func test_loadImageData_freshLoaderWithSameDiskDirectory_readsFromDiskWithoutNetwork() async {
        respond(statusCode: 200, data: Data([0x0A, 0x0B]))
        _ = await loader.loadImageData(from: "https://example.com/a.jpg")
        XCTAssertEqual(requestCount, 1)

        // 模拟下次启动：新实例、同磁盘目录、无网络应答也能命中
        MockURLProtocol.requestHandler = nil
        let freshLoader = ImageLoader(session: MockURLProtocol.makeSession(), diskDirectory: diskDirectory)

        let data = await freshLoader.loadImageData(from: "https://example.com/a.jpg")

        XCTAssertEqual(data, Data([0x0A, 0x0B]))
        XCTAssertEqual(requestCount, 1)
    }

    func test_cacheFileName_isStableHexAndDiffersPerURL() {
        let a1 = ImageLoader.cacheFileName(for: "https://example.com/a.jpg")
        let a2 = ImageLoader.cacheFileName(for: "https://example.com/a.jpg")
        let b = ImageLoader.cacheFileName(for: "https://example.com/b.jpg")

        XCTAssertEqual(a1, a2)
        XCTAssertNotEqual(a1, b)
        XCTAssertEqual(a1.count, 64) // SHA256 hex
        XCTAssertTrue(a1.allSatisfy { $0.isHexDigit })
    }
}
