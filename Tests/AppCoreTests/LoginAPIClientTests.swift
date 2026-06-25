import XCTest
@testable import AppCore

final class LoginAPIClientTests: XCTestCase {
    private var client: LoginAPIClient!

    override func setUp() {
        super.setUp()
        client = LoginAPIClient(baseURL: URL(string: "https://example.com")!, session: MockURLProtocol.makeSession())
    }

    private func respond(code: Int, message: String = "success", resultJSON: String? = nil) {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let resultField = resultJSON.map { ",\"result\":\($0)" } ?? ""
            let body = Data(#"{"code":\#(code),"message":"\#(message)"\#(resultField)}"#.utf8)
            return (response, body)
        }
    }

    func test_requestCode_postsToSendCodeWithMobileParam() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"code":0,"message":"success","result":true}"#.utf8))
        }

        try await client.requestCode(mobile: "13800000000")

        XCTAssertEqual(capturedRequest?.url?.path, "/send_code")
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(MockURLProtocol.capturedBody(of: capturedRequest!))
        let params = try JSONDecoder().decode([String: String].self, from: Data(body.utf8))
        XCTAssertEqual(params, ["mobile": "13800000000"])
    }

    func test_requestCode_nonZeroCode_throwsServerError() async {
        respond(code: 1, message: "invalid mobile")

        do {
            try await client.requestCode(mobile: "bad")
            XCTFail("expected a throw")
        } catch LoginAPIError.server(let code, let message) {
            XCTAssertEqual(code, 1)
            XCTAssertEqual(message, "invalid mobile")
        } catch {
            XCTFail("expected .server, got \(error)")
        }
    }

    func test_login_postsMobileCodeAndClientId() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"code":0,"message":"success","result":{"userId":"u1","token":"t1","register":false}}"#.utf8))
        }

        _ = try await client.login(mobile: "13800000000", code: "1234", clientId: "device-1")

        XCTAssertEqual(capturedRequest?.url?.path, "/login")
        let body = try XCTUnwrap(MockURLProtocol.capturedBody(of: capturedRequest!))
        let params = try JSONDecoder().decode([String: String].self, from: Data(body.utf8))
        XCTAssertEqual(params, ["mobile": "13800000000", "code": "1234", "clientId": "device-1"])
    }

    func test_login_decodesResultIntoLoginResult() async throws {
        respond(code: 0, resultJSON: #"{"userId":"u1","token":"t1","register":true}"#)

        let result = try await client.login(mobile: "13800000000", code: "1234", clientId: "device-1")

        XCTAssertEqual(result.userId, "u1")
        XCTAssertEqual(result.token, "t1")
        XCTAssertTrue(result.isNewRegistration)
    }

    func test_login_incorrectCode_throwsServerErrorWithoutCrashingOnMissingResult() async {
        // Real server behavior: error responses may omit `result` entirely
        // rather than sending `null`.
        respond(code: 6, message: "incorrect code")

        do {
            _ = try await client.login(mobile: "13800000000", code: "0000", clientId: "device-1")
            XCTFail("expected a throw")
        } catch LoginAPIError.server(let code, _) {
            XCTAssertEqual(code, 6)
        } catch {
            XCTFail("expected .server, got \(error)")
        }
    }
}
