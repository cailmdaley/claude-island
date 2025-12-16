//
//  NotchViewModel.swift
//  ClaudeIsland
//
//  State management for the dynamic island
//

import AppKit
import Combine
import SwiftUI

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

enum NotchOpenReason {
    case click
    case hover
    case notification
    case boot
    case hotkey
    case unknown
}

enum NotchContentType: Equatable {
    case instances
    case menu
    case chat(SessionState)

    var id: String {
        switch self {
        case .instances: return "instances"
        case .menu: return "menu"
        case .chat(let session): return "chat-\(session.sessionId)"
        }
    }
}

@MainActor
class NotchViewModel: ObservableObject {
    // MARK: - Published State

    @Published var status: NotchStatus = .closed
    @Published var openReason: NotchOpenReason = .unknown
    @Published var contentType: NotchContentType = .instances
    @Published var isHovering: Bool = false

    // MARK: - Keyboard Navigation State

    /// Currently selected session index (nil = no selection)
    @Published var selectedSessionIndex: Int? = nil

    /// Cached sessions for keyboard navigation (synced from view)
    private(set) var cachedSessions: [SessionState] = []

    /// Number of sessions (for dynamic height calculation)
    @Published private(set) var sessionCount: Int = 0

    // MARK: - Dependencies

    private let screenSelector = ScreenSelector.shared
    private let soundSelector = SoundSelector.shared

    // MARK: - Geometry

    let geometry: NotchGeometry
    let spacing: CGFloat = 12
    let hasPhysicalNotch: Bool

    var deviceNotchRect: CGRect { geometry.deviceNotchRect }
    var screenRect: CGRect { geometry.screenRect }
    var windowHeight: CGFloat { geometry.windowHeight }

    /// Dynamic opened size based on content type
    var openedSize: CGSize {
        switch contentType {
        case .chat:
            // Terminal-width chat view (80 chars @ 7.5px/char = 600px)
            let charWidth: CGFloat = 7.5  // Google Sans Mono size 13
            let terminalColumns: CGFloat = 80
            let calculatedWidth = terminalColumns * charWidth

            return CGSize(
                width: min(screenRect.width * 0.9, calculatedWidth),
                height: AppSettings.chatViewHeight
            )
        case .menu:
            // Menu size - account for all rows (~40px each) plus dividers
            // Rows: Back, Screen, Sound, Theme, Login, Hooks, Accessibility, Update, GitHub, Restart, Quit = 11 rows
            // Plus 4 dividers = ~15 rows worth of space
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 520 + screenSelector.expandedPickerHeight + soundSelector.expandedPickerHeight
            )
        case .instances:
            // Terminal-width instances view (80 chars @ 7.5px/char = 600px)
            let charWidth: CGFloat = 7.5
            let terminalColumns: CGFloat = 80
            let calculatedWidth = terminalColumns * charWidth

            // Dynamic height based on session count
            // Each row: ~60px (including padding), spacing: 2px between rows
            let baseHeight: CGFloat = 60
            let spacing: CGFloat = 2
            let minHeight: CGFloat = 150
            let maxHeight: CGFloat = 500

            let calculatedHeight: CGFloat
            if sessionCount == 0 {
                // Empty state
                calculatedHeight = minHeight
            } else {
                // Height = (rows * baseHeight) + (gaps * spacing)
                let contentHeight = CGFloat(sessionCount) * baseHeight + CGFloat(sessionCount - 1) * spacing
                calculatedHeight = contentHeight
            }

            return CGSize(
                width: min(screenRect.width * 0.9, calculatedWidth),
                height: min(max(calculatedHeight, minHeight), maxHeight)
            )
        }
    }

    // MARK: - Animation

    var animation: Animation {
        .easeOut(duration: 0.25)
    }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let events = EventMonitors.shared
    private var hoverTimer: DispatchWorkItem?

    // MARK: - Initialization

    init(deviceNotchRect: CGRect, screenRect: CGRect, windowHeight: CGFloat, hasPhysicalNotch: Bool) {
        self.geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
        self.hasPhysicalNotch = hasPhysicalNotch
        setupEventHandlers()
        observeSelectors()
    }

    private func observeSelectors() {
        screenSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        soundSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Event Handling

    private func setupEventHandlers() {
        events.mouseLocation
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] location in
                self?.handleMouseMove(location)
            }
            .store(in: &cancellables)

        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleMouseDown()
            }
            .store(in: &cancellables)
    }

    /// Whether we're in chat mode (sticky behavior)
    private var isInChatMode: Bool {
        if case .chat = contentType { return true }
        return false
    }

    /// The chat session we're viewing (persists across close/open)
    private var currentChatSession: SessionState?

    private func handleMouseMove(_ location: CGPoint) {
        let inNotch = geometry.isPointInNotch(location)
        let inOpened = status == .opened && geometry.isPointInOpenedPanel(location, size: openedSize)

        let newHovering = inNotch || inOpened

        // Only update if changed to prevent unnecessary re-renders
        guard newHovering != isHovering else { return }

        isHovering = newHovering

        // Cancel any pending hover timer
        hoverTimer?.cancel()
        hoverTimer = nil

        // Start hover timer to auto-expand after 1 second
        if isHovering && (status == .closed || status == .popping) {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.isHovering else { return }
                self.notchOpen(reason: .hover)
            }
            hoverTimer = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
        }
    }

    private func handleMouseDown() {
        let location = NSEvent.mouseLocation

        switch status {
        case .opened:
            if geometry.isPointOutsidePanel(location, size: openedSize) {
                notchClose()
                // Re-post the click so it reaches the window/app behind us
                repostClickAt(location)
            } else if geometry.notchScreenRect.contains(location) {
                // Clicking notch while opened - only close if NOT in chat mode
                if !isInChatMode {
                    notchClose()
                }
            }
        case .closed, .popping:
            if geometry.isPointInNotch(location) {
                notchOpen(reason: .click)
            }
        }
    }

    /// Re-posts a mouse click at the given screen location so it reaches windows behind us
    private func repostClickAt(_ location: CGPoint) {
        // Small delay to let the window's ignoresMouseEvents update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Convert to CGEvent coordinate system (screen coordinates with Y from top-left)
            guard let screen = NSScreen.main else { return }
            let screenHeight = screen.frame.height
            let cgPoint = CGPoint(x: location.x, y: screenHeight - location.y)

            // Create and post mouse down event
            if let mouseDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseDown.post(tap: .cghidEventTap)
            }

            // Create and post mouse up event
            if let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseUp.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Actions

    func notchOpen(reason: NotchOpenReason = .unknown) {
        openReason = reason
        status = .opened

        // Clear keyboard selection on fresh open
        clearSelection()

        // Don't restore chat on notification - show instances list instead
        if reason == .notification {
            currentChatSession = nil
            return
        }

        // Restore chat session if we had one open before
        if let chatSession = currentChatSession {
            // Avoid unnecessary updates if already showing this chat
            if case .chat(let current) = contentType, current.sessionId == chatSession.sessionId {
                return
            }
            contentType = .chat(chatSession)
        }
    }

    func notchClose() {
        // Save chat session before closing if in chat mode
        if case .chat(let session) = contentType {
            currentChatSession = session
        }
        status = .closed
        contentType = .instances
    }

    func notchPop() {
        guard status == .closed else { return }
        status = .popping
    }

    func notchUnpop() {
        guard status == .popping else { return }
        status = .closed
    }

    func toggleMenu() {
        contentType = contentType == .menu ? .instances : .menu
    }

    func showChat(for session: SessionState) {
        // Avoid unnecessary updates if already showing this chat
        if case .chat(let current) = contentType, current.sessionId == session.sessionId {
            return
        }
        contentType = .chat(session)
    }

    /// Go back to instances list and clear saved chat state
    func exitChat() {
        currentChatSession = nil
        contentType = .instances
    }

    /// Perform boot animation: expand briefly then collapse
    func performBootAnimation() {
        notchOpen(reason: .boot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.openReason == .boot else { return }
            self.notchClose()
        }
    }

    // MARK: - Keyboard Navigation

    /// Update cached sessions from the view (call when sessions change)
    func updateSessions(_ sessions: [SessionState]) {
        cachedSessions = sessions
        sessionCount = sessions.count

        // Auto-select first session if no selection exists
        if selectedSessionIndex == nil && !sessions.isEmpty {
            selectedSessionIndex = 0
        }

        // Clamp selection if out of bounds
        if let index = selectedSessionIndex, index >= sessions.count {
            selectedSessionIndex = sessions.isEmpty ? nil : sessions.count - 1
        }
    }

    /// Select next session (down arrow), wrapping to first
    func selectNext() {
        guard !cachedSessions.isEmpty else { return }

        if let current = selectedSessionIndex {
            selectedSessionIndex = (current + 1) % cachedSessions.count
        } else {
            selectedSessionIndex = 0
        }
    }

    /// Select previous session (up arrow), wrapping to last
    func selectPrevious() {
        guard !cachedSessions.isEmpty else { return }

        if let current = selectedSessionIndex {
            selectedSessionIndex = current == 0 ? cachedSessions.count - 1 : current - 1
        } else {
            selectedSessionIndex = cachedSessions.count - 1
        }
    }

    /// Get the currently selected session
    func selectedSession() -> SessionState? {
        guard let index = selectedSessionIndex, index < cachedSessions.count else {
            return nil
        }
        return cachedSessions[index]
    }

    /// Open chat for the selected session (enter key)
    func openSelectedChat() {
        guard let session = selectedSession() else { return }
        showChat(for: session)
    }

    /// Clear selection (called on fresh open)
    func clearSelection() {
        selectedSessionIndex = nil
    }
}
