import Darwin
import Foundation

enum ASPToolOutputContract: Codable, Equatable, Sendable {
    case workingDirectory(snapshotFileName: String)
    case explicitDirectory(relativeSnapshotPath: String)
    case standardOutput(snapshotFileName: String)
}

struct ASPToolInvocation: Codable, Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryURL: URL
    let outputContract: ASPToolOutputContract
}

struct ASPToolCommandProfile: Codable, Equatable, Sendable {
    let identifier: String
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let outputContract: ASPToolOutputContract

    init(
        identifier: String = "working-directory-v1",
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        outputContract: ASPToolOutputContract = .workingDirectory(
            snapshotFileName: "asptool_snapshot.log"
        )
    ) {
        self.identifier = identifier
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.outputContract = outputContract
    }

    func invocation(workingDirectoryURL: URL) -> ASPToolInvocation {
        ASPToolInvocation(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            workingDirectoryURL: workingDirectoryURL,
            outputContract: outputContract
        )
    }
}

struct ASPToolExecutionPolicy: Sendable {
    let timeout: TimeInterval
    let terminationGracePeriod: TimeInterval
    let outputDrainTimeout: TimeInterval
    let diagnosticBufferLimitBytes: Int
    let retainFailedWorkspaces: Bool

    init(
        timeout: TimeInterval = 120,
        terminationGracePeriod: TimeInterval = 1,
        outputDrainTimeout: TimeInterval = 2,
        diagnosticBufferLimitBytes: Int = 64 * 1024,
        retainFailedWorkspaces: Bool = false
    ) {
        self.timeout = max(timeout, 0.1)
        self.terminationGracePeriod = max(terminationGracePeriod, 0.1)
        self.outputDrainTimeout = max(outputDrainTimeout, 0.1)
        self.diagnosticBufferLimitBytes = max(diagnosticBufferLimitBytes, 1)
        self.retainFailedWorkspaces = retainFailedWorkspaces
    }
}

struct ASPToolExecutionResult: Sendable {
    let startedAt: Date
    let finishedAt: Date
    let terminationStatus: Int32
    let stdoutTail: Data
    let stderrTail: Data
}

/// Failures of the bounded process runner that starts the bundled probe.
enum ASPToolGenerationError: LocalizedError, Equatable, Sendable {
    case processLaunchFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case let .processLaunchFailed(message):
            return "probeを起動できませんでした: \(message)"
        case .timedOut:
            return "probeの実行がタイムアウトしました"
        }
    }
}

/// Runs one asptool process and keeps only bounded stdout/stderr tails.
/// The executable is invoked directly; no shell and no sudo are involved.
struct ASPToolProcessRunner: Sendable {
    let policy: ASPToolExecutionPolicy

    func run(_ invocation: ASPToolInvocation) throws -> ASPToolExecutionResult {
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = invocation.workingDirectoryURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        let startedAt = Date()

        do {
            try process.run()
        } catch {
            throw ASPToolGenerationError.processLaunchFailed(error.localizedDescription)
        }

        let stdoutTail = ProcessPipeReader(
            handle: stdoutPipe.fileHandleForReading,
            maximumBytes: policy.diagnosticBufferLimitBytes
        )
        let stderrTail = ProcessPipeReader(
            handle: stderrPipe.fileHandleForReading,
            maximumBytes: policy.diagnosticBufferLimitBytes
        )
        stdoutTail.start()
        stderrTail.start()
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        guard termination.wait(timeout: .now() + policy.timeout) == .success else {
            stop(process, termination: termination)
            stdoutTail.cancel()
            stderrTail.cancel()
            _ = stdoutTail.wait(timeout: policy.terminationGracePeriod)
            _ = stderrTail.wait(timeout: policy.terminationGracePeriod)
            throw ASPToolGenerationError.timedOut
        }

        guard stdoutTail.wait(timeout: policy.outputDrainTimeout),
              stderrTail.wait(timeout: policy.outputDrainTimeout)
        else {
            stdoutTail.cancel()
            stderrTail.cancel()
            throw ASPToolGenerationError.timedOut
        }

        return ASPToolExecutionResult(
            startedAt: startedAt,
            finishedAt: Date(),
            terminationStatus: process.terminationStatus,
            stdoutTail: stdoutTail.data,
            stderrTail: stderrTail.data
        )
    }

    private func stop(_ process: Process, termination: DispatchSemaphore) {
        if process.isRunning {
            process.terminate()
        }
        if termination.wait(timeout: .now() + policy.terminationGracePeriod) == .success {
            return
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        _ = termination.wait(timeout: .now() + policy.terminationGracePeriod)
    }
}

