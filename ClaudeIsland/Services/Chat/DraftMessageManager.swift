//
//  DraftMessageManager.swift
//  ClaudeIsland
//
//  Manages draft message text per session
//

import Foundation
import Combine

/// Manages draft message text for chat inputs, persisting across session switches
@MainActor
final class DraftMessageManager: ObservableObject {
    static let shared = DraftMessageManager()

    /// Draft text per session ID
    private var drafts: [String: String] = [:]

    private init() {}

    /// Get draft text for a session
    func getDraft(for sessionId: String) -> String {
        drafts[sessionId] ?? ""
    }

    /// Save draft text for a session
    func saveDraft(_ text: String, for sessionId: String) {
        if text.isEmpty {
            drafts.removeValue(forKey: sessionId)
        } else {
            drafts[sessionId] = text
        }
    }

    /// Clear draft for a session (called when message is sent)
    func clearDraft(for sessionId: String) {
        drafts.removeValue(forKey: sessionId)
    }
}
