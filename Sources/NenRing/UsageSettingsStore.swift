import Foundation

/// Stores user-provided lifetime assumptions separately from raw smartctl history.
/// Keys are the same local device identifiers used by HistoryStore.
actor UsageSettingsStore {
    private let fileURL: URL
    private var cache: [String: UsageSettings]?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = AppDataLocation.directoryURL
                .appendingPathComponent("usage-settings.json")
        }
    }

    func settings(for deviceID: String) throws -> UsageSettings {
        try ensureLoaded()[deviceID] ?? UsageSettings()
    }

    /// Reads settings using the current stable identity and migrates a
    /// matching path-based key from pre-stable-identity releases once.
    func settings(for snapshot: DriveSnapshot) throws -> UsageSettings {
        var allSettings = try ensureLoaded()
        if let settings = allSettings[snapshot.deviceID] {
            return settings
        }

        let legacyKeys = [
            DeviceIdentity.legacyPathID(model: snapshot.model, devicePath: snapshot.devicePath),
            DeviceIdentity.stableID(
                serialNumber: nil,
                model: snapshot.model,
                logicalCapacityBytes: nil
            )
        ]
        guard let legacyKey = legacyKeys.first(where: { allSettings[$0] != nil }),
              let settings = allSettings[legacyKey]
        else {
            return UsageSettings()
        }

        allSettings[snapshot.deviceID] = settings
        if legacyKey != snapshot.deviceID {
            allSettings.removeValue(forKey: legacyKey)
        }
        try persist(allSettings)
        cache = allSettings
        return settings
    }

    func save(_ settings: UsageSettings, for deviceID: String) throws {
        var allSettings = try ensureLoaded()
        if settings.isEmpty {
            allSettings.removeValue(forKey: deviceID)
        } else {
            allSettings[deviceID] = settings
        }

        try persist(allSettings)
        cache = allSettings
    }

    private func persist(_ allSettings: [String: UsageSettings]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(allSettings)

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private func ensureLoaded() throws -> [String: UsageSettings] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = [:]
            return [:]
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([String: UsageSettings].self, from: data)
        cache = decoded
        return decoded
    }
}
