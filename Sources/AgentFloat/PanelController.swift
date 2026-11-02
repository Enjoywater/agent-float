import AgentFloatCore
import AppKit
import Observation
import SwiftUI

/// Centralize transition tuning for later adjustments (spec §4.8: natural and smooth).
enum Motion {
    static let expandDelay = scaled(0.15)
    static let collapseDelay = scaled(0.4)
    static let spring = Animation.spring(response: scaled(0.42), dampingFraction: 0.86)
    static let listFadeInDelay = scaled(0.08)
    static let listFadeIn = Animation.easeOut(duration: scaled(0.2))
    static let listFadeOut = Animation.easeIn(duration: scaled(0.12))
    /// Use this transition instead of morphing when Reduce Motion is enabled.
    static let crossfade = Animation.easeInOut(duration: scaled(0.15))
    static let sweepPeriod = scaled(2.6)
    /// Wait for the content spring to settle before shrinking the window, avoiding clipping.
    static let pillShrinkDelay = scaled(0.5)
    /// Elapsed time is shown in minutes, so more frequent redraws are unnecessary.
    static let labelTick: TimeInterval = 15

    static func isReduced(_ systemSetting: Bool) -> Bool {
        systemSetting || forceReduced
    }

    /// Debug override for Reduce Motion without changing system settings.
    private static let forceReduced = ProcessInfo.processInfo.environment["AGENT_FLOAT_REDUCE_MOTION"] == "1"
    /// Slow transitions for intermediate screenshots; 8 means eight times slower.
    private static let slowFactor = Double(ProcessInfo.processInfo.environment["AGENT_FLOAT_SLOW_MOTION"] ?? "") ?? 1

    private static func scaled(_ seconds: Double) -> Double {
        seconds * slowFactor
    }
}

/// Only PanelController advances rendering phases because they must stay synchronized with window sizing.
@MainActor @Observable
final class PanelPresentation {
    var isGlassExpanded = false
    var isListVisible = false
    var anchorsTrailing = true
    var pillWidth: CGFloat = Layout.pillHeight
    var panelHeight: CGFloat = Layout.panelChromeHeight
    var listHeight: CGFloat = 0
    var glassContrast = GlassContrast.outline
    /// List width 280, reply width 320 (v1.2 design §4.8).
    var panelWidth: CGFloat = Layout.panelWidth
    var content = PanelContent.list
    var replyPlacement = ReplyPlacement.panel
    /// Do not observe values that cannot affect rendering.
    @ObservationIgnored var isDragging = false
    @ObservationIgnored var openReply: ((AgentSession) -> Void)?
    /// Forward the main glass's sampled tone; the side card follows appearance rather than sampling its own background.
    @ObservationIgnored var onGlassTone: ((GlassTone) -> Void)?
    @ObservationIgnored var replyActions = ReplyActions()
    /// Row positions relative to the window top are used only to align the side card, so do not observe them.
    @ObservationIgnored var rowFrames: [SessionKey: CGRect] = [:]
}

enum PanelContent {
    case list, reply
}

/// Own panel frames, hover handling, and expansion transitions.
/// Resize windows immediately; animate only SwiftUI content (spec §4.8).
@MainActor
final class PanelController: NSObject {
    private static let anchorKey = "panelAnchor"
    private static let contrastKey = "glassContrast"
    private static let placementKey = "replyPlacement"

    let panel: FloatingPanel
    let hostingView: PanelHostingView<FloatRootView>

    private let model: AppModel
    private let replies: ReplyCenter
    private let card: ReplyCardController
    private let presentation: PanelPresentation
    private let hoverTracker = HoverTracker()
    private let pillMeasurer = NSHostingView(rootView: PillMeasure(summary: AppModel.emptySummary))
    private let listMeasurer = NSHostingView(rootView: ListMeasure(groups: [], unseen: []))

    private var anchor: PanelAnchor
    private var phase = Phase.collapsed
    /// Version every transition so delayed phases cannot overwrite a newer reversal.
    private var generation = 0
    /// An old height spring may finish during a newer transition; only the latest completion may resize the window.
    private var heightGeneration = 0
    private var isHovering = false
    private var isAdjustingFrame = false
    private var lastAppliedFrame = CGRect.zero
    private var hoverTask: Task<Void, Never>?
    private var listFadeTask: Task<Void, Never>?
    private var pillResizeTask: Task<Void, Never>?
    private var dragSettleTask: Task<Void, Never>?
    private var buttonWatchTask: Task<Void, Never>?
    private var mouseDownMonitor: Any?
    private var keyMonitor: Any?
    /// Remember the frontmost app before replying and restore its keyboard input on close (v1.2 design §4.7).
    private var previousApp: NSRunningApplication?
    /// Overlapping width/height transitions must resize only from the latest completion.
    private var resizeGeneration = 0
    /// Open replies without keyboard input during screenshot-only debug runs.
    private var debugHoldsReply = false
    private var didRequestAccessibility = false

    private enum Phase {
        case collapsed, expanded, collapsing
    }

    init(model: AppModel, replies: ReplyCenter) {
        self.model = model
        self.replies = replies
        card = ReplyCardController(replies: replies)
        let presentation = PanelPresentation()
        presentation.glassContrast = GlassContrast.resolve(
            override: ProcessInfo.processInfo.environment["AGENT_FLOAT_CONTRAST"],
            saved: UserDefaults.standard.string(forKey: Self.contrastKey)
        )
        presentation.replyPlacement = ReplyPlacement.resolve(
            override: ProcessInfo.processInfo.environment["AGENT_FLOAT_REPLY_PLACEMENT"],
            saved: UserDefaults.standard.string(forKey: Self.placementKey)
        )
        self.presentation = presentation

        let host = PanelHostingView(rootView: FloatRootView(model: model, replies: replies, presentation: presentation))
        // Disable the default SwiftUI content-size constraint because this controller owns window sizing and morphing.
        host.sizingOptions = []
        hostingView = host

        let size = Self.measurePill(pillMeasurer, summary: model.summary)
        anchor = Self.restoredAnchor(saved: Self.savedAnchor(), size: size)
        presentation.anchorsTrailing = anchor.trailing
        presentation.pillWidth = size.width

        let frame = anchor.pillFrame(size: size)
        panel = FloatingPanel(contentRect: frame)
        panel.contentView = host
        lastAppliedFrame = frame
        super.init()

        // activeAlways is required to receive hover while the panel is not key.
        // Share tracking with the card so crossing the gap within the 0.4-second delay cancels collapse (design §4.5 B).
        for view in [host, card.panel.contentView].compactMap(\.self) {
            view.addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: hoverTracker,
                userInfo: nil
            ))
        }
        hoverTracker.onChange = { [weak self] inside in self?.hoverChanged(inside) }
        model.onChange = { [weak self] in self?.modelDidChange() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(panelWillMove(_:)), name: NSWindow.willMoveNotification, object: panel
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidMove(_:)), name: NSWindow.didMoveNotification, object: panel
        )
        // Do not expand during a pill drag, which would replace the object being dragged (R35).
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                if event.window === self?.panel { self?.mouseWentDown() }
            }
            return event
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensDidChange(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: panel
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: card.panel
        )
        connectReplies()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func resetPosition() {
        let size = pillSize()
        anchor = Self.restoredAnchor(saved: nil, size: size)
        saveAnchor()
        // While expanded, defer returning to the reset position until collapse.
        guard phase == .collapsed else { return }
        presentation.anchorsTrailing = anchor.trailing
        presentation.pillWidth = size.width
        applyFrame(anchor.pillFrame(size: size))
    }

    /// Flush pending position persistence before quitting; the 0.3-second debounce may not have fired (R28).
    func flushPendingSave() {
        guard let task = dragSettleTask else { return }
        task.cancel()
        dragSettleTask = nil
        anchor = anchorFromWindow()
        saveAnchor()
    }

    func debugExpand() {
        hoverTask?.cancel()
        expand()
        _ = after(1) { controller in
            AppDelegate.logTrackingAreas(of: controller.hostingView)
            controller.logHitTests()
            controller.debugOpenReply()
        }
    }

    /// AGENT_FLOAT_OPEN_REPLY=<n> opens the nth answerable waiting session after expansion for unattended capture.
    /// Synthetic keys can leak to the user's foreground app; simulate selection, input, send, and close via environment variables:
    /// _SELECT=<zero-based indices, comma-separated>, _TEXT=<text>, _ADVANCE=1, _SEND=1, _CLOSE_AFTER=<seconds>.
    private func debugOpenReply() {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["AGENT_FLOAT_OPEN_REPLY"], let index = Int(raw) else { return }
        var candidates = model.groups.flatMap(\.sessions).filter { $0.status == .waiting && $0.prompt != nil }
        // _SESSION=<sessionId> limits measurements to the designated test session, avoiding real user sessions.
        if let target = environment["AGENT_FLOAT_OPEN_REPLY_SESSION"] { candidates = candidates.filter { $0.key.sessionId == target } }
        guard candidates.indices.contains(index) else { return }
        DebugLog.write("debug focus before=\(Self.focusedApplicationPid()) front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
        openReply(candidates[index])
        for choice in (environment["AGENT_FLOAT_OPEN_REPLY_SELECT"] ?? "").split(separator: ",").compactMap({ Int($0) }) {
            replies.choose(choice)
        }
        if let text = environment["AGENT_FLOAT_OPEN_REPLY_TEXT"] {
            replies.edit { editor in
                if case .text = editor.prompt { editor.setReply(text) } else { editor.setOther(text) }
            }
        }
        if environment["AGENT_FLOAT_OPEN_REPLY_ADVANCE"] == "1" { replies.edit { $0.advance() } }
        // _STEPS=0;1 selects an answer and advances each question for multi-question confirmation captures.
        for step in (environment["AGENT_FLOAT_OPEN_REPLY_STEPS"] ?? "").split(separator: ";").compactMap({ Int($0) }) {
            replies.choose(step)
            replies.edit { $0.advance() }
        }
        // Screenshot-only runs must not take keyboard input from the user's app.
        if environment["AGENT_FLOAT_OPEN_REPLY_NO_KEY"] == "1" {
            debugHoldsReply = true
            releaseKeyInput(restoreFocus: false)
        }
        if environment["AGENT_FLOAT_OPEN_REPLY_SEND"] == "1" {
            // Wait for availability assessment before sending.
            _ = after(0.3) { $0.replyPrimary() }
        }
        DebugLog.write("debug focus open=\(Self.focusedApplicationPid()) key=\(panel.isKeyWindow)")
        if let seconds = environment["AGENT_FLOAT_OPEN_REPLY_CLOSE_AFTER"].flatMap(Double.init) {
            _ = after(seconds) { controller in
                controller.closeReply(restoreFocus: true)
                _ = controller.after(0.5) { controller in
                    DebugLog.write("debug focus closed=\(Self.focusedApplicationPid()) key=\(controller.panel.isKeyWindow)")
                }
            }
        }
    }

    /// The app receiving system keyboard input; verify restoration after closing replies (measurement S4).
    private static func focusedApplicationPid() -> Int32 {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return 0 }
        var pid: Int32 = 0
        AXUIElementGetPid(unsafeDowncast(value, to: AXUIElement.self), &pid)
        return pid
    }

    /// Use actual hitTest results to determine whether overlay AppKit views intercept dragging or row clicks.
    private func logHitTests() {
        let bounds = hostingView.bounds
        let probes = [
            ("summary", CGPoint(x: bounds.maxX - 30, y: Layout.pillHeight / 2)),
            ("row", CGPoint(x: bounds.midX, y: Layout.panelChromeHeight + 30)),
        ]
        for (name, point) in probes {
            guard let superview = hostingView.superview else { continue }
            let hit = superview.hitTest(hostingView.convert(point, to: superview))
            DebugLog.write("hitTest \(name)=\(hit.map { String(describing: type(of: $0)) } ?? "nil") attention=\(model.summary.attention)")
        }
    }

    func debugCollapse() {
        hoverTask?.cancel()
        collapse()
    }

    // MARK: hover

    private func hoverChanged(_ inside: Bool) {
        isHovering = inside
        DebugLog.write("hover inside=\(inside) phase=\(phase)")
        // Ignore hover while dragging; transitions would move the intended drop location (spec §4.8).
        guard !presentation.isDragging else { return }
        scheduleHoverTransition()
    }

    private func scheduleHoverTransition() {
        hoverTask?.cancel()
        if isHovering {
            guard phase != .expanded, !Self.isPrimaryButtonDown else { return }
            hoverTask = after(Motion.expandDelay) { controller in
                // A button pressed during the delay indicates a drag.
                guard !Self.isPrimaryButtonDown else { return }
                controller.expand()
            }
        } else {
            guard phase == .expanded, !holdsReplyOpen else { return }
            hoverTask = after(Motion.collapseDelay) { $0.collapse() }
        }
    }

    private static var isPrimaryButtonDown: Bool {
        NSEvent.pressedMouseButtons & 1 != 0
    }

    private func mouseWentDown() {
        hoverTask?.cancel()
        DebugLog.write("mouse down phase=\(phase)")
        // performDrag can consume mouse-up; observe button state directly.
        buttonWatchTask?.cancel()
        buttonWatchTask = Task { [weak self] in
            while Self.isPrimaryButtonDown {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            guard let self else { return }
            self.buttonWatchTask = nil
            DebugLog.write("mouse up phase=\(self.phase)")
            self.syncHover()
        }
    }

    /// Resizing can lose enter/exit events; reconcile against the actual cursor position.
    private func syncHover() {
        let pointer = NSEvent.mouseLocation
        isHovering = panel.frame.contains(pointer) || (card.isVisible && card.panel.frame.contains(pointer))
        guard !presentation.isDragging else { return }
        scheduleHoverTransition()
    }

    // MARK: Expansion and collapse

    private func expand() {
        // With no sessions, expansion adds only the summary row; keep the dimmed pill.
        guard !presentation.isDragging, !model.sessions.isEmpty else { return }
        let pill = anchor.pillFrame(size: pillSize())
        let layout = expandedLayout(pill: pill)
        presentation.pillWidth = pill.width
        generation += 1
        let generation = generation
        pillResizeTask?.cancel()
        listFadeTask?.cancel()
        phase = .expanded
        model.isExpanded = true

        // Grow the window to its target size first; fixed-corner anchoring keeps the pill stationary.
        presentation.anchorsTrailing = layout.trailing
        presentation.panelHeight = layout.panelHeight
        presentation.listHeight = layout.listHeight
        applyFrame(layout.windowFrame)
        // Resolve the pill frame in the enlarged window before morphing, or it slides from the old frame.
        hostingView.layoutSubtreeIfNeeded()
        DebugLog.write("expand frame=\(Self.describe(layout.windowFrame)) trailing=\(layout.trailing) list=\(layout.listHeight) reduced=\(isReduced)")

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.startExpandMotion(generation)
            }
        }
    }

    private func startExpandMotion(_ generation: Int) {
        if isReduced {
            withAnimation(Motion.crossfade) {
                presentation.isGlassExpanded = true
                presentation.isListVisible = true
            }
            return
        }
        withAnimation(Motion.spring) {
            presentation.isGlassExpanded = true
        }
        // Grow the glass before introducing the list so it reads as one expanding surface.
        listFadeTask = after(Motion.listFadeInDelay) { controller in
            guard controller.generation == generation else { return }
            DebugLog.write("list fade-in")
            withAnimation(Motion.listFadeIn) {
                controller.presentation.isListVisible = true
            }
        }
    }

    private func collapse() {
        guard phase == .expanded else { return }
        if replies.openKey != nil || presentation.content == .reply {
            // Preserve drafted answers but reopen on the list (design §4.7 collapse).
            replies.close()
            card.hide()
            presentation.content = .list
            releaseKeyInput(restoreFocus: false)
        }
        // Use the current count while collapsing; an outdated pill width would clip and jump.
        presentation.pillWidth = pillSize().width
        generation += 1
        let generation = generation
        listFadeTask?.cancel()
        phase = .collapsing
        model.isExpanded = false
        DebugLog.write("collapse begin reduced=\(isReduced)")

        if isReduced {
            withAnimation(Motion.crossfade) {
                presentation.isListVisible = false
                presentation.isGlassExpanded = false
            } completion: { [weak self] in
                self?.finishCollapse(generation)
            }
            return
        }
        // Remove the list before shrinking glass so text cannot protrude beyond it.
        withAnimation(Motion.listFadeOut) {
            presentation.isListVisible = false
        } completion: { [weak self] in
            guard let self, self.generation == generation else { return }
            DebugLog.write("glass collapse")
            withAnimation(Motion.spring) {
                self.presentation.isGlassExpanded = false
            } completion: { [weak self] in
                self?.finishCollapse(generation)
            }
        }
    }

    /// Shrink the window after morphing; shrinking first clips glass at the window edge.
    private func finishCollapse(_ generation: Int) {
        guard self.generation == generation, phase == .collapsing else { return }
        // If dragging began during collapse, collapse at the current drag position rather than the saved frame.
        if presentation.isDragging {
            anchor = anchorFromWindow()
        }
        phase = .collapsed
        presentation.panelWidth = Layout.panelWidth
        let size = pillSize()
        // Dragging to an edge or disconnecting a display can leave the collapsed pill offscreen.
        let onScreen = clampedAnchor(anchor, size: size)
        if onScreen != anchor {
            anchor = onScreen
            saveAnchor()
        }
        presentation.anchorsTrailing = anchor.trailing
        presentation.pillWidth = size.width
        let frame = anchor.pillFrame(size: size)
        applyFrame(frame)
        DebugLog.write("collapse end frame=\(Self.describe(frame))")
        syncHover()
    }

    private var isReduced: Bool {
        Motion.isReduced(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    // MARK: Content changes

    private func modelDidChange() {
        switch phase {
        case .collapsed:
            resizePill()
        case .expanded:
            replies.sync(with: model.sessions)
            if model.sessions.isEmpty {
                collapse()
            } else if replies.openKey != nil {
                adjustReplyLayout()
            } else {
                adjustExpandedHeight()
            }
        case .collapsing:
            // Fit the window to the current pill size when collapse finishes.
            break
        }
    }

    /// Grow the window before content expands, but shrink after content transitions to avoid clipping.
    private func resizePill() {
        let size = pillSize()
        // Recheck bounds: a position valid for the initial empty pill may not fit a wider pill.
        let onScreen = clampedAnchor(anchor, size: size)
        let relocated = onScreen != anchor
        anchor = onScreen
        if relocated { saveAnchor() }
        presentation.anchorsTrailing = anchor.trailing
        let target = anchor.pillFrame(size: size)
        pillResizeTask?.cancel()
        let resizeNow = relocated || target.width >= panel.frame.width
        if resizeNow {
            applyFrame(target)
            // Resolve the pill frame after growing the window so width morphing starts at the fixed corner.
            hostingView.layoutSubtreeIfNeeded()
        }
        withAnimation(isReduced ? Motion.crossfade : Motion.spring) {
            presentation.pillWidth = size.width
        }
        guard !resizeNow else { return }
        pillResizeTask = after(Motion.pillShrinkDelay) { controller in
            guard controller.phase == .collapsed else { return }
            controller.applyFrame(controller.anchor.pillFrame(size: controller.pillSize()))
        }
    }

    /// While expanded, keep the top and anchored side fixed and spring only the height.
    private func adjustExpandedHeight() {
        let layout = expandedLayout(pill: pillAtWindowCorner())
        guard layout.panelHeight != presentation.panelHeight else { return }
        let frame = expandedWindowFrame(height: layout.panelHeight)
        if frame.height > panel.frame.height { applyFrame(frame) }
        let generation = generation
        heightGeneration += 1
        let heightGeneration = heightGeneration
        DebugLog.write("adjust height panel=\(layout.panelHeight) list=\(layout.listHeight)")
        withAnimation(isReduced ? Motion.crossfade : Motion.spring) {
            presentation.panelHeight = layout.panelHeight
            presentation.listHeight = layout.listHeight
        } completion: { [weak self] in
            guard let self, self.generation == generation, self.heightGeneration == heightGeneration, self.phase == .expanded else {
                DebugLog.write("height completion skipped (superseded)")
                return
            }
            // Content may have grown again while shrinking; fit the current target, not the captured height.
            let settled = self.expandedWindowFrame(height: self.presentation.panelHeight)
            self.applyFrame(settled)
            DebugLog.write("height settled window=\(settled.height) panel=\(self.presentation.panelHeight)")
        }
    }

    /// Resize height while preserving the top and anchored side.
    private func expandedWindowFrame(height: CGFloat) -> CGRect {
        let current = panel.frame
        let visible = Self.visibleFrame(for: current)
        var frame = current
        frame.size.height = height
        frame.origin.y = max(current.maxY - height, visible.minY)
        return frame
    }

    private struct ExpandedLayout {
        let windowFrame: CGRect
        let trailing: Bool
        let panelHeight: CGFloat
        let listHeight: CGFloat
    }

    /// Measure the list before expansion so window and glass reach their target height together (spec §4.8).
    private func expandedLayout(pill: CGRect) -> ExpandedLayout {
        let visible = Self.visibleFrame(for: pill)
        let contentHeight = Self.measureList(listMeasurer, groups: model.groups, failed: model.failedSessions, unseen: model.unseen)
        // Cap height at the visible screen and scroll the remaining rows (Review Focus 2).
        let maxPanelHeight = floor(visible.height * Layout.maxHeightRatio)
        let panelHeight = min(Layout.panelChromeHeight + contentHeight, maxPanelHeight)
        let frame = PanelGeometry.expandedFrame(
            collapsed: pill,
            expandedSize: CGSize(width: Layout.panelWidth, height: panelHeight),
            visible: visible
        )
        return ExpandedLayout(
            windowFrame: frame,
            // Match PanelGeometry.expandedFrame so content and window share the anchored corner.
            trailing: pill.midX > visible.midX,
            panelHeight: panelHeight,
            listHeight: panelHeight - Layout.panelChromeHeight
        )
    }

    // MARK: Reply view (v1.2 design §§4.5 C, 4.7)

    private func connectReplies() {
        presentation.openReply = { [weak self] session in self?.openReply(session) }
        presentation.onGlassTone = { [weak self] tone in self?.card.setTone(tone) }
        presentation.replyActions = ReplyActions(
            back: { [weak self] in self?.closeReply(restoreFocus: true) },
            primary: { [weak self] in self?.replyPrimary() },
            openTerminal: { [weak self] in self?.openTerminalFromReply() },
            close: { [weak self] in self?.closeFailure() },
            recheck: { [weak self] in self?.replies.recheck() },
            openSettings: { Self.openAccessibilitySettings() },
            editQuestion: { [weak self] index in self?.replies.edit { $0.edit(question: index) } },
            contentHeight: { [weak self] height in self?.replyContentRendered(height) }
        )
        replies.onChange = { [weak self] in self?.adjustReplyLayout() }
        replies.onAutoClose = { [weak self] in self?.afterReplyClosed(restoreFocus: true) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return consumed ? nil : event
        }
    }

    /// Keep replies open on pointer exit; collapse on losing keyboard focus unless sending.
    private var holdsReplyOpen: Bool {
        guard replies.openKey != nil else { return false }
        if case .sending = replies.phase { return true }
        return panel.isKeyWindow || card.panel.isKeyWindow || debugHoldsReply
    }

    private func openReply(_ session: AgentSession) {
        guard phase == .expanded else { return }
        // Request Ghostty Accessibility permission once; denial leaves read-only guidance and an Open Settings action (design §4.9).
        if case .ghostty = session.locator, !didRequestAccessibility, !AXIsProcessTrusted() {
            didRequestAccessibility = true
            AXGhosttyScreenReader.requestTrust()
        }
        if replies.openKey == nil { previousApp = NSWorkspace.shared.frontmostApplication }
        replies.open(session)
        guard replies.openKey == session.key else { return }
        switch presentation.replyPlacement {
        case .panel:
            // Widen first so reply content is measured at its final width, avoiding an initial height jump.
            resizeExpanded(width: ReplyLayout.width, contentHeight: measureReply())
            withAnimation(isReduced ? Motion.crossfade : Motion.spring) {
                presentation.content = .reply
            }
        case .inline:
            withAnimation(isReduced ? Motion.crossfade : Motion.spring) {
                resizeExpanded(width: ReplyLayout.width, contentHeight: measureListContent())
            }
        case .card:
            showCard(for: session)
        }
        // Accept keyboard input only after an explicit reply click; do not activate the app itself.
        let keyWindow = presentation.replyPlacement == .card ? card.panel : panel
        keyWindow.acceptsKeyInput = true
        keyWindow.makeKey()
        // AppKit selects the first input automatically when a card appears; a focused field turns option-number keys into text.
        // Clear initial focus unless text entry was explicitly requested (final review C1).
        if !replies.fieldFocus.wanted, keyWindow.firstResponder is NSTextView { keyWindow.makeFirstResponder(nil) }
        DebugLog.write("reply open session=\(session.key.sessionId) key=\(panel.isKeyWindow) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
        guard DebugLog.isEnabled else { return }
        // Keyboard ownership must be verified at runtime (measurement S4).
        for delay in [0.5, 1.5] {
            _ = after(delay) { controller in
                DebugLog.write("reply focus +\(delay)s focused=\(Self.focusedApplicationPid()) key=\(controller.panel.isKeyWindow)")
            }
        }
    }

    private func closeReply(restoreFocus: Bool) {
        guard replies.openKey != nil else { return }
        replies.close()
        afterReplyClosed(restoreFocus: restoreFocus)
    }

    /// Reply state is already closed; restore list size and keyboard ownership for every placement.
    private func afterReplyClosed(restoreFocus: Bool) {
        let hadCard = card.isVisible
        card.hide()
        withAnimation(isReduced ? Motion.crossfade : Motion.spring) {
            presentation.content = .list
        }
        resizeExpanded(width: Layout.panelWidth, contentHeight: measureListContent())
        releaseKeyInput(restoreFocus: restoreFocus)
        // Removing the card does not deliver an exit event to the cursor that was over it.
        if hadCard { syncHover() }
    }

    /// Inline replies contribute to list height and must be measured with the list.
    private func measureListContent() -> CGFloat {
        let inline = inlineReply
        return Self.measureList(
            listMeasurer, groups: model.groups, failed: model.failedSessions, unseen: model.unseen,
            inline: inline, width: (inline == nil ? Layout.panelWidth : ReplyLayout.width) - Layout.panelPadding * 2
        )
    }

    /// Align the card with its selected row; use the summary row as a fallback before positions are known.
    private func showCard(for session: AgentSession, contentHeight: CGFloat? = nil) {
        let visible = Self.visibleFrame(for: panel.frame)
        let measured = contentHeight.map { $0 + ReplyCardController.padding * 2 } ?? card.measureHeight(for: session)
        let height = min(measured, floor(visible.height * Layout.maxHeightRatio))
        let rowTop = presentation.rowFrames[session.key].map { panel.frame.maxY - $0.minY } ?? panel.frame.maxY - Layout.panelChromeHeight
        let frame = PanelGeometry.cardFrame(
            panel: panel.frame, rowTop: rowTop, size: CGSize(width: ReplyLayout.width, height: height),
            trailing: presentation.anchorsTrailing, visible: visible
        )
        card.setContrast(presentation.glassContrast)
        card.show(frame: frame, actions: presentation.replyActions, reduced: isReduced)
    }

    private var inlineReply: InlineReply? {
        guard presentation.replyPlacement == .inline, replies.openKey != nil else { return nil }
        return InlineReply(center: replies, actions: presentation.replyActions)
    }

    /// Resign key status and return keyboard input to the app that was active before replying.
    private func releaseKeyInput(restoreFocus: Bool) {
        for window in [panel, card.panel] {
            let wasKey = window.isKeyWindow
            window.acceptsKeyInput = false
            if wasKey { window.resignKey() }
        }
        defer { previousApp = nil }
        guard restoreFocus, let app = previousApp, app != NSRunningApplication.current, !app.isTerminated else { return }
        app.activate()
        DebugLog.write("reply focus returned to=\(app.bundleIdentifier ?? "nil") key=\(panel.isKeyWindow)")
    }

    private func adjustReplyLayout() {
        guard phase == .expanded, replies.openKey != nil else { return }
        switch presentation.replyPlacement {
        case .panel:
            guard presentation.content == .reply else { return }
            resizeExpanded(width: ReplyLayout.width, contentHeight: measureReply())
        case .inline:
            resizeExpanded(width: ReplyLayout.width, contentHeight: measureListContent())
        case .card:
            if let session = replies.openSession { showCard(for: session) }
        }
    }

    /// Preserve the anchored corner; grow the window first and shrink only after the glass transition.
    private func resizeExpanded(width: CGFloat, contentHeight: CGFloat) {
        let pill = pillAtWindowCorner()
        let visible = Self.visibleFrame(for: pill)
        let panelHeight = min(Layout.panelChromeHeight + contentHeight, floor(visible.height * Layout.maxHeightRatio))
        guard width != presentation.panelWidth || panelHeight != presentation.panelHeight else { return }
        let target = PanelGeometry.expandedFrame(
            collapsed: pill, expandedSize: CGSize(width: width, height: panelHeight), visible: visible
        )
        // The window must contain both old and new frames so the transitioning glass is not clipped.
        applyFrame(target.union(panel.frame))
        hostingView.layoutSubtreeIfNeeded()
        resizeGeneration += 1
        let generation = resizeGeneration
        withAnimation(isReduced ? Motion.crossfade : Motion.spring) {
            presentation.panelWidth = width
            presentation.panelHeight = panelHeight
            presentation.listHeight = panelHeight - Layout.panelChromeHeight
        } completion: { [weak self] in
            guard let self, self.resizeGeneration == generation, self.phase == .expanded else { return }
            self.applyFrame(target)
        }
    }

    /// Reconcile measured and rendered heights; content height does not depend on window height, so this settles.
    private func replyContentRendered(_ height: CGFloat) {
        if presentation.replyPlacement == .card, card.isVisible, let session = replies.openSession, height > 0 {
            showCard(for: session, contentHeight: ReplyScreen.compactHeaderHeight + ceil(height) + ReplyFooter.height)
            return
        }
        guard phase == .expanded, presentation.content == .reply, height > 0 else { return }
        let total = ReplyHeader.height + ceil(height) + ReplyFooter.height
        guard abs(total - presentation.listHeight) > 1 else { return }
        DebugLog.write("reply rendered content=\(height) total=\(total) list=\(presentation.listHeight)")
        resizeExpanded(width: ReplyLayout.width, contentHeight: total)
    }

    private func measureReply() -> CGFloat {
        guard let session = replies.openSession else { return 0 }
        let measurer = NSHostingView(rootView: ReplyMeasure(center: replies, session: session))
        let height = ceil(measurer.fittingSize.height)
        DebugLog.write("reply measure height=\(height) width=\(measurer.fittingSize.width)")
        return height
    }

    /// Handle Return, Escape, numbers, and Tab before text fields; ask NSTextView whether composition is active (design §4.7 keys).
    /// Return true when consumed to prevent unwanted edits such as inserting a newline.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard replies.openKey != nil, let keyWindow = [panel, card.panel].first(where: \.isKeyWindow) else { return false }
        let fieldEditor = keyWindow.firstResponder as? NSTextView
        let fieldFocused = fieldEditor != nil
        let marked = fieldEditor?.hasMarkedText() ?? false
        if event.keyCode == KeyCode.tab, !marked {
            if fieldFocused {
                keyWindow.makeFirstResponder(nil)
                replies.releaseFieldFocus()
            } else {
                replies.requestFieldFocus()
            }
            return true
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        let input: ReplyKeyInput
        switch event.keyCode {
        case KeyCode.returnKey, KeyCode.keypadEnter: input = .returnKey
        case KeyCode.escape: input = .escape
        default:
            if modifiers.isEmpty, let digit = event.charactersIgnoringModifiers.flatMap(Int.init) {
                input = .digit(digit)
            } else {
                input = .other
            }
        }
        switch ReplyKeys.action(for: input, fieldFocused: fieldFocused, hasMarkedText: marked) {
        case let .select(index):
            replies.choose(index)
            return true
        case .primary:
            // Shift+Return cannot send a newline, so leave it inert (R59).
            if !event.modifierFlags.contains(.shift) { replyPrimary() }
            return true
        case .commitComposition, .passThrough:
            return false
        case .leaveField:
            keyWindow.makeFirstResponder(nil)
            replies.releaseFieldFocus()
            return true
        case .back:
            if case .sending = replies.phase { return true }
            closeReply(restoreFocus: true)
            return true
        }
    }

    /// Return and the primary action perform the same operation as the visible primary button.
    private func replyPrimary() {
        switch replies.phase {
        case .sending:
            return
        case let .result(outcome):
            switch outcome {
            case .delivered, .notSent(.alreadyAnswered), .notSent(.sessionEnded):
                closeReply(restoreFocus: true)
            case .notSent, .stopped, .mismatched:
                openTerminalFromReply()
            }
        case .editing:
            guard let key = replies.openKey else { return }
            if case .readOnly? = replies.availability[key] {
                openTerminalFromReply()
            } else {
                replies.primary()
            }
        }
    }

    /// Opening the terminal acknowledges failure; keep focus in the destination instead of restoring it.
    private func openTerminalFromReply() {
        guard let session = replies.openSession else { return }
        replies.acknowledgeFailure(session.key)
        closeReply(restoreFocus: false)
        Task { await model.activate(session) }
    }

    private func closeFailure() {
        if let key = replies.openKey { replies.acknowledgeFailure(key) }
        closeReply(restoreFocus: true)
    }

    private static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func panelDidResignKey(_ notification: Notification) {
        DebugLog.write("panel resigned key content=\(presentation.content)")
        guard replies.openKey != nil else { return }
        syncHover()
    }

    // MARK: Position (R27)

    /// Arrives before the first move notification so dragging can cancel pending expansion immediately (R35).
    @objc private func panelWillMove(_ notification: Notification) {
        guard !isAdjustingFrame else { return }
        beginDrag()
    }

    @objc private func panelDidMove(_ notification: Notification) {
        // Frames changed by expansion or collapse are not user moves.
        guard !isAdjustingFrame, panel.frame.origin != lastAppliedFrame.origin else { return }
        beginDrag()
    }

    private func beginDrag() {
        // The side card would be left behind when the panel moves.
        if card.isVisible { closeReply(restoreFocus: false) }
        if !presentation.isDragging {
            presentation.isDragging = true
            hoverTask?.cancel()
            DebugLog.write("drag began phase=\(phase)")
        }
        armDragSettle()
    }

    private func armDragSettle() {
        dragSettleTask?.cancel()
        dragSettleTask = after(.milliseconds(300)) { $0.dragSettled() }
    }

    /// Move notifications arrive continuously during dragging; persist once after release.
    private func dragSettled() {
        // Holding the button while stationary still counts as dragging.
        if NSEvent.pressedMouseButtons & 1 != 0 {
            armDragSettle()
            return
        }
        dragSettleTask = nil
        presentation.isDragging = false
        lastAppliedFrame = panel.frame
        anchor = anchorFromWindow()
        saveAnchor()
        DebugLog.write("drag ended phase=\(phase) anchor=\(Self.describe(anchor))")
        // Clamp a collapsed pill immediately after an offscreen drop; defer until collapse when expanded.
        if phase == .collapsed {
            presentation.anchorsTrailing = anchor.trailing
            applyFrame(anchor.pillFrame(size: pillSize()))
        }
        syncHover()
    }

    @objc private func screensDidChange(_ notification: Notification) {
        // Expanded panels are clamped the same way in finishCollapse.
        guard phase == .collapsed else { return }
        let size = pillSize()
        let onScreen = clampedAnchor(anchor, size: size)
        guard onScreen != anchor else { return }
        anchor = onScreen
        saveAnchor()
        presentation.anchorsTrailing = anchor.trailing
        applyFrame(anchor.pillFrame(size: size))
    }

    /// The pill shares the anchored corner in every phase, including after dragging while expanded.
    private func anchorFromWindow() -> PanelAnchor {
        let pill = pillAtWindowCorner()
        let raw = PanelAnchor(pillFrame: pill, visible: Self.visibleFrame(for: pill))
        return clampedAnchor(raw, size: pill.size)
    }

    /// Leave valid frames unchanged so the saved left/right anchor does not flip near screen center.
    private func clampedAnchor(_ current: PanelAnchor, size: CGSize) -> PanelAnchor {
        let pill = current.pillFrame(size: size)
        let clamped = PanelGeometry.clamped(pill, into: NSScreen.screens.map(\.visibleFrame))
        guard clamped != pill else { return current }
        return PanelAnchor(pillFrame: clamped, visible: Self.visibleFrame(for: clamped))
    }

    private func pillAtWindowCorner() -> CGRect {
        let frame = panel.frame
        let trailing = presentation.anchorsTrailing
        let corner = CGPoint(x: trailing ? frame.maxX : frame.minX, y: frame.maxY)
        return PanelAnchor(corner: corner, trailing: trailing).pillFrame(size: pillSize())
    }

    private func applyFrame(_ frame: CGRect) {
        guard panel.frame != frame else { return }
        isAdjustingFrame = true
        defer { isAdjustingFrame = false }
        lastAppliedFrame = frame
        panel.setFrame(frame, display: true, animate: false)
    }

    var glassContrast: GlassContrast {
        presentation.glassContrast
    }

    var replyPlacement: ReplyPlacement {
        presentation.replyPlacement
    }

    /// Close the current reply while preserving its draft; apply the new placement on next open.
    func setReplyPlacement(_ placement: ReplyPlacement) {
        closeReply(restoreFocus: false)
        presentation.replyPlacement = placement
        UserDefaults.standard.set(placement.rawValue, forKey: Self.placementKey)
        DebugLog.write("reply placement=\(placement.rawValue)")
    }

    func setGlassContrast(_ mode: GlassContrast) {
        presentation.glassContrast = mode
        card.setContrast(mode)
        UserDefaults.standard.set(mode.rawValue, forKey: Self.contrastKey)
        DebugLog.write("glass contrast=\(mode.rawValue)")
    }

    private func saveAnchor() {
        let stored: [String: Any] = ["x": Double(anchor.corner.x), "y": Double(anchor.corner.y), "trailing": anchor.trailing]
        UserDefaults.standard.set(stored, forKey: Self.anchorKey)
        DebugLog.write("saved panelAnchor=\(Self.describe(anchor))")
    }

    private static func savedAnchor() -> PanelAnchor? {
        guard let stored = UserDefaults.standard.dictionary(forKey: anchorKey),
              let x = stored["x"] as? Double,
              let y = stored["y"] as? Double,
              let trailing = stored["trailing"] as? Bool
        else { return nil }
        return PanelAnchor(corner: CGPoint(x: x, y: y), trailing: trailing)
    }

    /// Try the saved corner with the current pill width; fall back to the main screen's upper-right if no display fits.
    private static func restoredAnchor(saved: PanelAnchor?, size: CGSize) -> PanelAnchor {
        let savedFrame = saved?.pillFrame(size: size)
        let origin = PanelGeometry.restoredOrigin(
            saved: savedFrame?.origin,
            size: size,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        )
        if let saved, origin == savedFrame?.origin { return saved }
        let frame = CGRect(origin: origin, size: size)
        return PanelAnchor(pillFrame: frame, visible: visibleFrame(for: frame))
    }

    private static func visibleFrame(for rect: CGRect) -> CGRect {
        let screens = NSScreen.screens
        let best = screens.max { lhs, rhs in
            area(lhs.frame.intersection(rect)) < area(rhs.frame.intersection(rect))
        }
        guard let best, area(best.frame.intersection(rect)) > 0 else {
            return NSScreen.main?.visibleFrame ?? screens.first?.visibleFrame ?? rect
        }
        return best.visibleFrame
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    // MARK: Measurement

    private func pillSize() -> CGSize {
        Self.measurePill(pillMeasurer, summary: model.summary)
    }

    private static func measurePill(_ measurer: NSHostingView<PillMeasure>, summary: PillSummary) -> CGSize {
        measurer.rootView = PillMeasure(summary: summary)
        return CGSize(width: ceil(measurer.fittingSize.width), height: Layout.pillHeight)
    }

    private static func measureList(
        _ measurer: NSHostingView<ListMeasure>, groups: [SessionGroup], failed: [AgentSession], unseen: Set<SessionKey>,
        inline: InlineReply? = nil, width: CGFloat = Layout.listWidth
    ) -> CGFloat {
        measurer.rootView = ListMeasure(groups: groups, failed: failed, unseen: unseen, inline: inline, width: width)
        return ceil(measurer.fittingSize.height)
    }

    // MARK: Helpers

    /// Capture weakly: pending work has no purpose after the controller disappears.
    private func after(_ seconds: Double, _ action: @escaping @MainActor (PanelController) -> Void) -> Task<Void, Never> {
        after(.seconds(seconds), action)
    }

    private func after(_ delay: Duration, _ action: @escaping @MainActor (PanelController) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            action(self)
        }
    }

    private static func describe(_ rect: CGRect) -> String {
        "(\(rect.origin.x), \(rect.origin.y), \(rect.width), \(rect.height))"
    }

    private static func describe(_ anchor: PanelAnchor) -> String {
        "(\(anchor.corner.x), \(anchor.corner.y), \(anchor.trailing ? "trailing" : "leading"))"
    }
}

/// Receive panel enter/exit separately from NSHostingView's internal tracking areas.
private final class HoverTracker: NSResponder {
    var onChange: (@MainActor (Bool) -> Void)?

    override func mouseEntered(with event: NSEvent) {
        onChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onChange?(false)
    }
}

/// Measure the same collapsed pill shape offscreen.
struct PillMeasure: View {
    let summary: PillSummary

    var body: some View {
        SummaryRow(summary: summary).pillChrome()
    }
}

struct ListMeasure: View {
    let groups: [SessionGroup]
    var failed: [AgentSession] = []
    let unseen: Set<SessionKey>
    var inline: InlineReply? = nil
    var width: CGFloat = Layout.listWidth

    var body: some View {
        SessionListContent(groups: groups, failed: failed, unseen: unseen, now: .now, canNavigate: { _ in false }, onActivate: { _ in }, inline: inline)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Physical NSEvent.keyCode values independent of keyboard layout.
private enum KeyCode {
    static let tab: UInt16 = 48
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let escape: UInt16 = 53
}
