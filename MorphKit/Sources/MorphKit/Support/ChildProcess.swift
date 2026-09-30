import Foundation
import Synchronization

/// Result of a finished child process.
public struct ProcessOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}

public struct ProcessFailure: Error, LocalizedError, Sendable {
    public let status: Int32
    public let log: String

    public var errorDescription: String? {
        let lastLine = log.split(separator: "\n").last.map(String.init) ?? ""
        return lastLine.isEmpty ? "The converter exited with status \(status)." : lastLine
    }
}

/// Reads a pipe on a background queue. Either collects everything (bounded to `maxBytes`,
/// keeping the tail) or splits the stream into lines for a callback. Never blocks the
/// cooperative thread pool.
final class PipeReader: @unchecked Sendable {
    private struct State {
        var data = Data()
        var pendingLine = Data()
        var finished = false
        var waiters: [CheckedContinuation<Data, Never>] = []
    }

    private let handle: FileHandle
    private let maxBytes: Int
    private let onLine: (@Sendable (String) -> Void)?
    private let state = Mutex(State())

    init(handle: FileHandle, maxBytes: Int = 4 << 20, onLine: (@Sendable (String) -> Void)? = nil) {
        self.handle = handle
        self.maxBytes = maxBytes
        self.onLine = onLine
        handle.readabilityHandler = { [weak self] fileHandle in
            let chunk = fileHandle.availableData
            self?.consume(chunk)
        }
    }

    private func consume(_ chunk: Data) {
        if chunk.isEmpty {
            handle.readabilityHandler = nil
            let (lastLine, waiters, data): (String?, [CheckedContinuation<Data, Never>], Data) = state.withLock { s in
                s.finished = true
                let line = s.pendingLine.isEmpty ? nil : String(decoding: s.pendingLine, as: UTF8.self)
                s.pendingLine.removeAll()
                let w = s.waiters
                s.waiters.removeAll()
                return (line, w, s.data)
            }
            if let lastLine { onLine?(lastLine) }
            for waiter in waiters { waiter.resume(returning: data) }
            return
        }

        var lines: [String] = []
        state.withLock { s in
            s.data.append(chunk)
            if s.data.count > maxBytes {
                s.data.removeFirst(s.data.count - maxBytes)
            }
            guard onLine != nil else { return }
            s.pendingLine.append(chunk)
            while let newline = s.pendingLine.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = s.pendingLine[s.pendingLine.startIndex..<newline]
                lines.append(String(decoding: lineData, as: UTF8.self))
                s.pendingLine.removeSubrange(s.pendingLine.startIndex...newline)
            }
        }
        if let onLine {
            for line in lines { onLine(line) }
        }
    }

    /// Waits for end-of-file and returns the collected (tail of the) data.
    func collected() async -> Data {
        await withCheckedContinuation { continuation in
            let finishedData: Data? = state.withLock { s in
                if s.finished { return s.data }
                s.waiters.append(continuation)
                return nil
            }
            if let finishedData { continuation.resume(returning: finishedData) }
        }
    }
}

/// A child process with async exit, cancellation (SIGINT then SIGTERM) and pipe draining.
public final class ChildProcess: @unchecked Sendable {
    private struct ExitState {
        var status: Int32?
        var waiters: [CheckedContinuation<Int32, Never>] = []
    }

    private let process = Process()
    private let exitState = Mutex(ExitState())
    private let stdoutReader: PipeReader
    private let stderrReader: PipeReader

    /// - Parameters:
    ///   - onStdoutLine: when set, stdout is delivered line by line (e.g. `-progress pipe:1`).
    public init(executable: URL, arguments: [String], environment: [String: String]? = nil,
                currentDirectory: URL? = nil, onStdoutLine: (@Sendable (String) -> Void)? = nil) {
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.currentDirectoryURL = currentDirectory ?? FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        stdoutReader = PipeReader(handle: out.fileHandleForReading, maxBytes: 64 << 20, onLine: onStdoutLine)
        stderrReader = PipeReader(handle: err.fileHandleForReading, maxBytes: 256 << 10)
        process.terminationHandler = { [weak self] finished in
            self?.didExit(finished.terminationStatus)
        }
    }

    private func didExit(_ status: Int32) {
        let waiters = exitState.withLock { s in
            s.status = status
            let w = s.waiters
            s.waiters.removeAll()
            return w
        }
        for waiter in waiters { waiter.resume(returning: status) }
    }

    public func start() throws {
        try process.run()
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    /// Waits until the process exited *and* both pipes reached end-of-file.
    public func waitForExit() async -> ProcessOutput {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let status: Int32? = exitState.withLock { s in
                if let status = s.status { return status }
                s.waiters.append(continuation)
                return nil
            }
            if let status { continuation.resume(returning: status) }
        }
        async let out = stdoutReader.collected()
        async let err = stderrReader.collected()
        return await ProcessOutput(status: status, stdout: out, stderr: err)
    }

    /// Asks the process to stop (SIGINT, like pressing Ctrl-C), then kills it after `grace` seconds.
    public func cancel(grace: TimeInterval = 2) {
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) { [process] in
            if process.isRunning { process.terminate() }
        }
    }

    /// Runs a process to completion, cancelling it if the calling task is cancelled.
    public static func run(_ executable: URL, arguments: [String], environment: [String: String]? = nil,
                           onStdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessOutput {
        let child = ChildProcess(executable: executable, arguments: arguments, environment: environment,
                                 onStdoutLine: onStdoutLine)
        try child.start()
        return await withTaskCancellationHandler {
            await child.waitForExit()
        } onCancel: {
            child.cancel()
        }
    }
}
