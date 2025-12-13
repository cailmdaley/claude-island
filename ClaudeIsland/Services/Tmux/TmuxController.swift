//
//  TmuxController.swift
//  ClaudeIsland
//
//  High-level tmux operations controller
//  Supports both local and remote (SSH) sessions
//

import Foundation

/// Controller for tmux operations
actor TmuxController {
    static let shared = TmuxController()

    private init() {}

    // MARK: - Local Session Methods

    func findTmuxTarget(forClaudePid pid: Int) async -> TmuxTarget? {
        await TmuxTargetFinder.shared.findTarget(forClaudePid: pid)
    }

    func findTmuxTarget(forWorkingDirectory dir: String) async -> TmuxTarget? {
        await TmuxTargetFinder.shared.findTarget(forWorkingDirectory: dir)
    }

    func sendMessage(_ message: String, to target: TmuxTarget) async -> Bool {
        await ToolApprovalHandler.shared.sendMessage(message, to: target)
    }

    func approveOnce(target: TmuxTarget) async -> Bool {
        await ToolApprovalHandler.shared.approveOnce(target: target)
    }

    func approveAlways(target: TmuxTarget) async -> Bool {
        await ToolApprovalHandler.shared.approveAlways(target: target)
    }

    func reject(target: TmuxTarget, message: String? = nil) async -> Bool {
        await ToolApprovalHandler.shared.reject(target: target, message: message)
    }

    func switchToPane(target: TmuxTarget) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return false
        }

        do {
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "select-window", "-t", "\(target.session):\(target.window)"
            ])

            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "select-pane", "-t", target.targetString
            ])

            return true
        } catch {
            return false
        }
    }

    // MARK: - Remote Session Methods

    func sendMessage(_ message: String, remoteTmuxTarget: String, remoteHost: String) async -> Bool {
        await ToolApprovalHandler.shared.sendMessage(message, remoteTmuxTarget: remoteTmuxTarget, remoteHost: remoteHost)
    }

    func approveOnce(remoteTmuxTarget: String, remoteHost: String) async -> Bool {
        await ToolApprovalHandler.shared.approveOnce(remoteTmuxTarget: remoteTmuxTarget, remoteHost: remoteHost)
    }

    func approveAlways(remoteTmuxTarget: String, remoteHost: String) async -> Bool {
        await ToolApprovalHandler.shared.approveAlways(remoteTmuxTarget: remoteTmuxTarget, remoteHost: remoteHost)
    }

    func reject(remoteTmuxTarget: String, remoteHost: String, message: String? = nil) async -> Bool {
        await ToolApprovalHandler.shared.reject(remoteTmuxTarget: remoteTmuxTarget, remoteHost: remoteHost, message: message)
    }

    // MARK: - Session-Aware Methods

    /// Approve a tool once for a session (handles local vs remote automatically)
    func approveOnce(session: SessionState) async -> Bool {
        if let remoteHost = session.remoteHost, let remoteTmuxTarget = session.remoteTmuxTarget {
            return await approveOnce(remoteTmuxTarget: remoteTmuxTarget, remoteHost: remoteHost)
        } else if let pid = session.pid, let target = await findTmuxTarget(forClaudePid: pid) {
            return await approveOnce(target: target)
        }
        return false
    }

    /// Approve a tool always for a session (handles local vs remote automatically)
    func approveAlways(session: SessionState) async -> Bool {
        if let remoteHost = session.remoteHost, let remoteTmuxTarget = session.remoteTmuxTarget {
            return await approveAlways(remoteTmuxTarget: remoteTmuxTarget, remoteHost: remoteHost)
        } else if let target = await findTmuxTargetForSession(session) {
            return await approveAlways(target: target)
        }
        return false
    }

    /// Find tmux target for a session (tries pid first, then tty)
    private func findTmuxTargetForSession(_ session: SessionState) async -> TmuxTarget? {
        // Try by PID first
        if let pid = session.pid, let target = await findTmuxTarget(forClaudePid: pid) {
            return target
        }
        // Fall back to TTY
        if let tty = session.tty, let target = await findTmuxTarget(forTty: tty) {
            return target
        }
        return nil
    }

    /// Find tmux target by TTY
    func findTmuxTarget(forTty tty: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"]
            )

            let lines = output.components(separatedBy: "\n")
            for line in lines {
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { continue }

                let target = parts[0]
                let paneTty = parts[1].replacingOccurrences(of: "/dev/", with: "")

                if paneTty == tty {
                    return TmuxTarget(from: target)
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    /// Reject a tool for a session (handles local vs remote automatically)
    func reject(session: SessionState, message: String? = nil) async -> Bool {
        if let remoteHost = session.remoteHost, let remoteTmuxTarget = session.remoteTmuxTarget {
            return await reject(remoteTmuxTarget: remoteTmuxTarget, remoteHost: remoteHost, message: message)
        } else if let pid = session.pid, let target = await findTmuxTarget(forClaudePid: pid) {
            return await reject(target: target, message: message)
        }
        return false
    }

    /// Send a message to a session (handles local vs remote automatically)
    func sendMessage(_ message: String, to session: SessionState) async -> Bool {
        if let remoteHost = session.remoteHost, let remoteTmuxTarget = session.remoteTmuxTarget {
            return await sendMessage(message, remoteTmuxTarget: remoteTmuxTarget, remoteHost: remoteHost)
        } else if let pid = session.pid, let target = await findTmuxTarget(forClaudePid: pid) {
            return await sendMessage(message, to: target)
        }
        return false
    }
}
