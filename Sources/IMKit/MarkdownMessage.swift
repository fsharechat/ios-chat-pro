import Foundation

/// One styled run of text within a single source line.
public struct MarkdownSpan: Equatable {
    public let text: String
    public let isBold: Bool
    public let isItalic: Bool
    public let isCode: Bool
    public let isStrikethrough: Bool
    public let linkURL: URL?

    public init(text: String, isBold: Bool, isItalic: Bool, isCode: Bool, isStrikethrough: Bool, linkURL: URL?) {
        self.text = text
        self.isBold = isBold
        self.isItalic = isItalic
        self.isCode = isCode
        self.isStrikethrough = isStrikethrough
        self.linkURL = linkURL
    }
}

/// One rendered block. Each source line produces exactly one block (except a
/// fenced code block, which swallows its fence lines), so the message's
/// original line structure survives rendering verbatim.
public enum MarkdownBlock: Equatable {
    case heading(level: Int, spans: [MarkdownSpan])
    case bullet(spans: [MarkdownSpan])
    case ordered(number: Int, spans: [MarkdownSpan])
    case quote(spans: [MarkdownSpan])
    case codeBlock(String)
    case divider
    /// A whole table: consecutive `|` lines aggregated. The `|:---|---:|`
    /// separator row is consumed — it defines `alignments` and promotes the
    /// row above it to `header`. Rows are padded so every row has exactly
    /// `alignments.count` cells.
    case table(alignments: [MarkdownTableAlignment], header: [[MarkdownSpan]]?, rows: [[[MarkdownSpan]]])
    /// An ordinary line; a blank line is a paragraph with no spans.
    case paragraph(spans: [MarkdownSpan])
}

public enum MarkdownTableAlignment: Equatable {
    case left, center, right
}

/// Chat-oriented Markdown parser: UIKit-agnostic (the App target maps blocks
/// to `NSAttributedString`), testable under `swift test`.
///
/// Chat messages treat every newline as a hard break, but Foundation's
/// `.full` markdown parsing folds single newlines into spaces per CommonMark
/// paragraph semantics — so block structure (headings, lists, quotes, fences,
/// dividers) is scanned line-by-line here, and only inline syntax
/// (bold/italic/code/strikethrough/links) is delegated to Foundation's
/// parser in `.inlineOnlyPreservingWhitespace` mode.
///
/// Table rows (`|`-prefixed) are split into structured cells; true grid
/// alignment is left to the renderer's judgment (an NSAttributedString in a
/// width-limited bubble can't hold a real grid — rows wrap), but pipes and
/// separator rows never reach the screen.
public enum MarkdownMessage {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var lines = ArraySlice(text.components(separatedBy: "\n"))
        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                var codeLines: [String] = []
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    codeLines.append(next)
                }
                // An unclosed fence is treated as closed at end of message —
                // likely a message truncated mid-fence.
                blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
            } else if trimmed.hasPrefix("|") {
                var tableLines = [trimmed]
                while let next = lines.first {
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    guard nextTrimmed.hasPrefix("|") else { break }
                    lines = lines.dropFirst()
                    tableLines.append(nextTrimmed)
                }
                if let table = buildTable(tableLines) { blocks.append(table) }
            } else {
                blocks.append(parseLine(line, trimmed: trimmed))
            }
        }
        return blocks
    }

    /// Aggregates consecutive `|` lines into one `.table` block. The first
    /// separator row defines column alignments and promotes the row directly
    /// above it to the header; further separator rows are dropped. Returns
    /// nil for a "table" with no content rows at all (e.g. an orphan
    /// separator line).
    private static func buildTable(_ tableLines: [String]) -> MarkdownBlock? {
        var header: [[MarkdownSpan]]?
        var alignments: [MarkdownTableAlignment]?
        var rows: [[[MarkdownSpan]]] = []
        for line in tableLines {
            if isTableSeparator(line) {
                if alignments == nil {
                    alignments = separatorAlignments(line)
                    if !rows.isEmpty { header = rows.removeLast() }
                }
            } else {
                rows.append(tableCells(line))
            }
        }
        guard header != nil || !rows.isEmpty else { return nil }
        let columnCount = max(
            header?.count ?? 0,
            rows.map(\.count).max() ?? 0,
            alignments?.count ?? 0
        )
        func pad(_ row: [[MarkdownSpan]]) -> [[MarkdownSpan]] {
            row + Array(repeating: [], count: columnCount - row.count)
        }
        var finalAlignments = alignments ?? []
        if finalAlignments.count < columnCount {
            finalAlignments += Array(repeating: .left, count: columnCount - finalAlignments.count)
        }
        return .table(
            alignments: Array(finalAlignments.prefix(columnCount)),
            header: header.map(pad),
            rows: rows.map(pad)
        )
    }

    private static func splitTableCells(_ trimmed: String) -> [String] {
        var body = trimmed.dropFirst()                       // leading "|"
        if body.hasSuffix("|") { body = body.dropLast() }
        return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Splits a `|`-delimited row into trimmed, inline-parsed cells.
    private static func tableCells(_ trimmed: String) -> [[MarkdownSpan]] {
        splitTableCells(trimmed).map(inlineSpans)
    }

    /// A row like `|:---|---:|` — every cell is dashes with optional
    /// alignment colons.
    private static func isTableSeparator(_ trimmed: String) -> Bool {
        let cells = splitTableCells(trimmed)
        return !cells.isEmpty && cells.allSatisfy { cell in
            cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func separatorAlignments(_ trimmed: String) -> [MarkdownTableAlignment] {
        splitTableCells(trimmed).map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (_, true): return .right
            default: return .left
            }
        }
    }

    private static func parseLine(_ line: String, trimmed: String) -> MarkdownBlock {
        if trimmed.isEmpty { return .paragraph(spans: []) }
        // Divider must precede the bullet check: "***" would otherwise match
        // the "*"-bullet prefix.
        if trimmed.count >= 3, Set(trimmed).count == 1, "-*_".contains(trimmed.first!) {
            return .divider
        }
        if trimmed.hasPrefix("#") {
            let level = trimmed.prefix(while: { $0 == "#" }).count
            let rest = trimmed.dropFirst(level)
            if level <= 6, rest.first == " " {
                return .heading(level: level, spans: inlineSpans(String(rest).trimmingCharacters(in: .whitespaces)))
            }
        }
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
            return .bullet(spans: inlineSpans(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
        }
        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty, let number = Int(digits) {
            let afterDigits = trimmed.dropFirst(digits.count)
            if afterDigits.hasPrefix(". ") {
                return .ordered(number: number, spans: inlineSpans(String(afterDigits.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            }
        }
        if trimmed.hasPrefix(">") {
            let rest = trimmed.dropFirst().drop(while: { $0 == " " })
            return .quote(spans: inlineSpans(String(rest)))
        }
        return .paragraph(spans: inlineSpans(line))
    }

    private static func inlineSpans(_ text: String) -> [MarkdownSpan] {
        guard !text.isEmpty else { return [] }
        guard let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return [plainSpan(text)]
        }
        var spans: [MarkdownSpan] = []
        for run in attributed.runs {
            let intent = run.inlinePresentationIntent ?? []
            spans.append(MarkdownSpan(
                text: String(attributed[run.range].characters),
                isBold: intent.contains(.stronglyEmphasized),
                isItalic: intent.contains(.emphasized),
                isCode: intent.contains(.code),
                isStrikethrough: intent.contains(.strikethrough),
                linkURL: run.link
            ))
        }
        return spans
    }

    private static func plainSpan(_ text: String) -> MarkdownSpan {
        MarkdownSpan(text: text, isBold: false, isItalic: false, isCode: false, isStrikethrough: false, linkURL: nil)
    }
}
