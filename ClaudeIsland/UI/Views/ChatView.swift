//
//  ChatView.swift
//  ClaudeIsland
//
//  Redesigned chat interface with clean visual hierarchy
//

import Combine
import SwiftUI

struct ChatView: View {
    let sessionId: String
    let initialSession: SessionState
    let sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    @Environment(\.theme) private var theme

    @State private var inputText: String = ""
    @State private var history: [ChatHistoryItem] = []
    @State private var session: SessionState
    @State private var isLoading: Bool = true
    @State private var hasLoadedOnce: Bool = false
    @State private var shouldScrollToBottom: Bool = false
    @State private var isAutoscrollPaused: Bool = false
    @State private var newMessageCount: Int = 0
    @State private var previousHistoryCount: Int = 0
    @State private var isBottomVisible: Bool = true
    @State private var isRefreshing: Bool = false
    @FocusState private var isInputFocused: Bool

    init(sessionId: String, initialSession: SessionState, sessionMonitor: ClaudeSessionMonitor, viewModel: NotchViewModel) {
        self.sessionId = sessionId
        self.initialSession = initialSession
        self.sessionMonitor = sessionMonitor
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._session = State(initialValue: initialSession)

        // Initialize from cache if available (prevents loading flicker on view recreation)
        let cachedHistory = ChatHistoryManager.shared.history(for: sessionId)
        let alreadyLoaded = !cachedHistory.isEmpty
        self._history = State(initialValue: cachedHistory)
        self._isLoading = State(initialValue: !alreadyLoaded)
        self._hasLoadedOnce = State(initialValue: alreadyLoaded)
    }

    /// Whether we're waiting for approval
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Extract the tool name if waiting for approval
    private var approvalTool: String? {
        session.phase.approvalToolName
    }

    /// Whether this is a notification-based prompt (no "always" option)
    private var isNotificationPrompt: Bool {
        session.activePermission?.toolUseId.isEmpty ?? false
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                chatHeader

                // Messages
                if isLoading {
                    loadingState
                } else if history.isEmpty {
                    emptyState
                } else {
                    messageList
                }

                // Approval bar (if needed) + Input bar
                if let tool = approvalTool {
                    if tool == "AskUserQuestion" {
                        // Interactive tools - show prompt to answer in terminal
                        interactivePromptBar
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity
                            ))
                    } else {
                        // Show approval bar above input bar
                        VStack(spacing: 0) {
                            approvalBar(tool: tool)
                            inputBar
                        }
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        ))
                    }
                } else {
                    inputBar
                        .transition(.opacity)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isWaitingForApproval)
        .animation(nil, value: viewModel.status)
        .task {
            // Skip if already loaded (prevents redundant work on view recreation)
            guard !hasLoadedOnce else { return }
            hasLoadedOnce = true

            // Check if already loaded (from previous visit)
            // For remote sessions, check if we have conversation text (not just tool calls from hooks)
            let cachedHistory = ChatHistoryManager.shared.history(for: sessionId)
            let hasConversationText = cachedHistory.contains { item in
                if case .user(_) = item.type { return true }
                if case .assistant(_) = item.type { return true }
                return false
            }
            // Remote sessions need a load if they don't have conversation text yet
            let needsRemoteLoad = session.isRemote && !hasConversationText

            if ChatHistoryManager.shared.isLoaded(sessionId: sessionId) && !needsRemoteLoad {
                history = cachedHistory
                isLoading = false
                return
            }

            // Load in background, show loading state
            await ChatHistoryManager.shared.loadFromFile(sessionId: sessionId, cwd: session.cwd, forceRemote: needsRemoteLoad)
            history = ChatHistoryManager.shared.history(for: sessionId)

            withAnimation(.easeOut(duration: 0.2)) {
                isLoading = false
            }
        }
        .onReceive(ChatHistoryManager.shared.$histories) { histories in
            // Update when count changes, last item differs, or content changes (e.g., tool status)
            if let newHistory = histories[sessionId] {
                let countChanged = newHistory.count != history.count
                let lastItemChanged = newHistory.last?.id != history.last?.id
                // Always update - the @Published ensures we only get notified on real changes
                // This allows tool status updates (waitingForApproval -> running) to reflect
                if countChanged || lastItemChanged || newHistory != history {
                    // Track new messages when autoscroll is paused
                    if isAutoscrollPaused && newHistory.count > previousHistoryCount {
                        let addedCount = newHistory.count - previousHistoryCount
                        newMessageCount += addedCount
                        previousHistoryCount = newHistory.count
                    }

                    history = newHistory

                    // Auto-scroll to bottom only if autoscroll is NOT paused
                    if !isAutoscrollPaused && countChanged {
                        shouldScrollToBottom = true
                    }

                    // If we have data, skip loading state (handles view recreation)
                    if isLoading && !newHistory.isEmpty {
                        isLoading = false
                    }
                }
            } else if hasLoadedOnce {
                // Session was loaded but is now gone (removed via /clear) - navigate back
                viewModel.exitChat()
            }
        }
        .onReceive(sessionMonitor.$instances) { sessions in
            if let updated = sessions.first(where: { $0.sessionId == sessionId }),
               updated != session {
                // Check if permission was just accepted (transition from waitingForApproval to processing)
                let wasWaiting = isWaitingForApproval
                session = updated
                let isNowProcessing = updated.phase == .processing

                if wasWaiting && isNowProcessing {
                    // Scroll to bottom after permission accepted (with slight delay)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        shouldScrollToBottom = true
                    }
                }
            }
        }
        .onChange(of: canSendMessages) { _, canSend in
            // Auto-focus input when tmux messaging becomes available
            if canSend && !isInputFocused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
            }
        }
        .onAppear {
            // Auto-focus input when chat opens and tmux messaging is available
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if canSendMessages {
                    isInputFocused = true
                }
            }
        }
    }

    // MARK: - Header

    @State private var isHeaderHovered = false

    @State private var isRefreshHovered = false

    private var chatHeader: some View {
        HStack(spacing: 0) {
            Button {
                viewModel.exitChat()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.textSecondary.opacity(isHeaderHovered ? 1.0 : 0.6))
                        .frame(width: 24, height: 24)

                    Text(session.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.textSecondary.opacity(isHeaderHovered ? 1.0 : 0.85))
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHeaderHovered ? theme.backgroundHover : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHeaderHovered = $0 }

            // Refresh button for remote sessions
            if session.isRemote {
                Button {
                    refreshRemoteHistory()
                } label: {
                    Group {
                        if isRefreshing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: theme.textDim))
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.textDim.opacity(isRefreshHovered ? 0.9 : 0.5))
                        }
                    }
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(isRefreshHovered ? theme.backgroundHover : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .onHover { isRefreshHovered = $0 }
                .disabled(isRefreshing)
                .padding(.trailing, 8)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.backgroundElevated)
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [theme.background.opacity(0.7), theme.background.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: 24) // Push below header
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
    }

    /// Whether the session is currently processing
    private var isProcessing: Bool {
        session.phase == .processing || session.phase == .compacting
    }

    /// Get the last user message ID for stable text selection per turn
    private var lastUserMessageId: String {
        for item in history.reversed() {
            if case .user = item.type {
                return item.id
            }
        }
        return ""
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: theme.textDim))
                .scaleEffect(0.8)
            Text("Loading messages...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: session.isRemote ? "wifi.exclamationmark" : "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundColor(theme.textDimmer)

            if session.isRemote {
                Text("Couldn't load remote history")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.textDim)

                Button {
                    refreshRemoteHistory()
                } label: {
                    HStack(spacing: 6) {
                        if isRefreshing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: theme.textPrimary))
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text("Retry")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(theme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(theme.backgroundHover)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
            } else {
                Text("No messages yet")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.textDim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 16) {
                    // Invisible anchor at bottom (first due to flip)
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")

                    // Processing indicator at bottom (first due to flip)
                    if isProcessing {
                        ProcessingIndicatorView(turnId: lastUserMessageId)
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: -4)),
                                removal: .opacity
                            ))
                    }

                    ForEach(history.reversed()) { item in
                        MessageItemView(item: item, sessionId: sessionId)
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.98)),
                                removal: .opacity
                            ))
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 20)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isProcessing)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: history.count)
            }
            .scaleEffect(x: 1, y: -1)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Check if we're near the top of the content (which is bottom in inverted view)
                // contentOffset.y near 0 means at bottom, larger means scrolled up
                geometry.contentOffset.y < 50
            } action: { wasAtBottom, isNowAtBottom in
                if wasAtBottom && !isNowAtBottom {
                    // User scrolled away from bottom
                    pauseAutoscroll()
                } else if !wasAtBottom && isNowAtBottom && isAutoscrollPaused {
                    // User scrolled back to bottom
                    resumeAutoscroll()
                }
            }
            .onChange(of: shouldScrollToBottom) { _, shouldScroll in
                if shouldScroll {
                    withAnimation(.easeOut(duration: 0.3)) {
                        // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    shouldScrollToBottom = false
                    resumeAutoscroll()
                }
            }
            // New messages indicator overlay
            .overlay(alignment: .bottom) {
                if isAutoscrollPaused && newMessageCount > 0 {
                    NewMessagesIndicator(count: newMessageCount) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        resumeAutoscroll()
                    }
                    .padding(.bottom, 16)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity
                    ))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isAutoscrollPaused && newMessageCount > 0)
        }
    }

    // MARK: - Input Bar

    /// Can send messages only if session is in tmux (local or remote)
    private var canSendMessages: Bool {
        // Remote sessions can always send if we have the target
        if session.isRemote && session.remoteTmuxTarget != nil {
            return true
        }
        // Local sessions need tmux and tty
        return session.isInTmux && session.tty != nil
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                // Placeholder text (shown when empty)
                if inputText.isEmpty {
                    Text(canSendMessages ? "Message Claude..." : "Open Claude Code in tmux to enable messaging")
                        .font(.system(size: 13))
                        .foregroundColor(theme.textDim)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }

                TextEditor(text: $inputText)
                    .font(.system(size: 13))
                    .foregroundColor(canSendMessages ? theme.textPrimary : theme.textDim)
                    .scrollContentBackground(.hidden)
                    .focused($isInputFocused)
                    .disabled(!canSendMessages)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: 36, maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                    .onKeyPress(.return, phases: .down) { keyPress in
                        // Shift+Enter = insert newline (handled by TextEditor)
                        // Enter alone = send message
                        if !keyPress.modifiers.contains(.shift) {
                            sendMessage()
                            return .handled
                        }
                        return .ignored
                    }
            }
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(canSendMessages ? theme.backgroundHover : theme.backgroundElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(theme.backgroundHover, lineWidth: 1)
                    )
            )

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(!canSendMessages || inputText.isEmpty ? theme.textDimmer : theme.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSendMessages || inputText.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.backgroundElevated)
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [theme.background.opacity(0), theme.background.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: -24) // Push above input bar
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
    }

    // MARK: - Approval Bar

    private func approvalBar(tool: String) -> some View {
        ChatApprovalBar(
            tool: tool,
            toolInput: session.pendingToolInput,
            onApprove: { approvePermission() },
            onApproveAlways: { approveAlwaysPermission() },
            onDeny: { denyPermission() },
            hideAlways: isNotificationPrompt
        )
    }

    // MARK: - Interactive Prompt Bar

    /// Bar for interactive tools like AskUserQuestion that need terminal input
    private var interactivePromptBar: some View {
        ChatInteractivePromptBar(
            isInTmux: session.isInTmux,
            onGoToTerminal: { focusTerminal() }
        )
    }

    // MARK: - Autoscroll Management

    /// Pause autoscroll (user scrolled away from bottom)
    private func pauseAutoscroll() {
        isAutoscrollPaused = true
        previousHistoryCount = history.count
    }

    /// Resume autoscroll and reset new message count
    private func resumeAutoscroll() {
        isAutoscrollPaused = false
        newMessageCount = 0
        previousHistoryCount = history.count
    }

    // MARK: - Actions

    private func refreshRemoteHistory() {
        guard session.isRemote, !isRefreshing else { return }

        isRefreshing = true

        Task {
            // Force a fresh load from remote
            await ChatHistoryManager.shared.loadFromFile(
                sessionId: sessionId,
                cwd: session.cwd,
                forceRemote: true
            )

            // Update local history from manager
            await MainActor.run {
                history = ChatHistoryManager.shared.history(for: sessionId)
                isRefreshing = false
                isLoading = false
            }
        }
    }

    private func focusTerminal() {
        Task {
            if let pid = session.pid {
                _ = await YabaiController.shared.focusWindow(forClaudePid: pid)
            } else {
                _ = await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd)
            }
        }
    }

    private func approvePermission() {
        sessionMonitor.approvePermission(sessionId: sessionId)
    }

    private func approveAlwaysPermission() {
        sessionMonitor.approveAlwaysPermission(sessionId: sessionId)
    }

    private func denyPermission() {
        // Capture any typed message before denying
        let message = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = ""

        sessionMonitor.denyPermission(sessionId: sessionId, reason: nil)

        // If user typed a message, send it after a short delay
        if !message.isEmpty {
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
                await sendToSession(message)
            }
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""

        // Resume autoscroll when user sends a message
        resumeAutoscroll()
        shouldScrollToBottom = true

        // If waiting for approval, deny with the message as the reason
        // This sends "n" + Enter, then the message atomically
        if isWaitingForApproval {
            sessionMonitor.denyPermission(sessionId: sessionId, reason: text)
        } else {
            Task {
                await sendToSession(text)
            }
        }
    }

    private func sendToSession(_ text: String) async {
        // Query live session from SessionStore (local @State may be stale)
        guard let liveSession = await SessionStore.shared.session(for: sessionId) else { return }

        // Handle remote sessions
        if let remoteHost = liveSession.remoteHost, let remoteTmuxTarget = liveSession.remoteTmuxTarget {
            _ = await ToolApprovalHandler.shared.sendMessage(text, remoteTmuxTarget: remoteTmuxTarget, remoteHost: remoteHost)
            return
        }

        // Handle local sessions
        guard liveSession.isInTmux else { return }
        guard let tty = liveSession.tty else { return }

        if let target = await findTmuxTarget(tty: tty) {
            _ = await ToolApprovalHandler.shared.sendMessage(text, to: target)
        }
    }

    private func findTmuxTarget(tty: String) async -> TmuxTarget? {
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
}

// MARK: - Message Item View

struct MessageItemView: View {
    let item: ChatHistoryItem
    let sessionId: String

    var body: some View {
        switch item.type {
        case .user(let text):
            UserMessageView(text: text)
        case .assistant(let text):
            AssistantMessageView(text: text)
        case .toolCall(let tool):
            ToolCallView(tool: tool, sessionId: sessionId)
        case .thinking(let text):
            ThinkingView(text: text)
        case .interrupted:
            InterruptedMessageView()
        }
    }
}

// MARK: - User Message

struct UserMessageView: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Spacer(minLength: 60)

            MarkdownText(text, color: theme.textPrimary, fontSize: 13)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(theme.backgroundHover)
                )
        }
    }
}

// MARK: - Assistant Message

struct AssistantMessageView: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Dot indicator
            Circle()
                .fill(theme.textSecondary)
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            MarkdownText(text, color: theme.textSecondary, fontSize: 13)

            Spacer(minLength: 60)
        }
    }
}

// MARK: - Processing Indicator

struct ProcessingIndicatorView: View {
    private let baseTexts = ["Processing", "Working"]
    private let baseText: String
    @Environment(\.theme) private var theme

    @State private var dotCount: Int = 1
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    /// Use a turnId to select text consistently per user turn
    init(turnId: String = "") {
        // Use hash of turnId to pick base text consistently for this turn
        let index = abs(turnId.hashValue) % baseTexts.count
        baseText = baseTexts[index]
    }

    private var dots: String {
        String(repeating: ".", count: dotCount)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ProcessingSpinner()
                .frame(width: 6)

            Text(baseText + dots)
                .font(.system(size: 13))
                .foregroundColor(theme.accent)

            Spacer()
        }
        .onReceive(timer) { _ in
            dotCount = (dotCount % 3) + 1
        }
    }
}

// MARK: - Tool Call View

struct ToolCallView: View {
    let tool: ToolCallItem
    let sessionId: String
    @Environment(\.theme) private var theme

    @State private var pulseOpacity: Double = 0.6
    @State private var isExpanded: Bool = false
    @State private var isHovering: Bool = false

    private var statusColor: Color {
        switch tool.status {
        case .running:
            return theme.textSecondary
        case .waitingForApproval:
            return theme.warning
        case .success:
            return theme.success
        case .error, .interrupted:
            return theme.error
        }
    }

    private var textColor: Color {
        switch tool.status {
        case .running:
            return theme.textDim
        case .waitingForApproval:
            return theme.warning.opacity(0.9)
        case .success:
            return theme.textSecondary
        case .error, .interrupted:
            return theme.error.opacity(0.8)
        }
    }

    private var hasResult: Bool {
        tool.result != nil || tool.structuredResult != nil
    }

    /// Whether the tool can be expanded (has result, NOT Task tools, NOT Edit tools)
    private var canExpand: Bool {
        tool.name != "Task" && tool.name != "Edit" && hasResult
    }

    private var showContent: Bool {
        tool.name == "Edit" || isExpanded
    }

    private var agentDescription: String? {
        guard tool.name == "AgentOutputTool",
              let agentId = tool.input["agentId"],
              let sessionDescriptions = ChatHistoryManager.shared.agentDescriptions[sessionId] else {
            return nil
        }
        return sessionDescriptions[agentId]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor.opacity(tool.status == .running || tool.status == .waitingForApproval ? pulseOpacity : 0.6))
                    .frame(width: 6, height: 6)
                    .id(tool.status)  // Forces view recreation, cancelling repeatForever animation
                    .onAppear {
                        if tool.status == .running || tool.status == .waitingForApproval {
                            startPulsing()
                        }
                    }

                // Tool name (formatted for MCP tools)
                Text(MCPToolFormatter.formatToolName(tool.name))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(textColor)
                    .fixedSize()

                if tool.name == "Task" && !tool.subagentTools.isEmpty {
                    let taskDesc = tool.input["description"] ?? "Running agent..."
                    Text("\(taskDesc) (\(tool.subagentTools.count) tools)")
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if tool.name == "AgentOutputTool", let desc = agentDescription {
                    let blocking = tool.input["block"] == "true"
                    Text(blocking ? "Waiting: \(desc)" : desc)
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if MCPToolFormatter.isMCPTool(tool.name) && !tool.input.isEmpty {
                    Text(MCPToolFormatter.formatArgs(tool.input))
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(tool.statusDisplay.text)
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                // Expand indicator (only for expandable tools)
                if canExpand && tool.status != .running && tool.status != .waitingForApproval {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.textDimmer)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
                }
            }

            // Subagent tools list (for Task tools)
            if tool.name == "Task" && !tool.subagentTools.isEmpty {
                SubagentToolsList(tools: tool.subagentTools)
                    .padding(.leading, 12)
                    .padding(.top, 2)
            }

            // Result content (Edit always shows, others when expanded)
            // Edit tools bypass hasResult check - fallback in ToolResultContent renders from input params
            if showContent && tool.status != .running && tool.name != "Task" && (hasResult || tool.name == "Edit") {
                ToolResultContent(tool: tool)
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Edit tools show diff from input even while running
            if tool.name == "Edit" && tool.status == .running {
                EditInputDiffView(input: tool.input)
                    .padding(.leading, 12)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(canExpand && isHovering ? theme.backgroundHover : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            if canExpand {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
    }

    private func startPulsing() {
        withAnimation(
            .easeInOut(duration: 0.6)
            .repeatForever(autoreverses: true)
        ) {
            pulseOpacity = 0.15
        }
    }
}

// MARK: - Subagent Views

/// List of subagent tools (shown during Task execution)
struct SubagentToolsList: View {
    let tools: [SubagentToolCall]
    @Environment(\.theme) private var theme

    /// Number of hidden tools (all except last 2)
    private var hiddenCount: Int {
        max(0, tools.count - 2)
    }

    /// Recent tools to show (last 2, regardless of status)
    private var recentTools: [SubagentToolCall] {
        Array(tools.suffix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Show count of older hidden tools at top
            if hiddenCount > 0 {
                Text("+\(hiddenCount) more tool uses")
                    .font(.system(size: 10))
                    .foregroundColor(theme.textDim)
            }

            // Show last 2 tools (most recent activity)
            ForEach(recentTools) { tool in
                SubagentToolRow(tool: tool)
            }
        }
    }
}

/// Single subagent tool row
struct SubagentToolRow: View {
    let tool: SubagentToolCall
    @Environment(\.theme) private var theme

    @State private var dotOpacity: Double = 0.5

    private var statusColor: Color {
        switch tool.status {
        case .running, .waitingForApproval: return theme.warning
        case .success: return theme.success
        case .error, .interrupted: return theme.error
        }
    }

    /// Get status text using the same logic as regular tools
    private var statusText: String {
        if tool.status == .interrupted {
            return "Interrupted"
        } else if tool.status == .running {
            return ToolStatusDisplay.running(for: tool.name, input: tool.input).text
        } else {
            // For completed subagent tools, we don't have the result data
            // so use a simple display based on tool name and input
            return ToolStatusDisplay.running(for: tool.name, input: tool.input).text
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            // Status dot
            Circle()
                .fill(statusColor.opacity(tool.status == .running ? dotOpacity : 0.6))
                .frame(width: 4, height: 4)
                .id(tool.status)  // Forces view recreation, cancelling repeatForever animation
                .onAppear {
                    if tool.status == .running {
                        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                            dotOpacity = 0.2
                        }
                    }
                }

            // Tool name
            Text(tool.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.textDim)

            // Status text (same format as regular tools)
            Text(statusText)
                .font(.system(size: 10))
                .foregroundColor(theme.textDimmer)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Summary of subagent tools (shown when Task is expanded after completion)
struct SubagentToolsSummary: View {
    let tools: [SubagentToolCall]
    @Environment(\.theme) private var theme

    private var toolCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for tool in tools {
            counts[tool.name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Subagent used \(tools.count) tools:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.textDim)

            HStack(spacing: 8) {
                ForEach(toolCounts.prefix(5), id: \.0) { name, count in
                    HStack(spacing: 2) {
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.textDimmer)
                        Text("×\(count)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(theme.textDimmer.opacity(0.7))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.backgroundElevated)
        )
    }
}

// MARK: - Thinking View

struct ThinkingView: View {
    let text: String
    @Environment(\.theme) private var theme

    @State private var isExpanded = false

    private var canExpand: Bool {
        text.count > 80
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(theme.textDim)
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            Text(isExpanded ? text : String(text.prefix(80)) + (canExpand ? "..." : ""))
                .font(.system(size: 11))
                .foregroundColor(theme.textDim)
                .italic()
                .lineLimit(isExpanded ? nil : 1)
                .multilineTextAlignment(.leading)

            Spacer()

            if canExpand {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(theme.textDimmer)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.top, 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if canExpand {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

// MARK: - Interrupted Message

struct InterruptedMessageView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Text("Interrupted")
                .font(.system(size: 13))
                .foregroundColor(theme.error)
            Spacer()
        }
    }
}

// MARK: - Chat Interactive Prompt Bar

/// Bar for interactive tools like AskUserQuestion that need terminal input
struct ChatInteractivePromptBar: View {
    let isInTmux: Bool
    let onGoToTerminal: () -> Void
    @Environment(\.theme) private var theme

    @State private var showContent = false
    @State private var showButton = false

    var body: some View {
        HStack(spacing: 12) {
            // Tool info - same style as approval bar
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPToolFormatter.formatToolName("AskUserQuestion"))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.warning)
                Text("Claude Code needs your input")
                    .font(.system(size: 11))
                    .foregroundColor(theme.textDim)
                    .lineLimit(1)
            }
            .opacity(showContent ? 1 : 0)
            .offset(x: showContent ? 0 : -10)

            Spacer()

            // Terminal button on right (similar to Allow button)
            Button {
                if isInTmux {
                    onGoToTerminal()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                    Text("Terminal")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(isInTmux ? theme.background : theme.textDim)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isInTmux ? theme.textPrimary : theme.backgroundHover)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showButton ? 1 : 0)
            .scaleEffect(showButton ? 1 : 0.8)
        }
        .frame(minHeight: 44)  // Consistent height with other bars
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.backgroundElevated)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
                showButton = true
            }
        }
    }
}

// MARK: - Chat Approval Bar

/// Approval bar for the chat view with animated buttons
struct ChatApprovalBar: View {
    let tool: String
    let toolInput: String?
    let onApprove: () -> Void
    let onApproveAlways: () -> Void
    let onDeny: () -> Void
    var hideAlways: Bool = false
    @Environment(\.theme) private var theme

    @State private var showContent = false
    @State private var showAllowButton = false
    @State private var showAlwaysButton = false
    @State private var showDenyButton = false

    var body: some View {
        HStack(spacing: 12) {
            // Tool info
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPToolFormatter.formatToolName(tool))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.warning)
                if let input = toolInput {
                    Text(input)
                        .font(.system(size: 11))
                        .foregroundColor(theme.textDim)
                        .lineLimit(1)
                }
            }
            .opacity(showContent ? 1 : 0)
            .offset(x: showContent ? 0 : -10)

            Spacer()

            // Deny button
            Button {
                onDeny()
            } label: {
                Text("Deny")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(theme.backgroundHover)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            // Always button (hidden for notification-based prompts)
            if !hideAlways {
                Button {
                    onApproveAlways()
                } label: {
                    Text("Always")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.textSecondary.opacity(0.9))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(theme.backgroundHover.opacity(1.2))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity(showAlwaysButton ? 1 : 0)
                .scaleEffect(showAlwaysButton ? 1 : 0.8)
            }

            // Allow button
            Button {
                onApprove()
            } label: {
                Text("Allow")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.background)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(theme.textPrimary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .frame(minHeight: 44)  // Consistent height with other bars
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.backgroundElevated)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.15)) {
                showAlwaysButton = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.2)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - New Messages Indicator

/// Floating indicator showing count of new messages when user has scrolled up
struct NewMessagesIndicator: View {
    let count: Int
    let onTap: () -> Void
    @Environment(\.theme) private var theme

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))

                Text(count == 1 ? "1 new message" : "\(count) new messages")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(theme.background)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(theme.accent)
                    .shadow(color: theme.background.opacity(0.3), radius: 8, x: 0, y: 4)
            )
            .scaleEffect(isHovering ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
    }
}
