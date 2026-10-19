import AgentFloatCore
import AppKit

/// navigator 가 고른 앱을 앞으로 올린다. navigator 는 메인 밖에서 부르지만 AppKit 호출은 메인 전용이다 (R24)
@MainActor
final class AppActivator {
    /// 폴백은 조상 중 어느 앱을 올렸는지 실행해야 알 수 있어, 그 앱이 앞에 왔는지 확인할 수 있게 세션 pid 별로 남긴다 (R37)
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

    /// 가까운 조상부터 보므로 처음 만나는 Dock 앱이 세션을 띄운 터미널이다. 같은 앱의 보조 프로세스는 Dock 앱이 아니라 건너뛴다.
    /// 고르기만 하고 기록한다. tmux 바깥 터미널처럼 앱에 따라 올리는 방법(탭 선택 스크립트·LaunchServices)이 달라서다
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

    /// 한 번 읽으면 지운다. 다음 클릭은 새로 고른 앱을 기준으로 확인해야 한다
    func takeFallbackChoice(forSession pid: Int32) -> Int32? {
        fallbackChoices.removeValue(forKey: pid)
    }

    /// macOS 14+ 협조적 활성화에서는 앞에 있지 않은 앱이 보낸 `activate()` 가 무시될 수 있어,
    /// Dock 아이콘을 누른 것과 같은 LaunchServices 경로로 연다 (R36)
    private static func open(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // 이동할 때마다 터미널 앱이 최근 항목에 쌓이지 않게 한다
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
