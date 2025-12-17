//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import Carbon
import Foundation

/// Available hotkeys for opening/closing the island
enum OpenHotkey: String, CaseIterable {
    case ctrlSpace = "⌃Space"
    case cmdSection = "⌘§"
    case cmdBacktick = "⌘`"
    case optionSpace = "⌥Space"

    var displayName: String { rawValue }

    /// Carbon key code
    var keyCode: UInt32 {
        switch self {
        case .ctrlSpace: return 0x31       // Space key
        case .cmdSection: return 0x0A      // § key
        case .cmdBacktick: return 0x32     // ` key
        case .optionSpace: return 0x31     // Space key
        }
    }

    /// Carbon modifier flags
    var modifiers: UInt32 {
        switch self {
        case .ctrlSpace: return UInt32(controlKey)
        case .cmdSection: return UInt32(cmdKey)
        case .cmdBacktick: return UInt32(cmdKey)
        case .optionSpace: return UInt32(optionKey)
        }
    }
}

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let chatViewExpanded = "chatViewExpanded"
        static let openHotkey = "openHotkey"
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    // MARK: - Chat View Expanded

    /// Whether chat view is expanded to full screen (default false = half screen)
    static var chatViewExpanded: Bool {
        get {
            defaults.bool(forKey: Keys.chatViewExpanded)
        }
        set {
            defaults.set(newValue, forKey: Keys.chatViewExpanded)
        }
    }

    // MARK: - Open Hotkey

    /// Global hotkey for opening/closing the island
    static var openHotkey: OpenHotkey {
        get {
            guard let rawValue = defaults.string(forKey: Keys.openHotkey),
                  let hotkey = OpenHotkey(rawValue: rawValue) else {
                return .ctrlSpace // Default
            }
            return hotkey
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.openHotkey)
        }
    }
}
