// App/MarkdownTableRenderer.swift
import UIKit
import IMKit

/// Draws a parsed markdown table into a `UIImage` for embedding as an
/// `NSTextAttachment` — the Android client's grid look (hairline borders,
/// tinted bold header row, per-column alignment, cells wrapping within their
/// column) without giving up the bubble's single-label structure. Images are
/// cached upstream in `MarkdownRenderer` together with the surrounding text.
enum MarkdownTableRenderer {
    private static let cellPaddingH: CGFloat = 8
    private static let cellPaddingV: CGFloat = 8
    private static let hairline: CGFloat = 0.5

    static func image(
        alignments: [MarkdownTableAlignment],
        header: [[MarkdownSpan]]?,
        rows: [[[MarkdownSpan]]],
        maxWidth: CGFloat,
        textColor: UIColor,
        baseFontSize: CGFloat
    ) -> UIImage {
        let fontSize = baseFontSize - 2
        let columnCount = alignments.count

        var tableRows: [(cells: [NSAttributedString], isHeader: Bool)] = []
        if let header {
            tableRows.append((cellStrings(header, alignments: alignments, bold: true, color: textColor, size: fontSize), true))
        }
        for row in rows {
            tableRows.append((cellStrings(row, alignments: alignments, bold: false, color: textColor, size: fontSize), false))
        }

        var naturalWidths = [CGFloat](repeating: 0, count: columnCount)
        for row in tableRows {
            for (column, cell) in row.cells.enumerated() {
                naturalWidths[column] = max(naturalWidths[column], ceil(cell.size().width) + 2 * cellPaddingH)
            }
        }
        let bordersWidth = CGFloat(columnCount + 1) * hairline
        let widths = MarkdownTableLayout.columnWidths(
            naturalWidths: naturalWidths,
            available: maxWidth - bordersWidth
        )

        var heights: [CGFloat] = []
        for row in tableRows {
            var height = UIFont.systemFont(ofSize: fontSize).lineHeight + 2 * cellPaddingV
            for (column, cell) in row.cells.enumerated() {
                let bounded = cell.boundingRect(
                    with: CGSize(width: widths[column] - 2 * cellPaddingH, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin],
                    context: nil
                )
                height = max(height, ceil(bounded.height) + 2 * cellPaddingV)
            }
            heights.append(height)
        }

        let totalWidth = widths.reduce(0, +) + bordersWidth
        let totalHeight = heights.reduce(0, +) + CGFloat(tableRows.count + 1) * hairline
        let size = CGSize(width: totalWidth, height: totalHeight)

        return UIGraphicsImageRenderer(size: size).image { context in
            let headerFill = textColor.withAlphaComponent(0.12)
            let rowFill = textColor.withAlphaComponent(0.04)
            let gridColor = textColor.withAlphaComponent(0.25)

            var y = hairline
            for (index, row) in tableRows.enumerated() {
                (row.isHeader ? headerFill : rowFill).setFill()
                context.fill(CGRect(x: 0, y: y, width: totalWidth, height: heights[index]))

                var x = hairline
                for (column, cell) in row.cells.enumerated() {
                    cell.draw(
                        with: CGRect(
                            x: x + cellPaddingH,
                            y: y + cellPaddingV,
                            width: widths[column] - 2 * cellPaddingH,
                            height: heights[index] - 2 * cellPaddingV
                        ),
                        options: [.usesLineFragmentOrigin],
                        context: nil
                    )
                    x += widths[column] + hairline
                }
                y += heights[index] + hairline
            }

            gridColor.setFill()
            var lineY: CGFloat = 0
            context.fill(CGRect(x: 0, y: lineY, width: totalWidth, height: hairline))
            for height in heights {
                lineY += hairline + height
                context.fill(CGRect(x: 0, y: lineY, width: totalWidth, height: hairline))
            }
            var lineX: CGFloat = 0
            context.fill(CGRect(x: lineX, y: 0, width: hairline, height: totalHeight))
            for width in widths {
                lineX += hairline + width
                context.fill(CGRect(x: lineX, y: 0, width: hairline, height: totalHeight))
            }
        }
    }

    private static func cellStrings(
        _ cells: [[MarkdownSpan]],
        alignments: [MarkdownTableAlignment],
        bold: Bool,
        color: UIColor,
        size: CGFloat
    ) -> [NSAttributedString] {
        cells.enumerated().map { column, spans in
            let textAlignment: NSTextAlignment
            switch alignments[column] {
            case .left: textAlignment = .left
            case .center: textAlignment = .center
            case .right: textAlignment = .right
            }
            return MarkdownRenderer.spanString(spans, color: color, size: size, forceBold: bold, alignment: textAlignment)
        }
    }
}
