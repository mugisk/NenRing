import Foundation

/// One shared copy of each distinct string in loaded history. Swift keeps
/// strings longer than 15 UTF-8 bytes in their own allocation, so every
/// decoded record otherwise carries its own copy of the same device path,
/// device ID or contract version. Values are unchanged; only the duplicate
/// copies are dropped, so storage and analysis see the same records.
struct HistoryStringPool {
    private var strings: [String: String] = [:]

    mutating func shared(_ value: String) -> String {
        if let existing = strings[value] { return existing }
        strings[value] = value
        return value
    }

    mutating func shared(_ value: String?) -> String? {
        value.map { shared($0) }
    }
}
