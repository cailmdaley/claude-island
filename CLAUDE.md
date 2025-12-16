# Claude Island

A macOS menubar app for visualizing and interacting with Claude Code sessions.

## Features

- **Session Visualization**: View all active Claude Code sessions (local and remote)
- **Chat History**: Read conversation history with tool calls and results
- **Tool Approvals**: Approve/deny tool requests directly from the island
- **Keyboard Navigation**: Use arrow keys to navigate sessions (↑/↓), Enter to open chat, Escape to go back
- **Text Selection**: Copy/paste text from chat messages and tool outputs
- **Window Focusing**: Jump to terminal window for any session (requires yabai)

## Optional Dependencies

### Yabai (Window Management)

Enables the focus button (👁️) to bring terminal windows to the front.

**Installation:**
```bash
brew install koekeishiya/formulae/yabai
yabai --start-service
```

Then grant accessibility permissions: **System Settings** → **Privacy & Security** → **Accessibility** → Add yabai

**Supported terminals:** Terminal.app, iTerm2, Alacritty, kitty, WezTerm, Ghostty

**Note:** Focus button only works for local sessions (not remote).

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         SwiftUI Views                           │
│  (MenuBarView, ChatView, InstanceListView, PermissionSheet)     │
└──────────────────────────────┬──────────────────────────────────┘
                               │ @Published
┌──────────────────────────────▼──────────────────────────────────┐
│                    ClaudeSessionMonitor                         │
│              (MainActor, UI-facing publisher)                   │
└──────────────────────────────┬──────────────────────────────────┘
                               │ Combine
┌──────────────────────────────▼──────────────────────────────────┐
│                        SessionStore                             │
│           (Actor, central state machine, event-driven)          │
└───────┬─────────────────┬─────────────────┬─────────────────────┘
        │                 │                 │
        ▼                 ▼                 ▼
┌───────────────┐ ┌───────────────┐ ┌───────────────────┐
│ HookSocket    │ │ Conversation  │ │ ToolApproval      │
│ Server        │ │ Parser        │ │ Handler           │
│ (events in)   │ │ (JSONL parse) │ │ (tmux keys out)   │
└───────────────┘ └───────────────┘ └───────────────────┘
```

### Core Services

**`SessionStore`** (`Services/State/SessionStore.swift`)
- Actor-isolated central state machine
- Processes events via `process(_ event: SessionEvent)`
- Manages `sessions: [String: SessionState]`
- Schedules file syncs, handles history loading
- Publishes state changes via Combine

**`HookSocketServer`** (`Services/Hooks/HookSocketServer.swift`)
- Listens for hook events from Claude Code
- Unix socket at `/tmp/claude-island.sock` (local)
- TCP socket at port `12345` (remote)
- Parses JSON events, forwards to SessionStore

**`ConversationParser`** (`Services/Session/ConversationParser.swift`)
- Parses Claude's JSONL conversation files
- Incremental parsing (tracks file offset)
- Extracts messages, tool calls, results, summaries
- Path pattern: `~/.claude/projects/<cwd-escaped>/<session-id>.jsonl`

**`ToolApprovalHandler`** (`Services/Tmux/ToolApprovalHandler.swift`)
- Sends keystrokes to tmux for tool approvals
- `approveOnce()` → sends "1" + Enter
- `approveAlways()` → sends "2" + Enter
- `reject()` → sends "n" + Enter + optional message

### Models

**`SessionState`** (`Models/SessionState.swift`)
- Represents a Claude Code session
- Contains: sessionId, cwd, phase, chatItems, activePermission
- Remote session properties: remoteHost, remoteTmuxTarget

**`HookEvent`** (`Models/HookEvent.swift`)
- Decoded from hook JSON payloads
- Contains: event type, sessionId, tool info, status

### Hook Integration

Claude Code hooks fire Python scripts that write JSON to stdout. The Island app registers hooks in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/claude-island-state.py"}]}],
    "PreToolUse": [{"hooks": [...], "matcher": "*"}],
    "PostToolUse": [{"hooks": [...], "matcher": "*"}],
    "PermissionRequest": [{"hooks": [...], "matcher": "*"}]
  }
}
```

The Python hook (`claude-island-state.py`) reads event context from stdin, formats it, and sends to the Island socket.

---

## Development Stages

### Stage 1: Remote Session Support (PR-able)

**Goal:** Visualize and interact with Claude Code sessions running on remote machines (clusters, servers) via SSH.

**Status:** Implemented, working.

#### What was added:

1. **TCP Socket Support** (`HookSocketServer.swift`)
   - Added TCP listener on port 12345 alongside Unix socket
   - Remote hooks connect via SSH reverse tunnel

2. **Remote Session Properties** (`SessionState.swift`)
   ```swift
   var remoteHost: String?        // e.g., "cluster"
   var remoteTmuxTarget: String?  // e.g., "mysession:0"
   var isRemote: Bool { remoteHost != nil }
   ```

3. **SSH File Reader** (`Services/Remote/RemoteFileReader.swift`)
   - Fetches JSONL content via `ssh host "cat path"`
   - No filesystem mounts, no sync daemons

4. **Direct Content Parsing** (`ConversationParser.swift`)
   - `parseInfoFromContent(_:)` - parse summary from string
   - `parseMessagesFromContent(_:sessionId:)` - parse full conversation

5. **Remote History Loading** (`SessionStore.swift`)
   - `loadHistoryFromRemote()` - SSH fetch + direct parse
   - `syncRemoteSession()` - re-fetch on updates

6. **Remote Tool Approval** (`ToolApprovalHandler.swift`)
   - `sendKeysViaSSH()` - wraps tmux commands in SSH

7. **Hook TCP Support** (`claude-island-state.py`)
   - Reads `CLAUDE_ISLAND_TCP` env var for TCP connection
   - Reads `CLAUDE_ISLAND_REMOTE_HOST` for remote identification

#### Usage:

```bash
# Local machine: start Island app (TCP listener auto-starts)

# SSH to cluster with reverse tunnel
ssh -R 12345:localhost:12345 cluster

# On cluster: set env vars and run Claude
export CLAUDE_ISLAND_TCP="localhost:12345"
export CLAUDE_ISLAND_REMOTE_HOST="cluster"
tmux new -s research
claude
```

#### Design Decisions:

- **Query, don't sync**: SSH fetches files on-demand rather than mounting or syncing. More reliable, no kernel extensions.
- **Full re-fetch for remote**: Incremental parsing requires local file handles. Remote sessions do full JSONL fetch on each update. Acceptable for typical conversation sizes.
- **Env vars for configuration**: Remote host info passed via environment rather than config files. Simpler for SSH sessions.

#### Key Implementation Details:

**Path escaping**: Claude escapes project paths with `/` → `-`, `.` → `-`, `_` → `-`. Both RemoteFileReader and ConversationParser must match this.

**Tilde expansion**: Use `$HOME` instead of `~` in SSH commands (tilde doesn't expand in single quotes).

**SSH retry logic**: RemoteFileReader retries 3× with exponential backoff (500ms, 1s, 2s). Adds `ConnectTimeout=5` to avoid hanging.

**cwd mismatch**: Claude hooks send current working directory, but JSONL is stored by *project* directory. If user `cd`s during a session, these differ. ConversationParser now searches:
1. Given cwd path
2. Parent directories
3. All project directories (by sessionId)

Results are cached once resolved.

**Race condition**: Empty remote sessions must not be marked as "loaded" in ChatHistoryManager, otherwise the load guard prevents fetching.

**Refresh UI**: Remote sessions show refresh button in header; empty state shows Retry button.

---

### Stage 2: Research Claims & Evidence (Personal)

**Goal:** Visualize research workflow artifacts—claims, evidence, dependencies—for AI-mediated science verification.

**Status:** Design phase. Not started.

#### Concept:

Research produces claims backed by evidence (data, plots, computations). As AI accelerates output, verification becomes the bottleneck. This stage adds:

1. **Claims Index**: Structured summary of research claims (likely JSON, built separately)
2. **Evidence Links**: References to artifacts (plots, data files, notebooks)
3. **Workflow DAG**: Snakemake dependency graph visualization
4. **Query Interface**: SSH queries to snakemake for structure, on-demand artifact fetch

#### Architecture Sketch:

```
┌─────────────────────────────────────────┐
│           Claims Viewer (UI)            │
└─────────────────────┬───────────────────┘
                      │
┌─────────────────────▼───────────────────┐
│          WorkflowQueryService           │
│  - getClaimsIndex(host, project)        │
│  - getDAG(host, project)                │
│  - fetchArtifact(host, path)            │
└─────────────────────┬───────────────────┘
                      │ SSH
                      ▼
┌─────────────────────────────────────────┐
│              Cluster                    │
│  - claims.json (built by workflow)      │
│  - snakemake (DAG queries)              │
│  - artifacts (plots, data)              │
└─────────────────────────────────────────┘
```

This builds on Stage 1's SSH infrastructure. The `RemoteFileReader` pattern extends to artifact fetching. Snakemake queries (`--summary`, `--dag`) provide structure without syncing everything.

---

## File Organization

```
ClaudeIsland/
├── App/
│   └── ClaudeIslandApp.swift, AppDelegate.swift
├── Models/
│   ├── SessionState.swift
│   ├── SessionEvent.swift
│   ├── HookEvent.swift
│   └── ToolResultData.swift
├── Services/
│   ├── State/
│   │   └── SessionStore.swift          # Central state machine
│   ├── Session/
│   │   ├── ClaudeSessionMonitor.swift  # UI-facing publisher
│   │   ├── ConversationParser.swift    # JSONL parsing
│   │   └── JSONLInterruptWatcher.swift
│   ├── Hooks/
│   │   └── HookSocketServer.swift      # Socket listener
│   ├── Tmux/
│   │   ├── ToolApprovalHandler.swift   # Send keys
│   │   └── TmuxController.swift
│   ├── Remote/                         # [Stage 1 addition]
│   │   └── RemoteFileReader.swift      # SSH file fetch
│   └── Chat/
│       └── ChatHistoryManager.swift
├── Views/
│   ├── MenuBar/
│   ├── Chat/
│   └── Components/
└── Resources/
    └── claude-island-state.py          # Hook script
```

---

## Testing Remote Sessions

1. Build: `xcodebuild -scheme ClaudeIsland build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
2. Deploy: `cp -R DerivedData/.../Claude\ Island.app /Applications/`
3. Start app (TCP listener binds to 12345)
4. SSH with tunnel: `ssh -R 12345:localhost:12345 cluster`
5. On cluster: set env vars, run `tmux` + `claude`
6. Session should appear in Island with chat history

---

## Contributing (Stage 1)

Stage 1 changes are designed to be PR-able upstream. Key considerations:

- No new dependencies (uses Foundation Process for SSH)
- Backward compatible (local sessions unchanged)
- Clean separation (remote logic in dedicated files/methods)
- Env var configuration (no config file changes required)
