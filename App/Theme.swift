import UIKit

/// Day/night color tokens per the migration design doc §8 (already
/// user-approved): dark background `#14151A` with 3-level layering
/// (nav bar / list / card), accent `#3DDC84` used only for unread badges,
/// the outgoing message bubble, primary buttons, and selected state.
/// Automatic via `UITraitCollection.userInterfaceStyle` — manual in-app
/// theme switching is explicitly Phase 4 scope ("设置/换肤"), not built here.
public enum Theme {
    public static let backgroundPrimary = dynamicColor(dark: 0x14151A, light: 0xFFFFFF)
    public static let backgroundSecondary = dynamicColor(dark: 0x1B1C22, light: 0xF5F5F7)
    public static let backgroundTertiary = dynamicColor(dark: 0x232430, light: 0xEAEAEC)

    /// Same hue in both themes; lower saturation / higher brightness in
    /// light mode so it doesn't read as garishly bright on a white
    /// background (per design doc §8's explicit note on this).
    public static let accent = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0x3DDC84) : UIColor(hex: 0x1FAE63)
    }

    public static let incomingBubble = dynamicColor(dark: 0x1F212B, light: 0xF0F0F2)
    public static let textPrimary = UIColor.label
    public static let textOnAccent = UIColor { traits in traits.userInterfaceStyle == .dark ? .black : .white }

    public static let bubbleCornerRadius: CGFloat = 14
    public static let cardCornerRadius: CGFloat = 12
    public static let standardSpacing: CGFloat = 12

    private static func dynamicColor(dark: UInt32, light: UInt32) -> UIColor {
        UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
