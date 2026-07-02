import XCTest
import IMKit

final class MarkdownTableLayoutTests: XCTestCase {
    func test_naturalWidthsFitting_scaledUpToFillAvailable() {
        let widths = MarkdownTableLayout.columnWidths(naturalWidths: [50, 100], available: 300)
        XCTAssertEqual(widths, [100, 200], accuracy: 0.5)
        XCTAssertEqual(widths.reduce(0, +), 300, accuracy: 0.5)
    }

    func test_naturalWidthsOverflowing_shrunkProportionally() {
        let widths = MarkdownTableLayout.columnWidths(naturalWidths: [200, 200], available: 300)
        XCTAssertEqual(widths, [150, 150], accuracy: 0.5)
    }

    func test_shrinking_respectsMinimumWidth_excessTakenFromWidest() {
        // 比例缩得比 minimum 还小的列被抬到 minimum,超出部分从最宽列扣回
        let widths = MarkdownTableLayout.columnWidths(naturalWidths: [40, 400], available: 220, minimum: 44)
        XCTAssertEqual(widths[0], 44, accuracy: 0.5)
        XCTAssertEqual(widths.reduce(0, +), 220, accuracy: 0.5)
    }

    func test_zeroNaturalWidths_splitEvenly() {
        let widths = MarkdownTableLayout.columnWidths(naturalWidths: [0, 0], available: 100)
        XCTAssertEqual(widths, [50, 50], accuracy: 0.5)
    }
}

private func XCTAssertEqual(_ lhs: [CGFloat], _ rhs: [CGFloat], accuracy: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
    for (l, r) in zip(lhs, rhs) {
        XCTAssertEqual(l, r, accuracy: accuracy, file: file, line: line)
    }
}
