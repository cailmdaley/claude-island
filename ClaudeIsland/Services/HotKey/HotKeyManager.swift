//
//  HotKeyManager.swift
//  ClaudeIsland
//
//  Manages global hotkey registration using Carbon APIs.
//  Registers CMD+§ to open the Island.
//

import Carbon
import Foundation

/// Manages global hotkey for opening the Island
class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var openHandler: (() -> Void)?

    // § key (section sign) = keycode 0x0A (10)
    private let sectionKeyCode: UInt32 = 0x0A

    private init() {}

    /// Set up the global hotkey (CMD+§)
    func setup(openHandler: @escaping () -> Void) {
        self.openHandler = openHandler

        // Register the event handler
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

        // Register CMD+§ hotkey
        var hotKeyID = EventHotKeyID(signature: OSType(0x434C4953), id: 1) // "CLIS" signature
        let modifiers: UInt32 = UInt32(cmdKey)

        let registerStatus = RegisterEventHotKey(
            sectionKeyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus == noErr {
            print("[HotKeyManager] Registered CMD+§ hotkey")
        } else {
            print("[HotKeyManager] Failed to register hotkey: \(registerStatus)")
        }
    }

    /// Tear down the hotkey
    func teardown() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }

        openHandler = nil
        print("[HotKeyManager] Hotkey unregistered")
    }

    private func handleHotKey() {
        DispatchQueue.main.async { [weak self] in
            self?.openHandler?()
        }
    }
}
