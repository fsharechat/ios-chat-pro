// App/MarkdownRenderer.swift
import UIKit
import IMKit

/// Maps `MarkdownMessage` blocks to an `NSAttributedString` in the app's
/// theme. Results are cached — cells re-render the same text on every reuse,
/// and parsing + attribute assembly must never run per scroll frame.
enum MarkdownRenderer {
    private static let cache = NSCache<NSString, NSAttributedString>()

    /// `availableWidth` is the widest a line can render (the bubble/text
    /// view's content width) — tables are drawn to fill exactly that width.
    static func render(
        _ text: String,
        textColor: UIColor,
        baseFontSize: CGFloat = 16,
        availableWidth: CGFloat
    ) -> NSAttributedString {
        // textColor differs between incoming/outgoing bubbles (and theme
        // changes), width between bubble and full-text page — both are part
        // of the key.
        let key = "\(baseFontSize)|\(availableWidth)|\(textColor.hashValue)|\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let result = NSMutableAttributedString()
        for (index, block) in MarkdownMessage.parse(text).enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            append(block, to: result, textColor: textColor, baseFontSize: baseFontSize, availableWidth: availableWidth)
        }
        let immutable = NSAttributedString(attributedString: result)
        cache.setObject(immutable, forKey: key)
        return immutable
    }

    private static func append(
        _ block: MarkdownBlock,
        to result: NSMutableAttributedString,
        textColor: UIColor,
        baseFontSize: CGFloat,
        availableWidth: CGFloat
    ) {
        switch block {
        case .heading(let level, let spans):
            let sizes: [CGFloat] = [baseFontSize + 6, baseFontSize + 4, baseFontSize + 2]
            let size = level <= sizes.count ? sizes[level - 1] : baseFontSize
            appendSpans(spans, to: result, color: textColor, size: size, forceBold: true)
        case .bullet(let spans):
            result.append(NSAttributedString(string: "• ", attributes: [
                .font: UIFont.systemFont(ofSize: baseFontSize), .foregroundColor: textColor,
            ]))
            appendSpans(spans, to: result, color: textColor, size: baseFontSize)
        case .ordered(let number, let spans):
            result.append(NSAttributedString(string: "\(number). ", attributes: [
                .font: UIFont.systemFont(ofSize: baseFontSize), .foregroundColor: textColor,
            ]))
            appendSpans(spans, to: result, color: textColor, size: baseFontSize)
        case .quote(let spans):
            appendSpans(spans, to: result, color: textColor.withAlphaComponent(0.6), size: baseFontSize)
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
            appendSpans(spans, to: result, color: textColor, size: baseFontSize)
        }
    }

    private static func appendSpans(
        _ spans: [MarkdownSpan],
        to result: NSMutableAttributedString,
        color: UIColor,
        size: CGFloat,
        forceBold: Bool = false
    ) {
        result.append(spanString(spans, color: color, size: size, forceBold: forceBold))
    }

    /// Also used by `MarkdownTableRenderer` for cell content.
    static func spanString(
        _ spans: [MarkdownSpan],
        color: UIColor,
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
                // No underline (user preference) — the .link attribute's
                // color treatment alone marks it; UITextView makes it
                // tappable on the full-text page.
                attributes[.link] = url
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
