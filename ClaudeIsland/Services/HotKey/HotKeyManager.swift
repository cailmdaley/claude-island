//
//  HotKeyManager.swift
//  ClaudeIsland
//
//  Manages global hotkey registration using Carbon APIs.
//  Configurable via AppSettings.openHotkey.
//

import Carbon
import Foundation

/// Manages global hotkey for opening the Island
class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var openHandler: (() -> Void)?
    private var currentHotkey: OpenHotkey?

    private init() {}

    /// Set up the global hotkey using current setting
    func setup(openHandler: @escaping () -> Void) {
        self.openHandler = openHandler

        // Register the event handler (only once)
        if eventHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { (_, event, userData) -> OSStatus in
                    guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                    manager.handleHotKey()
                    return noErr
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandler
            )

            guard status == noErr else {
                print("[HotKeyManager] Failed to install event handler: \(status)")
                return
            }
        }

        // Register hotkey from settings
        registerHotkey(AppSettings.openHotkey)
    }

    /// Re-register with a new hotkey
    func reregister(hotkey: OpenHotkey) {
        unregisterHotkey()
        registerHotkey(hotkey)
    }

    private func registerHotkey(_ hotkey: OpenHotkey) {
        var hotKeyID = EventHotKeyID(signature: OSType(0x434C4953), id: 1) // "CLIS" signature

        let registerStatus = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus == noErr {
            currentHotkey = hotkey
            print("[HotKeyManager] Registered \(hotkey.displayName) hotkey")
        } else {
            print("[HotKeyManager] Failed to register hotkey: \(registerStatus)")
        }
    }

    private func unregisterHotkey() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
            if let current = currentHotkey {
                print("[HotKeyManager] Unregistered \(current.displayName) hotkey")
            }
            currentHotkey = nil
        }
    }

    /// Tear down the hotkey
    func teardown() {
        unregisterHotkey()

        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }

        openHandler = nil
        print("[HotKeyManager] Hotkey manager torn down")
    }

    private func handleHotKey() {
        DispatchQueue.main.async { [weak self] in
            self?.openHandler?()
        }
    }
}
