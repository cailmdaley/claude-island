//
//  RemoteFileReader.swift
//  ClaudeIsland
//
//  SSH-based file reader for remote Claude sessions.
//  Fetches JSONL conversation files from remote hosts.
//

import Foundation
import os.log

actor RemoteFileReader {
    static let shared = RemoteFileReader()

    nonisolated static let logger = Logger(subsystem: "com.claudeisland", category: "RemoteFile")

    private init() {}

    /// Build remote session file path (mirrors ConversationParser.sessionFilePath)
    func remoteSessionFilePath(sessionId: String, cwd: String) -> String {
        // Claude escapes: / → -, . → -, _ → -
        let projectDir = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        return "~/.claude/projects/" + projectDir + "/" + sessionId + ".jsonl"
    }

    /// Maximum retry attempts for SSH fetch
    private static let maxRetries = 3

    /// Delay between retries (doubles each attempt)
    private static let baseRetryDelayNs: UInt64 = 500_000_000  // 500ms

    /// Fetch file content from remote host via SSH with retry logic
    func fetchFile(host: String, path: String) async -> String? {
        // Expand ~ to $HOME for proper shell expansion (~ doesn't expand in single quotes)
        let expandedPath = path.hasPrefix("~/") ? "$HOME" + path.dropFirst(1) : path

        // Use cat to read the file, suppress errors if file doesn't exist
        // Don't quote the path so $HOME expands
        let command = "cat \(expandedPath) 2>/dev/null"

        for attempt in 1...Self.maxRetries {
            Self.logger.info("SSH fetch attempt \(attempt)/\(Self.maxRetries): \(host, privacy: .public) cat \(expandedPath, privacy: .public)")

            do {
                let output = try await ProcessExecutor.shared.run(
                    "/usr/bin/ssh",
                    arguments: ["-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new", host, command]
                )

                if output.isEmpty {
                    Self.logger.debug("Remote file empty or not found")
                    return nil
                }

                Self.logger.debug("Fetched \(output.count) bytes from remote")
                return output
            } catch {
                Self.logger.warning("SSH fetch attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")

                if attempt < Self.maxRetries {
                    // Exponential backoff: 500ms, 1s, 2s
                    let delay = Self.baseRetryDelayNs * UInt64(1 << (attempt - 1))
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }

        Self.logger.error("SSH fetch failed after \(Self.maxRetries) attempts")
        return nil
    }

    /// Fetch conversation JSONL for a session
    func fetchConversation(host: String, sessionId: String, cwd: String) async -> String? {
        let remotePath = remoteSessionFilePath(sessionId: sessionId, cwd: cwd)
        return await fetchFile(host: host, path: remotePath)
    }

    /// Fetch agent JSONL for subagent tools
    func fetchAgentFile(host: String, agentId: String, cwd: String) async -> String? {
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let remotePath = "~/.claude/projects/" + projectDir + "/agent-" + agentId + ".jsonl"
        return await fetchFile(host: host, path: remotePath)
    }
}
