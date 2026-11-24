import Foundation

protocol SmartctlProcessRunning: Sendable {
    func run(executable: URL, arguments: [String]) throws -> SmartctlCommandResult
}

final class LocalSmartctlRunner: SmartctlProcessRunning, @unchecked Sendable {
    private let processRunner: BoundedProcessRunner

    init(
        timeout: TimeInterval = 15,
        terminationGracePeriod: TimeInterval = 0.5,
        maximumStdoutBytes: Int = 8 * 1_024 * 1_024,
        maximumStderrBytes: Int = 1 * 1_024 * 1_024
    ) {
        self.processRunner = BoundedProcessRunner(
            timeout: timeout,
            terminationGracePeriod: terminationGracePeriod,
            maximumStdoutBytes: maximumStdoutBytes,
            maximumStderrBytes: maximumStderrBytes
        )
    }

    func run(executable: URL, arguments: [String]) throws -> SmartctlCommandResult {
        do {
            let result = try processRunner.run(
                executable: executable,
                arguments: arguments
            )
            return SmartctlCommandResult(
                stdout: result.stdout,
                stderr: result.stderr,
                terminationStatus: result.terminationStatus
            )
        } catch BoundedProcessError.timedOut {
            throw SmartctlServiceError.timedOut
        } catch BoundedProcessError.outputLimitExceeded {
            throw SmartctlServiceError.outputLimitExceeded
        }
    }
}

protocol StorageDeviceLocating: Sendable {
    func location(forPath path: String) async -> StorageDeviceLocation
}

struct LocalStorageDeviceLocator: StorageDeviceLocating, Sendable {
    private let runner: BoundedProcessRunner

    init(timeout: TimeInterval = 5) {
        self.runner = BoundedProcessRunner(timeout: timeout)
    }

    func location(forPath path: String) async -> StorageDeviceLocation {
        if path.localizedCaseInsensitiveContains("AppleANS") {
            return .internalDevice
        }
        guard path.hasPrefix("/dev/") else { return .unknown }

        let runner = self.runner
        return await Task.detached(priority: .utility) {
            do {
                let result = try runner.run(
                    executable: URL(fileURLWithPath: "/usr/sbin/diskutil"),
                    arguments: ["info", "-plist", path]
                )
                guard result.terminationStatus == 0 else { return StorageDeviceLocation.unknown }
                return Self.parseLocation(plistData: result.stdout)
            } catch {
                return .unknown
            }
        }.value
    }

    static func parseLocation(plistData: Data) -> StorageDeviceLocation {
        guard let value = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dictionary = value as? [String: Any],
              let isInternal = dictionary["Internal"] as? Bool else {
            return .unknown
        }
        return isInternal ? .internalDevice : .externalDevice
    }
}

private struct CachedSmartctlCandidate: Sendable {
    let candidate: DeviceCandidate
    /// Identity derived from the drive itself, compared with a fresh read.
    let deviceID: String
    /// The ID the reported snapshot carries, which may be a `media:` ID
    /// when several Apple SMART services share no serial. Temperature
    /// samples use it so they join the same history as SMART snapshots.
    let historyDeviceID: String
    let model: String?
    let serialNumber: String?
    let logicalCapacityBytes: UInt64?

    init(candidate: DeviceCandidate, snapshot: DriveSnapshot) {
        self.candidate = candidate
        self.deviceID = DeviceIdentity.stableID(serialNumber: snapshot.serialNumber,
            model: snapshot.model, logicalCapacityBytes: snapshot.logicalCapacityBytes)
        self.historyDeviceID = snapshot.deviceID
        self.model = snapshot.model
        self.serialNumber = snapshot.serialNumber
        self.logicalCapacityBytes = snapshot.logicalCapacityBytes
    }

    /// A cached path is trusted only while its identity still describes the
    /// same drive. If macOS reassigns a raw-disk number, the mismatch causes a
    /// one-time rediscovery instead of attaching the wrong history series.
    func matches(_ snapshot: DriveSnapshot) -> Bool {
        guard snapshot.deviceID == deviceID else { return false }
        if model != nil && snapshot.model != nil && model != snapshot.model {
            return false
        }
        if serialNumber != snapshot.serialNumber {
            return false
        }
        if logicalCapacityBytes != nil && snapshot.logicalCapacityBytes != nil,
           logicalCapacityBytes != snapshot.logicalCapacityBytes {
            return false
        }
        return true
    }

    func matches(identity: SmartctlIdentity) -> Bool {
        if let model, let actualModel = identity.model, model != actualModel {
            return false
        }
        if serialNumber != identity.serialNumber {
            return false
        }
        if let logicalCapacityBytes, let actualCapacity = identity.logicalCapacityBytes,
           logicalCapacityBytes != actualCapacity {
            return false
        }
        return true
    }
}

private final class SmartctlCandidateCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CachedSmartctlCandidate?

    func value() -> CachedSmartctlCandidate? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ candidate: CachedSmartctlCandidate) {
        lock.lock()
        stored = candidate
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        stored = nil
        lock.unlock()
    }
}

struct SmartctlService: Sendable {
    let runner: any SmartctlProcessRunning
    let parser: SmartctlJSONParser
    let ioRegistryService: IORegistryService
    let filesystemCapacityProvider: any FilesystemCapacityProviding
    let storageDeviceLocator: any StorageDeviceLocating
    let storageTargetResolver: any StorageTargetResolving
    private let candidateCache: SmartctlCandidateCache

    init(
        runner: any SmartctlProcessRunning = LocalSmartctlRunner(),
        parser: SmartctlJSONParser = SmartctlJSONParser(),
        ioRegistryService: IORegistryService = IORegistryService(),
        filesystemCapacityProvider: any FilesystemCapacityProviding = LocalFilesystemCapacityProvider(),
        storageDeviceLocator: any StorageDeviceLocating = LocalStorageDeviceLocator(),
        storageTargetResolver: any StorageTargetResolving = LocalStorageTargetResolver()
    ) {
        self.runner = runner
        self.parser = parser
        self.ioRegistryService = ioRegistryService
        self.filesystemCapacityProvider = filesystemCapacityProvider
        self.storageDeviceLocator = storageDeviceLocator
        self.storageTargetResolver = storageTargetResolver
        self.candidateCache = SmartctlCandidateCache()
    }

    func probe(
        capturedAt: Date = Date(),
        includeIORegistry: Bool = true,
        forceIORegistryRefresh: Bool = false
    ) async throws -> ProbeReport {
        guard let executable = findExecutable() else {
            throw SmartctlServiceError.executableNotFound
        }

        // Keep the fast path only for the preferred internal target. An
        // external/unknown candidate is rediscovered on full refresh so a
        // newly available Apple internal SSD can take priority.
        if let cached = candidateCache.value(),
           cached.candidate.location == .internalDevice {
            let cachedAttempt = await probeCandidate(
                cached.candidate,
                executable: executable,
                capturedAt: capturedAt
            )
            if let cachedSnapshot = cachedAttempt.snapshot,
               cached.matches(cachedSnapshot) {
                let report = await makeReport(
                    best: cachedSnapshot,
                    selectedCandidate: cached.candidate,
                    executable: executable,
                    attempts: [cachedAttempt],
                    includeIORegistry: includeIORegistry,
                    forceIORegistryRefresh: forceIORegistryRefresh
                )
                candidateCache.store(CachedSmartctlCandidate(
                    candidate: cached.candidate,
                    snapshot: report.snapshot
                ))
                return report
            }
            // The cached path disappeared, failed, or now describes another
            // device. Only this path invalidates the cache and reopens the
            // discovery path.
            candidateCache.invalidate()
        }

        let candidates = try await discoverCandidates(executable: executable)
        if candidates.isEmpty {
            throw SmartctlServiceError.noUsableDevice(["smartctl がデバイス候補を返しませんでした。"])
        }

        var attempts = [ProbeAttempt]()
        for candidate in candidates {
            attempts.append(await probeCandidate(
                candidate,
                executable: executable,
                capturedAt: capturedAt
            ))
        }

        guard let bestAttempt = attempts
            .filter({ $0.snapshot != nil })
            .max(by: { lhs, rhs in
                guard let lhsSnapshot = lhs.snapshot, let rhsSnapshot = rhs.snapshot else { return false }
                return score(lhsSnapshot, candidate: lhs.candidate) < score(rhsSnapshot, candidate: rhs.candidate)
            }),
            let best = bestAttempt.snapshot
        else {
            let messages = attempts.compactMap(\.errorMessage)
            throw SmartctlServiceError.noUsableDevice(messages)
        }

        let bestCandidate = bestAttempt.candidate
        let report = await makeReport(
            best: best,
            selectedCandidate: bestCandidate,
            executable: executable,
            attempts: attempts,
            includeIORegistry: includeIORegistry,
            forceIORegistryRefresh: forceIORegistryRefresh
        )
        candidateCache.store(CachedSmartctlCandidate(candidate: bestCandidate, snapshot: report.snapshot))
        return report
    }

    /// Reads only the temperature field through the already-known candidate.
    /// This keeps thermal sampling independent from the slower cumulative
    /// snapshot interval. A path/identity failure invalidates the cache and
    /// falls back to a full probe, which also repopulates the cache.
    func probeTemperature(capturedAt: Date = Date()) async throws -> TemperatureReading {
        guard let executable = findExecutable() else {
            throw SmartctlServiceError.executableNotFound
        }

        if let cached = candidateCache.value() {
            do {
                // `-i` is needed for the identity check: without it smartctl
                // reports no model or serial, the check always fails, and every
                // temperature sample would fall back to full device discovery.
                let result = try await run(
                    executable: executable,
                    arguments: ["-j", "-i", "-A", cached.candidate.path]
                )
                guard !result.stdout.isEmpty else {
                    throw SmartctlServiceError.noUsableDevice(["温度取得の出力が空でした"])
                }
                let identity = try parser.parseIdentity(data: result.stdout)
                guard cached.matches(identity: identity) else {
                    throw SmartctlServiceError.noUsableDevice(["温度取得先のデバイスが変わりました"])
                }
                guard let temperature = try parser.parseTemperature(data: result.stdout) else {
                    throw SmartctlServiceError.noUsableDevice(["温度が取得できませんでした"])
                }
                let criticalWarning = try parser.parseCriticalWarning(data: result.stdout)
                return TemperatureReading(
                    capturedAt: capturedAt,
                    deviceID: cached.historyDeviceID,
                    temperatureCelsius: temperature,
                    criticalWarning: criticalWarning
                )
            } catch {
                candidateCache.invalidate()
            }
        }

        let report = try await probe(capturedAt: capturedAt, includeIORegistry: false)
        guard let temperature = report.snapshot.temperatureCelsius else {
            throw SmartctlServiceError.noUsableDevice(["温度が取得できませんでした"])
        }
        return TemperatureReading(
            capturedAt: capturedAt,
            deviceID: report.snapshot.deviceID,
            temperatureCelsius: temperature,
            criticalWarning: report.snapshot.criticalWarning
        )
    }

    /// Refreshes only the optional Apple hardware profile. This is intentionally
    /// separate from `probe` so a 1-minute SMART schedule cannot cause ioreg to
    /// run at the same cadence.
    func resolveStorageTarget(devicePath: String) async -> StorageTargetResolution {
        let resolver = storageTargetResolver
        return await Task.detached(priority: .utility) { resolver.resolve(devicePath: devicePath) }.value
    }

    func probeIORegistry(modelNumber: String?, binding: StorageTargetBinding) async -> AppleNANDHardwareProfile? {
        return await ioRegistryService.profile(modelNumber: modelNumber, forceRefresh: true, binding: binding)
    }

    private func probeCandidate(
        _ candidate: DeviceCandidate,
        executable: URL,
        capturedAt: Date
    ) async -> ProbeAttempt {
        do {
            let commandResult = try await run(
                executable: executable,
                // -c formats the same Identify data already requested by -i.
                // Do not use -a/-x: those also request optional error/self-test logs.
                arguments: ["-j", "-i", "-H", "-A", "-c", candidate.path]
            )
            guard !commandResult.stdout.isEmpty else {
                let message = string(from: commandResult.stderr) ?? "smartctl の出力が空でした"
                return ProbeAttempt(candidate: candidate, snapshot: nil, errorMessage: message)
            }
            let snapshot = try parser.parse(
                data: commandResult.stdout,
                capturedAt: capturedAt,
                devicePath: candidate.path
            )
            guard snapshot.availableMetricCount > 0 else {
                let message = snapshot.messages.first ?? "認識できるメトリクスがありません"
                return ProbeAttempt(candidate: candidate, snapshot: nil, errorMessage: message)
            }
            return ProbeAttempt(candidate: candidate, snapshot: snapshot, errorMessage: nil)
        } catch {
            return ProbeAttempt(
                candidate: candidate,
                snapshot: nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func makeReport(
        best originalBest: DriveSnapshot,
        selectedCandidate: DeviceCandidate,
        executable: URL,
        attempts: [ProbeAttempt],
        includeIORegistry: Bool,
        forceIORegistryRefresh: Bool = false
    ) async -> ProbeReport {
        var best = originalBest

        let filesystemCapacityProvider = self.filesystemCapacityProvider
        let filesystemCapacity = await Task.detached(priority: .utility) {
            filesystemCapacityProvider.current()
        }.value
        best.filesystemTotalCapacityBytes = filesystemCapacity.totalBytes
        best.filesystemFreeBytes = filesystemCapacity.freeBytes
        best.filesystemAvailableBytes = filesystemCapacity.availableBytes

        let missing = best.healthMetricsMissing.map(\.title)
        let diagnostic: String?
        if missing.isEmpty {
            diagnostic = nil
        } else {
            diagnostic = "未取得: " + missing.joined(separator: "、")
        }

        let looksLikeAppleInternalSSD =
            selectedCandidate.isAppleANSControllerPath ||
            best.model?.uppercased().hasPrefix("APPLE SSD") == true
        let resolvedTarget = selectedCandidate.location == .internalDevice && looksLikeAppleInternalSSD
            ? await resolveStorageTarget(devicePath: best.devicePath) : nil
        // Two equal model/capacity identities must not share forecast history.
        // Without a durable identifier, multiple live Apple targets are kept
        // as SMART-only until their identity can be distinguished.
        let target = resolvedTarget?.identifyingDisk(serialNumber: best.serialNumber)
        let identityAmbiguous = target?.identityAmbiguous == true
        if best.serialNumber == nil, let target,
           (target.appleSMARTServiceCount ?? target.binding?.appleSMARTServiceCount ?? 0) > 1,
           let uuid = target.historyMediaUUID {
            best.deviceID = "media:\(uuid)"
        }
        let shouldReadAppleStorageProfile =
            includeIORegistry &&
            selectedCandidate.location == .internalDevice &&
            looksLikeAppleInternalSSD && target?.binding != nil && !identityAmbiguous
        let appleStorageProfile: AppleNANDHardwareProfile?
        if shouldReadAppleStorageProfile, let binding = target?.binding {
            appleStorageProfile = await ioRegistryService.profile(modelNumber: best.model,
                forceRefresh: forceIORegistryRefresh, binding: binding)
        } else if !includeIORegistry, let binding = target?.binding, !identityAmbiguous {
            // No IORegistry acquisition on routine SMART polls. Restore only
            // context cached for this exact live target after a transient loss.
            appleStorageProfile = await ioRegistryService.cachedProfile(binding: binding)
        } else { appleStorageProfile = nil }
        let capabilities = StorageDeviceCapabilities(
            location: selectedCandidate.location,
            appleDirectFTLEligible:
                DirectFTLContractRegistry.isAppleSiliconHost &&
                selectedCandidate.location == .internalDevice && looksLikeAppleInternalSSD &&
                target?.binding != nil && !identityAmbiguous,
            usableCandidateCount: attempts.filter { $0.snapshot != nil }.count
        )

        return ProbeReport(
            snapshot: best,
            executablePath: executable.path,
            attempts: attempts,
            diagnostic: diagnostic,
            appleStorageProfile: appleStorageProfile,
            deviceCapabilities: capabilities,
            storageTargetResolution: target
        )
    }

    private func run(executable: URL, arguments: [String]) async throws -> SmartctlCommandResult {
        let runner = self.runner
        return try await Task.detached(priority: .utility) {
            try runner.run(executable: executable, arguments: arguments)
        }.value
    }

    private func discoverCandidates(executable: URL) async throws -> [DeviceCandidate] {
        var candidates: [DeviceCandidate] = []

        let scanResult: SmartctlCommandResult?
        do {
            scanResult = try await run(executable: executable, arguments: ["--scan-open", "-j"])
        } catch SmartctlServiceError.outputLimitExceeded {
            throw SmartctlServiceError.outputLimitExceeded
        } catch {
            scanResult = nil
        }
        if let scanResult,
           let object = try? JSONSerialization.jsonObject(with: scanResult.stdout) as? [String: Any],
           let devices = object["devices"] as? [[String: Any]] {
            for device in devices {
                guard let name = device["name"] as? String, !name.isEmpty else { continue }
                candidates.append(DeviceCandidate(
                    path: name,
                    type: device["type"] as? String,
                    source: .smartctlScan
                ))
            }
        }

        let rawDisks = rawWholeDiskCandidates()
        candidates.append(contentsOf: rawDisks)

        var seen = Set<String>()
        let uniqueCandidates = candidates.filter { seen.insert($0.path).inserted }

        var classified: [DeviceCandidate] = []
        classified.reserveCapacity(uniqueCandidates.count)
        for candidate in uniqueCandidates {
            let location = await storageDeviceLocator.location(forPath: candidate.path)
            classified.append(DeviceCandidate(
                path: candidate.path,
                type: candidate.type,
                source: candidate.source,
                location: location
            ))
        }
        return classified
    }

    private func rawWholeDiskCandidates() -> [DeviceCandidate] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .compactMap { name -> (Int, String)? in
                guard name.hasPrefix("rdisk"), let number = Int(name.dropFirst(5)) else { return nil }
                return (number, name)
            }
            .sorted { $0.0 < $1.0 }
            .map { number, name in
                _ = number
                return DeviceCandidate(path: "/dev/\(name)", type: "nvme", source: .rawDiskFallback)
            }
    }

    private func findExecutable() -> URL? {
        var paths: [String] = []
        if let pathEnvironment = ProcessInfo.processInfo.environment["PATH"] {
            paths.append(contentsOf: pathEnvironment.split(separator: ":").map(String.init))
        }
        paths.append(contentsOf: [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            // MacPorts
            "/opt/local/bin",
            "/opt/local/sbin"
        ])

        var seen = Set<String>()
        for directory in paths where seen.insert(directory).inserted {
            let path = URL(fileURLWithPath: directory).appendingPathComponent("smartctl").path
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func score(_ snapshot: DriveSnapshot, candidate: DeviceCandidate) -> Int {
        var result = snapshot.availableMetricCount * 10
        if snapshot.model != nil { result += 10 }
        if snapshot.smartPassed != nil { result += 10 }
        if snapshot.hasHealthLogValues { result += 20 }
        if snapshot.smartctlExitStatus == 0 { result += 1 }

        switch candidate.location {
        case .internalDevice:
            result += 1_000
        case .externalDevice:
            result -= 100
        case .unknown:
            break
        }
        if candidate.isAppleANSControllerPath { result += 500 }
        if snapshot.model?.uppercased().hasPrefix("APPLE SSD") == true { result += 100 }
        return result
    }

    private func string(from data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
