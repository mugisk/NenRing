import Foundation

struct FilesystemCapacity: Equatable, Sendable {
    let totalBytes: UInt64?
    /// Space not used by any file. Purgeable files (caches, local
    /// snapshots) still occupy NAND, so analyses use this value.
    let freeBytes: UInt64?
    /// Space available to the user, including purgeable files that macOS
    /// frees when needed. Finder and System Settings show this value.
    var availableBytes: UInt64? = nil
}

protocol FilesystemCapacityProviding: Sendable {
    func current() -> FilesystemCapacity
}

/// Reads the filesystem containing the current user's home directory. For an
/// Apple Silicon Mac this is normally the APFS data volume used by the startup
/// system. It is host-visible free space, not a measurement of NAND spare
/// blocks.
struct LocalFilesystemCapacityProvider: FilesystemCapacityProviding, Sendable {
    func current() -> FilesystemCapacity {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: homeURL.path) else {
            return FilesystemCapacity(totalBytes: nil, freeBytes: nil)
        }
        let available = (try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage

        return FilesystemCapacity(
            totalBytes: bytes(from: attributes[.systemSize]),
            freeBytes: bytes(from: attributes[.systemFreeSize]),
            availableBytes: bytes(from: available)
        )
    }

    private func bytes(from value: Any?) -> UInt64? {
        if let value = value as? NSNumber {
            let number = value.int64Value
            guard number >= 0 else { return nil }
            return UInt64(number)
        }
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? Int64, value >= 0 {
            return UInt64(value)
        }
        return nil
    }
}
