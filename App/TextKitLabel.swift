// App/TextKitLabel.swift
import UIKit

/// 自己用 TextKit 1 排版、测量、绘制的 UILabel。
///
/// UILabel 内部的排版（换行规则、CJK 标点处理、行高）与 NSLayoutManager 并不完全一致，
/// 长文本里差异会累积——在外面另搭一份 TextKit 排版做选字/链接命中，高亮会和屏幕上的字
/// 对不上（长 Markdown 消息全选时停在倒数第二行）。这里让绘制和尺寸都走同一份
/// `LabelTextLayout`，选字与链接命中直接复用它，二者天然一致。
///
/// 只支持 `attributedText`（气泡文字都经 MarkdownRenderer 渲染），多行、左上对齐。
final class TextKitLabel: UILabel {
    /// 调用方设置的原始文本。UILabel 的 `attributedText` getter 会返回加工过的新实例，
    /// 不能用来做缓存键。
    private var sourceText: NSAttributedString?
    private var cachedLayout: LabelTextLayout?
    private var cachedWidth: CGFloat = -1

    override var attributedText: NSAttributedString? {
        get { super.attributedText }
        set {
            sourceText = newValue
            cachedLayout = nil
            super.attributedText = newValue
        }
    }

    /// 当前宽度下绘制所用的排版。
    var textLayout: LabelTextLayout? { layout(forWidth: bounds.width) }

    private func layout(forWidth width: CGFloat) -> LabelTextLayout? {
        guard let sourceText, sourceText.length > 0, width > 0 else { return nil }
        if let cachedLayout, cachedWidth == width { return cachedLayout }
        let layout = LabelTextLayout(attributedText: sourceText, width: width, font: font, textColor: textColor)
        cachedLayout = layout
        cachedWidth = width
        return layout
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        guard let layout = layout(forWidth: bounds.width) else {
            return super.textRect(forBounds: bounds, limitedToNumberOfLines: numberOfLines)
        }
        let used = layout.usedRect
        return CGRect(x: bounds.minX, y: bounds.minY, width: ceil(used.maxX), height: ceil(used.maxY))
    }

    override func drawText(in rect: CGRect) {
        guard let layout = textLayout else {
            super.drawText(in: rect)
            return
        }
        let glyphRange = layout.layoutManager.glyphRange(for: layout.textContainer)
        layout.layoutManager.drawBackground(forGlyphRange: glyphRange, at: bounds.origin)
        layout.layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: bounds.origin)
    }
}
