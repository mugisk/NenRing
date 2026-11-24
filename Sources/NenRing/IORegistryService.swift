import Foundation
import IOKit

actor IORegistryService {
    let parser: IORegistryProfileParser
    typealias ProfileReader = @Sendable (String?, StorageTargetBinding, IORegistryProfileParser) async -> AppleNANDHardwareProfile?
    private let reader: ProfileReader
    private var cache: [String: (binding: StorageTargetBinding, profile: AppleNANDHardwareProfile)] = [:]

    init(
        parser: IORegistryProfileParser = IORegistryProfileParser(),
        reader: @escaping ProfileReader = IORegistryService.readProfile
    ) {
        self.parser = parser
        self.reader = reader
    }

    /// The class follows the macOS release, not the chip: the reference M1
    /// Mac reported AppleANS3NVMeController on 25G83 and reports
    /// AppleANS3CGv2Controller on macOS 27. Both match AppleANS2NVMeController
    /// as their parent class (see docs/APPLE_SSD_HARDWARE.md).
    static let controllerClasses = [
        "AppleANS3NVMeController",
        "AppleANS3CGv2Controller",
        "AppleANS2NVMeController",
        "AppleANSNVMeController"
    ]

    /// IORegistry is optional context. Failure here must never make a SMART
    /// refresh fail. A live binding is required; no global first-match query
    /// or model-name fallback may supply another controller's metadata.
    /// A scheduled collector can explicitly refresh the cached profile without
    /// coupling that work to the SMART polling interval.
    func profile(
        modelNumber: String?,
        forceRefresh: Bool = false,
        binding: StorageTargetBinding
    ) async -> AppleNANDHardwareProfile? {
        if !forceRefresh, let cached = cachedProfile(binding: binding) { return cached }
        let found = await reader(modelNumber, binding, parser)
        if let found {
            cache[cacheKey(binding)] = (binding, found)
        }
        // Return the read's actual outcome. Keep the previous successful value
        // separately: a failed refresh must not erase last-known geometry or
        // masquerade as a fresh identity observation.
        return found
    }

    func cachedProfile(binding: StorageTargetBinding) -> AppleNANDHardwareProfile? {
        guard let entry = cache[cacheKey(binding)], entry.binding == binding else { return nil }
        return entry.profile
    }

    private func cacheKey(_ binding: StorageTargetBinding) -> String {
        "\(binding.controllerEntryID):\(binding.smartServiceID):\(binding.wholeMediaID)"
    }

    nonisolated static func readProfile(
        modelNumber: String?, binding: StorageTargetBinding, parser: IORegistryProfileParser
    ) async -> AppleNANDHardwareProfile? {
        let found = await Task.detached(priority: .utility) {
            let entry = IOServiceGetMatchingService(kIOMainPortDefault,
                IORegistryEntryIDMatching(binding.controllerEntryID))
            guard entry != 0 else { return Optional<AppleNANDHardwareProfile>.none }
            defer { IOObjectRelease(entry) }
            guard IOObjectConformsTo(entry, binding.controllerClass) != 0 else { return nil }
            var properties = LocalStorageTargetResolver.properties(entry)
            if properties["Controller Characteristics"] == nil {
                let service = IOServiceGetMatchingService(kIOMainPortDefault,
                    IORegistryEntryIDMatching(binding.smartServiceID))
                guard service != 0 else { return nil }
                defer { IOObjectRelease(service) }
                properties = LocalStorageTargetResolver.properties(service)
                properties["IOClass"] = binding.controllerClass
            }
            var profile = try? parser.parse(properties: properties, modelNumber: modelNumber, capturedAt: Date())
            // Read only the selected SMART service, never another global disk.
            let smartService = IOServiceGetMatchingService(kIOMainPortDefault,
                IORegistryEntryIDMatching(binding.smartServiceID))
            if smartService != 0 {
                defer { IOObjectRelease(smartService) }
                profile?.unmapSupported = Self.unmapSupport(in: LocalStorageTargetResolver.properties(smartService))
            }
            return profile
        }.value
        return found
    }

    nonisolated static func unmapSupport(in properties: [String: Any]) -> Bool? {
        (properties["IOStorageFeatures"] as? [String: Any])?["Unmap"] as? Bool
    }
}

struct IORegistryProfileParser: Sendable {
    /// Selected-entry properties are converted to the existing small grammar;
    /// the legacy text parser remains available for archived fixtures.
    func parse(properties: [String: Any], modelNumber: String?, capturedAt: Date?) throws -> AppleNANDHardwareProfile? {
        func quoted(_ value: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        }
        func encoded(_ value: Any) -> String? {
            if let string = value as? String { return quoted(string) }
            if let number = value as? NSNumber { return number.stringValue }
            if let array = value as? [NSNumber] { return "(" + array.map(\.stringValue).joined(separator: ",") + ")" }
            return nil
        }
        let characteristics: String
        if let dictionary = properties["Controller Characteristics"] as? [String: Any] {
            characteristics = "{" + dictionary.sorted { $0.key < $1.key }.compactMap { key, value in
                encoded(value).map { "\(quoted(key))=\($0)," }
            }.joined() + "}"
        } else if let string = properties["Controller Characteristics"] as? String {
            characteristics = string
        } else { return nil }
        let extras = properties.filter { $0.key != "Controller Characteristics" }.compactMap { key, value in
            encoded(value).map { "\(quoted(key))=\($0)," }
        }.joined()
        return try parse(data: Data(("\"Controller Characteristics\"=" + characteristics + "," + extras).utf8),
                         modelNumber: modelNumber, capturedAt: capturedAt)
    }

    func parse(data: Data, modelNumber: String?, capturedAt: Date? = nil) throws -> AppleNANDHardwareProfile? {
        guard let text = String(data: data, encoding: .utf8) else {
            throw IORegistryServiceError.invalidData
        }
        guard let dictionary = controllerCharacteristics(in: text) else {
            return nil
        }

        let values = parsePairs(in: dictionary)
        guard !values.isEmpty else { return nil }

        return AppleNANDHardwareProfile(
            capturedAt: capturedAt,
            modelNumber: modelNumber?.trimmedNonEmpty ?? "",
            logicalCapacityBytes: uint64(values["capacity"]) ?? 0,
            nandVendor: clean(values["vendor-name"]),
            nandMarketingName: clean(values["nand-marketing-name"]),
            defaultBitsPerCell: int(values["default-bits-per-cell"]),
            controllerClass: quotedValue(for: "IOClass", in: text),
            chipID: clean(values["chip-id"]),
            firmwareVersion: clean(values["firmware-version"]),
            mspVersion: clean(values["msp-version"]),
            pageSize: uint64(values["page-size"]),
            pagesPerBlockNative: uint64(values["pages-per-block-mlc"]),
            pagesPerBlockSLC: uint64(values["pages-per-block-slc"]),
            sectorsPerPage: uint64(values["sec-per-page"]),
            blocksPerCAU: uint64(values["blocks-per-cau"]),
            cauPerDie: uint64(values["cau-per-die"]),
            numBus: int(values["num-bus"]),
            diesPerBus: integerArray(values["dies-per-bus"]),
            busToMSP: integerArray(values["bus-to-msp"]),
            numDIP: int(values["num-dip"]),
            sectorsPerFullBand: uint64(values["sec-per-full-band"]),
            sectorsPerFullBandSLC: uint64(values["sec-per-full-band-slc"]),
            packageBlocksAtEOL: uint64(values["package_blocks_at_EOL"]),
            appleNANDStatus: quotedValue(for: "AppleNANDStatus", in: text),
            physicalInterconnect: quotedValue(for: "Physical Interconnect", in: text),
            physicalInterconnectLocation: quotedValue(for: "Physical Interconnect Location", in: text),
            profileVersion: 1
        )
    }

    private func controllerCharacteristics(in text: String) -> String? {
        guard let marker = text.range(of: "\"Controller Characteristics\"") else { return nil }
        guard let openBrace = text[marker.upperBound...].firstIndex(of: "{") else { return nil }

        var result = ""
        var depth = 0
        var inQuotes = false
        var escaped = false
        for character in text[openBrace...] {
            result.append(character)
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" && inQuotes {
                escaped = true
                continue
            }
            if character == "\"" {
                inQuotes.toggle()
            } else if !inQuotes {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
            }
        }
        return depth == 0 ? result : nil
    }

    /// Parses the small NeXT/IOKit dictionary grammar without evaluating the
    /// output. Values are kept only for the allow-listed keys above.
    private func parsePairs(in dictionary: String) -> [String: String] {
        let characters = Array(dictionary)
        var index = 0
        var pairs: [String: String] = [:]

        while index < characters.count {
            skipSeparators(characters, index: &index)
            guard index < characters.count else { break }
            guard let key = readQuoted(characters, index: &index) else {
                index += 1
                continue
            }
            skipWhitespace(characters, index: &index)
            guard index < characters.count, characters[index] == "=" else { continue }
            index += 1
            skipWhitespace(characters, index: &index)
            guard let value = readValue(characters, index: &index) else { continue }
            pairs[key] = value
        }
        return pairs
    }

    private func readQuoted(_ characters: [Character], index: inout Int) -> String? {
        guard index < characters.count, characters[index] == "\"" else { return nil }
        index += 1
        var value = ""
        var escaped = false
        while index < characters.count {
            let character = characters[index]
            index += 1
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return value
            } else {
                value.append(character)
            }
        }
        return nil
    }

    private func readValue(_ characters: [Character], index: inout Int) -> String? {
        guard index < characters.count else { return nil }
        if characters[index] == "\"" {
            return readQuoted(characters, index: &index)
        }
        let opening = characters[index]
        if opening == "(" {
            let start = index
            index += 1
            while index < characters.count, characters[index] != ")" { index += 1 }
            guard index < characters.count else { return nil }
            index += 1
            return String(characters[start..<index])
        }
        if opening == "<" {
            while index < characters.count, characters[index] != ">" { index += 1 }
            if index < characters.count { index += 1 }
            return nil
        }

        let start = index
        while index < characters.count,
              characters[index] != ",",
              characters[index] != "}" {
            index += 1
        }
        return String(characters[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func skipSeparators(_ characters: [Character], index: inout Int) {
        while index < characters.count,
              characters[index] == " " || characters[index] == "\t" ||
              characters[index] == "\n" || characters[index] == "\r" ||
              characters[index] == "," || characters[index] == "{" ||
              characters[index] == "}" {
            index += 1
        }
    }

    private func skipWhitespace(_ characters: [Character], index: inout Int) {
        while index < characters.count,
              characters[index] == " " || characters[index] == "\t" ||
              characters[index] == "\n" || characters[index] == "\r" {
            index += 1
        }
    }

    private func quotedValue(for key: String, in text: String) -> String? {
        clean(parsePairs(in: text)[key])
    }

    private func clean(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func uint64(_ value: String?) -> UInt64? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return UInt64(value)
    }

    private func int(_ value: String?) -> Int? {
        guard let number = uint64(value), number <= UInt64(Int.max) else { return nil }
        return Int(number)
    }

    private func integerArray(_ value: String?) -> [Int]? {
        guard let value else { return nil }
        let numbers = value
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return numbers.isEmpty ? nil : numbers
    }
}

enum IORegistryServiceError: LocalizedError, Equatable, Sendable {
    case invalidData

    var errorDescription: String? {
        switch self {
        case .invalidData: return "ioreg の出力を読み取れませんでした"
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var nilIfEmpty: String? { isEmpty ? nil : self }
}
