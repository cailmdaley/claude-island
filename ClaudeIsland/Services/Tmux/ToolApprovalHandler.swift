//
//  ToolApprovalHandler.swift
//  ClaudeIsland
//
//  Handles Claude tool approval operations via tmux
//  Supports both local and remote (SSH) sessions
//

import Foundation
import os.log

/// Handles tool approval and rejection for Claude instances
actor ToolApprovalHandler {
    static let shared = ToolApprovalHandler()

    /// Logger for tool approval (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.claudeisland", category: "Approval")

    private init() {}

    // MARK: - Local Session Methods (existing API)

    /// Approve a tool once (sends '1' + Enter)
    func approveOnce(target: TmuxTarget) async -> Bool {
        await sendKeys(to: target.targetString, keys: "1", pressEnter: true, remoteHost: nil)
    }

    /// Approve a tool always (sends '2' + Enter)
    func approveAlways(target: TmuxTarget) async -> Bool {
        await sendKeys(to: target.targetString, keys: "2", pressEnter: true, remoteHost: nil)
    }

    /// Reject a tool with optional message
    /// Claude Code uses "3" to select the deny/feedback option, then message + Enter
    func reject(target: TmuxTarget, message: String? = nil) async -> Bool {
        // Select deny option (option 3 in Claude's permission prompt)
        guard await sendKeys(to: target.targetString, keys: "3", pressEnter: false, remoteHost: nil) else {
            return false
        }

        // Small delay for UI to respond
        try? await Task.sleep(for: .milliseconds(100))

        // Send the message (or empty) and Enter to confirm denial
        let msg = message ?? ""
        return await sendKeys(to: target.targetString, keys: msg, pressEnter: true, remoteHost: nil)
    }

    /// Send a message to a tmux target
    func sendMessage(_ message: String, to target: TmuxTarget) async -> Bool {
        await sendKeys(to: target.targetString, keys: message, pressEnter: true, remoteHost: nil)
    }

    // MARK: - Remote Session Methods

    /// Approve a tool once for a remote session
    func approveOnce(remoteTmuxTarget: String, remoteHost: String) async -> Bool {
        await sendKeys(to: remoteTmuxTarget, keys: "1", pressEnter: true, remoteHost: remoteHost)
    }

    /// Approve a tool always for a remote session
    func approveAlways(remoteTmuxTarget: String, remoteHost: String) async -> Bool {
        await sendKeys(to: remoteTmuxTarget, keys: "2", pressEnter: true, remoteHost: remoteHost)
    }

    /// Reject a tool for a remote session with optional message
    /// Claude Code uses "3" to select the deny/feedback option, then message + Enter
    func reject(remoteTmuxTarget: String, remoteHost: String, message: String? = nil) async -> Bool {
        // Select deny option (option 3 in Claude's permission prompt)
        guard await sendKeys(to: remoteTmuxTarget, keys: "3", pressEnter: false, remoteHost: remoteHost) else {
            return false
        }

        // Small delay for UI to respond
        try? await Task.sleep(for: .milliseconds(100))

        // Send the message (or empty) and Enter to confirm denial
        let msg = message ?? ""
        return await sendKeys(to: remoteTmuxTarget, keys: msg, pressEnter: true, remoteHost: remoteHost)
    }

    /// Send a message to a remote tmux target
    func sendMessage(_ message: String, remoteTmuxTarget: String, remoteHost: String) async -> Bool {
        await sendKeys(to: remoteTmuxTarget, keys: message, pressEnter: true, remoteHost: remoteHost)
    }

    // MARK: - Private Methods

    private func sendKeys(to targetStr: String, keys: String, pressEnter: Bool, remoteHost: String?) async -> Bool {
        if let remoteHost = remoteHost {
            return await sendKeysViaSSH(to: targetStr, keys: keys, pressEnter: pressEnter, host: remoteHost)
        } else {
            return await sendKeysLocally(to: targetStr, keys: keys, pressEnter: pressEnter)
        }
    }

    private func sendKeysLocally(to targetStr: String, keys: String, pressEnter: Bool) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return false
        }

        let textArgs = ["send-keys", "-t", targetStr, "-l", keys]

        do {
            Self.logger.debug("Sending text to \(targetStr, privacy: .public)")
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: textArgs)

            if pressEnter {
                Self.logger.debug("Sending Enter key")
                let enterArgs = ["send-keys", "-t", targetStr, "Enter"]
                _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: enterArgs)
            }
            return true
        } catch {
            Self.logger.error("Error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func sendKeysViaSSH(to targetStr: String, keys: String, pressEnter: Bool, host: String) async -> Bool {
        // Escape single quotes in keys for shell safety
        let escapedKeys = keys.replacingOccurrences(of: "'", with: "'\"'\"'")

        // Build tmux command to run on remote host
        let tmuxTextCmd = "tmux send-keys -t '\(targetStr)' -l '\(escapedKeys)'"

        do {
            Self.logger.debug("Sending text via SSH to \(host, privacy: .public):\(targetStr, privacy: .public)")
            _ = try await ProcessExecutor.shared.run("/usr/bin/ssh", arguments: [host, tmuxTextCmd])

            if pressEnter {
                Self.logger.debug("Sending Enter key via SSH")
                let tmuxEnterCmd = "tmux send-keys -t '\(targetStr)' Enter"
                _ = try await ProcessExecutor.shared.run("/usr/bin/ssh", arguments: [host, tmuxEnterCmd])
            }
            return true
        } catch {
            Self.logger.error("SSH error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
