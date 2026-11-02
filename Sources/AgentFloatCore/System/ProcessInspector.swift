import Darwin
import Foundation

/// Use kernel APIs rather than ps for process liveness/environment/parents in this always-running widget.
public protocol ProcessInspecting: Sendable {
    func isAlive(pid: Int32, procStart: String?) -> Bool
    func environment(pid: Int32) -> [String: String]
    /// Nil for launchd or lower and inspection failure; terminates ancestor traversal.
    func parentPid(of pid: Int32) -> Int32?
    /// Controlling terminal device path, or nil when unavailable or absent.
    func tty(pid: Int32) -> String?
}

public extension ProcessInspecting {
    // Optional tty support lets unsupported terminals fall back to app activation.
    func tty(pid: Int32) -> String? { nil }
}

public struct DarwinProcessInspector: ProcessInspecting {
    /// Read ARGMAX once at initialization to avoid an extra sysctl per environment lookup.
    private static let argMax: Int = {
        var mib = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, UInt32(mib.count), &value, &size, nil, 0) == 0, value > 0 else {
            return 1 << 20
        }
        return Int(value)
    }()

    public init() {}

    public func isAlive(pid: Int32, procStart: String?) -> Bool {
        guard let info = Self.bsdInfo(pid) else { return false }
        // If start-time parsing changes, retain live sessions using existence rather than dropping the entire list.
        guard let text = procStart, let expected = ProcStart.parse(text) else { return true }
        // The same PID with a different start time identifies a different process.
        let actual = Int64(info.pbi_start_tvsec)
        return abs(actual - Int64(expected.timeIntervalSince1970)) <= 1
    }

    public func environment(pid: Int32) -> [String: String] {
        guard pid > 0 else { return [:] }
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        // Allocate ARGMAX directly; querying size first can race into EINVAL.
        var size = Self.argMax
        var buffer = [UInt8](repeating: 0, count: size)
        let status = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, UInt32(mib.count), raw.baseAddress, &size, nil, 0)
        }
        guard status == 0, size > 0, size <= buffer.count else { return [:] }
        return ProcArgs.parseEnvironment(Array(buffer[0..<size]))
    }

    public func parentPid(of pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        // Full PROC_PIDTBSDINFO returns EPERM for processes owned by another user.
        // Ghostty launches through root-owned login; use short BSD info to traverse that ancestor boundary.
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        guard info.pbsi_ppid > 1, let parent = Int32(exactly: info.pbsi_ppid) else { return nil }
        return parent
    }

    public func tty(pid: Int32) -> String? {
        // Processes without a terminal return NODEV, all bits set.
        guard let info = Self.bsdInfo(pid), info.e_tdev != UInt32.max else { return nil }
        // Supply a private buffer because devname's static buffer is not thread-safe.
        var buffer = [CChar](repeating: 0, count: 64)
        guard devname_r(dev_t(bitPattern: info.e_tdev), S_IFCHR, &buffer, Int32(buffer.count)) != nil else { return nil }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        // Some implementations return ?? instead of a name when no device matches.
        guard !name.isEmpty, name != "??" else { return nil }
        return "/dev/" + name
    }

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        // Accept only a complete info structure: missing PIDs return zero and permission failures return negative values.
        // With argument zero, unreaped zombies also return zero and are naturally treated as dead.
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }
}

/// Parse the sysctl KERN_PROCARGS2 buffer.
/// Layout: Int32 argc, NUL-terminated executable, alignment NULs, argc argv strings, then KEY=VALUE environment strings.
enum ProcArgs {
    static func parseEnvironment(_ buffer: [UInt8]) -> [String: String] {
        let headerSize = MemoryLayout<Int32>.size
        guard buffer.count >= headerSize else { return [:] }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return [:] }

        var index = headerSize
        index = skipString(in: buffer, from: index)
        while index < buffer.count, buffer[index] == 0 { index += 1 }

        for _ in 0..<argc {
            // If the buffer ends before argv is skipped, no environment region exists.
            guard index < buffer.count else { return [:] }
            index = skipString(in: buffer, from: index)
        }

        var environment: [String: String] = [:]
        while index < buffer.count {
            let end = buffer[index...].firstIndex(of: 0) ?? buffer.count
            // An empty string ends the environment; subsequent Apple strings are not variables.
            if end == index { break }
            let entry = buffer[index..<end]
            index = end + 1
            guard let separator = entry.firstIndex(of: UInt8(ascii: "=")), separator > entry.startIndex else { continue }
            let key = String(decoding: entry[entry.startIndex..<separator], as: UTF8.self)
            let value = String(decoding: entry[(separator + 1)...], as: UTF8.self)
            // Assign incrementally so duplicate keys cannot trap.
            environment[key] = value
        }
        return environment
    }

    /// Skip a NUL-terminated string, returning buffer end if the terminator is absent.
    private static func skipString(in buffer: [UInt8], from start: Int) -> Int {
        guard start < buffer.count else { return buffer.count }
        guard let nul = buffer[start...].firstIndex(of: 0) else { return buffer.count }
        return nul + 1
    }
}

/// Session procStart uses ps lstart format and is interpreted as UTC.
enum ProcStart {
    static func parse(_ text: String) -> Date? {
        // Collapse repeated whitespace to normalize single-digit day padding before date parsing.
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        // DateFormatter is not Sendable; construct per call rather than sharing a static instance.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: normalized)
    }
}
