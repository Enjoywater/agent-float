import Darwin
import Foundation
import Synchronization

public enum NavigationError: Error, Equatable {
    case terminalNotFound
    case commandFailed(String)
    case timedOut
}

/// 외부 명령 실행을 테스트에서 바꿔 끼우기 위한 경계. 성공하면 표준 출력 전체를 돌려준다
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) async throws -> String
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    /// 호출한 Task 가 취소되면 프로세스를 종료하고 곧바로 `CancellationError` 를 던진다
    public func run(_ executable: String, _ arguments: [String]) async throws -> String {
        let run = ProcessRun(executable: executable, arguments: arguments)
        let result = try await withTaskCancellationHandler {
            try await run.start()
        } onCancel: {
            run.cancel()
        }

        let stderr = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch result.exit {
        case .status(0):
            return String(decoding: result.stdout, as: UTF8.self)
        case let .status(code):
            throw NavigationError.commandFailed(stderr.isEmpty ? "exit status \(code)" : stderr)
        case let .signal(number):
            let reason = "terminated by signal \(number)"
            throw NavigationError.commandFailed(stderr.isEmpty ? reason : "\(reason): \(stderr)")
        }
    }
}

private struct ProcessResult: Sendable {
    enum Exit: Sendable {
        case status(Int32)
        case signal(Int32)
    }

    let exit: Exit
    let stdout: Data
    let stderr: Data
}

/// 프로세스 하나의 실행 전체를 소유한다. 종료와 두 파이프의 EOF 가 모두 관측되어야 끝나며(`ProcessResult`),
/// 취소·실행 실패·유예 만료 어느 경로로 끝나도 파이프 읽기 끝과 프로세스 참조를 모두 놓는다
private final class ProcessRun: Sendable {
    private struct State {
        var continuation: CheckedContinuation<ProcessResult, any Error>?
        var process: Process?
        var pid: Int32 = 0
        var stdout: PipeDrain?
        var stderr: PipeDrain?
        var exit: ProcessResult.Exit?
        var launched = false
        var cancelled = false
        var finished = false
        var openStreams = 2
    }

    // 종료 뒤 파이프가 닫히기를 기다리는 최대 시간. 명령이 물려준 백그라운드 자식이 파이프를 쥐고 있으면 EOF 가 오지 않는다
    private static let drainGrace: Duration = .milliseconds(500)
    // SIGTERM 을 무시하는 프로세스를 정리하기까지의 시간
    private static let killDelay: Duration = .seconds(2)

    private let executable: String
    private let arguments: [String]
    private let state = Mutex(State())

    init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    func start() async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            launch(continuation)
        }
    }

    func cancel() {
        let launched = state.withLock { state -> Bool in
            state.cancelled = true
            return state.launched
        }
        // 아직 띄우기 전이면 띄우는 쪽이 취소 여부를 보고 직접 종료한다
        if launched { terminateProcess() }
        abort(with: CancellationError())
    }

    // MARK: 실행

    private func launch(_ continuation: CheckedContinuation<ProcessResult, any Error>) {
        let proceed = state.withLock { state -> Bool in
            guard !state.cancelled else { return false }
            state.continuation = continuation
            return true
        }
        guard proceed else {
            continuation.resume(throwing: CancellationError())
            return
        }

        guard let outPipe = PosixPipe.make() else {
            abort(with: NavigationError.commandFailed("could not create a pipe"))
            return
        }
        guard let errPipe = PosixPipe.make() else {
            outPipe.closeBoth()
            abort(with: NavigationError.commandFailed("could not create a pipe"))
            return
        }
        // 프로세스를 띄우기 전에 읽기 시작해야 빨리 끝나는 명령의 출력도 놓치지 않는다
        let stdout = PipeDrain(readDescriptor: outPipe.read) { [self] in streamClosed() }
        let stderr = PipeDrain(readDescriptor: errPipe.read) { [self] in streamClosed() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // 표준 입력을 물려받으면 입력을 기다리는 명령이 영영 끝나지 않을 수 있다
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle(fileDescriptor: outPipe.write, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: errPipe.write, closeOnDealloc: false)
        // run() 뒤에 달면 빨리 끝난 프로세스의 종료 통지를 놓칠 수 있어 먼저 단다
        process.terminationHandler = { [self] finished in
            let exit: ProcessResult.Exit = finished.terminationReason == .uncaughtSignal
                ? .signal(finished.terminationStatus)
                : .status(finished.terminationStatus)
            processExited(exit)
        }
        let stillWanted = state.withLock { state -> Bool in
            guard !state.finished else { return false }
            state.process = process
            state.stdout = stdout
            state.stderr = stderr
            return true
        }
        // 파이프를 만드는 사이 취소되었다면 이미 호출자는 풀려났으므로 띄우지 않고 방금 만든 것만 정리한다
        guard stillWanted else {
            _ = stdout.close()
            _ = stderr.close()
            outPipe.closeWrite()
            errPipe.closeWrite()
            return
        }

        do {
            try process.run()
        } catch {
            outPipe.closeWrite()
            errPipe.closeWrite()
            // 종료 통지가 오지 않을 프로세스가 핸들러로 자기 자신을 붙들지 않게 끊는다
            process.terminationHandler = nil
            state.withLock { $0.process = nil }
            abort(with: NavigationError.commandFailed(error.localizedDescription))
            return
        }
        // 자식이 복제해 간 뒤에는 우리 쪽 쓰기 끝을 닫아야 자식이 끝날 때 EOF 가 온다
        outPipe.closeWrite()
        errPipe.closeWrite()

        let cancelledMeanwhile = state.withLock { state -> Bool in
            state.pid = process.processIdentifier
            state.launched = true
            return state.cancelled
        }
        if cancelledMeanwhile { terminateProcess() }
    }

    // MARK: 종료 관측

    private func processExited(_ exit: ProcessResult.Exit) {
        state.withLock {
            $0.exit = exit
            // 종료된 Process 를 붙들고 있으면 종료 신호를 다시 보낼 수 있는 상태로 오해할 수 있다
            $0.process = nil
        }
        if finishIfReady(force: false) { return }
        Task {
            try? await Task.sleep(for: Self.drainGrace)
            _ = finishIfReady(force: true)
        }
    }

    private func streamClosed() {
        state.withLock { $0.openStreams -= 1 }
        _ = finishIfReady(force: false)
    }

    /// 종료와 두 EOF 가 모두 왔거나(`force` 면 종료만 와도) 마무리한다. 이미 끝났으면 true
    @discardableResult
    private func finishIfReady(force: Bool) -> Bool {
        let claim = state.withLock { state -> (PipeDrain, PipeDrain, ProcessResult.Exit, CheckedContinuation<ProcessResult, any Error>?)? in
            guard !state.finished, let exit = state.exit, let stdout = state.stdout, let stderr = state.stderr,
                  force || state.openStreams == 0
            else { return nil }
            state.finished = true
            defer { state.continuation = nil; state.stdout = nil; state.stderr = nil }
            return (stdout, stderr, exit, state.continuation)
        }
        guard let (stdout, stderr, exit, continuation) = claim else {
            return state.withLock { $0.finished }
        }
        // 유예가 만료된 경우에도 파이프에 이미 쌓인 바이트는 마저 가져온다
        let result = ProcessResult(exit: exit, stdout: stdout.close(), stderr: stderr.close())
        continuation?.resume(returning: result)
        return true
    }

    /// 취소·실행 실패 같은 비정상 종료. 읽기 끝을 닫고 호출자를 곧바로 풀어 준다
    private func abort(with error: any Error) {
        let claim = state.withLock { state -> (PipeDrain?, PipeDrain?, CheckedContinuation<ProcessResult, any Error>?)? in
            guard !state.finished else { return nil }
            state.finished = true
            defer { state.continuation = nil; state.stdout = nil; state.stderr = nil }
            return (state.stdout, state.stderr, state.continuation)
        }
        guard let (stdout, stderr, continuation) = claim else { return }
        _ = stdout?.close()
        _ = stderr?.close()
        continuation?.resume(throwing: error)
    }

    // MARK: 종료 요청

    private func terminateProcess() {
        state.withLock { $0.process?.terminate() }
        Task {
            try? await Task.sleep(for: Self.killDelay)
            // 종료 통지가 이미 왔다면 pid 가 다른 프로세스에 재사용되었을 수 있어 건드리지 않는다
            let pid = state.withLock { $0.process == nil ? 0 : $0.pid }
            if pid > 0 { kill(pid, SIGKILL) }
        }
    }
}

private struct PosixPipe {
    let read: Int32
    let write: Int32

    static func make() -> PosixPipe? {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return nil }
        let made = PosixPipe(read: descriptors[0], write: descriptors[1])
        // 다른 곳에서 동시에 띄우는 자식에게 이 끝이 새어 나가면 그 자식이 끝날 때까지 EOF 가 오지 않는다
        for descriptor in descriptors {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                made.closeBoth()
                return nil
            }
        }
        // 읽기 끝은 이벤트가 올 때만 읽고 EAGAIN 에서 멈춰야 하므로 논블로킹이다
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0 else {
            made.closeBoth()
            return nil
        }
        return made
    }

    func closeWrite() { Darwin.close(write) }

    func closeBoth() {
        Darwin.close(read)
        Darwin.close(write)
    }
}

/// 파이프의 읽기 끝 하나를 EOF 까지 비운다. Foundation 의 `FileHandle` 은 프로세스가 끝나 Process 가 해제되는 순간
/// 읽지 못한 바이트와 함께 읽기 끝을 닫아 버리므로, 기술자를 직접 쥐고 소멸 시점을 우리가 정한다
private final class PipeDrain: Sendable {
    private struct State {
        var data = Data()
        // EOF 를 만났거나 우리가 닫았다. 기술자가 닫히면 번호가 다른 파일에 재사용될 수 있어 이후로는 절대 읽지 않는다
        var readClosed = false
    }

    private let descriptor: Int32
    private let queue = DispatchQueue(label: "agent-float.pipe-drain")
    private let source: any DispatchSourceRead
    private let state = Mutex(State())

    /// `onEnd` 는 EOF 를 만났을 때 한 번만 불린다
    init(readDescriptor: Int32, onEnd: @escaping @Sendable () -> Void) {
        descriptor = readDescriptor
        source = DispatchSource.makeReadSource(fileDescriptor: readDescriptor, queue: queue)
        source.setEventHandler { [self] in
            guard drainAvailable() else { return }
            source.cancel()
            // 이 핸들러는 우리 큐 위에서 돌고, 마무리 쪽이 같은 큐에 동기로 들어오므로 다른 큐로 넘겨야 교착하지 않는다
            DispatchQueue.global().async(execute: onEnd)
        }
        // 닫기는 취소 핸들러에서만 한다. 그 전에는 이벤트 핸들러가 이 기술자를 읽을 수 있다
        source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
        source.resume()
    }

    /// 쌓여 있는 바이트를 마저 읽고 더 이상 읽지 않도록 닫는다. 여러 번 불러도 안전하다
    func close() -> Data {
        queue.sync {
            _ = drainAvailable()
            state.withLock { $0.readClosed = true }
            source.cancel()
        }
        return state.withLock { $0.data }
    }

    /// 지금 읽을 수 있는 만큼 읽는다. 더 읽을 수 없는 끝에 이르렀으면 true
    private func drainAvailable() -> Bool {
        if state.withLock({ $0.readClosed }) { return true }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                state.withLock { $0.data.append(contentsOf: buffer[0..<count]) }
                continue
            }
            if count < 0, errno == EINTR { continue }
            // 읽을 것이 지금은 없을 뿐이면 다음 이벤트를 기다리고, 0 이나 그 밖의 오류면 더 읽을 수 없는 끝으로 본다
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return false }
            state.withLock { $0.readClosed = true }
            return true
        }
    }
}
