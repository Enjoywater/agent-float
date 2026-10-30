import AgentFloatCore
import AppKit
import ServiceManagement
import SwiftUI

/// 사람 손 없이 화면과 전환을 확인하려는 디버그 출력. 사용자 기기 설정을 건드리지 않고 실행 중인 실제 값을 남긴다
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
        let model = AppModel(
            store: store,
            navigators: Self.makeNavigators(runner: runner, activator: activator),
            focusProbes: [GhosttyFocusProbe(runner: runner), AppleTerminalFocusProbe(runner: runner), ITermFocusProbe(runner: runner)],
            activator: activator
        )
        let isFake = environment["AGENT_FLOAT_FAKE_SESSIONS"].flatMap(Int.init).map { $0 > 0 } ?? false
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
        applyIconPresence()

        if DebugLog.isEnabled {
            logLaunchState(panel: controller.panel, host: controller.hostingView)
            installDebugSignals(controller)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.flushPendingSave()
    }

    /// Dock 아이콘 우클릭 메뉴. 메뉴바 아이콘을 숨긴 동안에는 설정으로 가는 유일한 길이다
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        menuBar?.dockMenu()
    }

    private func setIconPresence(_ presence: IconPresence) {
        iconPresence = presence
        UserDefaults.standard.set(presence.rawValue, forKey: Self.presenceKey)
        applyIconPresence()
    }

    /// 실행은 Info.plist 의 LSUIElement 로 Dock 없이 시작하고, 고른 값에 따라 여기서 바꾼다
    private func applyIconPresence() {
        menuBar?.setStatusItemVisible(iconPresence.showsMenuBarIcon)
        let policy: NSApplication.ActivationPolicy = iconPresence.showsDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        DebugLog.write("icon presence=\(iconPresence.rawValue) policy=\(policy == .regular ? "regular" : "accessory")")
    }

    /// 보내기는 tmux·Orca·Ghostty 만 담당한다. 그 밖의 터미널은 보기만 (v1.2 설계 4.1)
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

    /// 위치 종류마다 담당이 하나뿐이라 등록 순서는 결과에 영향이 없다
    private static func makeNavigators(runner: ProcessCommandRunner, activator: AppActivator) -> NavigatorRegistry {
        NavigatorRegistry([
            GhosttyNavigator(runner: runner),
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

    /// tmux 클라이언트를 띄운 바깥 터미널이 tty 로 탭을 고를 수 있는 앱이면 그 탭까지, 아니면 그 앱만 앞으로 올린다
    private static func makeTmuxNavigator(runner: ProcessCommandRunner, activator: AppActivator) -> TmuxNavigator {
        let appleTerminal = AppleTerminalNavigator(runner: runner)
        let iTerm = ITermNavigator(runner: runner)
        return TmuxNavigator(runner: runner, inspector: DarwinProcessInspector(), executable: TmuxCLI.resolveExecutable()) { sessionPid, chain, clientTty in
            guard let app = activator.chooseFirstRegularApp(forSession: sessionPid, among: chain) else {
                throw NavigationError.terminalNotFound
            }
            switch app.bundleIdentifier {
            case TerminalBundle.appleTerminal?:
                try await appleTerminal.selectTab(tty: clientTty)
            case TerminalBundle.iTerm?:
                try await iTerm.selectTab(tty: clientTty)
            default:
                guard activator.activate(pid: app.pid) else { throw NavigationError.terminalNotFound }
            }
        }
    }

    /// 실제 세션을 띄우거나 바꾸지 않고 화면·전환을 확인할 수 있게 입력을 바꿔 끼운다
    static func makeProviders(_ environment: [String: String]) -> [any AgentProvider] {
        if let raw = environment["AGENT_FLOAT_FAKE_SESSIONS"], let count = Int(raw), count > 0 {
            return [FakeProvider(count: count, startedAt: Date())]
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

    /// 시스템 설정의 화면 모드를 바꾸지 않고 라이트·다크 모양을 각각 확인하려는 디버그 덮어쓰기
    private static func applyAppearanceOverride(_ value: String?) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }

    /// 사람이 마우스를 올리지 않아도 펼친 모습과 전환 순서를 확인할 수 있게 한다 (USR1 펼침, USR2 접힘)
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

    /// 모든 데스크탑 고정·비활성 동작(spec 4.8)은 데스크탑을 직접 넘겨 봐야 알 수 있어, 사람 손 없이도 확인되게 실행 중인 실제 값을 남긴다
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

    /// SwiftUI 줄 hover 가 비활성 패널에서도 동작하는지는 추적 영역 옵션으로 판단할 수 있다
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
