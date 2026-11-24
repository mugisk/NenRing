import Foundation

/// A macOS build and SSD firmware on which an imported asptool log matched the
/// Direct FTL reads of this Mac. It is a local display record only: it does not
/// enable collection, change the reviewed builds or feed the forecast.
struct ASPToolVerifiedEnvironment: Codable, Equatable, Sendable, Identifiable {
    let sourceBuild: String
    let firmware: String
    let macOSVersion: String?
    let logCapturedAt: Date
    let recordedAt: Date

    /// One record per macOS major version and firmware lineage, e.g.
    /// "macOS 27|591". Builds and point releases within them share a record.
    var id: String { Self.key(build: sourceBuild, firmware: firmware) }

    static func key(build: String, firmware: String) -> String {
        (UpdateLineage.build(build) ?? build) + "|" + (UpdateLineage.firmware(firmware) ?? firmware)
    }

    /// e.g. "macOS 27.2（26B123）・ファームウェア 591.40.3・ログ 2026/11/07 23:15"
    var summary: String {
        let os = macOSVersion.map { "macOS \($0)（\(sourceBuild)）" } ?? "macOS build \(sourceBuild)"
        return "\(os)・ファームウェア \(firmware)・ログ \(UIString.dateTime(logCapturedAt))"
    }

    /// A pass records or refreshes the environment, a failure removes it, and
    /// an inconclusive comparison leaves the records as they are. Only a log
    /// whose own sysdiagnose names the same macOS major version and firmware
    /// lineage counts: matching numbers alone do not show where a log came from.
    static func applying(_ verdict: ASPToolLogVerdict?, to records: [Self],
                         macOSVersion: String?, now: Date) -> [Self] {
        guard let verdict, verdict.sourceCheck == .confirmed,
              let build = verdict.sourceBuild, let firmware = verdict.firmware else { return records }
        let key = key(build: build, firmware: firmware)
        switch verdict.outcome {
        case .inconclusive:
            return records
        case .failed:
            return records.filter { $0.id != key }
        case .passed:
            if let existing = records.first(where: { $0.id == key }),
               existing.logCapturedAt >= verdict.logCapturedAt {
                return records
            }
            let record = Self(sourceBuild: build, firmware: firmware, macOSVersion: macOSVersion,
                              logCapturedAt: verdict.logCapturedAt, recordedAt: now)
            return (records.filter { $0.id != key } + [record]).sorted { $0.recordedAt < $1.recordedAt }
        }
    }

    /// Records saved per exact build and firmware collapse to the newest log
    /// for each macOS major version and firmware lineage.
    static func deduplicated(_ records: [Self]) -> [Self] {
        var newest: [String: Self] = [:]
        for record in records {
            if let existing = newest[record.id], existing.logCapturedAt >= record.logCapturedAt { continue }
            newest[record.id] = record
        }
        return newest.values.sorted { $0.recordedAt < $1.recordedAt }
    }
}

/// Where an imported asptool log came from, read from the files sysdiagnose
/// writes next to it. `asptool_snapshot.log` itself names no build, firmware
/// or capture time.
struct ASPToolLogSourceIdentity: Codable, Equatable, Sendable {
    /// The log's modification time as recorded inside the archive: when
    /// asptool wrote it. Copying or moving the archive does not change it.
    let logWrittenAt: Date
    /// From `sw_vers.txt`.
    let macOSBuild: String?
    let macOSVersion: String?
    /// From `SystemProfiler/SPNVMeDataType.spx`, the one internal Apple SSD.
    let ssdModel: String?
    let ssdFirmware: String?

    /// True when this identity describes `log` (same written time).
    func describes(_ log: ASPToolDiagnosticsSnapshot) -> Bool {
        abs(log.capturedAt.timeIntervalSince(logWrittenAt)) < 1
    }

    static func macOS(fromSwVers text: String) -> (build: String?, version: String?) {
        func value(_ key: String) -> String? {
            text.split(whereSeparator: \.isNewline).lazy.compactMap { line -> String? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { return nil }
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }.first
        }
        return (value("BuildVersion"), value("ProductVersion"))
    }

    /// The model and firmware of the single internal Apple SSD; nil when
    /// there is none or more than one, so the drive is never guessed.
    static func appleSSD(fromSystemProfiler data: Data) -> (model: String, firmware: String)? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        var found: Set<[String]> = []
        func walk(_ node: Any) {
            if let dictionary = node as? [String: Any] {
                if let model = (dictionary["device_model"] as? String)?.trimmingCharacters(in: .whitespaces),
                   let firmware = (dictionary["device_revision"] as? String)?.trimmingCharacters(in: .whitespaces),
                   model.hasPrefix("APPLE SSD"), !firmware.isEmpty {
                    found.insert([model, firmware])
                }
                dictionary.values.forEach(walk)
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(root)
        guard found.count == 1, let only = found.first else { return nil }
        return (only[0], only[1])
    }
}

/// Finds an `asptool_snapshot.log` in a sysdiagnose the user created. NenRing
/// never runs sysdiagnose or asptool itself; it only reads the result.
enum SysdiagnoseASPToolLocator {
    static let defaultDirectory = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
    static let logRelativePath = "ASPSnapshots/asptool_snapshot.log"
    static let swVersRelativePath = "sw_vers.txt"
    static let nvmeProfileRelativePath = "SystemProfiler/SPNVMeDataType.spx"
    private static let logSuffix = "-asptool_snapshot.log"
    private static let identitySuffix = "-asptool_source.json"
    /// sw_vers.txt and the NVMe profile are a few KB; anything far larger is
    /// not what sysdiagnose writes.
    private static let maximumIdentityFileBytes = 4 * 1_024 * 1_024

    enum LocatorError: LocalizedError, Equatable {
        case logNotFound
        case extractionFailed(Int32)
        case timedOut
        case cancelled
        case logTooLarge

        var errorDescription: String? {
            switch self {
            case .logNotFound:
                return "sysdiagnoseにasptool_snapshot.logが見つかりません"
            case let .extractionFailed(status):
                return "sysdiagnoseからasptool_snapshot.logを取り出せませんでした（終了コード\(status)）"
            case .timedOut:
                return "sysdiagnoseの展開がタイムアウトしました"
            case .cancelled:
                return "sysdiagnoseの取り込みを中止しました"
            case .logTooLarge:
                return "asptool_snapshot.logが大きすぎます（上限512 MiB）"
            }
        }
    }

    /// Lets another thread stop a running extraction.
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        init() {}

        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    static let extractionTimeout: TimeInterval = 180

    static func isArchive(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix(".tar.gz") || url.pathExtension == "tgz"
    }

    /// True while sysdiagnose is still writing into `directory`.
    static func isInProgress(in directory: URL = defaultDirectory) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains { $0.hasPrefix("IN_PROGRESS_sysdiagnose") }
    }

    /// The newest finished sysdiagnose archive, optionally no older than `notBefore`.
    static func latestArchive(in directory: URL = defaultDirectory, notBefore: Date? = nil) -> URL? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { $0.lastPathComponent.hasPrefix("sysdiagnose_") && isArchive($0) }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                      let modified = values.contentModificationDate else { return nil }
                if let notBefore, modified < notBefore { return nil }
                return (url, modified)
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// An expanded sysdiagnose folder, or the ASPSnapshots folder itself.
    static func logInDirectory(_ directory: URL) -> URL? {
        let candidates = [
            directory.appendingPathComponent(logRelativePath),
            directory.appendingPathComponent("asptool_snapshot.log")
        ]
        return candidates.first(where: isRegularFile)
    }

    /// Copies only `asptool_snapshot.log` out of `archive` into `destination`
    /// and returns the copied file. The archive itself is not changed.
    ///
    /// tar is stopped when it runs past `timeout`, when `cancellation` is
    /// cancelled, or when the extracted files exceed `maximumLogBytes`. The
    /// staging folder is removed in every case.
    static func extractLog(from archive: URL, into destination: URL,
                           fileManager: FileManager = .default,
                           tarExecutable: URL = URL(fileURLWithPath: "/usr/bin/tar"),
                           timeout: TimeInterval = extractionTimeout,
                           maximumLogBytes: Int = ASPToolSnapshotParser.maximumFileBytes,
                           cancellation: Cancellation? = nil) throws -> URL {
        if cancellation?.isCancelled == true { throw LocatorError.cancelled }
        let staging = destination.appendingPathComponent(".extract-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        // bsdtar refuses absolute paths and ".." unless -P is given.
        // -q stops once each pattern has matched.
        let arguments = ["-xzf", archive.path, "-C", staging.path, "-q",
                         "--include", "*/" + logRelativePath,
                         "--include", "*/" + swVersRelativePath,
                         "--include", "*/" + nvmeProfileRelativePath]
        let runner = BoundedProcessRunner(timeout: timeout,
                                          maximumStdoutBytes: 64 * 1_024,
                                          maximumStderrBytes: 64 * 1_024)
        let result: BoundedProcessResult
        do {
            result = try runner.run(executable: tarExecutable, arguments: arguments) {
                if cancellation?.isCancelled == true { return LocatorError.cancelled }
                if allocatedBytes(in: staging, fileManager: fileManager) > maximumLogBytes {
                    return LocatorError.logTooLarge
                }
                return nil
            }
        } catch BoundedProcessError.timedOut {
            throw LocatorError.timedOut
        }
        guard result.terminationStatus == 0 || onlyMissedPatterns(result.stderr) else {
            throw LocatorError.extractionFailed(result.terminationStatus)
        }
        // tar may finish between two size checks.
        guard allocatedBytes(in: staging, fileManager: fileManager) <= maximumLogBytes else {
            throw LocatorError.logTooLarge
        }

        let roots = (try? fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        guard let (root, extracted) = roots.lazy.compactMap({ root in logInDirectory(root).map { (root, $0) } }).first else {
            throw LocatorError.logNotFound
        }
        let stem = archive.lastPathComponent
            .replacingOccurrences(of: ".tar.gz", with: "")
            .replacingOccurrences(of: ".tgz", with: "")
        let target = destination.appendingPathComponent(stem + logSuffix)
        let identityURL = destination.appendingPathComponent(stem + identitySuffix)
        for url in [target, identityURL] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        // bsdtar restores the modification time stored in the archive.
        let writtenAt = try extracted.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try fileManager.moveItem(at: extracted, to: target)
        if let writtenAt {
            let identity = sourceIdentity(in: root, logWrittenAt: writtenAt)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(identity).write(to: identityURL, options: .atomic)
        }
        return target
    }

    /// bsdtar exits with 1 when an `--include` pattern matched nothing, even
    /// though it extracted the others. That alone is not a failure: a missing
    /// log is reported as `logNotFound` and missing identity files leave the
    /// source unconfirmed.
    private static func onlyMissedPatterns(_ stderr: Data) -> Bool {
        let lines = String(decoding: stderr, as: UTF8.self).split(whereSeparator: \.isNewline)
        return !lines.isEmpty && lines.allSatisfy {
            $0.hasSuffix(": Not found in archive") || $0 == "tar: Error exit delayed from previous errors."
        }
    }

    /// The identity saved next to a log copied out of an archive, if any.
    /// A log read on its own has none.
    static func sourceIdentity(forLog log: URL?) -> ASPToolLogSourceIdentity? {
        guard let log, log.lastPathComponent.hasSuffix(logSuffix) else { return nil }
        let name = String(log.lastPathComponent.dropLast(logSuffix.count)) + identitySuffix
        guard let data = try? Data(contentsOf: log.deletingLastPathComponent().appendingPathComponent(name)) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ASPToolLogSourceIdentity.self, from: data)
    }

    private static func sourceIdentity(in root: URL, logWrittenAt: Date) -> ASPToolLogSourceIdentity {
        func contents(_ relativePath: String) -> Data? {
            let url = root.appendingPathComponent(relativePath)
            guard isRegularFile(url),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= maximumIdentityFileBytes else { return nil }
            return try? Data(contentsOf: url)
        }
        let macOS = contents(swVersRelativePath)
            .flatMap { String(data: $0, encoding: .utf8) }
            .map(ASPToolLogSourceIdentity.macOS(fromSwVers:))
        let ssd = contents(nvmeProfileRelativePath).flatMap(ASPToolLogSourceIdentity.appleSSD(fromSystemProfiler:))
        return ASPToolLogSourceIdentity(logWrittenAt: logWrittenAt, macOSBuild: macOS?.build,
                                        macOSVersion: macOS?.version, ssdModel: ssd?.model, ssdFirmware: ssd?.firmware)
    }

    /// The total size of the regular files under `directory`.
    private static func allocatedBytes(in directory: URL, fileManager: FileManager) -> Int {
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += values.fileSize ?? 0
        }
        return total
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        // A symbolic link is not followed into another part of the disk.
        (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
            .map { $0.isRegularFile == true && $0.isSymbolicLink != true } ?? false
    }
}

/// Opens Terminal with a script that runs `sudo sysdiagnose`. The password or
/// Touch ID prompt appears in Terminal; NenRing never sees or stores it.
enum SysdiagnoseTerminalLauncher {
    static let terminalBundleIdentifier = "com.apple.Terminal"

    static func script(language: String) -> String {
        let japanese = language.lowercased().hasPrefix("ja")
        let intro = japanese
            ? "NenRing: asptool_snapshot.log を含む sysdiagnose を作成します。\nパスワード（設定によってはTouch ID）の入力と、Enterキーでの確認を求められます。\n完了まで数分かかります。完了するとFinderに出力ファイルが表示されます。"
            : "NenRing: creating a sysdiagnose, which contains asptool_snapshot.log.\nTerminal asks for your password (or Touch ID, if set up) and for Enter to confirm.\nIt takes a few minutes. Finder shows the output file when it is done."
        let done = japanese
            ? "完了しました。NenRingが /private/var/tmp の最新のsysdiagnoseからasptool_snapshot.logを読み込みます。このウインドウは閉じて構いません。"
            : "Done. NenRing reads asptool_snapshot.log from the newest sysdiagnose in /private/var/tmp. You can close this window."
        let failed = japanese
            ? "sysdiagnoseは完了しませんでした。"
            : "sysdiagnose did not finish."
        return """
        #!/bin/zsh
        clear
        print -r -- \(shellQuoted(intro))
        print
        if /usr/bin/sudo /usr/bin/sysdiagnose; then
          print
          print -r -- \(shellQuoted(done))
        else
          print
          print -r -- \(shellQuoted(failed))
        fi

        """
    }

    /// Writes the script into `directory` with owner-only permissions.
    static func writeScript(into directory: URL, language: String,
                            fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("NenRing-sysdiagnose.command")
        try Data(script(language: language).utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
