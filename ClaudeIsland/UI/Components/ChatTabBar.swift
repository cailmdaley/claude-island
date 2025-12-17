//
//  ChatTabBar.swift
//  ClaudeIsland
//
//  Tab bar for navigating between chat sessions
//

import SwiftUI

struct ChatTabBar: View {
    let sessions: [SessionState]
    let currentSessionId: String
    let onSelect: (SessionState) -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var themeManager = ThemeManager.shared

    private var isGlass: Bool {
        themeManager.preference == .glass
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(sessions) { session in
                ChatTabItem(
                    title: session.displayTitle,
                    isActive: session.sessionId == currentSessionId,
                    isGlass: isGlass,
                    onTap: { onSelect(session) }
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// MARK: - Tab Item

private struct ChatTabItem: View {
    let title: String
    let isActive: Bool
    let isGlass: Bool
    let onTap: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            Text(title)
                .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                .foregroundColor(isActive ? theme.textPrimary : theme.textDim)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(tabBackground)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.2), value: isActive)
    }

    @ViewBuilder
    private var tabBackground: some View {
        if isActive {
            if isGlass {
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                    .glassEffect(.regular, in: Capsule())
            } else {
                Capsule()
                    .fill(theme.backgroundHover)
            }
        } else if isHovered {
            Capsule()
                .fill(theme.backgroundElevated)
        }
    }
}
