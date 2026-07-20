// App/MarkdownRenderer.swift
import UIKit
import IMKit

/// Maps `MarkdownMessage` blocks to an `NSAttributedString` in the app's
/// theme. Results are cached — cells re-render the same text on every reuse,
/// and parsing + attribute assembly must never run per scroll frame.
enum MarkdownRenderer {
    private static let cache = NSCache<NSString, NSAttributedString>()

    /// Carries the link URL for text rendered into a `UILabel` (the chat
    /// bubble). Deliberately not the system `.link` key: `UILabel` paints
    /// `.link`-attributed runs with its own default link color, silently
    /// overriding any explicit `.foregroundColor` on that range — which is
    /// why a bubble link kept rendering system blue even after this file
    /// set a distinct `linkColor`. `UITextView` (the full-text page) has no
    /// such override — `linkTextAttributes` governs it there — so it keeps
    /// using the real `.link` key for the native tap/preview behavior.
    static let bubbleLinkAttributeKey = NSAttributedString.Key("MarkdownBubbleLinkURL")

    /// `availableWidth` is the widest a line can render (the bubble/text
    /// view's content width) — tables are drawn to fill exactly that width.
    /// `linkColor` styles link runs distinctly from body text — callers must
    /// pick one with contrast against their own background (e.g. the
    /// accent-colored outgoing bubble needs a different tint than plain
    /// body text, see `Theme.linkOnAccent`). `linkAttributeKey` selects
    /// which attribute key carries the URL — see `bubbleLinkAttributeKey`.
    static func render(
        _ text: String,
        textColor: UIColor,
        linkColor: UIColor,
        linkAttributeKey: NSAttributedString.Key = .link,
        baseFontSize: CGFloat = 16,
        availableWidth: CGFloat
    ) -> NSAttributedString {
        // textColor/linkColor differ between incoming/outgoing bubbles (and
        // theme changes), width between bubble and full-text page — all are
        // part of the key.
        let key = "\(baseFontSize)|\(availableWidth)|\(textColor.hashValue)|\(linkColor.hashValue)|\(linkAttributeKey.rawValue)|\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let result = NSMutableAttributedString()
        for (index, block) in MarkdownMessage.parse(text).enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            append(block, to: result, textColor: textColor, linkColor: linkColor, linkAttributeKey: linkAttributeKey, baseFontSize: baseFontSize, availableWidth: availableWidth)
        }
        let immutable = NSAttributedString(attributedString: result)
        cache.setObject(immutable, forKey: key)
        return immutable
    }

    private static func append(
        _ block: MarkdownBlock,
        to result: NSMutableAttributedString,
        textColor: UIColor,
        linkColor: UIColor,
        linkAttributeKey: NSAttributedString.Key,
        baseFontSize: CGFloat,
        availableWidth: CGFloat
    ) {
        switch block {
        case .heading(let level, let spans):
            let sizes: [CGFloat] = [baseFontSize + 6, baseFontSize + 4, baseFontSize + 2]
            let size = level <= sizes.count ? sizes[level - 1] : baseFontSize
            appendSpans(spans, to: result, color: textColor, linkColor: linkColor, linkAttributeKey: linkAttributeKey, size: size, forceBold: true)
        case .bullet(let spans):
            result.append(NSAttributedString(string: "• ", attributes: [
                .font: UIFont.systemFont(ofSize: baseFontSize), .foregroundColor: textColor,
            ]))
            appendSpans(spans, to: result, color: textColor, linkColor: linkColor, linkAttributeKey: linkAttributeKey, size: baseFontSize)
        case .ordered(let number, let spans):
            result.append(NSAttributedString(string: "\(number). ", attributes: [
                .font: UIFont.systemFont(ofSize: baseFontSize), .foregroundColor: textColor,
            ]))
            appendSpans(spans, to: result, color: textColor, linkColor: linkColor, linkAttributeKey: linkAttributeKey, size: baseFontSize)
        case .quote(let spans):
            appendSpans(spans, to: result, color: textColor.withAlphaComponent(0.6), linkColor: linkColor, linkAttributeKey: linkAttributeKey, size: baseFontSize)
        case .codeBlock(let code):
            let image = MarkdownCodeBlockRenderer.image(
                code: code, maxWidth: availableWidth,
                textColor: textColor, baseFontSize: baseFontSize
            )
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(origin: .zero, size: image.size)
            result.append(NSAttributedString(attachment: attachment))
        case .divider:
            result.append(NSAttributedString(string: "───", attributes: [
                .font: UIFont.systemFont(ofSize: baseFontSize),
                .foregroundColor: textColor.withAlphaComponent(0.4),
            ]))
        case .table(let alignments, let header, let rows):
            let image = MarkdownTableRenderer.image(
                alignments: alignments, header: header, rows: rows,
                maxWidth: availableWidth, textColor: textColor, baseFontSize: baseFontSize
            )
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(origin: .zero, size: image.size)
            result.append(NSAttributedString(attachment: attachment))
        case .paragraph(let spans):
            appendSpans(spans, to: result, color: textColor, linkColor: linkColor, linkAttributeKey: linkAttributeKey, size: baseFontSize)
        }
    }

    private static func appendSpans(
        _ spans: [MarkdownSpan],
        to result: NSMutableAttributedString,
        color: UIColor,
        linkColor: UIColor,
        linkAttributeKey: NSAttributedString.Key,
        size: CGFloat,
        forceBold: Bool = false
    ) {
        result.append(spanString(spans, color: color, linkColor: linkColor, linkAttributeKey: linkAttributeKey, size: size, forceBold: forceBold))
    }

    /// Also used by `MarkdownTableRenderer` for cell content — table cells
    /// pass `color` again for `linkColor` since a table never renders on an
    /// accent-colored background needing a distinct tint.
    static func spanString(
        _ spans: [MarkdownSpan],
        color: UIColor,
        linkColor: UIColor? = nil,
        linkAttributeKey: NSAttributedString.Key = .link,
        size: CGFloat,
        forceBold: Bool = false,
        alignment: NSTextAlignment? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for span in spans {
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if span.isCode {
                attributes[.font] = UIFont.monospacedSystemFont(ofSize: size - 2, weight: .regular)
                attributes[.backgroundColor] = color.withAlphaComponent(0.12)
            } else {
                attributes[.font] = font(size: size, bold: forceBold || span.isBold, italic: span.isItalic)
            }
            if span.isStrikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let url = span.linkURL {
                // No underline (user preference) — the distinct link color
                // alone marks it; TextMessageCell/TextPreviewViewController
                // hit-test `linkAttributeKey` to make it tappable.
                attributes[linkAttributeKey] = url
                attributes[.foregroundColor] = linkColor ?? color
            }
            if let alignment {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = alignment
                paragraph.lineBreakMode = .byWordWrapping
                attributes[.paragraphStyle] = paragraph
            }
            result.append(NSAttributedString(string: span.text, attributes: attributes))
        }
        return result
    }

    private static func font(size: CGFloat, bold: Bool, italic: Bool) -> UIFont {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let base = UIFont.systemFont(ofSize: size)
        guard !traits.isEmpty, let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: size)
    }
}
