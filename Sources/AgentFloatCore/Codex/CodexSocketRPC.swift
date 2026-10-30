import CryptoKit
import Darwin
import Foundation

protocol CodexRPC {
    func call(_ method: String, params: Data) throws -> Data
    func notify(_ method: String) throws
}

enum CodexRPCError: Error {
    case unavailable, timeout, invalidResponse, server(Int)
}

/// Codex의 기존 Unix control socket에만 연결한다. 서버 실행·세션 resume·이벤트 구독은 하지 않는다.
/// 동기 snapshot은 메인 밖에서 실행된다. 연결 전체에 3초, 응답 크기에 16MiB 제한을 둔다.
final class CodexSocketRPC: CodexRPC {
    private let descriptor: Int32
    private let deadline: TimeInterval
    private var nextID = 0
    private static let maxMessage = 16 * 1024 * 1024

    init(path: String, timeout: TimeInterval = 3) throws {
        deadline = ProcessInfo.processInfo.systemUptime + timeout
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CodexRPCError.unavailable }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw CodexRPCError.unavailable }
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw CodexRPCError.unavailable
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CodexRPCError.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw CodexRPCError.unavailable }
            try wait(for: Int16(POLLOUT))
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw CodexRPCError.unavailable
            }
        }
        try upgrade()
    }

    deinit { Darwin.close(descriptor) }

    func call(_ method: String, params: Data) throws -> Data {
        nextID += 1
        let id = nextID
        try sendFrame(opcode: 1, payload: JSONSerialization.data(withJSONObject: [
            "id": id, "method": method, "params": try JSONSerialization.jsonObject(with: params),
        ]))
        while true {
            let data = try readMessage()
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CodexRPCError.invalidResponse
            }
            // 다른 세션의 알림은 요청한 응답과 섞지 않는다.
            guard object["id"] as? Int == id else { continue }
            if let error = object["error"] as? [String: Any] {
                throw CodexRPCError.server(error["code"] as? Int ?? 0)
            }
            guard let result = object["result"] else { throw CodexRPCError.invalidResponse }
            return try JSONSerialization.data(withJSONObject: result)
        }
    }

    func notify(_ method: String) throws {
        try sendFrame(opcode: 1, payload: JSONSerialization.data(withJSONObject: ["method": method]))
    }

    private func upgrade() throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try write(Data(request.utf8))
        var header = Data()
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard header.count < 16 * 1024 else { throw CodexRPCError.invalidResponse }
            header.append(try read(1))
        }
        let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
        let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let accepted = lines.dropFirst().contains { line in
            let pair = line.split(separator: ":", maxSplits: 1)
            return pair.count == 2 && pair[0].lowercased() == "sec-websocket-accept"
                && pair[1].trimmingCharacters(in: .whitespaces) == expected
        }
        guard lines.first?.hasPrefix("HTTP/1.1 101 ") == true, accepted else { throw CodexRPCError.invalidResponse }
    }

    private func sendFrame(opcode: UInt8, payload: Data) throws {
        guard payload.count <= Self.maxMessage else { throw CodexRPCError.invalidResponse }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(0x80 | 126)
            frame.append(UInt8(payload.count >> 8)); frame.append(UInt8(payload.count & 255))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(payload.count) >> shift) & 255)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try write(frame)
    }

    private func readMessage() throws -> Data {
        var message = Data()
        var started = false
        while true {
            let header = Array(try read(2))
            let final = header[0] & 0x80 != 0
            let opcode = header[0] & 0x0F
            guard header[0] & 0x70 == 0, header[1] & 0x80 == 0 else { throw CodexRPCError.invalidResponse }
            var count = UInt64(header[1] & 0x7F)
            if count == 126 { count = try read(2).reduce(0) { ($0 << 8) | UInt64($1) } }
            else if count == 127 { count = try read(8).reduce(0) { ($0 << 8) | UInt64($1) } }
            guard count <= UInt64(Self.maxMessage - message.count) else { throw CodexRPCError.invalidResponse }
            if opcode >= 8, (!final || count > 125) { throw CodexRPCError.invalidResponse }
            let payload = try read(Int(count))
            switch opcode {
            case 8: throw CodexRPCError.unavailable
            case 9: try sendFrame(opcode: 10, payload: payload); continue
            case 10: continue
            case 1:
                guard !started else { throw CodexRPCError.invalidResponse }
                started = true
            case 0:
                guard started else { throw CodexRPCError.invalidResponse }
            default: throw CodexRPCError.invalidResponse
            }
            message.append(payload)
            if final { return message }
        }
    }

    private func wait(for events: Int16) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CodexRPCError.timeout }
            var entry = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&entry, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw result == 0 ? CodexRPCError.timeout : CodexRPCError.unavailable }
            guard entry.revents & events != 0 else { throw CodexRPCError.unavailable }
            return
        }
    }

    private func read(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            try wait(for: Int16(POLLIN))
            let received = data.withUnsafeMutableBytes { raw in
                recv(descriptor, raw.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if received < 0, [EINTR, EAGAIN].contains(errno) { continue }
            guard received > 0 else { throw CodexRPCError.unavailable }
            offset += received
        }
        return data
    }

    private func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            try wait(for: Int16(POLLOUT))
            let sent = data.withUnsafeBytes { raw in
                send(descriptor, raw.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            if sent < 0, [EINTR, EAGAIN].contains(errno) { continue }
            guard sent > 0 else { throw CodexRPCError.unavailable }
            offset += sent
        }
    }
}
