import Foundation

/// Collapses very long message text for in-bubble display — the WeChat-style
/// "折叠 + 查看全文" treatment. A multi-thousand-character message rendered
/// whole into one self-sizing UILabel produces a bubble tens of thousands of
/// points tall: opening the conversation stalls on synchronous TextKit layout
/// of every visible giant label, and scrolling re-rasterizes text layers far
/// beyond the GPU's maximum texture size on every frame. Bounding the
/// displayed prefix bounds both costs; the full text stays untouched in
/// storage, so copy/forward/search still operate on the whole message.
public enum LongTextPreview {
    /// Characters shown in the bubble before collapsing. ~600 CJK characters
    /// is roughly one screenful — long enough that ordinary chat never
    /// collapses, short enough that layout cost stays flat.
    public static let characterLimit = 600

    /// Truncates on `Character` (grapheme) boundaries, so composed emoji and
    /// the like are never split mid-character.
    public static func preview(for text: String) -> (text: String, isTruncated: Bool) {
        guard text.count > characterLimit else { return (text, false) }
        return (String(text.prefix(characterLimit)) + "…", true)
    }
}
