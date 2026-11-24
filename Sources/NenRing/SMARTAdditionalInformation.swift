import Foundation

struct SMARTAdditionalCounters: Codable, Equatable, Sendable {
    var hostReadCommands: UInt64?
    var hostWriteCommands: UInt64?
    /// NVMe Controller Busy Time is reported in minutes; zero may be a placeholder.
    var controllerBusyMinutes: UInt64?
    var errorLogEntries: UInt64?
}

/// Reported Identify bits, not proof that macOS exposes the corresponding command.
struct NVMeCapabilities: Codable, Equatable, Sendable {
    var adminCommands: UInt64?
    var nvmCommands: UInt64?
    var logPageAttributes: UInt64?
    var firmwareSlots: UInt64?
    var maximumTransferPages: UInt64?

    var selfTestSupported: Bool? { adminCommands.map { $0 & 0x10 != 0 } }
    var deallocateSupported: Bool? { nvmCommands.map { $0 & 0x04 != 0 } }
    var telemetrySupported: Bool? { logPageAttributes.map { $0 & 0x08 != 0 } }
}

enum SMARTRequestSizeFormatter {
    static func string(_ bytes: Double?) -> String? {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return nil }
        // The general endurance formatter starts at GB; requests need B/kB/MB.
        let unit = [(1e9, "GB"), (1e6, "MB"), (1e3, "kB"), (1.0, "B")]
            .first { bytes >= $0.0 } ?? (1.0, "B")
        return String(format: "%.2f %@", locale: UIString.locale, bytes / unit.0, unit.1)
    }
}

struct SMARTCounterDelta: Equatable, Sendable {
    enum State: Sendable { case valid, noBaseline, missing, reset, boundary }
    let value: UInt64?
    let state: State

    static func compare(_ before: UInt64?, _ after: UInt64?) -> Self {
        guard let before, let after else { return Self(value: nil, state: .missing) }
        guard after >= before else { return Self(value: nil, state: .reset) }
        return Self(value: after - before, state: .valid)
    }

    var statusKey: String {
        switch state {
        case .valid: return "増分"
        case .noBaseline: return "比較履歴なし"
        case .missing: return "比較値未取得"
        case .reset: return "カウンタ逆行・比較保留"
        case .boundary: return "系列境界・比較保留"
        }
    }
}

/// Built on full analytics refresh, never by walking history from a view body.
struct SMARTCounterInterval: Equatable, Sendable {
    var start: Date?
    var end: Date?
    var readCommands = SMARTCounterDelta(value: nil, state: .noBaseline)
    var writeCommands = SMARTCounterDelta(value: nil, state: .noBaseline)
    var busyMinutes = SMARTCounterDelta(value: nil, state: .noBaseline)
    var errorLogEntries = SMARTCounterDelta(value: nil, state: .noBaseline)
    var averageReadBytes: Double?
    var averageWriteBytes: Double?
    static let empty = Self()

    static func make(history: [DriveSnapshot], deviceID: String?) -> Self {
        guard let deviceID else { return .empty }
        // Only retain the latest pair; do not allocate/sort a second history.
        var latest: DriveSnapshot?
        var previous: DriveSnapshot?
        for snapshot in history where snapshot.deviceID == deviceID {
            if latest == nil || snapshot.capturedAt >= latest!.capturedAt {
                previous = latest
                latest = snapshot
            } else if previous == nil || snapshot.capturedAt > previous!.capturedAt {
                previous = snapshot
            }
        }
        guard let after = latest else { return .empty }
        var result = Self(end: after.capturedAt)
        guard let before = previous else { return result }
        result.start = before.capturedAt
        guard after.capturedAt > before.capturedAt, before.firmware == after.firmware,
              !(before.powerOnHours != nil && after.powerOnHours != nil && after.powerOnHours! < before.powerOnHours!)
        else {
            let boundary = SMARTCounterDelta(value: nil, state: .boundary)
            result.readCommands = boundary; result.writeCommands = boundary
            result.busyMinutes = boundary; result.errorLogEntries = boundary
            return result
        }
        result.readCommands = .compare(before.additionalSMART?.hostReadCommands, after.additionalSMART?.hostReadCommands)
        result.writeCommands = .compare(before.additionalSMART?.hostWriteCommands, after.additionalSMART?.hostWriteCommands)
        result.busyMinutes = .compare(before.additionalSMART?.controllerBusyMinutes, after.additionalSMART?.controllerBusyMinutes)
        result.errorLogEntries = .compare(before.additionalSMART?.errorLogEntries, after.additionalSMART?.errorLogEntries)
        func average(_ first: UInt64?, _ last: UInt64?, _ commands: UInt64?) -> Double? {
            guard let first, let last, last >= first, let commands, commands > 0 else { return nil }
            return Double(last - first) * 512_000 / Double(commands)
        }
        result.averageReadBytes = average(before.dataUnitsRead, after.dataUnitsRead, result.readCommands.value)
        result.averageWriteBytes = average(before.dataUnitsWritten, after.dataUnitsWritten, result.writeCommands.value)
        return result
    }
}
