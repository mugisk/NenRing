import Darwin
import Foundation

struct BoundedProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let terminationStatus: Int32
}

enum BoundedProcessError: LocalizedError, Equatable, Sendable {
    case timedOut
    case outputLimitExceeded

    var errorDescription: String? {
        switch self {
        case .timedOut: return "外部コマンドの取得がタイムアウトしました"
        case .outputLimitExceeded: return "外部コマンドの出力が上限を超えました"
        }
    }
}

/// Runs a child process while continuously draining both output pipes.
///
/// Waiting for termination before reading a `Pipe` can deadlock once the child
/// fills the kernel pipe buffer. Each stream is therefore drained on its own
/// queue for the whole lifetime of the process. The timeout covers both child
/// termination and reaching EOF on the streams.
struct BoundedProcessRunner: Sendable {
    let timeout: TimeInterval
    let terminationGracePeriod: TimeInterval
    let outputDrainTimeout: TimeInterval
    let maximumStdoutBytes: Int
    let maximumStderrBytes: Int

    init(
        timeout: TimeInterval,
        terminationGracePeriod: TimeInterval = 0.5,
        outputDrainTimeout: TimeInterval = 2,
        maximumStdoutBytes: Int = 8 * 1_024 * 1_024,
        maximumStderrBytes: Int = 1 * 1_024 * 1_024
    ) {
        self.timeout = max(timeout, 0.01)
        self.terminationGracePeriod = max(terminationGracePeriod, 0.01)
        self.outputDrainTimeout = max(outputDrainTimeout, 0.01)
        self.maximumStdoutBytes = max(maximumStdoutBytes, 1)
        self.maximumStderrBytes = max(maximumStderrBytes, 1)
    }

    /// `shouldStop` is polled while the child runs; when it returns an error
    /// the child is terminated (then killed) and that error is thrown.
    func run(executable: URL, arguments: [String],
             shouldStop: (() -> Error?)? = nil) throws -> BoundedProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }

        try process.run()

        let stdoutDrainer = ProcessPipeReader(handle: stdoutPipe.fileHandleForReading,
                                              maximumBytes: maximumStdoutBytes, retainPrefix: true)
        let stderrDrainer = ProcessPipeReader(handle: stderrPipe.fileHandleForReading,
                                              maximumBytes: maximumStderrBytes, retainPrefix: true)
        stdoutDrainer.start()
        stderrDrainer.start()

        // The parent does not write to these pipes. Closing its copies ensures
        // the readers observe EOF even if Foundation retains the Pipe objects.
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        let deadline = DispatchTime.now() + timeout
        while termination.wait(timeout: .now() + 0.05) != .success {
            if let stopError = shouldStop?() {
                stop(process, termination: termination)
                stdoutDrainer.cancel()
                stderrDrainer.cancel()
                _ = stdoutDrainer.wait(timeout: terminationGracePeriod)
                _ = stderrDrainer.wait(timeout: terminationGracePeriod)
                throw stopError
            }
            if stdoutDrainer.didExceedLimit || stderrDrainer.didExceedLimit ||
                DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds {
                let exceeded = stdoutDrainer.didExceedLimit || stderrDrainer.didExceedLimit
                stop(process, termination: termination)
                stdoutDrainer.cancel()
                stderrDrainer.cancel()
                _ = stdoutDrainer.wait(timeout: terminationGracePeriod)
                _ = stderrDrainer.wait(timeout: terminationGracePeriod)
                throw exceeded ? BoundedProcessError.outputLimitExceeded : .timedOut
            }
        }

        let stdoutFinished = stdoutDrainer.wait(timeout: outputDrainTimeout)
        let stderrFinished = stderrDrainer.wait(timeout: outputDrainTimeout)
        if stdoutDrainer.didExceedLimit || stderrDrainer.didExceedLimit {
            stdoutDrainer.cancel()
            stderrDrainer.cancel()
            throw BoundedProcessError.outputLimitExceeded
        }
        guard stdoutFinished, stderrFinished else {
            stdoutDrainer.cancel()
            stderrDrainer.cancel()
            throw BoundedProcessError.timedOut
        }

        return BoundedProcessResult(
            stdout: stdoutDrainer.data,
            stderr: stderrDrainer.data,
            terminationStatus: process.terminationStatus
        )
    }

    private func stop(_ process: Process, termination: DispatchSemaphore) {
        if process.isRunning {
            process.terminate()
        }
        if termination.wait(timeout: .now() + terminationGracePeriod) == .success {
            return
        }

        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        _ = termination.wait(timeout: .now() + terminationGracePeriod)
    }
}

/// Reads one output pipe until EOF or until it is cancelled.
///
/// The reader alone closes the handle, after its loop has exited. Closing it
/// from another thread while a read is in progress let a later read hit the
/// closed descriptor and raise an Objective-C exception, which crashed the
/// app when a background child wrote after the runner had given up on EOF.
/// Reads therefore wait in `poll` with a short timeout and check the cancel
/// flag between waits.
final class ProcessPipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let maximumBytes: Int?
    private let retainPrefix: Bool
    private let completion = DispatchGroup()
    private let lock = NSLock()
    private var storage = Data()
    private var cancelled = false
    private var exceededLimit = false

    /// Keeps only the last `maximumBytes` when set.
    init(handle: FileHandle, maximumBytes: Int? = nil, retainPrefix: Bool = false) {
        self.handle = handle
        self.maximumBytes = maximumBytes
        self.retainPrefix = retainPrefix
    }

    func start() {
        completion.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                handle.closeFile()
                completion.leave()
            }
            let descriptor = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while !isCancelled {
                var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&request, 1, 100)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if ready == 0 { continue }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return
                }
                guard count > 0 else { return }
                append(buffer[0..<count])
            }
        }
    }

    private var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    private func append(_ chunk: ArraySlice<UInt8>) {
        lock.withLock {
            guard let maximumBytes else {
                storage.append(contentsOf: chunk)
                return
            }
            if chunk.count > maximumBytes - storage.count {
                exceededLimit = true
            }
            if retainPrefix {
                storage.append(contentsOf: chunk.prefix(maximumBytes - storage.count))
            } else {
                storage.append(contentsOf: chunk)
                if storage.count > maximumBytes {
                    storage = Data(storage.suffix(maximumBytes))
                }
            }
        }
    }

    var didExceedLimit: Bool { lock.withLock { exceededLimit } }

    func wait(timeout: TimeInterval) -> Bool {
        completion.wait(timeout: .now() + timeout) == .success
    }

    /// Asks the reader to stop; it closes the handle itself within about
    /// 100 ms.
    func cancel() {
        lock.withLock { cancelled = true }
    }

    var data: Data {
        lock.withLock { storage }
    }
}
