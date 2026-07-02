import Foundation

/// Pure column-width math for rendering a markdown table into a fixed
/// available width (the bubble's content width). UIKit-free so it's
/// testable under `swift test`; the App target measures natural cell widths
/// and draws with the widths computed here.
public enum MarkdownTableLayout {
    /// Distributes `available` points across columns.
    ///
    /// - Natural widths that fit are scaled *up* proportionally so the table
    ///   fills the full available width (matching the Android client's
    ///   full-bleed table look).
    /// - Overflowing natural widths are scaled down proportionally; columns
    ///   that would drop below `minimum` are pinned there and the excess is
    ///   reclaimed from the widest columns (their cells wrap instead).
    public static func columnWidths(
        naturalWidths: [CGFloat],
        available: CGFloat,
        minimum: CGFloat = 44
    ) -> [CGFloat] {
        guard !naturalWidths.isEmpty, available > 0 else { return naturalWidths }
        let total = naturalWidths.reduce(0, +)
        guard total > 0 else {
            return Array(repeating: available / CGFloat(naturalWidths.count), count: naturalWidths.count)
        }
        guard total > available else {
            let scale = available / total
            return naturalWidths.map { $0 * scale }
        }
        var widths = naturalWidths.map { max(minimum, $0 * available / total) }
        var excess = widths.reduce(0, +) - available
        while excess > 0.5 {
            guard let widest = widths.indices.max(by: { widths[$0] < widths[$1] }),
                  widths[widest] - minimum > 0.5 else { break }
            let cut = min(excess, widths[widest] - minimum)
            widths[widest] -= cut
            excess -= cut
        }
        return widths
    }
}
