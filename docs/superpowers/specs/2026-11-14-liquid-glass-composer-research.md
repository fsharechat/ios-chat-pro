# 消息发送面板 Liquid Glass 官方资料核实

日期：2026-11-14。用途：为输入栏重构提供材质、API 与兼容性依据；具体尺寸和交互由设计方案决定。

## 1. 原生 API 与工具链

- `UIGlassEffect`、`UIGlassContainerEffect` 均从 iOS / iPadOS 26.0 开始提供。前者继承 `UIVisualEffect`，可交给 `UIVisualEffectView`；提供 `init(style:)`、`isInteractive` 和 `tintColor`。[UIGlassEffect](https://developer.apple.com/documentation/uikit/uiglasseffect)、[UIGlassContainerEffect](https://developer.apple.com/documentation/uikit/uiglasscontainereffect)
- 容器将其 `contentView` 内多个玻璃效果视图组合渲染，`spacing` 决定元素接近到多大距离开始融合。它适合在同一控制层协调“加号圆钮 + 输入胶囊”，不意味着要给全部子按钮再铺一层玻璃。[容器 API](https://developer.apple.com/documentation/uikit/uiglasscontainereffect)
- Apple 的 UIKit 示例通过设置 `effect` 使玻璃出现或消失，通过 `isInteractive = true` 启用触摸反馈；内容放入效果视图的 `contentView`。默认形状为胶囊，新 `cornerConfiguration` 用于自定义形状。[WWDC25：Build a UIKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/284/)
- Xcode 26 包含 iOS 26 SDK，运行要求至少 macOS Sequoia 15.6。仓库 `CLAUDE.md` 记载当前机器为 macOS 13.7 + Xcode 15.2，因此当前本机工具链无法直接构建原生 Liquid Glass 分支；此结论来自官方要求与仓库环境记录的对照。[Xcode 系统要求](https://developer.apple.com/xcode/system-requirements/)、[Xcode 26 发布说明](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)
- `if #available(iOS 26, *)` 是运行时可用性检查，不能为旧 SDK 补充未知的类型声明。工程应在支持 iOS 26 SDK 的构建环境验证原生实现；保留旧工具链时，以构建条件隔离新 API 源码，再在新 SDK 分支做运行时检查。仅写 `#available` 不足以让 Xcode 15.2 识别 `UIGlassEffect`；这是 Swift 编译规则在本工程中的推论。[Swift 条件编译与可用性条件](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/statements/)

## 2. 材质选择

- Liquid Glass 用于浮在内容上方的控制与导航层；消息内容区域保留标准材质。Apple 建议克制使用自定义玻璃效果。[HIG：Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- `regular` 是聊天输入栏的推荐选择：HIG 将 `clear` 限于视觉丰富的背景。聊天主要包含文字，设计应优先保证输入文字、占位符和按钮对比度，而非追求最大透明度。后半句是面向本项目的设计判断。[HIG：Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- 避免玻璃叠玻璃；输入胶囊内的表情、发送控件可作为同一材质上的内容。Apple 同时要求避免在稳态让重要内容与玻璃相互交叠，因此最后一条消息应有足够底部滚动空间。[WWDC25：Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)

## 3. 无障碍与动画

- 原生材质会响应系统设置：减少透明度使材质更磨砂；增强对比度强化黑白与边界；减少动态效果降低视觉动态并关闭弹性属性。自定义模拟方案必须自行处理对应状态。[WWDC25：Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)
- Apple 明确要求检查自定义元素、颜色、动画在不同透明度和动态设置下的表现，因此应覆盖浅色 / 深色、减少透明度、增强对比度、减少动态效果，并保持输入与发送可操作。[Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)

## 4. 面向本工程的建议（设计判断）

1. 当前 Xcode 15.2 路径采用 `UIBlurEffect` 的磨砂兼容实现，保留悬浮胶囊、层次与交互；明确称为兼容玻璃效果，不能声称具备系统原生折射和融合。
2. 以独立材质适配层承接未来 Xcode 26+ 原生 `UIGlassEffect(.regular)` 实现，业务输入状态不依赖材质类型。
3. 首期无需自绘实时折射、截图采样或每帧重建背景；优先输入可读性、滚动性能和键盘连续性。
4. 用户提供的 Apple 截图是视觉参照。微信的按住说话、表情 / 键盘切换、加号功能盘可作为熟悉的交互参照；本笔记未核实微信当前版本的官方布局规范，不将具体尺寸、手势阈值或动画参数归于微信官方。
