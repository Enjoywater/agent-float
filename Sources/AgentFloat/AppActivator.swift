import AgentFloatCore
import AppKit

/// Raise the app selected by the navigator; navigation runs off-main but AppKit requires the main thread (R24).
@MainActor
final class AppActivator {
    /// Record fallback choices by session PID so confirmation can check the ancestor app actually selected (R37).
    private var fallbackChoices: [Int32: Int32] = [:]

    nonisolated func activate(bundleIdentifier: String) {
        onMain {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
            guard let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                DebugLog.write("activate skipped bundle=\(bundleIdentifier) reason=no-url")
                return
            }
            Self.open(url)
        }
    }

    nonisolated func activateFirstRegularApp(among pids: [Int32]) -> Bool {
        guard let session = pids.first, let app = chooseFirstRegularApp(forSession: session, among: pids) else { return false }
        return activate(pid: app.pid)
    }

    /// The nearest regular Dock app owns the terminal; skip helper processes without a Dock presence.
    /// Only select and record here; tab scripts and LaunchServices require different activation paths.
    nonisolated func chooseFirstRegularApp(forSession session: Int32, among pids: [Int32]) -> (pid: Int32, bundleIdentifier: String?)? {
        onMain {
            for pid in pids {
                guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
                fallbackChoices[session] = app.processIdentifier
                return (app.processIdentifier, app.bundleIdentifier)
            }
            return nil
        }
    }

    nonisolated func activate(pid: Int32) -> Bool {
        onMain {
            guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
            Self.open(url)
            return true
        }
    }

    /// Consume each choice once so the next click confirms its own selection.
    func takeFallbackChoice(forSession pid: Int32) -> Int32? {
        fallbackChoices.removeValue(forKey: pid)
    }

    /// macOS 14+ cooperative activation may ignore activate() from a background app.
    /// Use LaunchServices, matching a Dock click (R36).
    private static func open(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Avoid adding the terminal to recent items on every navigation.
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { DebugLog.write("open application failed url=\(url.path) error=\(error)") }
        }
    }

    private nonisolated func onMain<T: Sendable>(_ work: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(work) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
    }
}
