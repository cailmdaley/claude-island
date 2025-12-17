//
//  Theme.swift
//  ClaudeIsland
//
//  Theme protocol and implementations for light/dark mode support.
//

import SwiftUI

/// Theme protocol defining all colors used in the app
protocol Theme {
    // Background colors
    var background: Color { get }
    var backgroundElevated: Color { get }
    var backgroundHover: Color { get }

    // Text colors
    var textPrimary: Color { get }
    var textSecondary: Color { get }
    var textDim: Color { get }
    var textDimmer: Color { get }

    // Accent & status colors
    var accent: Color { get }
    var success: Color { get }
    var warning: Color { get }
    var error: Color { get }

    // Code/diff colors
    var codeBackground: Color { get }
    var diffAdded: Color { get }
    var diffRemoved: Color { get }

    // Terminal colors (semantic)
    var terminalGreen: Color { get }
    var terminalAmber: Color { get }
    var terminalRed: Color { get }
    var terminalCyan: Color { get }
    var terminalBlue: Color { get }
    var terminalMagenta: Color { get }
    var terminalPrompt: Color { get }
}

/// Dark theme (current default)
struct DarkTheme: Theme {
    let background = Color.black
    let backgroundElevated = Color.white.opacity(0.05)
    let backgroundHover = Color.white.opacity(0.1)

    let textPrimary = Color.white
    let textSecondary = Color.white.opacity(0.85)
    let textDim = Color.white.opacity(0.4)
    let textDimmer = Color.white.opacity(0.2)

    let accent = Color(red: 0.85, green: 0.47, blue: 0.34)  // Claude orange #d97857
    let success = Color(red: 0.4, green: 0.75, blue: 0.45)
    let warning = Color(red: 1.0, green: 0.7, blue: 0.0)
    let error = Color(red: 1.0, green: 0.3, blue: 0.3)

    let codeBackground = Color.white.opacity(0.08)
    let diffAdded = Color(red: 0.2, green: 0.4, blue: 0.2)
    let diffRemoved = Color(red: 0.4, green: 0.2, blue: 0.2)

    let terminalGreen = Color(red: 0.4, green: 0.75, blue: 0.45)
    let terminalAmber = Color(red: 1.0, green: 0.7, blue: 0.0)
    let terminalRed = Color(red: 1.0, green: 0.3, blue: 0.3)
    let terminalCyan = Color(red: 0.0, green: 0.8, blue: 0.8)
    let terminalBlue = Color(red: 0.4, green: 0.6, blue: 1.0)
    let terminalMagenta = Color(red: 0.8, green: 0.4, blue: 0.8)
    let terminalPrompt = Color(red: 0.85, green: 0.47, blue: 0.34)
}

/// Light theme (Dawnfox-inspired)
/// Based on rosepine dawn: warm, soft colors
struct LightTheme: Theme {
    // Dawnfox palette
    // Background: #faf4ed (warm cream)
    // Foreground: #575279 (muted purple-gray)
    // Accent: #b4637a (rose)

    let background = Color(red: 0.94, green: 0.91, blue: 0.87)  // darker cream
    let backgroundElevated = Color(red: 0.94, green: 0.91, blue: 0.87)  // same as bg for uniformity
    let backgroundHover = Color(red: 0.91, green: 0.88, blue: 0.84)  // very subtle

    let textPrimary = Color(red: 0.34, green: 0.32, blue: 0.47)  // #575279
    let textSecondary = Color(red: 0.34, green: 0.32, blue: 0.47).opacity(0.85)
    let textDim = Color(red: 0.34, green: 0.32, blue: 0.47).opacity(0.5)
    let textDimmer = Color(red: 0.34, green: 0.32, blue: 0.47).opacity(0.3)

    let accent = Color(red: 0.71, green: 0.39, blue: 0.48)  // #b4637a rose
    let success = Color(red: 0.16, green: 0.51, blue: 0.42)  // #286983 pine
    let warning = Color(red: 0.92, green: 0.60, blue: 0.28)  // #ea9d34 gold
    let error = Color(red: 0.71, green: 0.39, blue: 0.48)  // #b4637a rose (same as accent for dawnfox)

    let codeBackground = Color(red: 0.90, green: 0.87, blue: 0.83)
    let diffAdded = Color(red: 0.13, green: 0.45, blue: 0.27)  // dark green for text
    let diffRemoved = Color(red: 0.65, green: 0.20, blue: 0.20)  // dark red for text

    // Terminal colors adjusted for light background
    let terminalGreen = Color(red: 0.16, green: 0.51, blue: 0.42)  // pine
    let terminalAmber = Color(red: 0.92, green: 0.60, blue: 0.28)  // gold
    let terminalRed = Color(red: 0.71, green: 0.39, blue: 0.48)  // rose
    let terminalCyan = Color(red: 0.20, green: 0.54, blue: 0.55)  // foam
    let terminalBlue = Color(red: 0.16, green: 0.51, blue: 0.42)  // pine
    let terminalMagenta = Color(red: 0.56, green: 0.41, blue: 0.62)  // iris
    let terminalPrompt = Color(red: 0.71, green: 0.39, blue: 0.48)  // rose
}

/// Liquid glass theme - translucent with vibrant colors
struct GlassTheme: Theme {
    // Glass uses transparency - actual blur/material effects applied in views
    let background = Color.black.opacity(0.3)  // Light tint
    let backgroundElevated = Color.white.opacity(0.05)  // Very subtle
    let backgroundHover = Color.white.opacity(0.08)  // Slightly more visible

    // Bright, high-contrast text for visibility on glass
    let textPrimary = Color.white
    let textSecondary = Color.white.opacity(0.9)
    let textDim = Color.white.opacity(0.6)
    let textDimmer = Color.white.opacity(0.35)

    // Vibrant accent colors with slight transparency
    let accent = Color(red: 1.0, green: 0.6, blue: 0.4)  // Warm orange
    let success = Color(red: 0.5, green: 1.0, blue: 0.6)  // Bright green
    let warning = Color(red: 1.0, green: 0.85, blue: 0.3)  // Bright yellow
    let error = Color(red: 1.0, green: 0.4, blue: 0.5)  // Bright red-pink

    // Code with subtle tint
    let codeBackground = Color.white.opacity(0.12)
    let diffAdded = Color(red: 0.3, green: 0.6, blue: 0.3)
    let diffRemoved = Color(red: 0.6, green: 0.3, blue: 0.3)

    // Vibrant terminal colors
    let terminalGreen = Color(red: 0.5, green: 1.0, blue: 0.6)
    let terminalAmber = Color(red: 1.0, green: 0.85, blue: 0.3)
    let terminalRed = Color(red: 1.0, green: 0.4, blue: 0.5)
    let terminalCyan = Color(red: 0.4, green: 1.0, blue: 1.0)
    let terminalBlue = Color(red: 0.5, green: 0.7, blue: 1.0)
    let terminalMagenta = Color(red: 1.0, green: 0.5, blue: 1.0)
    let terminalPrompt = Color(red: 1.0, green: 0.6, blue: 0.4)
}
