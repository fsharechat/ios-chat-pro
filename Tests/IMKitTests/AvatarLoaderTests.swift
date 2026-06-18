import XCTest
@testable import IMKit

final class AvatarLoaderTests: XCTestCase {
    private var loader: AvatarLoader!
    private var requestCount: Int!

    override func setUp() {
        super.setUp()
        requestCount = 0
        loader = AvatarLoader(session: MockURLProtocol.makeSession())
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
}
