#if canImport(Darwin)
import Darwin
import Foundation

/// A child process that cannot stall its caller. Both pipes are drained while it runs, each up to a byte cap, and reading
/// ends when it exits rather than at pipe EOF, because a grandchild can inherit the pipes and hold them open indefinitely.
public final class ChildProcess: @unchecked Sendable {
    public struct Output: Sendable {
        /// The termination status, or nil while the child is running.
        public var status: Int32?
        /// Reading lines consumes stdout.
        public var stdout = Data(), stderr = Data()
        /// Stdout outgrew its cap and the rest was discarded.
        public var truncated = false
    }

    /// Between SIGTERM and SIGKILL.
    public static let grace: TimeInterval = 2
    public static let stderrLimit = 64 * 1024

    private enum Condition { case line, exit }

    private let process = Process()
    private let stdoutLimit: Int
    /// Default QoS, like the child: a lower one lets a busy machine starve the drain into a timeout.
    private let queue = DispatchQueue(label: "app.agenthud.child-process")
    private var streams: [(source: DispatchSourceRead, isStdout: Bool)] = []
    // Confined to `queue` after init.
    private var input: FileHandle?
    private var collected = Output()
    private var lineStart = 0
    private var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    private var waiter: (id: Int, condition: Condition, continuation: CheckedContinuation<Void, Never>)?
    private var waits = 0, cancelledWait = 0, stopping = false

    public var output: Output { queue.sync { collected } }

    /// Launches the child. With `input` its stdin is a pipe for `write`, otherwise /dev/null.
    public init(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil, directory: URL? = nil,
                input: Bool = false, stdoutLimit: Int) throws {
        self.stdoutLimit = stdoutLimit
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        let stdin = input ? Pipe() : nil, stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin ?? FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        if let stdin {
            // A write after the child is gone fails with EPIPE instead of raising SIGPIPE in this process.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            self.input = stdin.fileHandleForWriting
        }
        for (pipe, isStdout) in [(stdout, true), (stderr, false)] {
            let handle = pipe.fileHandleForReading, fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in if read(fd, isStdout: isStdout) == 0 { source.cancel() } }
            source.setCancelHandler { try? handle.close() }
            source.resume()
            streams.append((source, isStdout))
        }
        process.terminationHandler = { [self] _ in queue.async { self.exited() } }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            streams.forEach { $0.source.cancel() }
            throw error
        }
    }

    /// Runs a child without stdin until it exits; at the deadline it is stopped and the output has no status.
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                           timeout: TimeInterval, stdoutLimit: Int) async throws -> Output {
        try Task.checkCancellation()
        let child = try ChildProcess(executable, arguments, environment: environment, stdoutLimit: stdoutLimit)
        defer { child.stop() }
        try await child.waitForExit(before: Date().addingTimeInterval(timeout))
        return child.output
    }

    /// Writes to stdin. Requests are small, so a child that does not read cannot block the drain.
    public func write(_ data: Data) throws {
        try queue.sync {
            guard let input else { throw POSIXError(.EPIPE) }
            try input.write(contentsOf: data)
        }
    }

    /// The next complete stdout line; nil at the deadline, or once the child has exited, or stdout outgrew its cap, and no
    /// complete line is left.
    public func line(before deadline: Date) async throws -> String? {
        try await wait(until: deadline, for: .line)
        return queue.sync {
            guard let newline = collected.stdout[lineStart...].firstIndex(of: 0x0A) else { return nil }
            let line = String(decoding: collected.stdout[lineStart..<newline], as: UTF8.self)
            lineStart = newline + 1
            // Returned lines are dropped once they fill half the buffer, so a long exchange does not run into the cap.
            if lineStart * 2 >= collected.stdout.count { collected.stdout = Data(collected.stdout[lineStart...]); lineStart = 0 }
            return line
        }
    }

    /// Waits until the child exits or the deadline passes; `output.status` tells which.
    public func waitForExit(before deadline: Date) async throws {
        try await wait(until: deadline, for: .exit)
    }

    /// Closes stdin and sends SIGTERM, then SIGKILL if the child outlives the grace period. Returns immediately.
    public func stop() {
        queue.async { [self] in
            try? input?.close()
            input = nil
            guard collected.status == nil, !stopping else { return }
            stopping = true
            if process.isRunning { process.terminate() }
            queue.asyncAfter(deadline: .now() + Self.grace) { [weak self] in
                guard let self, collected.status == nil, process.isRunning else { return }
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    /// Cancellation stops the child and throws.
    private func wait(until deadline: Date, for condition: Condition) async throws {
        let id = queue.sync { waits += 1; return waits }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    waiter = (id, condition, continuation)
                    let delay = min(max(deadline.timeIntervalSinceNow, 0), 86_400)
                    queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.wake(expired: id) }
                    wake()
                }
            }
        } onCancel: {
            queue.async { [self] in
                cancelledWait = id
                wake()
            }
            stop()
        }
        try Task.checkCancellation()
    }

    /// Resumes the waiter when its condition holds, its deadline passed (`expired`) or it was cancelled, even before it was registered.
    /// A line waiter also wakes once stdout outgrew its cap: the lines after the bytes it lost cannot be trusted.
    private func wake(expired id: Int? = nil) {
        guard let current = waiter else { return }
        let ready = collected.status != nil
            || current.condition == .line && (collected.truncated || collected.stdout[lineStart...].contains(0x0A))
        guard ready || current.id == id || current.id == cancelledWait else { return }
        waiter = nil
        current.continuation.resume()
    }

    /// Reads one chunk, leaving the queue free between chunks. Returns 0 at EOF or on failure, -1 when nothing is ready.
    private func read(_ fd: Int32, isStdout: Bool) -> Int {
        let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count > 0 else { return count < 0 && (errno == EAGAIN || errno == EINTR) ? -1 : 0 }
        let held = isStdout ? collected.stdout.count : collected.stderr.count
        let kept = min(count, max(0, (isStdout ? stdoutLimit : Self.stderrLimit) - held))
        chunk.withUnsafeBufferPointer { bytes in
            guard let base = bytes.baseAddress, kept > 0 else { return }
            if isStdout { collected.stdout.append(base, count: kept) } else { collected.stderr.append(base, count: kept) }
        }
        if isStdout, kept < count { collected.truncated = true }
        wake()
        return count
    }

    private func exited() {
        process.terminationHandler = nil
        for stream in streams where !stream.source.isCancelled {
            // What the child left fits in the pipe buffer; a grandchild still writing is not waited for.
            var reads = 0
            while reads < 16, read(Int32(stream.source.handle), isStdout: stream.isStdout) > 0 { reads += 1 }
            stream.source.cancel()
        }
        collected.status = process.terminationStatus
        try? input?.close()
        input = nil
        wake()
    }
}
#else
import Foundation
import ucrt
import WinSDK

/// The Windows side of the same child. Dispatch cannot watch pipe file descriptors here, so each pipe gets a thread
/// that asks the pipe what it holds before reading; reading ends when the child exits and the pipes ran dry.
public final class ChildProcess: @unchecked Sendable {
    public struct Output: Sendable {
        public var status: Int32?
        public var stdout = Data(), stderr = Data()
        public var truncated = false
    }

    public static let grace: TimeInterval = 2
    public static let stderrLimit = 64 * 1024

    private enum Condition { case line, exit }

    private let process = Process()
    private let stdoutLimit: Int
    private let queue = DispatchQueue(label: "app.agenthud.child-process")
    /// Whether the child has exited, so a drain thread can stop; set from `queue`, polled from the drain threads.
    private let exitedBox = Locked(false)
    // Confined to `queue` after init.
    private var input: FileHandle?
    private var collected = Output()
    private var lineStart = 0
    private var waiter: (id: Int, condition: Condition, continuation: CheckedContinuation<Void, Never>)?
    private var waits = 0, cancelledWait = 0, stopping = false

    public var output: Output { queue.sync { collected } }

    public init(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil, directory: URL? = nil,
                input: Bool = false, stdoutLimit: Int) throws {
        self.stdoutLimit = stdoutLimit
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        let stdin = input ? Pipe() : nil, stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin ?? FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        if let stdin { self.input = stdin.fileHandleForWriting }
        process.terminationHandler = { [self] _ in
            queue.async {
                exitedBox.set()
                self.exited()
            }
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw error
        }
        for (pipe, isStdout) in [(stdout, true), (stderr, false)] {
            let handle = pipe.fileHandleForReading, fd = handle.fileDescriptor
            let thread = Thread { [weak self] in self?.drain(fd: fd, pipe: ucrt._get_osfhandle(fd), isStdout: isStdout) }
            thread.stackSize = 128 * 1024
            thread.start()
        }
    }

    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                           timeout: TimeInterval, stdoutLimit: Int) async throws -> Output {
        try Task.checkCancellation()
        let child = try ChildProcess(executable, arguments, environment: environment, stdoutLimit: stdoutLimit)
        defer { child.stop() }
        try await child.waitForExit(before: Date().addingTimeInterval(timeout))
        return child.output
    }

    public func write(_ data: Data) throws {
        try queue.sync {
            guard let input else { throw POSIXError(.EPIPE) }
            try input.write(contentsOf: data)
        }
    }

    public func line(before deadline: Date) async throws -> String? {
        try await wait(until: deadline, for: .line)
        return queue.sync {
            guard let newline = collected.stdout[lineStart...].firstIndex(of: 0x0A) else { return nil }
            let line = String(decoding: collected.stdout[lineStart..<newline], as: UTF8.self)
            lineStart = newline + 1
            if lineStart * 2 >= collected.stdout.count { collected.stdout = Data(collected.stdout[lineStart...]); lineStart = 0 }
            return line
        }
    }

    public func waitForExit(before deadline: Date) async throws {
        try await wait(until: deadline, for: .exit)
    }

    /// Closes stdin and asks the child to stop, then terminates it outright if it outlives the grace period.
    public func stop() {
        queue.async { [self] in
            try? input?.close()
            input = nil
            guard collected.status == nil, !stopping else { return }
            stopping = true
            if process.isRunning { process.terminate() }
            queue.asyncAfter(deadline: .now() + Self.grace) { [weak self] in
                guard let self, collected.status == nil, process.isRunning else { return }
                let process = OpenProcess(PROCESS_TERMINATE, 0, DWORD(process.processIdentifier))
                if let process {
                    TerminateProcess(process, 1)
                    CloseHandle(process)
                }
            }
        }
    }

    private func wait(until deadline: Date, for condition: Condition) async throws {
        let id = queue.sync { waits += 1; return waits }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    waiter = (id, condition, continuation)
                    let delay = min(max(deadline.timeIntervalSinceNow, 0), 86_400)
                    queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.wake(expired: id) }
                    wake()
                }
            }
        } onCancel: {
            queue.async { [self] in
                cancelledWait = id
                wake()
            }
            stop()
        }
        try Task.checkCancellation()
    }

    private func wake(expired id: Int? = nil) {
        guard let current = waiter else { return }
        let ready = collected.status != nil
            || current.condition == .line && (collected.truncated || collected.stdout[lineStart...].contains(0x0A))
        guard ready || current.id == id || current.id == cancelledWait else { return }
        waiter = nil
        current.continuation.resume()
    }

    /// Runs on the pipe's own thread: reads what the pipe holds, and stops once the child is gone and the pipe ran dry.
    /// A grandchild that inherited the pipe can keep it open past the child's exit, so EOF alone is not the end.
    private func drain(fd: Int32, pipe: Int, isStdout: Bool) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var available: DWORD = 0
            let peek = pipe != INVALID_HANDLE_VALUE
                && PeekNamedPipe(HANDLE(bitPattern: Int(pipe)), nil, 0, nil, &available, nil)
            guard peek else { break }
            if available == 0 {
                if exitedBox.get() { break }
                Sleep(10)
                continue
            }
            // The pipe says what it holds, so this read returns without waiting for more.
            let asked = Int32(min(Int(available), buffer.count))
            let count = buffer.withUnsafeMutableBytes { ucrt._read(fd, $0.baseAddress?.assumingMemoryBound(to: CChar.self), asked) }
            guard count > 0 else { break }
            let chunk = Data(buffer[..<count])
            queue.sync { absorb(chunk, isStdout: isStdout) }
        }
    }

    /// Adds one read to the output under the caps. Confined to `queue`.
    private func absorb(_ data: Data, isStdout: Bool) {
        let held = isStdout ? collected.stdout.count : collected.stderr.count
        let kept = min(data.count, max(0, (isStdout ? stdoutLimit : Self.stderrLimit) - held))
        if kept > 0 {
            if isStdout { collected.stdout.append(data.prefix(kept)) } else { collected.stderr.append(data.prefix(kept)) }
        }
        if isStdout, kept < data.count { collected.truncated = true }
        wake()
    }

    private func exited() {
        process.terminationHandler = nil
        collected.status = process.terminationStatus
        try? input?.close()
        input = nil
        wake()
    }
}

/// A set-once flag the drain threads poll.
private final class Locked: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func get() -> Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
#endif
