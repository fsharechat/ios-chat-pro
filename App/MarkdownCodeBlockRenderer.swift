// App/MarkdownCodeBlockRenderer.swift
import UIKit

/// Draws a fenced code block as a full-width rounded card image for
/// `NSTextAttachment` embedding — NSAttributedString's `.backgroundColor`
/// only tints glyph runs, it can't produce the padded whole-region block
/// background a code block needs. Same attachment pattern as
/// `MarkdownTableRenderer`; cached upstream in `MarkdownRenderer`.
enum MarkdownCodeBlockRenderer {
    private static let padding: CGFloat = 10
    private static let cornerRadius: CGFloat = 8

    static func image(
        code: String,
        maxWidth: CGFloat,
        textColor: UIColor,
        baseFontSize: CGFloat
    ) -> UIImage {
        let font = UIFont.monospacedSystemFont(ofSize: baseFontSize - 3, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        // Char wrapping: code has long unbroken tokens (URLs, identifiers)
        // that word wrapping would push past the card's edge.
        paragraph.lineBreakMode = .byCharWrapping
        let attributed = NSAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ])

        let textWidth = maxWidth - 2 * padding
        let textHeight = max(
            font.lineHeight,
            ceil(attributed.boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                context: nil
            ).height)
        )
        let size = CGSize(width: maxWidth, height: textHeight + 2 * padding)

        return UIGraphicsImageRenderer(size: size).image { _ in
            textColor.withAlphaComponent(0.12).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: cornerRadius).fill()
            attributed.draw(
                with: CGRect(x: padding, y: padding, width: textWidth, height: textHeight),
                options: [.usesLineFragmentOrigin],
                context: nil
            )
        }
    }
}
