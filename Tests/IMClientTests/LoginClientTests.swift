import XCTest
@testable import IMClient

private final class FakeHTTPRequester: HTTPRequesting {
    var lastRequest: URLRequest?
    var responseData: Data = Data()
    var responseStatusCode: Int = 200

    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: responseStatusCode, httpVersion: nil, headerFields: nil)!
        return (responseData, response)
    }
}

final class LoginClientTests: XCTestCase {
    private var requester: FakeHTTPRequester!
    private var client: LoginClient!

    override func setUp() {
        super.setUp()
        requester = FakeHTTPRequester()
        client = LoginClient(baseURL: URL(string: "https://backend-http.fsharechat.cn/")!, requester: requester)
    }

    func test_sendCode_postsMobileAndSucceedsOnCodeZero() async throws {
        requester.responseData = Data(#"{"code":0,"message":"success","result":true}"#.utf8)

        try await client.sendCode(mobile: "13800000000")

        let body = try XCTUnwrap(requester.lastRequest?.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["mobile"] as? String, "13800000000")
        XCTAssertEqual(requester.lastRequest?.url?.absoluteString, "https://backend-http.fsharechat.cn/send_code")
        XCTAssertEqual(requester.lastRequest?.httpMethod, "POST")
    }

    func test_login_postsMobileCodeClientId_andDecodesResult() async throws {
        requester.responseData = Data(#"{"code":0,"message":"success","result":{"userId":"u1","token":"tok==","register":false}}"#.utf8)

        let result = try await client.login(mobile: "13800000000", code: "556677", clientId: "device-1")

        let body = try XCTUnwrap(requester.lastRequest?.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["mobile"] as? String, "13800000000")
        XCTAssertEqual(json?["code"] as? String, "556677")
        XCTAssertEqual(json?["clientId"] as? String, "device-1")
        XCTAssertEqual(requester.lastRequest?.url?.absoluteString, "https://backend-http.fsharechat.cn/login")

        XCTAssertEqual(result.userId, "u1")
        XCTAssertEqual(result.token, "tok==")
        XCTAssertEqual(result.register, false)
    }

    func test_login_nonZeroCode_throwsServerError() async {
        requester.responseData = Data(#"{"code":6,"message":"验证码错误","result":null}"#.utf8)

        await XCTAssertThrowsErrorAsync(try await client.login(mobile: "13800000000", code: "000000", clientId: "device-1")) { error in
            XCTAssertEqual(error as? LoginClientError, .server(code: 6, message: "验证码错误"))
        }
    }
}

/// XCTest has no built-in async `XCTAssertThrowsError` — this is the
/// standard small shim used throughout this codebase's async tests.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (_ error: Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
