//
//  ThemeManager.swift
//  ClaudeIsland
//
//  Manages theme selection and persistence.
//

import Combine
import SwiftUI

/// User's theme preference
enum ThemePreference: String, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Manages the current theme based on user preference and system settings
@MainActor
class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @AppStorage("themePreference") private var preferenceRaw: String = ThemePreference.dark.rawValue

    @Published private(set) var currentTheme: any Theme = DarkTheme()

    var preference: ThemePreference {
        get { ThemePreference(rawValue: preferenceRaw) ?? .dark }
        set {
            preferenceRaw = newValue.rawValue
            updateTheme()
        }
    }

    private init() {
        updateTheme()
        // Observe system appearance changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: NSApplication.didChangeOcclusionStateNotification,
            object: nil
        )
    }

    @objc private func systemAppearanceChanged() {
        if preference == .system {
            updateTheme()
        }
    }

    private func updateTheme() {
        switch preference {
        case .system:
            let isDark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            currentTheme = isDark ? DarkTheme() : LightTheme()
        case .light:
            currentTheme = LightTheme()
        case .dark:
            currentTheme = DarkTheme()
        }
    }
}

/// Environment key for accessing the current theme
struct ThemeKey: EnvironmentKey {
    static let defaultValue: any Theme = DarkTheme()
}

extension EnvironmentValues {
    var theme: any Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
