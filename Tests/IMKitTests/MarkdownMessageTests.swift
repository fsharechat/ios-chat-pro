import XCTest
import IMKit

final class MarkdownMessageTests: XCTestCase {
    private func plainSpan(_ text: String) -> MarkdownSpan {
        MarkdownSpan(text: text, isBold: false, isItalic: false, isCode: false, isStrikethrough: false, linkURL: nil)
    }

    // MARK: 纯文本

    func test_plainMultilineText_preservesLinesAndBlankLines() {
        let blocks = MarkdownMessage.parse("第一行\n\n第二行")
        XCTAssertEqual(blocks, [
            .paragraph(spans: [plainSpan("第一行")]),
            .paragraph(spans: []),
            .paragraph(spans: [plainSpan("第二行")]),
        ])
    }

    // MARK: 行内语法

    func test_boldSpan() {
        let blocks = MarkdownMessage.parse("含**粗体**文字")
        guard case .paragraph(let spans) = blocks.first else { return XCTFail("expected paragraph") }
        XCTAssertEqual(spans.map(\.text), ["含", "粗体", "文字"])
        XCTAssertEqual(spans.map(\.isBold), [false, true, false])
    }

    func test_italicCodeStrikethroughSpans() {
        let blocks = MarkdownMessage.parse("*斜* `码` ~~删~~")
        guard case .paragraph(let spans) = blocks.first else { return XCTFail("expected paragraph") }
        XCTAssertEqual(spans.first { $0.text == "斜" }?.isItalic, true)
        XCTAssertEqual(spans.first { $0.text == "码" }?.isCode, true)
        XCTAssertEqual(spans.first { $0.text == "删" }?.isStrikethrough, true)
    }

    func test_linkSpan() {
        let blocks = MarkdownMessage.parse("见[官网](https://example.com)了解")
        guard case .paragraph(let spans) = blocks.first else { return XCTFail("expected paragraph") }
        XCTAssertEqual(spans.first { $0.text == "官网" }?.linkURL, URL(string: "https://example.com"))
    }

    func test_invalidInlineSyntax_fallsBackToPlainText() {
        let text = "半个**粗体标记"
        let blocks = MarkdownMessage.parse(text)
        guard case .paragraph(let spans) = blocks.first else { return XCTFail("expected paragraph") }
        XCTAssertEqual(spans.map(\.text).joined(), text)
    }

    // MARK: 块级语法

    func test_headingLevels() {
        let blocks = MarkdownMessage.parse("# 一级\n### 三级")
        XCTAssertEqual(blocks, [
            .heading(level: 1, spans: [plainSpan("一级")]),
            .heading(level: 3, spans: [plainSpan("三级")]),
        ])
    }

    func test_bulletAndOrderedLists() {
        let blocks = MarkdownMessage.parse("- 甲\n* 乙\n1. 丙\n2. 丁")
        XCTAssertEqual(blocks, [
            .bullet(spans: [plainSpan("甲")]),
            .bullet(spans: [plainSpan("乙")]),
            .ordered(number: 1, spans: [plainSpan("丙")]),
            .ordered(number: 2, spans: [plainSpan("丁")]),
        ])
    }

    func test_bulletWithInlineBold() {
        let blocks = MarkdownMessage.parse("- **数据待补充** — 暂无摘要")
        guard case .bullet(let spans) = blocks.first else { return XCTFail("expected bullet") }
        XCTAssertEqual(spans.first?.text, "数据待补充")
        XCTAssertEqual(spans.first?.isBold, true)
    }

    func test_quote() {
        let blocks = MarkdownMessage.parse("> 引用内容")
        XCTAssertEqual(blocks, [.quote(spans: [plainSpan("引用内容")])])
    }

    func test_divider() {
        let blocks = MarkdownMessage.parse("---\n***")
        XCTAssertEqual(blocks, [.divider, .divider])
    }

    // MARK: 代码块

    func test_fencedCodeBlock() {
        let blocks = MarkdownMessage.parse("```\nlet a = 1\nlet b = 2\n```\n尾行")
        XCTAssertEqual(blocks, [
            .codeBlock("let a = 1\nlet b = 2"),
            .paragraph(spans: [plainSpan("尾行")]),
        ])
    }

    func test_unclosedFence_treatedAsClosedAtEnd() {
        let blocks = MarkdownMessage.parse("```\n未闭合内容")
        XCTAssertEqual(blocks, [.codeBlock("未闭合内容")])
    }

    // MARK: 表格

    func test_table_aggregatesHeaderAlignmentsAndRows() {
        let blocks = MarkdownMessage.parse("""
        | 代码 | 盘前价 |
        |:---|---:|
        | AAPL | $294.38 |
        | MSFT | $384.28 |
        """)
        XCTAssertEqual(blocks, [
            .table(
                alignments: [.left, .right],
                header: [[plainSpan("代码")], [plainSpan("盘前价")]],
                rows: [
                    [[plainSpan("AAPL")], [plainSpan("$294.38")]],
                    [[plainSpan("MSFT")], [plainSpan("$384.28")]],
                ]
            ),
        ])
    }

    func test_tableWithoutSeparator_hasNoHeaderAndLeftAlignments() {
        let blocks = MarkdownMessage.parse("| META | $612.91 | +8.81% |")
        XCTAssertEqual(blocks, [
            .table(
                alignments: [.left, .left, .left],
                header: nil,
                rows: [[[plainSpan("META")], [plainSpan("$612.91")], [plainSpan("+8.81%")]]]
            ),
        ])
    }

    func test_tableCell_supportsInlineSyntax() {
        let blocks = MarkdownMessage.parse("| **重点** | 说明 |")
        guard case .table(_, _, let rows) = blocks.first else { return XCTFail("expected table") }
        XCTAssertEqual(rows.first?.first?.first?.text, "重点")
        XCTAssertEqual(rows.first?.first?.first?.isBold, true)
    }

    func test_orphanSeparatorLine_dropped() {
        XCTAssertEqual(MarkdownMessage.parse("|:---|---:|"), [])
    }

    func test_centerAlignment() {
        let blocks = MarkdownMessage.parse("| 甲 |\n|:---:|\n| 乙 |")
        guard case .table(let alignments, _, _) = blocks.first else { return XCTFail("expected table") }
        XCTAssertEqual(alignments, [.center])
    }

    func test_raggedRows_paddedToWidestColumnCount() {
        let blocks = MarkdownMessage.parse("| 甲 | 乙 |\n| 丙 |")
        XCTAssertEqual(blocks, [
            .table(
                alignments: [.left, .left],
                header: nil,
                rows: [
                    [[plainSpan("甲")], [plainSpan("乙")]],
                    [[plainSpan("丙")], []],
                ]
            ),
        ])
    }

    func test_textAfterTable_isSeparateParagraph() {
        let blocks = MarkdownMessage.parse("| 甲 |\n尾行")
        XCTAssertEqual(blocks, [
            .table(alignments: [.left], header: nil, rows: [[[plainSpan("甲")]]]),
            .paragraph(spans: [plainSpan("尾行")]),
        ])
    }
}
