import Darwin
import Foundation
import Synchronization

public enum NavigationError: Error, Equatable {
    case terminalNotFound
    case commandFailed(String)
    case timedOut
}

/// Inject command execution in tests; successful runs return complete stdout.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) async throws -> String
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    /// Task cancellation terminates the child and immediately throws CancellationError.
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

/// Own one command's full lifecycle, completing only after process exit and both pipe EOFs.
/// Cancellation, launch failures, and grace expiry all release pipe readers and process references.
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

    // Limit post-exit drain time because background descendants may keep inherited pipes open indefinitely.
    private static let drainGrace: Duration = .milliseconds(500)
    // Grace period before killing a child that ignores SIGTERM.
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
        // If not launched yet, the launching path observes cancellation and terminates it.
        if launched { terminateProcess() }
        abort(with: CancellationError())
    }

    // MARK: Launch

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
        // Start draining before launch so fast commands cannot lose output.
        let stdout = PipeDrain(readDescriptor: outPipe.read) { [self] in streamClosed() }
        let stderr = PipeDrain(readDescriptor: errPipe.read) { [self] in streamClosed() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Do not inherit stdin: commands waiting for input might otherwise never finish.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle(fileDescriptor: outPipe.write, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: errPipe.write, closeOnDealloc: false)
        // Install termination observation before run() to catch fast exits.
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
        // If cancelled while creating pipes, release them without launching; the caller has already resumed.
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
            // Break the self-retaining handler for a process that will never deliver termination.
            process.terminationHandler = nil
            state.withLock { $0.process = nil }
            abort(with: NavigationError.commandFailed(error.localizedDescription))
            return
        }
        // Close parent write ends after inheritance so child exit can produce EOF.
        outPipe.closeWrite()
        errPipe.closeWrite()

        let cancelledMeanwhile = state.withLock { state -> Bool in
            state.pid = process.processIdentifier
            state.launched = true
            return state.cancelled
        }
        if cancelledMeanwhile { terminateProcess() }
    }

    // MARK: Exit observation

    private func processExited(_ exit: ProcessResult.Exit) {
        state.withLock {
            $0.exit = exit
            // Release the exited Process so it cannot appear eligible for another termination signal.
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

    /// Finish once exit and both EOFs arrive, or exit alone when forced; return true if already finished.
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
        // On grace expiry, still collect bytes already buffered in the pipes.
        let result = ProcessResult(exit: exit, stdout: stdout.close(), stderr: stderr.close())
        continuation?.resume(returning: result)
        return true
    }

    /// Abnormal completion such as cancellation/launch failure closes readers and resumes the caller immediately.
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

    // MARK: Termination requests

    private func terminateProcess() {
        state.withLock { $0.process?.terminate() }
        Task {
            try? await Task.sleep(for: Self.killDelay)
            // After exit, the PID may already belong to another process; never signal it again.
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
        // Prevent descriptor leakage into concurrent child launches, which would delay EOF until those children exit.
        for descriptor in descriptors {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                made.closeBoth()
                return nil
            }
        }
        // Use nonblocking reads and stop at EAGAIN between read events.
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

/// Drain one pipe reader through EOF. Foundation FileHandle can close readers with unread bytes
/// when Process is released, so own the descriptor lifetime directly.
private final class PipeDrain: Sendable {
    private struct State {
        var data = Data()
        // After EOF/closure, never read again: descriptor numbers can be reused for unrelated files.
        var readClosed = false
    }

    private let descriptor: Int32
    private let queue = DispatchQueue(label: "agent-float.pipe-drain")
    private let source: any DispatchSourceRead
    private let state = Mutex(State())

    /// Call onEnd exactly once on EOF.
    init(readDescriptor: Int32, onEnd: @escaping @Sendable () -> Void) {
        descriptor = readDescriptor
        source = DispatchSource.makeReadSource(fileDescriptor: readDescriptor, queue: queue)
        source.setEventHandler { [self] in
            guard drainAvailable() else { return }
            source.cancel()
            // Dispatch completion off this queue to avoid deadlock when finalization synchronously enters it.
            DispatchQueue.global().async(execute: onEnd)
        }
        // Close only in the cancellation handler; event handlers may still be using the descriptor before then.
        source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
        source.resume()
    }

    /// Drain buffered bytes and stop reading; safe to call repeatedly.
    func close() -> Data {
        queue.sync {
            _ = drainAvailable()
            state.withLock { $0.readClosed = true }
            source.cancel()
        }
        return state.withLock { $0.data }
    }

    /// Drain currently available data; return true once no future reads are possible.
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
            // EAGAIN means temporarily empty; EOF or other errors end reading permanently.
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return false }
            state.withLock { $0.readClosed = true }
            return true
        }
    }
}
