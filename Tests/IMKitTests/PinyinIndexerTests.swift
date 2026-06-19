// Tests/IMKitTests/PinyinIndexerTests.swift
import XCTest
@testable import IMKit

final class PinyinIndexerTests: XCTestCase {
    func test_sectionLetter_englishName_returnsFirstLetterUppercased() {
        XCTAssertEqual(PinyinIndexer.sectionLetter(for: "alice"), "A")
        XCTAssertEqual(PinyinIndexer.sectionLetter(for: "Bob"), "B")
    }

    func test_sectionLetter_chineseName_returnsTransliteratedFirstLetter() {
        XCTAssertEqual(PinyinIndexer.sectionLetter(for: "张三"), "Z")
        XCTAssertEqual(PinyinIndexer.sectionLetter(for: "李雷"), "L")
    }

    func test_sectionLetter_nonLetterName_returnsHash() {
        XCTAssertEqual(PinyinIndexer.sectionLetter(for: "123"), "#")
        XCTAssertEqual(PinyinIndexer.sectionLetter(for: "👍"), "#")
    }

    func test_sectionLetter_emptyString_returnsHash() {
        XCTAssertEqual(PinyinIndexer.sectionLetter(for: ""), "#")
    }

    func test_sectionLetter_alreadyLatinNameStartingWithDigit_findsFirstLetter() {
        // "starts with a letter somewhere" is the actual rule, not strictly
        // "first character is a letter" — a leading digit doesn't force "#"
        // if a real letter follows.
        XCTAssertEqual(PinyinIndexer.sectionLetter(for: "007zz"), "Z")
    }

    func test_sortKey_englishName_isLowercased() {
        XCTAssertEqual(PinyinIndexer.sortKey(for: "Alice"), "alice")
    }

    func test_sortKey_chineseName_startsWithLowercaseTransliteration() {
        XCTAssertTrue(PinyinIndexer.sortKey(for: "张三").hasPrefix("z"))
    }

    func test_sortKey_isDeterministic() {
        XCTAssertEqual(PinyinIndexer.sortKey(for: "张三"), PinyinIndexer.sortKey(for: "张三"))
    }
}
