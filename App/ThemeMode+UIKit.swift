// App/ThemeMode+UIKit.swift
import UIKit
import AppCore

extension ThemeMode {
    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return .unspecified
        }
    }
}
