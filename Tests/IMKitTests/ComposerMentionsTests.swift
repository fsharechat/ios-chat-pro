import XCTest
@testable import IMKit

final class ComposerMentionsTests: XCTestCase {
    private func mention(_ name: String, uid: String?) -> NSAttributedString {
        NSAttributedString(string: "@\(name) ", attributes: [ComposerMentions.attributeKey: ComposerMentions.Reference(uid: uid)])
    }

    func testIdenticalNamesKeepTheirOwnRecipientIdentity() {
        let text = NSMutableAttributedString(attributedString: mention("小明", uid: "first"))
        text.append(mention("小明", uid: "second"))
        text.deleteCharacters(in: NSRange(location: 0, length: 4))
        XCTAssertEqual(ComposerMentions.recipients(in: text).targets, ["second"])
    }

    func testRemovingAllRestoresTheRemainingIndividualMentions() {
        let text = NSMutableAttributedString(attributedString: mention("小明", uid: "first"))
        text.append(mention("所有人", uid: nil))
        XCTAssertEqual(ComposerMentions.recipients(in: text).type, 2)
        XCTAssertEqual(ComposerMentions.recipients(in: text).targets, [])
        text.deleteCharacters(in: NSRange(location: 4, length: text.length - 4))
        XCTAssertEqual(ComposerMentions.recipients(in: text).type, 1)
        XCTAssertEqual(ComposerMentions.recipients(in: text).targets, ["first"])
    }

    func testBackspaceAndPartialSelectionReplaceTheWholeMention() {
        let text = NSMutableAttributedString(string: "你好 ")
        text.append(mention("小明", uid: "first"))
        XCTAssertEqual(ComposerMentions.expandedRange(for: NSRange(location: 6, length: 1), in: text), NSRange(location: 3, length: 4))
        let edit = ComposerMentions.expandedRange(for: NSRange(location: 1, length: 4), in: text)
        text.replaceCharacters(in: edit, with: "新的文字")
        XCTAssertEqual(text.string, "你新的文字")
        XCTAssertEqual(ComposerMentions.recipients(in: text).type, 0)
    }

    func testInsertionAtBoundaryDoesNotDeleteMentionButInsideIsAtomic() {
        let text = mention("小明", uid: "first")
        XCTAssertEqual(ComposerMentions.expandedRange(for: NSRange(location: 4, length: 0), in: text), NSRange(location: 4, length: 0))
        XCTAssertEqual(ComposerMentions.expandedRange(for: NSRange(location: 2, length: 0), in: text), NSRange(location: 0, length: 4))
    }

    func testPastedPlainAtTextDoesNotInventRecipientsAndIDsAreDeduplicated() {
        let text = NSMutableAttributedString(string: "粘贴 @小明 ")
        XCTAssertEqual(ComposerMentions.recipients(in: text).type, 0)
        text.append(mention("小明", uid: "first"))
        text.append(mention("新昵称", uid: "first"))
        XCTAssertEqual(ComposerMentions.recipients(in: text).targets, ["first"])
    }
}
