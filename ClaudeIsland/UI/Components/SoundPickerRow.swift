//
//  SoundPickerRow.swift
//  ClaudeIsland
//
//  Notification sound selection picker for settings menu
//

import AppKit
import SwiftUI

struct SoundPickerRow: View {
    @ObservedObject var soundSelector: SoundSelector
    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var selectedSound: NotificationSound = AppSettings.notificationSound

    private var isExpanded: Bool {
        soundSelector.isPickerExpanded
    }

    private func setExpanded(_ value: Bool) {
        soundSelector.isPickerExpanded = value
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main row - shows current selection
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    setExpanded(!isExpanded)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text("Notification Sound")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    Text(selectedSound.rawValue)
                        .font(.system(size: 11))
                        .foregroundColor(theme.textDim)
                        .lineLimit(1)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(theme.textDim)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? theme.backgroundHover : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            // Expanded sound list
            if isExpanded {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(NotificationSound.allCases, id: \.self) { sound in
                            SoundOptionRowInline(
                                sound: sound,
                                isSelected: selectedSound == sound
                            ) {
                                // Play preview sound
                                if let soundName = sound.soundName {
                                    NSSound(named: soundName)?.play()
                                }
                                selectedSound = sound
                                AppSettings.notificationSound = sound
                            }
                        }
                    }
                }
                .frame(maxHeight: CGFloat(min(NotificationSound.allCases.count, 6)) * 32)
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
        .onAppear {
            selectedSound = AppSettings.notificationSound
        }
    }

    private var textColor: Color {
        isHovered ? theme.textPrimary : theme.textSecondary
    }
}

// MARK: - Sound Option Row (Inline version)

private struct SoundOptionRowInline: View {
    let sound: NotificationSound
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? theme.terminalGreen : theme.textDimmer)
                    .frame(width: 6, height: 6)

                Text(sound.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isHovered ? theme.textPrimary : theme.textSecondary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.terminalGreen)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? theme.backgroundHover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
