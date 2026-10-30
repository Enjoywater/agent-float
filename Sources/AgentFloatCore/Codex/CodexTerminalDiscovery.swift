import Darwin
import Foundation

struct CodexProcess: Sendable {
    let pid: Int32
    let cwd: String
    let environment: [String: String]
    let tty: String
}

struct CodexPlacement: Sendable {
    let app: TerminalApp
    let locator: TerminalLocator
}

/// 서버에 남은 thread 대신 실제 TUI 프로세스와 현재 터미널 제목을 함께 확인한다.
struct CodexTerminalInventory: Sendable {
    let processes: [CodexProcess]
    let ghostty: [GhosttyTerminal]
    let titlesByTTY: [String: String]
    let tmuxTitles: [String: String]
    let orcaTitles: [String: String]

    func placement(title: String?, cwd: String) -> CodexPlacement? {
        guard let title, !title.isEmpty else { return nil }
        var matches: [CodexPlacement] = []
        for process in processes where Self.samePath(process.cwd, cwd) {
            let env = process.environment
            if let pane = env["TMUX_PANE"], let tmux = env["TMUX"] {
                let pieces = tmux.split(separator: ",", omittingEmptySubsequences: false)
                let path = pieces.dropLast(2).joined(separator: ",")
                if pieces.count >= 3, TmuxCLI.isSafeSocketPath(path), TmuxCLI.isPaneId(pane), Self.matches(tmuxTitles[path + "\t" + pane], title: title, cwd: cwd) {
                    matches.append(CodexPlacement(app: .other("tmux"), locator: .tmux(socket: path, paneId: pane, pid: process.pid)))
                }
                continue
            }
            switch env["TERM_PROGRAM"] {
            case "ghostty":
                let surfaces = ghostty.filter { Self.samePath($0.cwd, cwd) && Self.matches($0.title, title: title, cwd: cwd) }
                if surfaces.count == 1 {
                    let locator = TerminalLocator.ghostty(title: GhosttyMatcher.strippedTitle(surfaces[0].title), cwd: cwd)
                    // 여러 프로세스가 같은 경로에 있어도 같은 surface를 중복 후보로 세지 않는다.
                    if !matches.contains(where: { $0.locator == locator }) { matches.append(CodexPlacement(app: .ghostty, locator: locator)) }
                }
            case "Orca":
                guard let pane = env["ORCA_PANE_KEY"], Self.matches(orcaTitles[pane], title: title, cwd: cwd) else { continue }
                let parts = pane.split(separator: ":")
                if parts.count == 2 {
                    matches.append(CodexPlacement(app: .orca, locator: .orca(tabId: String(parts[0]), leafId: String(parts[1]), handle: env["ORCA_TERMINAL_HANDLE"])))
                }
            case "Apple_Terminal":
                if Self.matches(titlesByTTY[process.tty], title: title, cwd: cwd) {
                    matches.append(CodexPlacement(app: .other("Apple_Terminal"), locator: .appleTerminal(tty: process.tty)))
                }
            case "iTerm.app":
                if Self.matches(titlesByTTY[process.tty], title: title, cwd: cwd) {
                    matches.append(CodexPlacement(app: .other("iTerm.app"), locator: .iTerm(tty: process.tty)))
                }
            default: break
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath().path
            == URL(fileURLWithPath: b).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func matches(_ raw: String?, title: String, cwd: String) -> Bool {
        guard let raw else { return false }
        let normalized = GhosttyMatcher.strippedTitle(raw).precomposedStringWithCanonicalMapping
        let expected = title.precomposedStringWithCanonicalMapping
        return normalized == expected || normalized == expected + " | " + URL(fileURLWithPath: cwd).lastPathComponent
    }

    static func live(codexHome: URL? = nil) throws -> CodexTerminalInventory {
        let inspector = DarwinProcessInspector()
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { throw CodexRPCError.unavailable }
        var pids = [Int32](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { throw CodexRPCError.unavailable }
        var processes: [CodexProcess] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard URL(fileURLWithPath: executable).lastPathComponent == "codex", let tty = inspector.tty(pid: pid) else { continue }
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { continue }
            let cwd = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            let environment = inspector.environment(pid: pid)
            if let codexHome {
                let processHome = environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
                if !samePath(processHome, codexHome.path) { continue }
            }
            var outerTTY = tty
            for ancestor in ProcessAncestry.chain(from: pid, inspector: inspector) {
                guard let device = inspector.tty(pid: ancestor) else { break }
                outerTTY = device
            }
            processes.append(CodexProcess(pid: pid, cwd: cwd, environment: environment, tty: outerTTY))
        }
        let programs = Set(processes.compactMap { $0.environment["TERM_PROGRAM"] })
        var ghostty: [GhosttyTerminal] = []
        var titlesByTTY: [String: String] = [:]
        var tmuxTitles: [String: String] = [:]
        var orcaTitles: [String: String] = [:]
        if programs.contains("ghostty") {
            ghostty = GhosttyMatcher.parseList(try SyncCommand.run("/usr/bin/osascript", ["-e", GhosttyScripts.listTerminals]))
        }
        for (program, app, collection, property) in [
            ("Apple_Terminal", "Terminal", "tabs", "name"),
            ("iTerm.app", "iTerm2", "sessions", "name"),
        ] where programs.contains(program) {
            let script = """
            set sep to character id 9
            tell application "\(app)"
              set out to ""
              repeat with w in windows
                \(program == "iTerm.app" ? "repeat with t in tabs of w" : "")
                repeat with s in \(collection) of \(program == "iTerm.app" ? "t" : "w")
                  set out to out & (tty of s) & sep & (\(property) of s) & linefeed
                end repeat
                \(program == "iTerm.app" ? "end repeat" : "")
              end repeat
              return out
            end tell
            """
            let output = try SyncCommand.run("/usr/bin/osascript", ["-e", script])
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1)
                if parts.count == 2 { titlesByTTY[String(parts[0])] = String(parts[1]) }
            }
        }
        if programs.contains("Orca") {
            let output = try SyncCommand.run("/usr/bin/env", ["orca", "terminal", "list", "--json"])
            let json = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
            let terminals = (json?["result"] as? [String: Any])?["terminals"] as? [[String: Any]] ?? []
            for t in terminals {
                if let tab = t["tabId"] as? String, let leaf = t["leafId"] as? String, let title = t["title"] as? String {
                    orcaTitles[tab + ":" + leaf] = title
                }
            }
        }
        if let executable = TmuxCLI.resolveExecutable() {
            let sockets = Set(processes.compactMap { $0.environment["TMUX"] }.map { $0.split(separator: ",").dropLast(2).joined(separator: ",") })
            for socket in sockets where TmuxCLI.isSafeSocketPath(socket) {
                let output = try SyncCommand.run(executable, ["-S", socket, "list-panes", "-a", "-F", "#{pane_id}\t#{pane_title}"])
                for line in output.split(separator: "\n") {
                    let parts = line.split(separator: "\t", maxSplits: 1)
                    if parts.count == 2 { tmuxTitles[socket + "\t" + String(parts[0])] = String(parts[1]) }
                }
            }
        }
        return CodexTerminalInventory(processes: processes, ghostty: ghostty, titlesByTTY: titlesByTTY, tmuxTitles: tmuxTitles, orcaTitles: orcaTitles)
    }
}

/// 동기 provider에서 Swift Task를 만들고 기다리면 협력 실행기 전체가 막힐 수 있다.
/// 짧은 읽기 전용 조회는 같은 스레드에서 두 출력을 함께 비우고 제한 시간 안에 끝낸다.
enum SyncCommand {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 2) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let outFD = output.fileHandleForReading.fileDescriptor
        let errFD = errors.fileHandleForReading.fileDescriptor
        defer {
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        guard fcntl(outFD, F_SETFL, O_NONBLOCK) == 0, fcntl(errFD, F_SETFL, O_NONBLOCK) == 0 else {
            throw CodexRPCError.unavailable
        }
        var data = [Data(), Data()]
        var open = [true, true]
        let descriptors = [outFD, errFD]
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while open.contains(true) || process.isRunning {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CodexRPCError.timeout }
            var entries = descriptors.enumerated().map {
                pollfd(fd: open[$0.offset] ? $0.element : -1, events: Int16(POLLIN), revents: 0)
            }
            let result = poll(&entries, nfds_t(entries.count), Int32(min(remaining * 1000 + 1, 50)))
            if result < 0 {
                if errno == EINTR { continue }
                throw CodexRPCError.unavailable
            }
            for index in entries.indices where open[index] && entries[index].revents != 0 {
                while true {
                    let count = Darwin.read(descriptors[index], &buffer, buffer.count)
                    if count > 0 {
                        data[index].append(contentsOf: buffer.prefix(count))
                        guard data[index].count <= 16 * 1024 * 1024 else { throw CodexRPCError.invalidResponse }
                    } else if count == 0 {
                        open[index] = false
                        break
                    } else if errno == EINTR {
                        continue
                    } else if errno == EAGAIN {
                        break
                    } else {
                        throw CodexRPCError.unavailable
                    }
                }
            }
        }
        guard process.terminationStatus == 0 else {
            throw NavigationError.commandFailed(String(decoding: data[1], as: UTF8.self))
        }
        return String(decoding: data[0], as: UTF8.self)
    }
}
