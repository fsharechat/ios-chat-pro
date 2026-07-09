import XCTest
@testable import IMKit

final class QRCodeContentTests: XCTestCase {
    // MARK: - 生成

    func test_userQRCodeString_usesWildfirechatUserPrefix() {
        XCTAssertEqual(QRCodeContent.userQRCodeString(uid: "u1"), "wildfirechat://user/u1")
    }

    func test_groupQRCodeString_usesWildfirechatGroupPrefix() {
        XCTAssertEqual(QRCodeContent.groupQRCodeString(groupId: "g1"), "wildfirechat://group/g1")
    }

    // MARK: - 解析:标准前缀

    func test_parse_userCode_returnsUser() {
        XCTAssertEqual(QRCodeContent.parse("wildfirechat://user/u42"), .user(uid: "u42"))
    }

    func test_parse_groupCode_returnsGroup() {
        XCTAssertEqual(QRCodeContent.parse("wildfirechat://group/g42"), .group(groupId: "g42"))
    }

    func test_parse_roundTripsGeneratedCodes() {
        XCTAssertEqual(QRCodeContent.parse(QRCodeContent.userQRCodeString(uid: "me")), .user(uid: "me"))
        XCTAssertEqual(QRCodeContent.parse(QRCodeContent.groupQRCodeString(groupId: "team")), .group(groupId: "team"))
    }

    // MARK: - 解析:旧版 iOS 群码格式兼容

    func test_parse_legacyGroupCode_returnsGroup() {
        XCTAssertEqual(QRCodeContent.parse("group:g7"), .group(groupId: "g7"))
    }

    // MARK: - 解析:无效输入

    func test_parse_emptyUid_returnsNil() {
        XCTAssertNil(QRCodeContent.parse("wildfirechat://user/"))
    }

    func test_parse_emptyGroupId_returnsNil() {
        XCTAssertNil(QRCodeContent.parse("wildfirechat://group/"))
        XCTAssertNil(QRCodeContent.parse("group:"))
    }

    func test_parse_unknownContent_returnsNil() {
        XCTAssertNil(QRCodeContent.parse("https://example.com"))
        XCTAssertNil(QRCodeContent.parse("wildfirechat://pcsession/token123"))
        XCTAssertNil(QRCodeContent.parse("wildfirechat://channel/c1"))
        XCTAssertNil(QRCodeContent.parse(""))
        XCTAssertNil(QRCodeContent.parse("随便一段文本"))
    }
}
