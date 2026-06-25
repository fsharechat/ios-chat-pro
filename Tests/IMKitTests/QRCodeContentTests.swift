import XCTest
@testable import IMKit

final class QRCodeContentTests: XCTestCase {
    func test_userQRCodeString_usesWildfirechatUserPrefix() {
        XCTAssertEqual(QRCodeContent.userQRCodeString(uid: "u1"), "wildfirechat://user/u1")
    }
}
