// App/TextSelectionController.swift
import UIKit

/// 微信式消息选字：长按后全选，高亮铺在文字下面，首尾两个绿色圆点手柄拖动调整选区。
///
/// UILabel 本身不能选字，这里按 label 的 attributedText / bounds 自己搭一套 TextKit
/// 排版来做「坐标 ↔ 字符位置」换算——与 `TextMessageCell.link(at:)` 同一套假设：
/// 文字从 label 左上角开始排、不缩放。
final class TextSelectionController: NSObject, UIGestureRecognizerDelegate {
    private weak var label: UILabel?
    /// 手柄挂在这个视图上（cell 的 contentView），高亮层插在 label 的父视图里、label 之下。
    private weak var handleHost: UIView?
    private let highlightLayer = CAShapeLayer()
    private let startHandle = SelectionHandleView(isStart: true)
    private let endHandle = SelectionHandleView(isStart: false)

    private var layout: LabelTextLayout?
    private(set) var selectedRange: NSRange?
    /// 拖动开始时「手指 → 手柄所指那一行中线」的偏移，拖动中保持不变，
    /// 免得按在圆点上（行的下方）时一碰就跳到下一行。
    private var dragTouchOffset: CGPoint = .zero

    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    var isActive: Bool { selectedRange != nil }

    var isFullySelected: Bool {
        guard let selectedRange, let layout else { return false }
        return selectedRange.location == 0 && selectedRange.length == layout.length
    }

    /// 选中的显示文字。表格等以图片附件渲染的内容只占一个 U+FFFC 占位符，复制时去掉。
    var selectedText: String? {
        guard let selectedRange, let layout else { return nil }
        return layout.textStorage.attributedSubstring(from: selectedRange).string
            .replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    init(label: UILabel, handleHost: UIView) {
        self.label = label
        self.handleHost = handleHost
        super.init()
        highlightLayer.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        for handle in [startHandle, endHandle] {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePanned(_:)))
            pan.delegate = self
            handle.addGestureRecognizer(pan)
        }
    }

    /// 全选并显示高亮与手柄；文字为空时返回 false。
    @discardableResult
    func selectAll(highlightColor: UIColor, handleColor: UIColor) -> Bool {
        guard let label, let handleHost, let layout = LabelTextLayout(label: label), layout.length > 0 else { return false }
        self.layout = layout
        selectedRange = NSRange(location: 0, length: layout.length)
        highlightLayer.fillColor = highlightColor.cgColor
        startHandle.color = handleColor
        endHandle.color = handleColor
        label.superview?.layer.insertSublayer(highlightLayer, below: label.layer)
        handleHost.addSubview(startHandle)
        handleHost.addSubview(endHandle)
        refresh()
        return true
    }

    func clear() {
        selectedRange = nil
        layout = nil
        highlightLayer.removeFromSuperlayer()
        startHandle.removeFromSuperview()
        endHandle.removeFromSuperview()
    }

    /// label 尺寸可能随布局变化（如转屏），重新排版并刷新高亮与手柄位置。
    func layoutDidChange() {
        guard isActive, let label, let newLayout = LabelTextLayout(label: label), newLayout.length == layout?.length else { return }
        layout = newLayout
        refresh()
    }

    /// 命中手柄（含扩大后的触摸区）时返回该手柄；`point` 为 handleHost 坐标。
    func handle(at point: CGPoint) -> UIView? {
        guard isActive, let handleHost else { return nil }
        for handle in [endHandle, startHandle] where handle.superview === handleHost && handle.frame.contains(point) {
            return handle
        }
        return nil
    }

    /// 选区外接矩形（转换到 `view` 坐标），用来锚定菜单。
    func selectionBounds(in view: UIView) -> CGRect? {
        guard isActive, let label, let path = highlightLayer.path, !path.isEmpty else { return nil }
        return label.convert(path.boundingBoxOfPath, to: view)
    }

    private func refresh() {
        guard let label, let handleHost, let layout, let selectedRange else { return }
        highlightLayer.frame = label.frame
        highlightLayer.path = layout.selectionPath(for: selectedRange).cgPath

        let startCaret = label.convert(layout.caretRect(at: selectedRange.location, atRangeEnd: false), to: handleHost)
        let endCaret = label.convert(layout.caretRect(at: NSMaxRange(selectedRange), atRangeEnd: true), to: handleHost)
        startHandle.place(at: startCaret)
        endHandle.place(at: endCaret)
    }

    @objc private func handlePanned(_ recognizer: UIPanGestureRecognizer) {
        guard let label, let layout, let range = selectedRange,
              let handle = recognizer.view as? SelectionHandleView else { return }
        let touch = recognizer.location(in: label)
        switch recognizer.state {
        case .began:
            let index = handle.isStart ? range.location : NSMaxRange(range)
            let caret = layout.caretRect(at: index, atRangeEnd: !handle.isStart)
            dragTouchOffset = CGPoint(x: caret.midX - touch.x, y: caret.midY - touch.y)
            onDragBegan?()
        case .changed:
            let target = CGPoint(x: touch.x + dragTouchOffset.x, y: touch.y + dragTouchOffset.y)
            let index = layout.insertionIndex(at: target)
            var start = range.location
            var end = NSMaxRange(range)
            // 两个手柄不交叉，选区至少保留一个完整字符（含 emoji 等组合字符）。
            if handle.isStart {
                start = index < end ? index : layout.composedRange(at: end - 1).location
            } else {
                end = index > start ? index : NSMaxRange(layout.composedRange(at: start))
            }
            let newRange = NSRange(location: start, length: end - start)
            guard newRange != range else { return }
            selectedRange = newRange
            refresh()
        case .ended, .cancelled, .failed:
            onDragEnded?()
        default:
            break
        }
    }

    /// 拖手柄时列表的滚动、长按等手势都要等手柄的 pan 失败才生效。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

/// 选区手柄：一个绿色圆点，挂在光标所在行的下方；视图本身是 44pt 的触摸热区。
final class SelectionHandleView: UIView {
    let isStart: Bool
    private let knob = UIView()
    private static let knobDiameter: CGFloat = 14
    private static let touchSize: CGFloat = 44

    var color: UIColor = .systemGreen {
        didSet { knob.backgroundColor = color }
    }

    init(isStart: Bool) {
        self.isStart = isStart
        super.init(frame: CGRect(x: 0, y: 0, width: Self.touchSize, height: Self.touchSize))
        backgroundColor = .clear
        knob.frame = CGRect(
            x: (Self.touchSize - Self.knobDiameter) / 2,
            y: (Self.touchSize - Self.knobDiameter) / 2,
            width: Self.knobDiameter,
            height: Self.knobDiameter
        )
        knob.layer.cornerRadius = Self.knobDiameter / 2
        knob.isUserInteractionEnabled = false
        addSubview(knob)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 圆点挂在光标底部：起点手柄偏左、终点手柄偏右，各自朝选区外侧。
    func place(at caret: CGRect) {
        let offsetX = Self.knobDiameter / 2 - 3
        center = CGPoint(
            x: isStart ? caret.minX - offsetX : caret.maxX + offsetX,
            y: caret.maxY + Self.knobDiameter / 2 - 4
        )
    }
}

/// 一份 TextKit 1 排版。气泡文字（`TextKitLabel`）用它绘制，选字、链接命中也用它换算，
/// 显示与换算同源，才不会出现「高亮停在倒数第二行」这类偏差。
struct LabelTextLayout {
    let textStorage: NSTextStorage
    let layoutManager: NSLayoutManager
    let textContainer: NSTextContainer

    var length: Int { textStorage.length }

    /// 文字实际占用的区域（容器坐标，原点即 label 左上角）。
    var usedRect: CGRect { layoutManager.usedRect(for: textContainer) }

    /// `TextKitLabel` 直接取它绘制时用的那份排版；普通 UILabel 只能按同样的参数另排一份（可能有细微偏差）。
    init?(label: UILabel) {
        if let textKitLabel = label as? TextKitLabel {
            guard let layout = textKitLabel.textLayout else { return nil }
            self = layout
            return
        }
        guard let attributedText = label.attributedText, label.bounds.width > 0 else { return nil }
        self.init(attributedText: attributedText, width: label.bounds.width, font: label.font, textColor: label.textColor)
    }

    init(attributedText: NSAttributedString, width: CGFloat, font: UIFont?, textColor: UIColor?) {
        let storage = NSTextStorage(attributedString: attributedText)
        // 没带字体/颜色的片段（如 MarkdownRenderer 在块之间插的 "\n"），UILabel 按 label.font
        // 排；TextKit 会退回 12pt Helvetica，空行就矮一截。补成 label 的字体与颜色。
        let fullRange = NSRange(location: 0, length: storage.length)
        if let font {
            storage.enumerateAttribute(.font, in: fullRange) { value, range, _ in
                if value == nil { storage.addAttribute(.font, value: font, range: range) }
            }
        }
        if let textColor {
            storage.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
                if value == nil { storage.addAttribute(.foregroundColor, value: textColor, range: range) }
            }
        }
        textStorage = storage
        layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        // 只限宽、不限高，高度由排版结果决定（label 的高度也取自这里）。
        textContainer = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byWordWrapping
        textContainer.maximumNumberOfLines = 0
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)
    }

    func composedRange(at index: Int) -> NSRange {
        (textStorage.string as NSString).rangeOfComposedCharacterSequence(at: min(max(index, 0), length - 1))
    }

    /// 离 `point` 最近的插入位置（0...length），落在组合字符边界上。
    func insertionIndex(at point: CGPoint) -> Int {
        let used = layoutManager.usedRect(for: textContainer)
        // 手指拖出文字区域上下方时，按首行/末行处理。
        let clamped = CGPoint(x: point.x, y: min(max(point.y, used.minY + 1), used.maxY - 1))
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(for: clamped, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
        let insertion = min(fraction > 0.5 ? index + 1 : index, length)
        guard insertion < length else { return insertion }
        let composed = composedRange(at: insertion)
        return composed.location == insertion ? insertion : NSMaxRange(composed)
    }

    /// 插入位置处的光标矩形（label 坐标，零宽，高度为所在行）。选区终点取前一个字符的右边缘，
    /// 这样折行处的终点停在上一行行尾，而不是下一行行首。
    func caretRect(at index: Int, atRangeEnd: Bool) -> CGRect {
        let charIndex = atRangeEnd ? max(index - 1, 0) : min(index, length - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
        let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        let x = atRangeEnd ? glyphRect.maxX : glyphRect.minX
        return CGRect(x: x, y: lineRect.minY, width: 0, height: lineRect.height)
    }

    /// 选区每一行一个矩形，拼成高亮路径（label 坐标）。
    func selectionPath(for range: NSRange) -> UIBezierPath {
        let path = UIBezierPath()
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer
        ) { rect, _ in
            path.append(UIBezierPath(rect: rect))
        }
        return path
    }
}
