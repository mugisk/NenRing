import Foundation

struct SmartctlJSONParser: Sendable {
    func parseTemperature(data: Data) throws -> Int? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SmartctlServiceError.invalidJSON("トップレベルが JSON オブジェクトではありません")
        }
        return firstInt(in: object, paths: [
            ["temperature", "current"],
            ["nvme_smart_health_information_log", "temperature"],
            ["temperature"]
        ])
    }

    func parseCriticalWarning(data: Data) throws -> UInt64? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SmartctlServiceError.invalidJSON("トップレベルが JSON オブジェクトではありません")
        }
        return firstUInt64(in: object, paths: [
            ["nvme_smart_health_information_log", "critical_warning"],
            ["critical_warning"]
        ])
    }

    func parseIdentity(data: Data) throws -> SmartctlIdentity {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SmartctlServiceError.invalidJSON("トップレベルが JSON オブジェクトではありません")
        }
        return SmartctlIdentity(
            model: firstString(in: object, paths: [
                ["model_name"], ["device", "model_name"]
            ]),
            serialNumber: firstString(in: object, paths: [
                ["serial_number"], ["device", "serial_number"]
            ]),
            logicalCapacityBytes: firstUInt64(in: object, paths: [
                ["user_capacity", "bytes"],
                ["user_capacity"],
                ["capacity", "bytes"],
                ["capacity"]
            ])
        )
    }

    func parse(data: Data, capturedAt: Date, devicePath: String) throws -> DriveSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SmartctlServiceError.invalidJSON("トップレベルが JSON オブジェクトではありません")
        }

        let model = firstString(in: object, paths: [
            ["model_name"], ["device", "model_name"]
        ])
        let serialNumber = firstString(in: object, paths: [
            ["serial_number"], ["device", "serial_number"]
        ])
        let firmware = firstString(in: object, paths: [
            ["firmware_version"], ["device", "firmware_version"]
        ])
        let logicalCapacityBytes = firstUInt64(in: object, paths: [
            ["user_capacity", "bytes"],
            ["user_capacity"],
            ["capacity", "bytes"],
            ["capacity"]
        ])
        let smartctlVersion = parseVersion(firstValue(in: object, paths: [["smartctl", "version"]]))
        let smartctlExitStatus = firstInt(in: object, paths: [["smartctl", "exit_status"]])
        let smartPassed = firstBool(in: object, paths: [["smart_status", "passed"]])
        let usageStartDate = firstDate(in: object, paths: [
            ["usage_start_date"],
            ["first_use_date"],
            ["first_power_on_date"],
            ["power_on_time", "start_date"],
            ["power_on_time", "date"],
            ["device", "usage_start_date"],
            ["device", "first_use_date"]
        ])

        let temperature = firstInt(in: object, paths: [
            ["temperature", "current"],
            ["nvme_smart_health_information_log", "temperature"],
            ["temperature"]
        ])
        let powerOnHours = firstUInt64(in: object, paths: [
            ["power_on_time", "hours"],
            ["nvme_smart_health_information_log", "power_on_hours"],
            ["power_on_hours"]
        ])
        let powerCycles = firstUInt64(in: object, paths: [
            ["power_cycle_count"],
            ["nvme_smart_health_information_log", "power_cycles"],
            ["power_cycles"]
        ])
        let unsafeShutdowns = firstUInt64(in: object, paths: [
            ["unsafe_shutdowns"],
            ["nvme_smart_health_information_log", "unsafe_shutdowns"]
        ])
        let percentageUsed = firstUInt64(in: object, paths: [
            ["nvme_smart_health_information_log", "percentage_used"],
            ["percentage_used"]
        ])
        let availableSpare = firstUInt64(in: object, paths: [
            ["nvme_smart_health_information_log", "available_spare"],
            ["available_spare"]
        ])
        let availableSpareThreshold = firstUInt64(in: object, paths: [
            ["nvme_smart_health_information_log", "available_spare_threshold"],
            ["available_spare_threshold"]
        ])
        let criticalWarning = firstUInt64(in: object, paths: [
            ["nvme_smart_health_information_log", "critical_warning"],
            ["critical_warning"]
        ])
        let mediaErrors = firstUInt64(in: object, paths: [
            ["nvme_smart_health_information_log", "media_errors"],
            ["nvme_smart_health_information_log", "media_and_data_integrity_errors"],
            ["media_errors"],
            ["media_and_data_integrity_errors"]
        ])
        let dataUnitsRead = firstUInt64(in: object, paths: [
            ["nvme_smart_health_information_log", "data_units_read"],
            ["data_units_read"]
        ])
        let dataUnitsWritten = firstUInt64(in: object, paths: [
            ["nvme_smart_health_information_log", "data_units_written"],
            ["data_units_written"]
        ])

        let messages = parseMessages(in: object)
        var warnings: [String] = []
        if let smartctlExitStatus, smartctlExitStatus != 0 {
            warnings.append("smartctl exit_status = \(smartctlExitStatus)")
        }
        if let format = parseVersionArray(firstValue(in: object, paths: [["json_format_version"]])) {
            if format.first != 1 {
                warnings.append("未知の json_format_version: \(format.map(String.init).joined(separator: "."))")
            }
        }
        if model == nil {
            warnings.append("model_name が取得できませんでした")
        }
        if !messages.isEmpty {
            warnings.append(contentsOf: messages.filter { $0.lowercased().contains("failed") })
        }

        let deviceID: String
        deviceID = DeviceIdentity.stableID(
            serialNumber: serialNumber,
            model: model,
            logicalCapacityBytes: logicalCapacityBytes
        )

        return DriveSnapshot(
            capturedAt: capturedAt,
            deviceID: deviceID,
            devicePath: devicePath,
            logicalCapacityBytes: logicalCapacityBytes,
            model: model,
            serialNumber: serialNumber,
            firmware: firmware,
            smartctlVersion: smartctlVersion,
            smartctlExitStatus: smartctlExitStatus,
            usageStartDate: usageStartDate,
            temperatureCelsius: temperature,
            powerOnHours: powerOnHours,
            powerCycleCount: powerCycles,
            unsafeShutdowns: unsafeShutdowns,
            percentageUsed: percentageUsed,
            availableSpare: availableSpare,
            availableSpareThreshold: availableSpareThreshold,
            criticalWarning: criticalWarning,
            mediaAndDataIntegrityErrors: mediaErrors,
            dataUnitsRead: dataUnitsRead,
            dataUnitsWritten: dataUnitsWritten,
            smartPassed: smartPassed,
            messages: messages,
            parseWarnings: warnings,
            rawJSON: String(data: data, encoding: .utf8) ?? "",
            additionalSMART: additionalCounters(in: object),
            nvmeCapabilities: capabilities(in: object)
        )
    }

    private func additionalCounters(in object: [String: Any]) -> SMARTAdditionalCounters? {
        func counter(_ key: String) -> UInt64? {
            firstUInt64(in: object, paths: [["nvme_smart_health_information_log", key]])
        }
        let result = SMARTAdditionalCounters(hostReadCommands: counter("host_reads"),
            hostWriteCommands: counter("host_writes"), controllerBusyMinutes: counter("controller_busy_time"),
            errorLogEntries: counter("num_err_log_entries"))
        return result.hostReadCommands == nil && result.hostWriteCommands == nil
            && result.controllerBusyMinutes == nil && result.errorLogEntries == nil ? nil : result
    }

    private func capabilities(in object: [String: Any]) -> NVMeCapabilities? {
        let result = NVMeCapabilities(
            adminCommands: firstUInt64(in: object, paths: [["nvme_optional_admin_commands", "value"]]),
            nvmCommands: firstUInt64(in: object, paths: [["nvme_optional_nvm_commands", "value"]]),
            logPageAttributes: firstUInt64(in: object, paths: [["nvme_log_page_attributes", "value"]]),
            firmwareSlots: firstUInt64(in: object, paths: [["nvme_firmware_update_capabilities", "slots"]]),
            maximumTransferPages: firstUInt64(in: object, paths: [["nvme_maximum_data_transfer_pages"]]))
        return result.adminCommands == nil && result.nvmCommands == nil && result.logPageAttributes == nil
            && result.firmwareSlots == nil && result.maximumTransferPages == nil ? nil : result
    }

    private func parseMessages(in object: [String: Any]) -> [String] {
        guard let rawMessages = value(in: object, path: ["smartctl", "messages"]) as? [[String: Any]] else {
            return []
        }
        return rawMessages.compactMap { message in
            guard let string = message["string"] as? String else { return nil }
            return string
        }
    }

    private func parseVersion(_ value: Any?) -> String? {
        guard let parts = parseVersionArray(value) else { return nil }
        return parts.map(String.init).joined(separator: ".")
    }

    private func parseVersionArray(_ value: Any?) -> [Int]? {
        guard let array = value as? [Any] else { return nil }
        let parts = array.compactMap { numberAsInt($0) }
        return parts.isEmpty ? nil : parts
    }

    private func firstValue(in object: [String: Any], paths: [[String]]) -> Any? {
        for path in paths {
            if let value = value(in: object, path: path) {
                return value
            }
        }
        return nil
    }

    private func value(in object: [String: Any], path: [String]) -> Any? {
        var current: Any = object
        for key in path {
            guard let dictionary = current as? [String: Any], let next = dictionary[key] else {
                return nil
            }
            current = next
        }
        return current
    }

    private func firstString(in object: [String: Any], paths: [[String]]) -> String? {
        for path in paths {
            if let string = value(in: object, path: path) as? String, !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private func firstUInt64(in object: [String: Any], paths: [[String]]) -> UInt64? {
        for path in paths {
            if let number = numberAsUInt64(value(in: object, path: path)) {
                return number
            }
        }
        return nil
    }

    private func firstInt(in object: [String: Any], paths: [[String]]) -> Int? {
        for path in paths {
            if let number = numberAsInt(value(in: object, path: path)) {
                return number
            }
        }
        return nil
    }

    private func firstBool(in object: [String: Any], paths: [[String]]) -> Bool? {
        for path in paths {
            guard let rawValue = value(in: object, path: path) else { continue }
            if let value = rawValue as? Bool {
                return value
            }
            if let string = rawValue as? String {
                switch string.lowercased() {
                case "true", "yes", "passed": return true
                case "false", "no", "failed": return false
                default: break
                }
            }
        }
        return nil
    }

    private func firstDate(in object: [String: Any], paths: [[String]]) -> Date? {
        for path in paths {
            guard let rawValue = value(in: object, path: path) else { continue }
            if let date = date(from: rawValue) {
                return date
            }
        }
        return nil
    }

    private func date(from value: Any) -> Date? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        for format in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    private func numberAsUInt64(_ value: Any?) -> UInt64? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            let doubleValue = number.doubleValue
            // Double(UInt64.max) rounds up to 2^64, so a bound check against
            // it still lets a value through that UInt64 cannot hold.
            guard doubleValue.isFinite, doubleValue >= 0 else { return nil }
            return UInt64(exactly: doubleValue.rounded())
        }
        if let string = value as? String {
            let cleaned = string
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let direct = UInt64(cleaned) { return direct }
            if cleaned.lowercased().hasPrefix("0x"),
               let hexadecimal = UInt64(cleaned.dropFirst(2), radix: 16) {
                return hexadecimal
            }
            if let doubleValue = Double(cleaned), doubleValue.isFinite, doubleValue >= 0 {
                return UInt64(exactly: doubleValue.rounded())
            }
        }
        return nil
    }

    private func numberAsInt(_ value: Any?) -> Int? {
        guard let unsigned = numberAsUInt64(value), unsigned <= UInt64(Int.max) else { return nil }
        return Int(unsigned)
    }
}
