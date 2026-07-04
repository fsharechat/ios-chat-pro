import CoreGraphics

/// 图片/视频消息气泡按原图宽高比算展示尺寸——对齐微信风格：不再固定
/// 正方形,而是在 [min, max] 区间内保持原图比例。缩略图 Data decode 出的
/// UIImage.size 即为"原图宽高比"来源(缩略图本身就是原图等比缩放生成的
/// JPEG,比例可信),App 层负责 decode,这里只做纯几何计算,不依赖 UIKit
/// 以便在 macOS 上 `swift test`。
public enum ImageBubbleSizing {
    public static let maxWidth: CGFloat = 200
    public static let maxHeight: CGFloat = 200
    public static let minWidth: CGFloat = 80
    public static let minHeight: CGFloat = 80

    /// 无法得知原图尺寸(decode 失败)时的回退尺寸,与本次改动前的固定气泡
    /// 尺寸一致,避免行为断崖式变化。
    public static let fallbackSize = CGSize(width: 160, height: 160)

    /// 1. 若原图超出 maxWidth×maxHeight 的框,等比缩小到刚好落入框内;在框内的
    ///    图片不做处理(不会为了"填满气泡"而人为放大,避免模糊);
    /// 2. 若结果任一边小于对应下限,等比放大补足下限;
    /// 3. 最后把两边分别夹到 [min, max] 区间内 —— 步骤 2 的放大在极端长宽比
    ///    下可能使另一边超出上限,这里做最终安全夹紧(常规照片/截图的宽高比
    ///    不会触发这个边界,只有极端长图/窄图才会牺牲一点精确比例)。
    public static func displaySize(forNaturalSize naturalSize: CGSize) -> CGSize {
        guard naturalSize.width > 0, naturalSize.height > 0 else {
            return fallbackSize
        }

        // `, 1` 封顶:只允许缩小,不允许这一步把小图强行放大去填满 max 框。
        let fitScale = min(maxWidth / naturalSize.width, maxHeight / naturalSize.height, 1)
        var width = naturalSize.width * fitScale
        var height = naturalSize.height * fitScale

        let growScale = max(minWidth / width, minHeight / height, 1)
        width *= growScale
        height *= growScale

        width = min(max(width, minWidth), maxWidth)
        height = min(max(height, minHeight), maxHeight)

        return CGSize(width: width, height: height)
    }
}
