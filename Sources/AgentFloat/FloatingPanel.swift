import AppKit
import SwiftUI

/// Clicks and hover must not steal focus from the user's current app (spec §2 failure condition).
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        // Pass nonactivatingPanel at creation; changing styleMask afterward does not apply it.
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        // Stay fixed across all Spaces and fullscreen apps instead of sliding during transitions (spec §4.8).
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // SwiftUI consumes mouse-down before background dragging; the WindowDragGesture handle owns dragging.
        isMovableByWindowBackground = false
        // The app is usually inactive; NSPanel's default hidesOnDeactivate would immediately hide it.
        hidesOnDeactivate = false
    }

    /// Allow key status only while replying; otherwise the user's typing app would lose keyboard input (v1.2 design §4.7 exception).
    var acceptsKeyInput = false

    override var canBecomeKey: Bool { acceptsKeyInput }
    override var canBecomeMain: Bool { false }
}

/// The panel never becomes key, so every click is an inactive window's first click.
/// NSHostingView's default rejects first clicks, potentially consuming row clicks and drags solely for activation.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
