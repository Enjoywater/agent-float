import AgentFloatCore
import AppKit
import ServiceManagement
import SwiftUI

/// Log actual runtime state for unattended UI verification without changing system settings.
enum DebugLog {
    static let isEnabled = ProcessInfo.processInfo.environment["AGENT_FLOAT_DEBUG"] == "1"
    private static let launchedAt = Date()

    static func write(_ line: @autoclosure () -> String) {
        guard isEnabled else { return }
        let elapsed = String(format: "%8.3f", Date().timeIntervalSince(launchedAt))
        FileHandle.standardError.write(Data("[agent-float \(elapsed)] \(line())\n".utf8))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var panelController: PanelController?
    private var menuBar: MenuBarController?
    private var debugSignals: [any DispatchSourceSignal] = []
    private static let presenceKey = "iconPresence"
    private var iconPresence = IconPresence.resolve(saved: UserDefaults.standard.string(forKey: presenceKey))

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        Self.applyAppearanceOverride(environment["AGENT_FLOAT_APPEARANCE"])
        NSApp.mainMenu = MainMenu.make()

        let runner = ProcessCommandRunner()
        let activator = AppActivator()
        let store = SessionStore(providers: Self.makeProviders(environment))
        let isFake = environment["AGENT_FLOAT_FAKE_SESSIONS"].flatMap(Int.init).map { $0 > 0 } ?? false
        let model = AppModel(
            store: store,
            navigators: isFake ? NavigatorRegistry([]) : Self.makeNavigators(runner: runner, activator: activator),
            focusProbes: isFake ? [] : [GhosttyFocusProbe(runner: runner), AppleTerminalFocusProbe(runner: runner), ITermFocusProbe(runner: runner)],
            activator: activator
        )
        let replies = ReplyCenter(backend: isFake ? FakeReplyBackend.make(environment) : Self.makeReplyBackend(runner: runner, store: store))
        replies.onFailuresChange = { [weak model] keys in model?.setFailures(keys) }
        let controller = PanelController(model: model, replies: replies)
        controller.show()
        model.start()
        self.model = model
        panelController = controller

        menuBar = MenuBarController(
            onResetPosition: { [weak controller] in controller?.resetPosition() },
            contrast: { [weak controller] in controller?.glassContrast ?? .outline },
            onSelectContrast: { [weak controller] mode in controller?.setGlassContrast(mode) },
            placement: { [weak controller] in controller?.replyPlacement ?? .panel },
            onSelectPlacement: { [weak controller] placement in controller?.setReplyPlacement(placement) },
            presence: { [weak self] in self?.iconPresence ?? .menuBar },
            onSelectPresence: { [weak self] presence in self?.setIconPresence(presence) }
        )
        LanguageSettings.shared.onChange = { [weak model] in
            NSApp.mainMenu = MainMenu.make()
            model?.onChange?()
            if isFake { model?.requestRefresh() }
        }
        applyIconPresence()

        if DebugLog.isEnabled {
            logLaunchState(panel: controller.panel, host: controller.hostingView)
            installDebugSignals(controller)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.flushPendingSave()
    }

    /// The Dock context menu is the only settings entry point while the menu bar icon is hidden.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        menuBar?.dockMenu()
    }

    private func setIconPresence(_ presence: IconPresence) {
        iconPresence = presence
        UserDefaults.standard.set(presence.rawValue, forKey: Self.presenceKey)
        applyIconPresence()
    }

    /// LSUIElement starts without a Dock icon; apply the user's icon preference here.
    private func applyIconPresence() {
        menuBar?.setStatusItemVisible(iconPresence.showsMenuBarIcon)
        let policy: NSApplication.ActivationPolicy = iconPresence.showsDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        DebugLog.write("icon presence=\(iconPresence.rawValue) policy=\(policy == .regular ? "regular" : "accessory")")
    }

    /// Only tmux, Orca, and Ghostty support sending; other terminals remain read-only (v1.2 design §4.1).
    private static func makeReplyBackend(runner: ProcessCommandRunner, store: SessionStore) -> ReplyBackend {
        let consoles = ConsoleRegistry([
            TmuxConsole(runner: runner, executable: TmuxCLI.resolveExecutable()),
            OrcaConsole(runner: runner),
            GhosttyConsole(runner: runner, screenReader: AXGhosttyScreenReader()),
        ])
        let delivery = ReplyDelivery(
            currentSessions: { store.snapshot(now: Date()) },
            consoles: consoles,
            answers: { key, promptId in store.recordedAnswer(for: key, promptId: promptId) }
        )
        return ReplyBackend(
            availability: { session in await consoles.availability(of: session) },
            deliver: { draft, prompt, session, onStage in
                await delivery.deliver(draft, prompt: prompt, session: session, onStage: onStage)
            }
        )
    }

    /// Each locator has one owner, so registration order cannot affect routing.
    private static func makeNavigators(runner: ProcessCommandRunner, activator: AppActivator) -> NavigatorRegistry {
        NavigatorRegistry([
            GhosttyNavigator(runner: runner),
            HerdrNavigator(runner: runner, activateHerdr: {
                activator.activate(bundleIdentifier: TerminalBundle.herdr)
            }),
            OrcaNavigator(runner: runner, activateOrca: {
                activator.activate(bundleIdentifier: TerminalBundle.orca)
            }),
            AppleTerminalNavigator(runner: runner),
            ITermNavigator(runner: runner),
            makeTmuxNavigator(runner: runner, activator: activator),
            AppActivationNavigator(inspector: DarwinProcessInspector(), activateFirstApp: { pids in
                activator.activateFirstRegularApp(among: pids)
            }),
        ])
    }

    /// Select the outer tmux terminal's tab when tty selection is supported; otherwise raise its app.
    private static func makeTmuxNavigator(runner: ProcessCommandRunner, activator: AppActivator) -> TmuxNavigator {
        let appleTerminal = AppleTerminalNavigator(runner: runner)
        let iTerm = ITermNavigator(runner: runner)
        return TmuxNavigator(runner: runner, inspector: DarwinProcessInspector(), executable: TmuxCLI.resolveExecutable()) { sessionPid, chain, clientTty in
            guard let app = activator.chooseFirstRegularApp(forSession: sessionPid, among: chain) else {
                throw NavigationError.terminalNotFound
            }
            switch app.bundleIdentifier {
            case TerminalBundle.herdr?:
                let inspector = DarwinProcessInspector()
                guard let clientPid = chain.first,
                      let target = HerdrTarget.detect(pid: clientPid, environment: inspector.environment(pid: clientPid), inspector: inspector) else {
                    throw NavigationError.terminalNotFound
                }
                try await HerdrNavigator(runner: runner, activateHerdr: {
                    activator.activate(bundleIdentifier: TerminalBundle.herdr)
                }).focus(target)
            case TerminalBundle.appleTerminal?:
                try await appleTerminal.selectTab(tty: clientTty)
            case TerminalBundle.iTerm?:
                try await iTerm.selectTab(tty: clientTty)
            default:
                guard activator.activate(pid: app.pid) else { throw NavigationError.terminalNotFound }
            }
        }
    }

    /// Inject fake input to verify rendering and transitions without opening or modifying real sessions.
    static func makeProviders(_ environment: [String: String]) -> [any AgentProvider] {
        if let raw = environment["AGENT_FLOAT_FAKE_SESSIONS"], let count = Int(raw), count > 0 {
            return [FakeProvider(
                count: count, startedAt: Date(),
                mediaScene: environment["AGENT_FLOAT_MEDIA_SCENE"].flatMap(FakeProvider.MediaScene.init(rawValue:)),
                mediaAgent: environment["AGENT_FLOAT_MEDIA_AGENT"].flatMap(FakeProvider.MediaAgent.init(rawValue:)) ?? .claude,
                language: { LanguageSettings.snapshot }
            )]
        }
        let claude: ClaudeCodeProvider
        if let home = environment["AGENT_FLOAT_CLAUDE_HOME"], !home.isEmpty {
            claude = ClaudeCodeProvider(
                claudeHome: URL(fileURLWithPath: home, isDirectory: true),
                homeDirectory: NSHomeDirectory(),
                inspector: DarwinProcessInspector()
            )
        } else {
            claude = ClaudeCodeProvider.live()
        }
        let codexHome = environment["AGENT_FLOAT_CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory() + "/.codex"
        return [claude, CodexCodeProvider(codexHome: URL(fileURLWithPath: codexHome, isDirectory: true))]
    }

    /// Override appearance for debugging without changing the system light/dark setting.
    private static func applyAppearanceOverride(_ value: String?) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }

    /// Verify expansion unattended: USR1 expands and USR2 collapses.
    private func installDebugSignals(_ controller: PanelController) {
        let handlers: [(Int32, @MainActor () -> Void)] = [
            (SIGUSR1, { [weak controller] in controller?.debugExpand() }),
            (SIGUSR2, { [weak controller] in controller?.debugCollapse() }),
        ]
        for (number, handler) in handlers {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { handler() }
            }
            source.resume()
            debugSignals.append(source)
        }
    }

    /// Log actual runtime values for unattended checks of all-Spaces and inactive behavior (spec §4.8).
    private func logLaunchState(panel: FloatingPanel, host: NSView) {
        let frame = panel.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let captureTop = primaryHeight - frame.maxY
        let policy = switch NSApp.activationPolicy() {
        case .regular: "regular"
        case .accessory: "accessory"
        case .prohibited: "prohibited"
        @unknown default: "unknown"
        }
        DebugLog.write("collectionBehavior=\(Self.names(of: panel.collectionBehavior)) raw=0x\(String(panel.collectionBehavior.rawValue, radix: 16))")
        DebugLog.write("level=\(panel.level.rawValue) floating=\(NSWindow.Level.floating.rawValue) isFloatingPanel=\(panel.isFloatingPanel)")
        DebugLog.write("frame=(\(frame.origin.x), \(frame.origin.y), \(frame.width), \(frame.height)) screencaptureRect=\(frame.origin.x),\(captureTop),\(frame.width),\(frame.height)")
        DebugLog.write("nonactivating=\(panel.styleMask.contains(.nonactivatingPanel)) canBecomeKey=\(panel.canBecomeKey) canBecomeMain=\(panel.canBecomeMain) hidesOnDeactivate=\(panel.hidesOnDeactivate) acceptsFirstMouse=\(host.acceptsFirstMouse(for: nil))")
        DebugLog.write("activationPolicy=\(policy) loginItemStatus=\(Self.name(of: SMAppService.mainApp.status)) reduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) reduceTransparency=\(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)")
        Self.logTrackingAreas(of: host)
    }

    /// Tracking-area options establish whether SwiftUI row hover works in an inactive panel.
    static func logTrackingAreas(of view: NSView) {
        for area in view.trackingAreas {
            let options = area.options
            let activeAlways = options.contains(.activeAlways)
            let owner = area.owner.map { String(describing: type(of: $0)) } ?? "nil"
            DebugLog.write("trackingArea owner=\(owner) activeAlways=\(activeAlways) inVisibleRect=\(options.contains(.inVisibleRect)) rect=\(area.rect)")
        }
    }

    private static func names(of behavior: NSWindow.CollectionBehavior) -> [String] {
        let known: [(NSWindow.CollectionBehavior, String)] = [
            (.canJoinAllSpaces, "canJoinAllSpaces"),
            (.moveToActiveSpace, "moveToActiveSpace"),
            (.managed, "managed"),
            (.transient, "transient"),
            (.stationary, "stationary"),
            (.participatesInCycle, "participatesInCycle"),
            (.ignoresCycle, "ignoresCycle"),
            (.fullScreenPrimary, "fullScreenPrimary"),
            (.fullScreenAuxiliary, "fullScreenAuxiliary"),
            (.fullScreenNone, "fullScreenNone"),
            (.fullScreenAllowsTiling, "fullScreenAllowsTiling"),
            (.fullScreenDisallowsTiling, "fullScreenDisallowsTiling"),
            (.primary, "primary"),
            (.auxiliary, "auxiliary"),
            (.canJoinAllApplications, "canJoinAllApplications"),
        ]
        return known.filter { behavior.contains($0.0) }.map(\.1)
    }

    private static func name(of status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }
}
