import XCTest
@testable import IMClient

final class ConnectMessageTests: XCTestCase {
    func test_encodesAllFieldsWithFastjsonCompatibleKeyNames() throws {
        let message = ConnectMessage(userName: "u1", password: "encrypted-pwd", clientIdentifier: "device-123")

        let data = try message.encodedJSONData()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["userName"] as? String, "u1")
        XCTAssertEqual(json?["password"] as? String, "encrypted-pwd")
        XCTAssertEqual(json?["clientIdentifier"] as? String, "device-123")
        XCTAssertEqual(json?["willTopic"] as? String, "")
        XCTAssertEqual(json?["willMessage"] as? String, "")
        XCTAssertEqual(json?.keys.count, 5) // exactly these 5 fields, matching ConnectMessage.java's properties
    }
}
