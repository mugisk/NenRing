import Foundation

/// Host facts that identify the hardware/OS cohort, never the individual Mac.
struct DiagnosticHostEnvironment: Codable, Equatable, Sendable {
    let hardwareModel: String?
    let cpuBrand: String?
    let osVersion: String
    let osBuild: String?

    static func current() -> Self {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return Self(
            hardwareModel: sysctlString("hw.model"),
            cpuBrand: sysctlString("machdep.cpu.brand_string"),
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            osBuild: sysctlString("kern.osversion")
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// A contributor-shareable snapshot of what this environment exposes. It is
/// written only when the user explicitly saves it and is never uploaded.
/// Serial numbers, device paths and device IDs are intentionally omitted.
struct DiagnosticReport: Codable, Equatable, Sendable {
    /// v2: every date is rounded to a UTC calendar day.
    /// v3: adds `asptoolVerifiedEnvironments`.
    static let currentSchemaVersion = 3

    struct App: Codable, Equatable, Sendable {
        let version: String
        let build: String
        let sourceRevision: String?
    }

    struct Storage: Codable, Equatable, Sendable {
        let model: String?
        let firmware: String?
        let logicalCapacityBytes: UInt64?
        let location: String
        let appleDirectFTLEligible: Bool
        let smartctlVersion: String?
        let smartctlExitStatus: Int?
        let percentageUsed: UInt64?
        let availableSpare: UInt64?
        let availableSpareThreshold: UInt64?
        let criticalWarning: UInt64?
        let mediaAndDataIntegrityErrors: UInt64?
        let powerOnHours: UInt64?
        let powerCycleCount: UInt64?
        let unsafeShutdowns: UInt64?
        let dataUnitsRead: UInt64?
        let dataUnitsWritten: UInt64?
        let temperatureCelsius: Int?
    }

    struct DirectFTLContract: Codable, Equatable, Sendable {
        struct TargetSelection: Codable, Equatable, Sendable {
            let state: String
            let method: String
            let appleSMARTServiceCount: Int?
            let wholeMediaCount: Int?
            let scope: String
        }
        var targetSelection: TargetSelection? = nil
        /// Build the reviewed contract covers when the running build matches.
        let matchedContractBuild: String?
        let reviewStatus: String
        let registeredContractBuilds: [String]
        /// "reviewed", "unreviewedBuild" or "unreviewedHardware" for this Mac's
        /// macOS build and IORegistry SSD controller chip ID.
        let executionReview: String
    }

    struct FTLSnapshotSummary: Codable, Equatable, Sendable {
        let capturedAt: Date
        let sourceArtifact: String
        /// Analysis-resolved runtime build (legacy labels are re-resolved).
        let sourceBuild: String?
        let buildProvenance: String
        let contractBuild: String?
        let probeVersion: Int?
        let semanticContractVersion: String?
        let firmware: String?
        let mspVersion: String?
        let controllerChipID: String?
        let hostWrites: UInt64?
        let nandWrites: UInt64?
        let hostWritesUnitState: String
        let nandWritesUnitState: String
        let tlcAveragePE: Double?
        let tlcMaximumPE: Double?
        let tlcEOLPE: Double?
        let slcAveragePE: Double?
        let slcMaximumPE: Double?
        let slcEOLPE: Double?
        let powerOnHours: UInt64?
        let writeAmp: Double?
        let topology: DirectFTLTopology?
    }

    /// One row per distinct instrument seen in local history, so contributors
    /// can report which build/firmware combinations produced data.
    struct ObservedInstrument: Codable, Equatable, Sendable {
        let sourceArtifact: String
        let sourceBuild: String?
        let buildProvenance: String
        let contractBuild: String?
        let firmware: String?
        let snapshotCount: Int
        let firstCapturedAt: Date
        let lastCapturedAt: Date
    }

    /// A macOS build and firmware on which an imported asptool log matched
    /// the Direct FTL reads within the criteria on this Mac.
    struct ASPToolVerifiedEnvironment: Codable, Equatable, Sendable {
        let sourceBuild: String
        let macOSVersion: String?
        let firmware: String
        let logCapturedAt: Date
    }

    let schemaVersion: Int
    let generatedAt: Date
    let app: App
    let host: DiagnosticHostEnvironment
    let storage: Storage?
    let appleStorageProfile: AppleNANDHardwareProfile?
    let directFTLContract: DirectFTLContract
    let latestFTLSnapshot: FTLSnapshotSummary?
    let observedInstruments: [ObservedInstrument]
    let asptoolVerifiedEnvironments: [ASPToolVerifiedEnvironment]
    let notes: [String]
}

enum DiagnosticReportBuilder {
    static func make(
        host: DiagnosticHostEnvironment,
        app: DiagnosticReport.App,
        smart: DriveSnapshot?,
        capabilities: StorageDeviceCapabilities,
        profile: AppleNANDHardwareProfile?,
        ftlSnapshots: [ASPToolDiagnosticsSnapshot],
        smartHistory: [DriveSnapshot] = [],
        locallyVerifiedMacOSMajors: Set<Int> = [],
        targetResolution: StorageTargetResolution? = nil,
        asptoolVerifiedEnvironments: [ASPToolVerifiedEnvironment] = [],
        now: Date
    ) -> DiagnosticReport {
        // Only snapshots for the selected device; the device ID itself is not exported.
        let selectedDeviceID = smart?.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceSnapshots = ftlSnapshots
            .filter { capabilities.location != .externalDevice && selectedDeviceID?.isEmpty == false && $0.deviceID == selectedDeviceID }
            .sorted { $0.capturedAt < $1.capturedAt }
        let matched = DirectFTLContractRegistry.descriptor(runtimeBuild: host.osBuild)
        let executionReview = DirectFTLContractRegistry.executionReview(
            runtimeBuild: host.osBuild,
            locallyVerifiedMajors: locallyVerifiedMacOSMajors
        )

        var notes: [String] = []
        if smart == nil {
            notes.append("SMART unavailable: smartctl missing or no readable device.")
        }
        if capabilities.appleDirectFTLEligible, matched == nil {
            if case .locallyVerified = executionReview {
                notes.append("Running macOS release is not reviewed by the project, but a read on this Mac passed the SMART cross-check.")
            } else if case .compatibilityTrial = executionReview {
                notes.append("FTL collection is attempted by default on this macOS release as a compatibility trial; its ABI and private-key meanings are not reviewed.")
            } else {
                notes.append("Running macOS build has no reviewed Direct FTL contract; FTL values are unverified on this build.")
            }
        }
        if capabilities.appleDirectFTLEligible,
           !DirectFTLContractRegistry.reviewed25G83.isReviewedHardware(chipID: profile?.chipID) {
            notes.append("SSD controller chip-id is not in the reviewed set; FTL reads are stored only after the SMART cross-check.")
        }
        if deviceSnapshots.isEmpty {
            notes.append("No Direct FTL / asptool snapshots for the selected device; unidentified records are excluded.")
        }

        return DiagnosticReport(
            schemaVersion: DiagnosticReport.currentSchemaVersion,
            generatedAt: now,
            app: app,
            host: host,
            storage: smart.map { storage($0, capabilities: capabilities) },
            appleStorageProfile: profile,
            directFTLContract: DiagnosticReport.DirectFTLContract(
                targetSelection: targetResolution.map {
                    .init(state: $0.state.rawValue, method: "selectedDiskAncestry",
                          appleSMARTServiceCount: $0.binding?.appleSMARTServiceCount ?? $0.appleSMARTServiceCount,
                          wholeMediaCount: $0.binding?.wholeMediaCount ?? $0.physicalWholeMediaCount,
                          scope: $0.binding == nil ? "unresolved" : "singleWholeMedia")
                },
                matchedContractBuild: matched?.contractBuild,
                reviewStatus: matched?.reviewStatus.rawValue ?? "unreviewed",
                registeredContractBuilds: DirectFTLContractRegistry.descriptors.map(\.contractBuild),
                executionReview: {
                    switch executionReview {
                    case .reviewed: return "reviewed"
                    case .compatibilityTrial: return "compatibilityTrial"
                    case .locallyVerified: return "locallyVerified"
                    case .unreviewedBuild: return "unreviewedBuild"
                    }
                }()
            ),
            latestFTLSnapshot: deviceSnapshots.last.map { summary($0, smartHistory: smartHistory) },
            observedInstruments: observedInstruments(deviceSnapshots, smartHistory: smartHistory),
            asptoolVerifiedEnvironments: asptoolVerifiedEnvironments
                .sorted { ($0.sourceBuild, $0.firmware) < ($1.sourceBuild, $1.firmware) }
                .map { .init(sourceBuild: $0.sourceBuild, macOSVersion: $0.macOSVersion,
                             firmware: $0.firmware, logCapturedAt: $0.logCapturedAt) },
            notes: notes
        )
    }

    /// Dates are written as UTC days so a shared report does not reveal
    /// when the Mac was in use.
    static func encode(_ report: DiagnosticReport) throws -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .formatted(formatter)
        return try encoder.encode(report)
    }

    private static func storage(_ smart: DriveSnapshot, capabilities: StorageDeviceCapabilities) -> DiagnosticReport.Storage {
        DiagnosticReport.Storage(
            model: smart.model,
            firmware: smart.firmware,
            logicalCapacityBytes: smart.logicalCapacityBytes,
            location: capabilities.location.rawValue,
            appleDirectFTLEligible: capabilities.appleDirectFTLEligible,
            smartctlVersion: smart.smartctlVersion,
            smartctlExitStatus: smart.smartctlExitStatus,
            percentageUsed: smart.percentageUsed,
            availableSpare: smart.availableSpare,
            availableSpareThreshold: smart.availableSpareThreshold,
            criticalWarning: smart.criticalWarning,
            mediaAndDataIntegrityErrors: smart.mediaAndDataIntegrityErrors,
            powerOnHours: smart.powerOnHours,
            powerCycleCount: smart.powerCycleCount,
            unsafeShutdowns: smart.unsafeShutdowns,
            dataUnitsRead: smart.dataUnitsRead,
            dataUnitsWritten: smart.dataUnitsWritten,
            temperatureCelsius: smart.temperatureCelsius
        )
    }

    /// Uses the same legacy-build overlay as the continuity analysis, so old
    /// snapshots whose stored build was a fixed label are not reported as
    /// having run on that build.
    private static func resolvedBuild(
        _ snapshot: ASPToolDiagnosticsSnapshot,
        smartHistory: [DriveSnapshot]
    ) -> (build: String?, provenance: String) {
        let resolved = LegacyBuildOverlay.resolve(snapshot, smartHistory: smartHistory)
        return (resolved.build, resolved.provenance.rawValue)
    }

    private static func summary(
        _ snapshot: ASPToolDiagnosticsSnapshot,
        smartHistory: [DriveSnapshot]
    ) -> DiagnosticReport.FTLSnapshotSummary {
        let build = resolvedBuild(snapshot, smartHistory: smartHistory)
        return DiagnosticReport.FTLSnapshotSummary(
            capturedAt: snapshot.capturedAt,
            sourceArtifact: snapshot.sourceArtifact.rawValue,
            sourceBuild: build.build,
            buildProvenance: build.provenance,
            contractBuild: snapshot.contractBuild,
            probeVersion: snapshot.probeVersion,
            semanticContractVersion: snapshot.semanticContractVersion,
            firmware: snapshot.firmware,
            mspVersion: snapshot.mspVersion,
            controllerChipID: snapshot.chipID,
            hostWrites: snapshot.hostWrites,
            nandWrites: snapshot.nandWrites,
            hostWritesUnitState: snapshot.hostWritesUnitState.rawValue,
            nandWritesUnitState: snapshot.nandWritesUnitState.rawValue,
            tlcAveragePE: snapshot.tlcAveragePE,
            tlcMaximumPE: snapshot.tlcMaximumPE,
            tlcEOLPE: snapshot.tlcEOLPE,
            slcAveragePE: snapshot.slcAveragePE,
            slcMaximumPE: snapshot.slcMaximumPE,
            slcEOLPE: snapshot.slcEOLPE,
            powerOnHours: snapshot.powerOnHours,
            writeAmp: snapshot.writeAmp,
            topology: snapshot.directTopology
        )
    }

    private static func observedInstruments(
        _ snapshots: [ASPToolDiagnosticsSnapshot],
        smartHistory: [DriveSnapshot]
    ) -> [DiagnosticReport.ObservedInstrument] {
        var rows: [DiagnosticReport.ObservedInstrument] = []
        for snapshot in snapshots {
            let build = resolvedBuild(snapshot, smartHistory: smartHistory)
            if let index = rows.firstIndex(where: {
                $0.sourceArtifact == snapshot.sourceArtifact.rawValue &&
                    $0.sourceBuild == build.build &&
                    $0.buildProvenance == build.provenance &&
                    $0.contractBuild == snapshot.contractBuild &&
                    $0.firmware == snapshot.firmware
            }) {
                let row = rows[index]
                rows[index] = DiagnosticReport.ObservedInstrument(
                    sourceArtifact: row.sourceArtifact, sourceBuild: row.sourceBuild,
                    buildProvenance: row.buildProvenance, contractBuild: row.contractBuild, firmware: row.firmware,
                    snapshotCount: row.snapshotCount + 1,
                    firstCapturedAt: row.firstCapturedAt, lastCapturedAt: snapshot.capturedAt
                )
            } else {
                rows.append(DiagnosticReport.ObservedInstrument(
                    sourceArtifact: snapshot.sourceArtifact.rawValue, sourceBuild: build.build,
                    buildProvenance: build.provenance, contractBuild: snapshot.contractBuild, firmware: snapshot.firmware,
                    snapshotCount: 1, firstCapturedAt: snapshot.capturedAt, lastCapturedAt: snapshot.capturedAt
                ))
            }
        }
        return rows
    }
}

/// What the report sheet needs from a report: a file name, a short summary
/// of what is inside, and a link to a new GitHub issue with the title filled
/// in. Nothing is sent by the app; the link only opens the browser.
enum DiagnosticReportSharing {
    static let newIssueURL = URL(string: "https://github.com/mugisk/NenRing/issues/new")!
    static let issueTemplate = "diagnostic-report.yml"

    struct SummaryItem: Equatable, Sendable {
        let label: String
        let value: String
    }

    /// `nenring-report-<UTC day>-<Mac model>.json`
    static func fileName(for report: DiagnosticReport) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ",.-_"))
        let model = String((report.host.hardwareModel ?? "Mac").unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        })
        return "nenring-report-\(formatter.string(from: report.generatedAt))-\(model).json"
    }

    static func issueTitle(for report: DiagnosticReport) -> String {
        let capacity = report.storage?.logicalCapacityBytes.map(capacityText) ?? "unknown capacity"
        let build = report.host.osBuild.map { " (\($0))" } ?? ""
        return "[Report] \(report.host.hardwareModel ?? "Mac") / \(capacity) / macOS \(report.host.osVersion)\(build)"
    }

    static func issueURL(for report: DiagnosticReport) -> URL {
        var components = URLComponents(url: newIssueURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "template", value: issueTemplate),
            URLQueryItem(name: "title", value: issueTitle(for: report))
        ]
        return components.url ?? newIssueURL
    }

    static func summary(for report: DiagnosticReport) -> [SummaryItem] {
        let mac = [report.host.hardwareModel, report.host.cpuBrand].compactMap { $0 }.joined(separator: " · ")
        let ssd = report.storage.map { storage in
            [storage.model, storage.logicalCapacityBytes.map(capacityText)].compactMap { $0 }.joined(separator: " · ")
        }
        return [
            SummaryItem(label: "Mac", value: mac.isEmpty ? "-" : mac),
            SummaryItem(label: "macOS", value: report.host.osVersion + (report.host.osBuild.map { " (\($0))" } ?? "")),
            SummaryItem(label: "SSD", value: ssd ?? "SMART未取得"),
            SummaryItem(label: "Direct FTL", value: report.latestFTLSnapshot == nil ? "保存済みの値なし" : "保存済みの値あり")
        ]
    }

    /// Decimal units, as on the box: 251 GB, 1.0 TB.
    static func capacityText(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        return value >= 1e12 ? String(format: "%.1f TB", value / 1e12) : String(format: "%.0f GB", value / 1e9)
    }
}
