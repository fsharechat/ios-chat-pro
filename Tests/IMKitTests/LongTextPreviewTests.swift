import XCTest
import IMKit

final class LongTextPreviewTests: XCTestCase {
    func test_shortText_returnsUnchangedAndNotTruncated() {
        let text = "早上好"
        let preview = LongTextPreview.preview(for: text)
        XCTAssertEqual(preview.text, text)
        XCTAssertFalse(preview.isTruncated)
    }

    func test_textAtExactLimit_notTruncated() {
        let text = String(repeating: "字", count: LongTextPreview.characterLimit)
        let preview = LongTextPreview.preview(for: text)
        XCTAssertEqual(preview.text, text)
        XCTAssertFalse(preview.isTruncated)
    }

    func test_textOverLimit_truncatedWithEllipsis() {
        let text = String(repeating: "报", count: LongTextPreview.characterLimit + 1)
        let preview = LongTextPreview.preview(for: text)
        XCTAssertTrue(preview.isTruncated)
        XCTAssertEqual(preview.text.count, LongTextPreview.characterLimit + 1) // limit 字 + "…"
        XCTAssertTrue(preview.text.hasSuffix("…"))
        XCTAssertEqual(String(preview.text.dropLast()), String(text.prefix(LongTextPreview.characterLimit)))
    }

    func test_truncationRespectsCharacterBoundary_emoji() {
        // 组合 emoji（多个 unicode scalar）不能被截成半个字符
        let emoji = "👨‍👩‍👧‍👦"
        let text = String(repeating: emoji, count: LongTextPreview.characterLimit + 10)
        let preview = LongTextPreview.preview(for: text)
        XCTAssertTrue(preview.isTruncated)
        let body = String(preview.text.dropLast())
        XCTAssertTrue(body.allSatisfy { String($0) == emoji })
        XCTAssertEqual(body.count, LongTextPreview.characterLimit)
    }
}
