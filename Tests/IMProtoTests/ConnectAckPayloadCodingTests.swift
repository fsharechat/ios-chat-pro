import XCTest
@testable import IMProto

final class ConnectAckPayloadCodingTests: XCTestCase {
    func test_roundTripBinarySerialization() throws {
        var payload = Im_ConnectAckPayload()
        payload.msgHead = 1001
        payload.friendHead = 5
        payload.friendRqHead = 2
        payload.settingHead = 9
        payload.serverTime = 1_750_000_000

        let bytes = try payload.serializedData()
        let decoded = try Im_ConnectAckPayload(serializedBytes: bytes)

        XCTAssertEqual(decoded.msgHead, 1001)
        XCTAssertEqual(decoded.friendHead, 5)
        XCTAssertEqual(decoded.friendRqHead, 2)
        XCTAssertEqual(decoded.settingHead, 9)
        XCTAssertEqual(decoded.serverTime, 1_750_000_000)
    }

    func test_optionalFieldsDefaultToZeroWhenAbsent() throws {
        var payload = Im_ConnectAckPayload()
        payload.msgHead = 1

        let bytes = try payload.serializedData()
        let decoded = try Im_ConnectAckPayload(serializedBytes: bytes)

        XCTAssertEqual(decoded.msgHead, 1)
        XCTAssertEqual(decoded.friendHead, 0)
        XCTAssertFalse(decoded.hasNodeAddr)
    }
}
