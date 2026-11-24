import Foundation

/// Creates the local series key used by history and per-device settings.
///
/// A device path is deliberately not part of the fallback key. macOS can
/// assign a different rdisk number after an external device is attached, and
/// an IOService path and a raw-disk path can describe the same physical SSD.
enum DeviceIdentity {
    static func stableID(
        serialNumber: String?,
        model: String?,
        logicalCapacityBytes: UInt64?
    ) -> String {
        if let serial = normalized(serialNumber), !serial.isEmpty {
            return "serial:\(serial)"
        }

        let modelPart = normalized(model).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        if let logicalCapacityBytes, logicalCapacityBytes > 0 {
            return "model:\(modelPart)|capacity:\(logicalCapacityBytes)"
        }
        return "model:\(modelPart)"
    }

    static func legacyPathID(model: String?, devicePath: String) -> String {
        let modelPart = model ?? "unknown"
        return "model:\(modelPart)|path:\(devicePath)"
    }

    static func isLegacyPathID(_ deviceID: String) -> Bool {
        deviceID.contains("|path:")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return collapsed.replacingOccurrences(of: "|", with: "/")
    }
}
