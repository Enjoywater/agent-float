import Foundation
import Testing
@testable import AgentFloatCore

@Suite struct ProcessInspectorTests {
    private func cstr(_ text: String) -> [UInt8] {
        Array(text.utf8) + [0]
    }

    private func argc(_ count: Int32) -> [UInt8] {
        withUnsafeBytes(of: count) { Array($0) }
    }

    @Test func parsesProcArgs2Layout() {
        // argc(Int32 LE)=2, exec path "/bin/claude\0\0\0", argv "claude\0--resume\0", env "TERM_PROGRAM=ghostty\0ORCA_PANE_KEY=t1:l1\0\0"
        let buffer = argc(2)
            + cstr("/bin/claude") + [0, 0]
            + cstr("claude") + cstr("--resume")
            + cstr("TERM_PROGRAM=ghostty") + cstr("ORCA_PANE_KEY=t1:l1") + [0]
        #expect(ProcArgs.parseEnvironment(buffer) == ["TERM_PROGRAM": "ghostty", "ORCA_PANE_KEY": "t1:l1"])
    }

    @Test func splitsEnvironmentEntryAtFirstEqualsOnly() {
        let buffer = argc(1) + cstr("/bin/x") + [0] + cstr("x") + cstr("LS_COLORS=a=b:c=d") + [0]
        #expect(ProcArgs.parseEnvironment(buffer) == ["LS_COLORS": "a=b:c=d"])
    }

    @Test func survivesDuplicateKeysAndEntriesWithoutEquals() {
        let buffer = argc(1) + cstr("/bin/x") + [0] + cstr("x")
            + cstr("A=1") + cstr("garbage") + cstr("A=2") + [0]
        let env = ProcArgs.parseEnvironment(buffer)
        #expect(env.count == 1)
        #expect(env["A"] != nil)
    }

    @Test func stopsAtBufferEndWithoutTerminator() {
        let buffer = argc(1) + cstr("/bin/x") + [0] + cstr("x") + cstr("A=1") + Array("B=2".utf8)
        #expect(ProcArgs.parseEnvironment(buffer) == ["A": "1", "B": "2"])
    }

    @Test func malformedBuffersYieldEmptyEnvironment() {
        #expect(ProcArgs.parseEnvironment([]).isEmpty)
        #expect(ProcArgs.parseEnvironment([2, 0]).isEmpty)
        #expect(ProcArgs.parseEnvironment(argc(2) + cstr("/bin/x")).isEmpty)
        #expect(ProcArgs.parseEnvironment(argc(-1) + cstr("/bin/x") + [0] + cstr("x")).isEmpty)
        #expect(ProcArgs.parseEnvironment(argc(Int32.max) + cstr("/bin/x") + [0] + cstr("x") + cstr("A=1")).isEmpty)
    }

    @Test func parsesProcStart() {
        #expect(ProcStart.parse("Fri Oct 16 04:12:10 2026") == Date(timeIntervalSince1970: 1_792_123_930))
        #expect(ProcStart.parse("Thu Oct  1 09:05:03 2026") == Date(timeIntervalSince1970: 1_790_845_503))
        #expect(ProcStart.parse("nonsense") == nil)
    }

    @Test func acceptsMatchingStartAndRejectsReusedPid() {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        #expect(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size)
        let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let i = DarwinProcessInspector()
        #expect(i.isAlive(pid: getpid(), procStart: formatter.string(from: started)))
        #expect(i.isAlive(pid: getpid(), procStart: formatter.string(from: started.addingTimeInterval(1))))
        #expect(!i.isAlive(pid: getpid(), procStart: formatter.string(from: started.addingTimeInterval(5))))
    }

    @Test func liveSelfInspection() {
        let i = DarwinProcessInspector()
        #expect(i.isAlive(pid: getpid(), procStart: nil))
        #expect(i.environment(pid: getpid())["PATH"] != nil)
        #expect(!i.isAlive(pid: 999_999, procStart: nil))
        #expect(!i.isAlive(pid: getpid(), procStart: "Thu Jan  1 00:00:00 2015"))
        #expect(i.parentPid(of: getpid()) == getppid())
        #expect(i.parentPid(of: 1) == nil)
    }

    /// Reference values use the same sysctl path as ps, including parents owned by other users.
    private static func processTable() -> [(pid: Int32, ppid: Int32, uid: uid_t)] {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = table.count * stride
        guard sysctl(&mib, 4, &table, &size, nil, 0) == 0 else { return [] }
        return table.prefix(size / stride).map { ($0.kp_proc.p_pid, $0.kp_eproc.e_ppid, $0.kp_eproc.e_ucred.cr_uid) }
    }

    // Ghostty launches through root-owned login; stopping there would prevent terminal-app fallback.
    @Test func ttyOfMissingProcessIsNil() {
        let inspector = DarwinProcessInspector()
        #expect(inspector.tty(pid: 0) == nil)
        #expect(inspector.tty(pid: Int32.max) == nil)
    }

    /// Test runners may lack a tty; compare against stdin's terminal name rather than assuming one exists.
    @Test func ttyOfCurrentProcessMatchesTtyname() {
        let expected = ttyname(STDIN_FILENO).map { String(cString: $0) }
        #expect(DarwinProcessInspector().tty(pid: getpid()) == expected)
    }

    @Test func parentPidReadsProcessesOwnedByOtherUsers() {
        let inspector = DarwinProcessInspector()
        let others = Self.processTable().filter { $0.uid != getuid() && $0.ppid > 1 }
        var checked = 0
        for process in others {
            // Processes that exit or are reparented to launchd after enumeration legitimately return nil; skip those comparisons.
            guard let parent = inspector.parentPid(of: process.pid) else { continue }
            #expect(parent == process.ppid, "pid \(process.pid)")
            checked += 1
        }
        // Reject an all-nil result from EPERM so the reference comparisons cannot pass vacuously.
        #expect(checked >= 1, "no other-user process could be read out of \(others.count)")
    }

    @Test func ancestorWalkFromSelfReachesLaunchd() {
        let inspector = DarwinProcessInspector()
        let truth = Dictionary(Self.processTable().map { ($0.pid, $0.ppid) }, uniquingKeysWith: { first, _ in first })
        var current = getpid()
        var steps = 0
        while steps < 64, let parent = inspector.parentPid(of: current) {
            current = parent
            steps += 1
        }
        #expect(truth[current] == 1, "walk stopped at pid \(current)")
    }
}
