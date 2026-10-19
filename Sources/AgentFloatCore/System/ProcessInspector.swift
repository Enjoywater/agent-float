import Darwin
import Foundation

/// 에이전트 프로세스의 생존·환경변수·부모 pid 조회. 위젯이 하루 종일 떠 있으므로 `ps` 대신 커널 API 로 읽는다
public protocol ProcessInspecting: Sendable {
    func isAlive(pid: Int32, procStart: String?) -> Bool
    func environment(pid: Int32) -> [String: String]
    /// launchd(1) 이하이거나 조회에 실패하면 nil. 터미널 앱을 찾아 올라가는 순회의 종료 조건으로 쓴다
    func parentPid(of pid: Int32) -> Int32?
}

public struct DarwinProcessInspector: ProcessInspecting {
    /// 로딩 시점에 한 번만 읽는다. 환경변수 조회마다 sysctl 을 한 번 더 부르지 않기 위함
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
        // 파싱되지 않는 값으로 살아 있는 세션을 버리면 포맷이 한 번 바뀔 때 목록이 통째로 비므로 존재 여부만 본다
        guard let text = procStart, let expected = ProcStart.parse(text) else { return true }
        // pid 는 재사용되므로 같은 pid 라도 시작 시각이 다르면 다른 프로세스다
        let actual = Int64(info.pbi_start_tvsec)
        return abs(actual - Int64(expected.timeIntervalSince1970)) <= 1
    }

    public func environment(pid: Int32) -> [String: String] {
        guard pid > 0 else { return [:] }
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        // 크기를 먼저 묻는 방식은 두 호출 사이에 EINVAL 이 날 수 있어 ARGMAX 만큼 한 번에 받는다
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
        // 전체 정보(PROC_PIDTBSDINFO)는 다른 사용자 소유 프로세스에서 EPERM 으로 거부된다.
        // Ghostty 는 root 소유 /usr/bin/login 을 거쳐 셸을 띄우므로(실측) 그 너머 부모까지 알려주는 짧은 정보를 쓴다
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        guard info.pbsi_ppid > 1, let parent = Int32(exactly: info.pbsi_ppid) else { return nil }
        return parent
    }

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        // 없는 pid 는 0, 권한이 없으면 음수를 돌려주므로 구조체가 가득 찼을 때만 성공으로 본다
        // arg 를 0 으로 부르면 부모가 거두지 않은 좀비도 0 이 돌아와 따로 거르지 않아도 죽은 것으로 취급된다
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }
}

/// `sysctl(KERN_PROCARGS2)` 버퍼 해석.
/// 배치는 Int32 argc, 실행 경로(NUL 종료), 정렬용 NUL 패딩, argv argc 개, 이어서 `KEY=VALUE` 환경 문자열이다
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
            // argv 를 다 건너뛰기 전에 버퍼가 끝났다면 환경 영역이 없는 것이다
            guard index < buffer.count else { return [:] }
            index = skipString(in: buffer, from: index)
        }

        var environment: [String: String] = [:]
        while index < buffer.count {
            let end = buffer[index...].firstIndex(of: 0) ?? buffer.count
            // 빈 문자열은 환경 끝이며, 뒤따르는 apple 문자열은 환경변수가 아니다
            if end == index { break }
            let entry = buffer[index..<end]
            index = end + 1
            guard let separator = entry.firstIndex(of: UInt8(ascii: "=")), separator > entry.startIndex else { continue }
            let key = String(decoding: entry[entry.startIndex..<separator], as: UTF8.self)
            let value = String(decoding: entry[(separator + 1)...], as: UTF8.self)
            // 같은 키가 겹쳐도 죽지 않도록 대입으로 쌓는다
            environment[key] = value
        }
        return environment
    }

    /// NUL 로 끝나는 문자열 하나를 건너뛴 다음 위치. 종료 NUL 이 없으면 버퍼 끝을 돌려준다
    private static func skipString(in buffer: [UInt8], from start: Int) -> Int {
        guard start < buffer.count else { return buffer.count }
        guard let nul = buffer[start...].firstIndex(of: 0) else { return buffer.count }
        return nul + 1
    }
}

/// 세션 파일의 `procStart`. `ps -o lstart` 형태("Fri Oct 16 04:12:10 2026")이며 UTC 로 해석한다
enum ProcStart {
    static func parse(_ text: String) -> Date? {
        // 한 자리 일자는 공백 두 칸으로 채워지므로 연속 공백을 하나로 줄여야 날짜 패턴과 맞는다
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        // DateFormatter 는 Sendable 이 아니라 공유 static 으로 둘 수 없어 호출마다 만든다
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: normalized)
    }
}
