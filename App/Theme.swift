import UIKit

/// Day/night color tokens. Dark values per the migration design doc §8
/// (user-approved): background `#14151A` with 3-level layering
/// (nav bar / list / card), accent `#3DDC84`. Light values port the
/// android-chat-pro day palette (chat/src/main/res/values/colors.xml):
/// paper `#F5F7FC` / surface white / fog `#E9EDF6` hairlines, cobalt
/// `#3E64E4` for the outgoing bubble, primary buttons, and selected
/// state, mist `#8B93A7` secondary text, ink `#171A21` primary text.
/// Automatic via `UITraitCollection.userInterfaceStyle` — manual in-app
/// theme switching is explicitly Phase 4 scope ("设置/换肤"), not built here.
public enum Theme {
    public static let backgroundPrimary = dynamicColor(dark: 0x14151A, light: 0xFFFFFF)
    public static let backgroundSecondary = dynamicColor(dark: 0x1B1C22, light: 0xF5F7FC)
    public static let backgroundTertiary = dynamicColor(dark: 0x232430, light: 0xE9EDF6)

    /// Dark: the doc §8 green. Light: Android's cobalt brand blue — the
    /// day palette is cool blue-tinted throughout, so the accent follows.
    public static let accent = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0x3DDC84) : UIColor(hex: 0x3E64E4)
    }

    public static let incomingBubble = dynamicColor(dark: 0x1F212B, light: 0xE9EDF6)
    /// Elevated popup card (e.g. the nav-bar "+" menu) — white in light mode
    /// like WeChat's, one layer above `backgroundSecondary` in dark mode.
    public static let popupCard = dynamicColor(dark: 0x232430, light: 0xFFFFFF)
    public static let textPrimary = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .label : UIColor(hex: 0x171A21)
    }
    /// Secondary text (timestamps, previews, hints) — Android "mist".
    public static let textSecondary = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .secondaryLabel : UIColor(hex: 0x8B93A7)
    }
    /// Hairlines and thin borders — Android "fog"/"line".
    public static let separator = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .separator : UIColor(hex: 0xE9EDF6)
    }
    /// Brand blue (Android "cobalt") — link text and blue icon chips.
    /// Stays system blue in dark mode, where the accent is green.
    public static let link = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemBlue : UIColor(hex: 0x3E64E4)
    }
    /// Link color for text drawn on the accent-colored outgoing bubble.
    /// `link` alone is unusable there in light mode: it resolves to the same
    /// cobalt hex as `accent`, so a link would sit invisible on its own
    /// bubble. Mirrors Android's day-palette send-bubble link tint
    /// (`message_text_link_send_dark` = `#DCE4FF`, colors.xml). Dark mode's
    /// green accent doesn't clash with `link`'s systemBlue, so it's reused.
    public static let linkOnAccent = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemBlue : UIColor(hex: 0xDCE4FF)
    }
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
