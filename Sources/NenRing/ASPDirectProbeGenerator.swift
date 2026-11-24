import Darwin
import Foundation

/// The fixed, reviewed probe entry points bundled with the app.
///
/// This is intentionally a closed list. The app never accepts an arbitrary
/// opcode or constructs a user-provided shell command for a private call.
enum ASPDirectProbeRequest: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case snapshotPayload = "snapshot-0x16"
    case snapshotHeader = "snapshot-0x91"
    case ftlAll = "ftl-all"
    case ftlPerm = "ftl-perm"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .snapshotPayload: return "snapshot 0x16"
        case .snapshotHeader: return "snapshot header 0x91"
        case .ftlAll: return "FTL all"
        case .ftlPerm: return "FTL perm"
        }
    }

    var detail: String {
        switch self {
        case .snapshotPayload:
            return "時系列snapshotのraw payload。レコード値は未解釈です。"
        case .snapshotHeader:
            return "snapshot headerのサイズ・offset境界を検証します。"
        case .ftlAll:
            return "FTL all。key/count/valueの確認済みParserで解析します。"
        case .ftlPerm:
            return "FTL perm。取得metadataとpayloadサイズのみを確認します。"
        }
    }

    var executableName: String {
        switch self {
        case .snapshotPayload, .snapshotHeader:
            return "asp-snapshot-probe"
        case .ftlAll, .ftlPerm:
            return "asp-ftl-stats-probe"
        }
    }

    func arguments(
        outputRootURL: URL,
        ownerUID: Int? = nil,
        ownerGID: Int? = nil,
        allowUnreviewedBuild: Bool = false,
        targetBinding: StorageTargetBinding? = nil
    ) -> [String] {
        let outputPath = outputRootURL.standardizedFileURL.path
        var arguments: [String]
        switch self {
        case .snapshotPayload:
            arguments = ["--opcode", "0x16", "--output-dir", outputPath]
        case .snapshotHeader:
            arguments = ["--opcode", "0x91", "--output-dir", outputPath]
        case .ftlAll:
            arguments = ["--kind", "all", "--output-dir", outputPath]
        case .ftlPerm:
            arguments = ["--kind", "perm", "--output-dir", outputPath]
        }

        // A root-launched FTL probe creates mode-0700 artifacts owned by
        // root. The manual fallback passes the original app user's IDs so
        // the probe can hand the completed run directory back for parsing.
        if self == .ftlAll, let ownerUID, let ownerGID {
            arguments += [
                "--owner-uid", String(ownerUID),
                "--owner-gid", String(ownerGID)
            ]
        }
        // The FTL and snapshot probes refuse macOS releases outside their
        // reviewed list unless the caller explicitly accepts an unverified read.
        if allowUnreviewedBuild {
            arguments.append("--allow-unreviewed-build")
        }
        if let targetBinding, self == .ftlAll || self == .ftlPerm {
            arguments += ["--smart-service-id", String(targetBinding.smartServiceID),
                          "--controller-id", String(targetBinding.controllerEntryID),
                          "--whole-media-id", String(targetBinding.wholeMediaID)]
        }
        return arguments
    }
}

enum ASPDirectProbePrivilege: Equatable, Sendable {
    case currentUser
    case administrator
}

struct ASPDirectProbeGenerationResult: Sendable {
    let request: ASPDirectProbeRequest
    let runDirectoryURL: URL
    let outputRootURL: URL
    let execution: ASPToolExecutionResult
    let privilege: ASPDirectProbePrivilege

    var metadataURL: URL {
        runDirectoryURL.appendingPathComponent("metadata.txt")
    }

    var exitStatus: Int32 { execution.terminationStatus }

    var processSucceeded: Bool { exitStatus == 0 }
}

enum ASPDirectProbeGenerationError: LocalizedError, Equatable, Sendable {
    case bundledProbeMissing(String)
    case probeSignatureInvalid(String)
    case outputRootUnavailable(String)
    case artifactDirectoryMissing(status: Int32, stderr: String?)
    case metadataMissing

    var errorDescription: String? {
        switch self {
        case let .bundledProbeMissing(name):
            return "アプリ内のASP probeが見つかりません: \(name)"
        case let .probeSignatureInvalid(message):
            return "ASP probeの実行を拒否しました: \(message)"
        case let .outputRootUnavailable(message):
            return "ASP probeの保存先を準備できませんでした: \(message)"
        case let .artifactDirectoryMissing(status, stderr):
            if let stderr, !stderr.isEmpty {
                return "SSD詳細統計の取得フォルダを作成できませんでした（終了コード\(status)）: \(stderr)"
            }
            return "SSD詳細統計の取得フォルダを作成できませんでした（終了コード\(status)）"
        case .metadataMissing:
            return "ASP probeのmetadata.txtが生成されませんでした"
        }
    }
}

/// Runs one fixed ASP probe from the app and returns its private run directory.
///
/// Snapshot and FTL probes first run directly as the current user. A manual
/// FTL `all` action may retry through the macOS administrator authorization
/// dialog when the probe reports the reviewed `resource shortage` privilege
/// failure. Background monitoring never enables that retry, so it cannot
/// repeatedly prompt while the user is away. (The former tunnel probes, which
/// always needed authorization and mostly returned kIOReturnDeviceError, have
/// been removed; their saved artifacts can still be inspected.) A non-zero probe exit
/// is not discarded when the probe managed to persist metadata: the caller
/// can still inspect the read failure and exact euid. The app never receives
/// or stores the administrator password.
struct ASPDirectProbeGenerator: Sendable {
    let policy: ASPToolExecutionPolicy
    let probeDirectoryURL: URL?
    let outputRootURL: URL?
    let signatureVerifier: ASPProbeSignatureVerifier

    init(
        policy: ASPToolExecutionPolicy = ASPToolExecutionPolicy(
            timeout: 30,
            terminationGracePeriod: 1,
            outputDrainTimeout: 2,
            diagnosticBufferLimitBytes: 64 * 1024,
            retainFailedWorkspaces: true
        ),
        probeDirectoryURL: URL? = nil,
        outputRootURL: URL? = nil,
        signatureVerifier: ASPProbeSignatureVerifier = ASPProbeSignatureVerifier()
    ) {
        self.policy = policy
        self.probeDirectoryURL = probeDirectoryURL
        self.outputRootURL = outputRootURL
        self.signatureVerifier = signatureVerifier
    }

    /// The administrator run's time limit also covers the password prompt,
    /// so it gets more time than the probe itself needs.
    private var administratorPolicy: ASPToolExecutionPolicy {
        ASPToolExecutionPolicy(
            timeout: max(policy.timeout, Self.administratorPromptTimeout),
            terminationGracePeriod: policy.terminationGracePeriod,
            outputDrainTimeout: policy.outputDrainTimeout,
            diagnosticBufferLimitBytes: policy.diagnosticBufferLimitBytes,
            retainFailedWorkspaces: policy.retainFailedWorkspaces
        )
    }

    static let administratorPromptTimeout: TimeInterval = 180

    func generate(
        request: ASPDirectProbeRequest,
        allowAdministratorFallback: Bool = false,
        allowUnreviewedBuild: Bool = false,
        targetBinding: StorageTargetBinding? = nil
    ) throws -> ASPDirectProbeGenerationResult {
        let executableURL = try executableURL(
            for: request,
            requiresAdministrator: false
        )
        let outputRoot = try prepareOutputRoot()
        let execution: ASPToolExecutionResult
        let privilege: ASPDirectProbePrivilege
        // Every request starts as the current user; only a manual FTL all
        // read may retry with administrator authentication.
        let profile = ASPToolCommandProfile(
            identifier: "asp-direct-probe-v1",
            executableURL: executableURL,
            arguments: request.arguments(outputRootURL: outputRoot, allowUnreviewedBuild: allowUnreviewedBuild, targetBinding: targetBinding),
            outputContract: .standardOutput(snapshotFileName: "probe-output")
        )
        let currentUserExecution = try ASPToolProcessRunner(policy: policy).run(
            profile.invocation(workingDirectoryURL: outputRoot)
        )
        if request == .ftlAll,
           allowAdministratorFallback,
           Self.shouldRetryWithAdministrator(currentUserExecution) {
            try verify(
                executableURL: executableURL,
                request: request,
                requiresAdministrator: true
            )
            execution = try ASPAdministratorProbeRunner(policy: administratorPolicy).run(
                executableURL: executableURL,
                arguments: request.arguments(
                    outputRootURL: outputRoot,
                    ownerUID: Int(getuid()),
                    ownerGID: Int(getgid()),
                    allowUnreviewedBuild: allowUnreviewedBuild,
                    targetBinding: targetBinding
                ),
                workingDirectoryURL: outputRoot
            )
            privilege = .administrator
        } else {
            execution = currentUserExecution
            privilege = .currentUser
        }

        guard let runDirectoryURL = artifactDirectory(
            from: execution.stdoutTail,
            outputRootURL: outputRoot
        ) else {
            throw ASPDirectProbeGenerationError.artifactDirectoryMissing(
                status: execution.terminationStatus,
                stderr: String(data: execution.stderrTail, encoding: .utf8)
            )
        }

        let metadataURL = runDirectoryURL.appendingPathComponent("metadata.txt")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw ASPDirectProbeGenerationError.metadataMissing
        }

        return ASPDirectProbeGenerationResult(
            request: request,
            runDirectoryURL: runDirectoryURL,
            outputRootURL: outputRoot,
            execution: execution,
            privilege: privilege
        )
    }

    static func shouldRetryWithAdministrator(_ execution: ASPToolExecutionResult) -> Bool {
        guard execution.terminationStatus != 0 else { return false }
        let diagnostic = [execution.stdoutTail, execution.stderrTail]
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
            .lowercased()
        return [
            "resource shortage",
            "not privileged",
            "permission denied",
            "e00002c1"
        ].contains { diagnostic.contains($0) }
    }

    /// Removes only one completed run directory produced under this
    /// generator's private output root. Failed or partially parsed runs are
    /// intentionally left in place so the user can inspect them manually.
    func cleanup(_ result: ASPDirectProbeGenerationResult) throws {
        let rootPath = result.outputRootURL.standardizedFileURL.path
        let runPath = result.runDirectoryURL.standardizedFileURL.path
        guard runPath.hasPrefix(rootPath + "/"), runPath != rootPath else {
            return
        }
        try FileManager.default.removeItem(atPath: runPath)
    }

    private func executableURL(
        for request: ASPDirectProbeRequest,
        requiresAdministrator: Bool
    ) throws -> URL {
        let directory = probeDirectoryURL
            ?? Bundle.main.url(forResource: "ASPProbes", withExtension: nil)
            ?? Bundle.main.resourceURL?.appendingPathComponent("ASPProbes", isDirectory: true)
        guard let directory else {
            throw ASPDirectProbeGenerationError.bundledProbeMissing(request.executableName)
        }

        let url = directory.appendingPathComponent(request.executableName)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ASPDirectProbeGenerationError.bundledProbeMissing(url.path)
        }
        try verify(
            executableURL: url,
            request: request,
            requiresAdministrator: requiresAdministrator
        )
        return url
    }

    private func verify(
        executableURL: URL,
        request: ASPDirectProbeRequest,
        requiresAdministrator: Bool
    ) throws {
        do {
            _ = try signatureVerifier.verify(
                executableURL: executableURL,
                expectedIdentifier: request.executableName,
                bundleURL: probeDirectoryURL == nil ? Bundle.main.bundleURL : nil,
                requiresAdministrator: requiresAdministrator
            )
        } catch let error as ASPProbeSignatureError {
            throw ASPDirectProbeGenerationError.probeSignatureInvalid(
                error.localizedDescription
            )
        }
    }

    private func prepareOutputRoot() throws -> URL {
        let root = outputRootURL ?? Self.defaultOutputRootURL()
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            guard chmod(root.path, mode_t(0o700)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return root.standardizedFileURL
        } catch {
            throw ASPDirectProbeGenerationError.outputRootUnavailable(error.localizedDescription)
        }
    }

    private func artifactDirectory(from output: Data, outputRootURL: URL) -> URL? {
        guard let text = String(data: output, encoding: .utf8) else { return nil }
        let rootPath = outputRootURL.standardizedFileURL.path
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let prefix = "artifact_dir="
            guard line.hasPrefix(prefix) else { continue }
            let rawPath = String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard rawPath.hasPrefix("/") else { return nil }
            let candidate = URL(fileURLWithPath: rawPath).standardizedFileURL
            let candidatePath = candidate.path
            guard candidatePath.hasPrefix(rootPath + "/"),
                  FileManager.default.fileExists(atPath: candidatePath) else {
                return nil
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidatePath, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return candidate
        }
        return nil
    }

    static func defaultOutputRootURL() -> URL {
        AppDataLocation.directoryURL
            .appendingPathComponent("ASPDirectProbes", isDirectory: true)
    }
}

/// Executes only a fixed, app-selected ASP probe through macOS's administrator
/// authorization dialog. The app never receives or stores the password and
/// never constructs a user-provided shell command. Every executable and
/// argument is quoted inside the fixed AppleScript wrapper before it reaches
/// `do shell script`.
/// Reads the probe's exit status from the administrator run's output.
/// `do shell script` returns line breaks as CR, so the marker is looked up
/// after normalising CR and CRLF to LF.
enum ASPAdministratorOutput {
    static let marker = "__NENRING_EXIT__"
    /// Reported when the marker is missing and osascript claimed success.
    static let missingStatus: Int32 = 125

    static func parse(_ raw: String) -> (status: Int32, output: String)? {
        let output = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard let markerRange = output.range(of: "\n" + marker, options: .backwards) else { return nil }
        let rest = output[markerRange.upperBound...]
        let statusText = rest.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
        guard let status = Int32(statusText) else { return nil }
        let probeOutput = String(output[..<markerRange.lowerBound]).trimmingCharacters(in: .newlines)
        return (status, probeOutput)
    }
}

private struct ASPAdministratorProbeRunner: Sendable {
    let policy: ASPToolExecutionPolicy

    func run(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL
    ) throws -> ASPToolExecutionResult {
        let osascriptURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let invocation = ASPToolInvocation(
            executableURL: osascriptURL,
            arguments: ["-e", Self.script, executableURL.path] + arguments,
            environment: ProcessInfo.processInfo.environment,
            workingDirectoryURL: workingDirectoryURL,
            outputContract: .standardOutput(snapshotFileName: "administrator-probe-output")
        )
        let raw = try ASPToolProcessRunner(policy: policy).run(invocation)
        return normalizedResult(raw)
    }

    private func normalizedResult(_ result: ASPToolExecutionResult) -> ASPToolExecutionResult {
        let parsed = String(data: result.stdoutTail, encoding: .utf8)
            .flatMap(ASPAdministratorOutput.parse)
        // Without the marker the probe's own status is unknown. osascript
        // itself exits 0 in that case, so report a failure instead.
        let status = parsed?.status
            ?? (result.terminationStatus == 0 ? ASPAdministratorOutput.missingStatus : result.terminationStatus)
        return ASPToolExecutionResult(
            startedAt: result.startedAt,
            finishedAt: result.finishedAt,
            terminationStatus: status,
            stdoutTail: parsed.map { Data($0.output.utf8) } ?? result.stdoutTail,
            stderrTail: result.stderrTail
        )
    }

    private static let script = #"""
    on run argv
        set commandLine to quoted form of (item 1 of argv)
        repeat with argumentIndex from 2 to count of argv
            set commandLine to commandLine & " " & quoted form of (item argumentIndex of argv)
        end repeat
        set shellOutput to do shell script "set +e; " & commandLine & " 2>&1; status=$?; printf '\n__NENRING_EXIT__%s\n' \"$status\"; exit 0" with administrator privileges
        return shellOutput
    end run
    """#
}
