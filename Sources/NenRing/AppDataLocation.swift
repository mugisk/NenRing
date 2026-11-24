import AppKit
import Foundation

/// Where NenRing keeps its local history and settings files.
///
/// Before the app was renamed, the folder was `SmartHealthMonitor` and the
/// bundle identifier was `local.smarthealthmonitor.app`. On launch the folder
/// is copied to `NenRing` once and the old preferences are copied into the
/// new domain. Neither the old folder nor the old preferences are modified or
/// deleted, so a failed or interrupted migration cannot lose measurements.
enum AppDataLocation {
    static let folderName = "NenRing"
    static let legacyFolderName = "SmartHealthMonitor"
    /// Supported pre-rename bundle identifiers.
    static let legacyBundleIdentifiers = ["local.smarthealthmonitor.app"]
    static let migrationNoteName = "migrated-from-SmartHealthMonitor.txt"

    enum MigrationOutcome: Equatable {
        /// The NenRing folder already existed; nothing was copied.
        case alreadyMigrated
        /// Neither folder existed.
        case freshInstall
        /// The old folder was copied and verified.
        case migrated(fileCount: Int)
        /// Copying or verification failed; the old folder stays in use.
        case failed(String)
    }

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var url: URL?

        func value() -> URL? {
            lock.lock()
            defer { lock.unlock() }
            return url
        }

        func store(_ newValue: URL) {
            lock.lock()
            url = newValue
            lock.unlock()
        }
    }

    private static let storage = Storage()

    static var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// The folder every store writes to. `prepareAtLaunch` fixes it; before
    /// that (for example in tests) it is resolved without copying anything.
    static var directoryURL: URL {
        storage.value() ?? resolveWithoutMigrating(base: applicationSupportURL)
    }

    static func resolveWithoutMigrating(base: URL, fileManager: FileManager = .default) -> URL {
        let current = base.appendingPathComponent(folderName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyFolderName, isDirectory: true)
        if !directoryExists(current, fileManager: fileManager) && directoryExists(legacy, fileManager: fileManager) {
            return legacy
        }
        return current
    }

    /// Runs once at launch, before any store or preference is read. It does
    /// nothing while an app with the old bundle identifier is running, because
    /// that app could still be writing to the old folder.
    @MainActor
    static func prepareAtLaunch() {
        let base = applicationSupportURL
        guard !isLegacyAppRunning else {
            storage.store(resolveWithoutMigrating(base: base))
            return
        }

        let (url, outcome) = migrateIfNeeded(base: base)
        storage.store(url)
        if case let .failed(message) = outcome {
            NSLog("NenRing: kept using the SmartHealthMonitor folder; migration failed: %@", message)
        }

        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            let legacyDomains = legacyBundleIdentifiers
                .filter { $0 != bundleIdentifier }
                .map { (name: $0, values: UserDefaults.standard.persistentDomain(forName: $0)) }
            LegacyPreferencesMigration.migrateIfNeeded(
                legacyDomains: legacyDomains,
                into: .standard,
                domainName: bundleIdentifier
            )
        }
    }

    static var isLegacyAppRunning: Bool {
        legacyBundleIdentifiers.contains {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
    }

    /// Copies the old folder to a staging folder, checks that every file is
    /// identical, then renames the staging folder into place in one step. On
    /// any failure the staging copy is removed and the old folder is used.
    static func migrateIfNeeded(
        base: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> (url: URL, outcome: MigrationOutcome) {
        let current = base.appendingPathComponent(folderName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyFolderName, isDirectory: true)

        if directoryExists(current, fileManager: fileManager) {
            return (current, .alreadyMigrated)
        }
        guard directoryExists(legacy, fileManager: fileManager) else {
            return (current, .freshInstall)
        }

        let staging = base.appendingPathComponent(".\(folderName)-migrating-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.copyItem(at: legacy, to: staging)
            let fileCount = try verifyIdenticalContents(source: legacy, copy: staging, fileManager: fileManager)
            let note = "Copied from \(legacyFolderName) on \(ISO8601DateFormatter().string(from: now)). " +
                "The \(legacyFolderName) folder was left unchanged.\n"
            try Data(note.utf8).write(to: staging.appendingPathComponent(migrationNoteName))
            do {
                try fileManager.moveItem(at: staging, to: current)
            } catch {
                guard directoryExists(current, fileManager: fileManager) else { throw error }
                // Another launch finished the migration first; keep its copy.
                try? fileManager.removeItem(at: staging)
                return (current, .alreadyMigrated)
            }
            return (current, .migrated(fileCount: fileCount))
        } catch {
            try? fileManager.removeItem(at: staging)
            return (legacy, .failed(error.localizedDescription))
        }
    }

    enum VerificationError: LocalizedError {
        case mismatch(String)

        var errorDescription: String? {
            switch self {
            case let .mismatch(path): return "copied file differs: \(path)"
            }
        }
    }

    /// Returns the number of files when both trees hold the same files with
    /// identical contents.
    static func verifyIdenticalContents(source: URL, copy: URL, fileManager: FileManager = .default) throws -> Int {
        let sourceFiles = try relativeFilePaths(in: source, fileManager: fileManager)
        let copiedFiles = try relativeFilePaths(in: copy, fileManager: fileManager)
        guard sourceFiles == copiedFiles else {
            let missing = sourceFiles.symmetricDifference(copiedFiles).sorted().first ?? "?"
            throw VerificationError.mismatch(missing)
        }
        for path in sourceFiles {
            guard fileManager.contentsEqual(
                atPath: source.appendingPathComponent(path).path,
                andPath: copy.appendingPathComponent(path).path
            ) else {
                throw VerificationError.mismatch(path)
            }
        }
        return sourceFiles.count
    }

    private static func relativeFilePaths(in root: URL, fileManager: FileManager) throws -> Set<String> {
        let rootPath = root.resolvingSymlinksInPath().path
        guard let enumerator = fileManager.enumerator(
            at: root.resolvingSymlinksInPath(),
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw VerificationError.mismatch(root.lastPathComponent)
        }
        var paths = Set<String>()
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            paths.insert(String(path.dropFirst(rootPath.count + 1)))
        }
        return paths
    }

    private static func directoryExists(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// Copies the preferences saved under earlier bundle identifiers into the new
/// domain once. Keys already set in the new domain win, then the newest old
/// domain; the old domains are left as they are.
enum LegacyPreferencesMigration {
    static let markerKey = "legacyPreferencesMigratedFrom"

    /// `legacyDomains` is ordered newest first.
    @discardableResult
    static func migrateIfNeeded(
        legacyDomains: [(name: String, values: [String: Any]?)],
        into defaults: UserDefaults,
        domainName: String
    ) -> Int {
        var current = defaults.persistentDomain(forName: domainName) ?? [:]
        guard current[markerKey] == nil else { return 0 }

        var copied = 0
        var sources: [String] = []
        for domain in legacyDomains {
            guard let values = domain.values, !values.isEmpty else { continue }
            sources.append(domain.name)
            for (key, value) in values where key != markerKey && current[key] == nil {
                current[key] = value
                copied += 1
            }
        }
        current[markerKey] = sources.isEmpty ? "none" : sources.joined(separator: ",")
        defaults.setPersistentDomain(current, forName: domainName)
        return copied
    }
}
