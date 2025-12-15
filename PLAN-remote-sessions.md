# Phase 1: Remote Claude Island

## Overview

Enable claude-island to work with Claude Code sessions running on remote clusters via SSH.

**Current state:** Unix socket on `/tmp/claude-island.sock` → local tmux commands
**Target state:** TCP + reverse SSH tunnel → SSH-wrapped tmux commands

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  CLUSTER                                                        │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  tmux session                                           │    │
│  │  └── Claude Code CLI                                    │    │
│  │       └── claude-island-state.py hook                   │    │
│  │            │                                            │    │
│  │            │ CLAUDE_ISLAND_TCP=localhost:12345          │    │
│  │            ▼                                            │    │
│  │       TCP localhost:12345 ────────────────────────┐     │    │
│  └────────────────────────────────────────────────────│────┘    │
│                                                       │         │
│  SSH reverse tunnel (ssh -R 12345:localhost:12345)    │         │
│                                                       │         │
└───────────────────────────────────────────────────────│─────────┘
                                                        │
┌───────────────────────────────────────────────────────│─────────┐
│  MAC                                                  │         │
│                                                       ▼         │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  claude-island                                          │    │
│  │  ├── HookSocketServer (Unix + TCP listeners)            │    │
│  │  │    └── TCP :12345 ◄─────────────────────────────────│    │
│  │  │                                                      │    │
│  │  ├── SessionStore (tracks remoteHost per session)       │    │
│  │  │                                                      │    │
│  │  └── ToolApprovalHandler                               │    │
│  │       └── sendKeys() → if remote: ssh cluster "tmux.." │    │
│  └────────────────────────────────────────────────────────┘    │
│                                                                 │
│  Dynamic Island UI                                              │
└─────────────────────────────────────────────────────────────────┘
```

---

## File Changes

### 1. HookSocketServer.swift — Add TCP listener

**Location:** `ClaudeIsland/Services/Hooks/HookSocketServer.swift`

**Changes:**
- Add `tcpServerSocket: Int32` property
- Add `tcpPort: UInt16` (default 12345, eventually configurable)
- Add `tcpAcceptSource: DispatchSourceRead?`
- In `startServer()`, call new `startTCPServer()` alongside Unix socket
- TCP connections feed into same `handleClient()` pipeline
- Extract `remoteHost` from incoming events (new field in HookEvent)

**Key code:**
```swift
private var tcpServerSocket: Int32 = -1
private var tcpAcceptSource: DispatchSourceRead?
private let tcpPort: UInt16 = 12345

private func startTCPServer() {
    tcpServerSocket = socket(AF_INET, SOCK_STREAM, 0)
    guard tcpServerSocket >= 0 else { return }

    var yes: Int32 = 1
    setsockopt(tcpServerSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    let flags = fcntl(tcpServerSocket, F_GETFL)
    _ = fcntl(tcpServerSocket, F_SETFL, flags | O_NONBLOCK)

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = tcpPort.bigEndian
    addr.sin_addr.s_addr = INADDR_ANY  // or inet_addr("127.0.0.1") for localhost-only

    // bind, listen, create DispatchSource same pattern as Unix socket
}
```

### 2. HookEvent — Add remoteHost field

**Location:** `ClaudeIsland/Services/Hooks/HookSocketServer.swift` (HookEvent struct)

**Changes:**
```swift
struct HookEvent: Codable, Sendable {
    // ... existing fields ...
    let remoteHost: String?  // NEW: hostname for SSH commands

    enum CodingKeys: String, CodingKey {
        // ... existing keys ...
        case remoteHost = "remote_host"
    }
}
```

### 3. claude-island-state.py — TCP support

**Location:** `ClaudeIsland/Resources/claude-island-state.py`

**Changes:**
- Check `CLAUDE_ISLAND_TCP` env var (format: `host:port`)
- If set, connect via TCP instead of Unix socket
- Add `remote_host` field to state payload (from `CLAUDE_ISLAND_REMOTE_HOST` env var)

**Key code:**
```python
def get_socket():
    """Get socket connection - TCP if CLAUDE_ISLAND_TCP is set, else Unix"""
    tcp_target = os.environ.get("CLAUDE_ISLAND_TCP")
    if tcp_target:
        host, port = tcp_target.rsplit(":", 1)
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect((host, int(port)))
        return sock
    else:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect(SOCKET_PATH)
        return sock

# In main(), add to state dict:
state["remote_host"] = os.environ.get("CLAUDE_ISLAND_REMOTE_HOST")
```

### 4. SessionState.swift — Add remoteHost

**Location:** `ClaudeIsland/Models/SessionState.swift`

**Changes:**
```swift
struct SessionState: Equatable, Identifiable, Sendable {
    // ... existing fields ...

    /// Remote host for SSH commands (nil for local sessions)
    var remoteHost: String?

    // Update init to include remoteHost parameter
}
```

### 5. SessionStore.swift — Propagate remoteHost

**Location:** `ClaudeIsland/Services/State/SessionStore.swift`

**Changes:**
- In `createSession(from:)`, set `remoteHost` from event
- In `processHookEvent()`, update session's `remoteHost` if present

```swift
private func createSession(from event: HookEvent) -> SessionState {
    SessionState(
        sessionId: event.sessionId,
        cwd: event.cwd,
        // ... existing ...
        remoteHost: event.remoteHost  // NEW
    )
}
```

### 6. ToolApprovalHandler.swift — SSH-wrap tmux commands

**Location:** `ClaudeIsland/Services/Tmux/ToolApprovalHandler.swift`

**Changes:**
- Add `remoteHost: String?` parameter to all public methods
- In `sendKeys()`, wrap tmux command in SSH if remote

```swift
private func sendKeys(to target: TmuxTarget, keys: String, pressEnter: Bool, remoteHost: String? = nil) async -> Bool {
    guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
        return false
    }

    let targetStr = target.targetString

    if let host = remoteHost {
        // Remote: ssh host "tmux send-keys -t target -l 'keys'"
        let tmuxCmd = "tmux send-keys -t '\(targetStr)' -l '\(keys.escapedForShell)'"
        let args = [host, tmuxCmd]

        do {
            _ = try await ProcessExecutor.shared.run("/usr/bin/ssh", arguments: args)
            if pressEnter {
                let enterCmd = "tmux send-keys -t '\(targetStr)' Enter"
                _ = try await ProcessExecutor.shared.run("/usr/bin/ssh", arguments: [host, enterCmd])
            }
            return true
        } catch {
            return false
        }
    } else {
        // Local: existing implementation
        // ...
    }
}
```

### 7. TmuxTargetFinder.swift — SSH-wrap queries

**Location:** `ClaudeIsland/Services/Tmux/TmuxTargetFinder.swift`

**Changes:**
- For remote sessions, we may not need to "find" the target the same way
- The hook already knows the tmux target on the remote side
- Consider adding target info to the hook event, or...
- Accept that for remote, we pass target explicitly

**Option A:** Add `tmux_target` to hook event (simpler, recommended)
```python
# In claude-island-state.py
state["tmux_target"] = os.environ.get("TMUX_PANE")  # e.g., "%42"
```

**Option B:** Run `ssh host "tmux list-panes -a -F ..."` for queries (complex)

### 8. TmuxController.swift — Thread remoteHost through

**Location:** `ClaudeIsland/Services/Tmux/TmuxController.swift`

**Changes:**
- Update method signatures to accept `remoteHost: String?`
- Pass through to ToolApprovalHandler

### 9. UI Layer — Pass remoteHost when approving

**Location:** Files that call `TmuxController.shared.approveOnce()` etc.

**Changes:**
- Get `remoteHost` from current session state
- Pass to approval methods

---

## Implementation Order

1. **Hook event schema** — Add `remoteHost` and `tmuxTarget` fields to HookEvent
2. **SessionState** — Add `remoteHost` property
3. **SessionStore** — Propagate remoteHost from events to sessions
4. **Python hook** — TCP connection + new fields
5. **HookSocketServer** — TCP listener
6. **ToolApprovalHandler** — SSH-wrapped commands
7. **TmuxController** — Thread remoteHost through
8. **UI integration** — Pass remoteHost from session state

---

## Testing Plan

### Local testing (no cluster needed)
1. Run TCP server on Mac, connect from local Python script
2. Verify events flow through TCP same as Unix socket

### Remote testing
1. SSH to cluster with reverse tunnel: `ssh -R 12345:localhost:12345 cluster`
2. On cluster: `export CLAUDE_ISLAND_TCP=localhost:12345`
3. On cluster: `export CLAUDE_ISLAND_REMOTE_HOST=cluster`
4. On cluster: Run Claude in tmux
5. Verify: Session appears in island, permissions work, chat works

---

## Future Considerations

- **Settings UI:** TCP port configuration
- **Multiple remotes:** Track different hosts simultaneously
- **SSH key management:** Currently assumes `ssh cluster` works (agent forwarding)
- **Connection health:** Detect when tunnel drops, show status in UI
- **Claims layer (Phase 2):** Remote file watching via SSHFS or rsync

---

## Questions Resolved

| Question | Answer |
|----------|--------|
| How to route tmux commands? | SSH wrap: `ssh host "tmux send-keys..."` |
| How to identify remote sessions? | `remote_host` field in hook event |
| How to find tmux target remotely? | Add `tmux_target` to hook event (from `$TMUX_PANE`) |
| TCP or Unix socket forwarding? | TCP — cleaner than Unix socket forwarding |
| What port? | 12345 default (configurable later) |

---

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| SSH latency affects approval UX | Pre-establish connection, consider multiplexing |
| Tunnel drops silently | Add heartbeat/health check (Phase 1.1) |
| Multiple clusters | Track `remoteHost` per session (already designed) |
| Security (open port) | Bind to localhost only, require tunnel |
