# 文本消息 Markdown 显示设计

日期:2026-07-02
状态:定稿(用户暂离,按推荐默认项推进,可事后调整)

## 背景与目标

「系统通知」等会话中的长文本消息(如纳斯达克日报)以 Markdown 源码形态展示:`**粗体**`、`# 标题`、`|表格|`、`---` 等符号原样可见,阅读体验差。目标:文本消息在**聊天气泡(折叠预览)**与**「查看全文」页**中渲染 Markdown 富文本。

前置:长文本折叠已实现(`LongTextPreview`,600 字符阈值),本设计在其之上渲染。

## 方案选型

| 方案 | 结论 |
|---|---|
| A. 系统 `AttributedString(markdown:)` + 自研按行块级扫描 | **采用**。零依赖,iOS 15/macOS 12 可用 |
| B. 第三方库(Down / swift-markdown-ui) | 弃。引入依赖;swift-markdown-ui 是 SwiftUI |
| C. WKWebView 渲染 HTML | 弃。气泡内每行一个 WebView 性能不可行 |

**为什么不用系统解析器的 `.full` 模式:** 聊天消息把单个换行当硬换行,而 `.full` 按标准 Markdown 语义把段落内单换行合并成空格,消息会被"挤成一行"。因此:

- **块级结构自己按行扫描**(标题 `#`、无序列表 `-`/`*`、有序列表 `1.`、引用 `>`、围栏代码块 ```` ``` ````、分隔线 `---`),每行一个块,换行逐行保留;
- **行内语法交给系统解析**:每行用 `AttributedString(markdown:options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))` 解析粗体/斜体/行内代码/删除线/链接。

## 架构(依赖方向:App → IMKit)

### IMKit:`MarkdownMessage.swift`(平台无关,swift test 可覆盖)

```swift
public struct MarkdownSpan: Equatable {
    public let text: String
    public let isBold, isItalic, isCode, isStrikethrough: Bool
    public let linkURL: URL?
}

public enum MarkdownBlock: Equatable {
    case heading(level: Int, spans: [MarkdownSpan])   // level 1...6
    case bullet(spans: [MarkdownSpan])
    case ordered(number: Int, spans: [MarkdownSpan])
    case quote(spans: [MarkdownSpan])
    case codeBlock(String)                            // 围栏内原样多行
    case divider                                      // --- / ***
    case paragraph(spans: [MarkdownSpan])             // 普通行;空行 = 空 spans
}

public enum MarkdownMessage {
    public static func parse(_ text: String) -> [MarkdownBlock]
}
```

规则:
- 逐行扫描;每个源码行产出一个块,渲染时块间以换行连接 → 原始换行结构完整保留。
- 行内解析失败(非法语法)→ 该行降级为纯文本 span。
- **表格行(`|` 开头)不解析**,原样保留为 paragraph——NSAttributedString 无法合理渲染表格,降级最稳妥。
- 代码围栏 ```` ``` ```` 开/闭之间的行原样收进 `codeBlock`;未闭合的围栏视为闭合到文末。

### App:`MarkdownRenderer.swift`(UIKit)

```swift
enum MarkdownRenderer {
    static func render(_ text: String, textColor: UIColor, baseFontSize: CGFloat = 16) -> NSAttributedString
}
```

- 样式映射:标题 1/2/3 级 → 加粗 22/20/18pt(4-6 级 → 加粗 16pt);列表加 "• " / "n. " 前缀;引用 → 60% 透明度;代码(行内与块)→ 等宽 13pt;分隔线 → "───" 40% 透明度;粗体/斜体/删除线/链接为标准 attribute。
- 链接:加 `.link` attribute——全文页(UITextView)可点击跳转,气泡(UILabel)仅显示样式,不可点(接受)。
- **缓存**:`NSCache<NSString, NSAttributedString>`,key = `"\(fontSize)|\(textColor hash)|\(text)"`,滚动复用零重复解析。

### 接入点

- `TextMessageCell.configure`:`messageTextLabel.attributedText = MarkdownRenderer.render(折叠预览文本, ...)`,进出方向传各自文字色。
- `TextPreviewViewController`:整篇渲染进 UITextView(懒排版,长文一次解析可接受)。

## 性能

气泡内只解析折叠后 ≤600 字符(单次远小于 1ms 量级)+ NSCache 命中后零成本;与长文本折叠修复(ea8e00c)叠加后滚动无额外压力。

## 折叠截断与 Markdown 的交互

`LongTextPreview` 在 600 字符处截断可能切断语法(如 `**粗` 或代码围栏未闭合)。逐行解析天然限制影响范围:最多最后一行行内样式丢失/围栏降级,不会破坏整体渲染。接受,不做语法感知截断。

## 测试

`Tests/IMKitTests/MarkdownMessageTests.swift`(SPM,macOS 可跑):
- 纯文本(含多行/空行)原样 passthrough;
- 粗体/斜体/行内代码/删除线/链接 span 解析;
- 标题各级、无序/有序列表、引用、分隔线;
- 围栏代码块(闭合与未闭合);
- 表格行降级为原样 paragraph。

App 层渲染由使用者真机验证(项目约定)。
