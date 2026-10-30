import CryptoKit
import Darwin
import Foundation
import Testing
@testable import AgentFloatCore

/// 실제 Unix socket과 WebSocket 프레임을 사용한다. 외부 Codex 설치·네트워크는 필요 없다.
private final class CodexSocketFixture: @unchecked Sendable {
    let path = "/tmp/af-\(UUID().uuidString).sock"
    private let listener: Int32
    private let finished = DispatchSemaphore(value: 0)

    init(_ serve: @escaping @Sendable (Int32) throws -> Void) throws {
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw CodexRPCError.unavailable }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else {
            finished.signal()
            throw CodexRPCError.unavailable
        }
        let serverDescriptor = listener
        let completion = finished
        DispatchQueue.global().async {
            defer { completion.signal() }
            var ready = pollfd(fd: serverDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 3000) > 0 else { return }
            let peer = accept(serverDescriptor, nil, nil)
            guard peer >= 0 else { return }
            defer { Darwin.close(peer) }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            do { try serve(peer) }
            catch {
                // 잘못된 handshake·시간 초과 테스트에서는 클라이언트가 먼저 닫는다.
                // 정상 경로의 서버 실패는 클라이언트 요청이 실패하면서 호출한 테스트에 기록된다.
            }
        }
    }

    deinit {
        _ = finished.wait(timeout: .now() + 4)
        Darwin.close(listener)
        unlink(path)
    }

    static func read(_ peer: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes { recv(peer, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            guard received > 0 else { throw CodexRPCError.unavailable }
            offset += received
        }
        return data
    }

    static func write(_ peer: Int32, _ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { send(peer, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            guard sent > 0 else { throw CodexRPCError.unavailable }
            offset += sent
        }
    }

    static func upgrade(_ peer: Int32) throws {
        var data = Data()
        while !data.suffix(4).elementsEqual([13, 10, 13, 10]) { data.append(try read(peer, 1)) }
        let header = String(decoding: data, as: UTF8.self)
        let keyLine = try #require(header.components(separatedBy: "\r\n").first { $0.hasPrefix("Sec-WebSocket-Key:") })
        let key = keyLine.dropFirst("Sec-WebSocket-Key:".count).trimmingCharacters(in: .whitespaces)
        let digest = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        try write(peer, Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(digest)\r\n\r\n".utf8))
    }

    static func frame(_ peer: Int32) throws -> (UInt8, Data) {
        let header = Array(try read(peer, 2))
        #expect(header[1] & 0x80 != 0) // 클라이언트 프레임은 반드시 마스킹한다.
        var count = Int(header[1] & 127)
        if count == 126 { count = try read(peer, 2).reduce(0) { ($0 << 8) | Int($1) } }
        let mask = Array(try read(peer, 4))
        let payload = try read(peer, count)
        return (header[0] & 15, Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }))
    }
}

struct CodexSocketRPCTests {
    @Test func rejectsInvalidUpgradeAndClosedConnection() throws {
        let fixture = try CodexSocketFixture { peer in
            // 성공 상태 코드만으로 WebSocket 연결을 신뢰하지 않는다.
            try CodexSocketFixture.write(peer, Data("HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: invalid\r\n\r\n".utf8))
        }
        #expect(throws: CodexRPCError.self) { try CodexSocketRPC(path: fixture.path) }
        withExtendedLifetime(fixture) {}
        let closed = try CodexSocketFixture { _ in }
        #expect(throws: CodexRPCError.self) { try CodexSocketRPC(path: closed.path) }
        withExtendedLifetime(closed) {}
    }

    @Test func handlesFragmentedResponsePingAndUnrelatedNotifications() throws {
        let fixture = try CodexSocketFixture { peer in
            try CodexSocketFixture.upgrade(peer)
            let (_, request) = try CodexSocketFixture.frame(peer)
            let json = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
            #expect(json["method"] as? String == "thread/loaded/list")
            let notification = Data(#"{"method":"thread/status/changed","params":{}}"#.utf8)
            try CodexSocketFixture.write(peer, Data([0x81, UInt8(notification.count)]) + notification)
            try CodexSocketFixture.write(peer, Data([0x89, 1, 42]))
            let (opcode, pong) = try CodexSocketFixture.frame(peer)
            #expect(opcode == 10)
            #expect(pong == Data([42]))
            let response = Array(#"{"id":1,"result":{"data":["a"],"nextCursor":null}}"#.utf8)
            let first = Data([0x01, 10]) + Data(response.prefix(10))
            let last = Data([0x80, UInt8(response.count - 10)]) + Data(response.dropFirst(10))
            // recv가 헤더나 payload 전체를 한 번에 주지 않는 경우도 검사한다.
            for byte in first + last { try CodexSocketFixture.write(peer, Data([byte])) }
        }
        let rpc = try CodexSocketRPC(path: fixture.path)
        let result = try rpc.call("thread/loaded/list", params: Data("{}".utf8))
        let object = try #require(JSONSerialization.jsonObject(with: result) as? [String: Any])
        #expect(object["data"] as? [String] == ["a"])
        withExtendedLifetime(fixture) {}
    }

    @Test func propagatesRPCError() throws {
        let fixture = try CodexSocketFixture { peer in
            try CodexSocketFixture.upgrade(peer)
            _ = try CodexSocketFixture.frame(peer)
            let response = Data(#"{"id":1,"error":{"code":-32602,"message":"not found"}}"#.utf8)
            try CodexSocketFixture.write(peer, Data([0x81, UInt8(response.count)]) + response)
        }
        let rpc = try CodexSocketRPC(path: fixture.path)
        do {
            _ = try rpc.call("thread/read", params: Data("{}".utf8))
            Issue.record("expected RPC error")
        } catch CodexRPCError.server(let code) { #expect(code == -32602) }
        withExtendedLifetime(fixture) {}
    }

    @Test func rejectsOversizedFramesBeforeAllocatingPayload() throws {
        let fixture = try CodexSocketFixture { peer in
            try CodexSocketFixture.upgrade(peer)
            _ = try CodexSocketFixture.frame(peer)
            try CodexSocketFixture.write(peer, Data([0x81, 127, 0, 0, 0, 0, 2, 0, 0, 0])) // 32MiB
        }
        let rpc = try CodexSocketRPC(path: fixture.path)
        #expect(throws: CodexRPCError.self) { try rpc.call("thread/loaded/list", params: Data("{}".utf8)) }
        withExtendedLifetime(fixture) {}
    }

    @Test func boundsSilentServerWait() throws {
        let fixture = try CodexSocketFixture { peer in
            try CodexSocketFixture.upgrade(peer)
            _ = try CodexSocketFixture.frame(peer)
            _ = poll(nil, 0, 800)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let rpc = try CodexSocketRPC(path: fixture.path, timeout: 0.5)
        #expect(throws: CodexRPCError.self) { try rpc.call("thread/loaded/list", params: Data("{}".utf8)) }
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
        withExtendedLifetime(fixture) {}
    }
}
