import Foundation
import IOKit

/// A live acquisition address, never a durable history key. Registry IDs are
/// valid only for this boot. Paths/IDs stay local and out of shared reports.
struct StorageTargetBinding: Codable, Equatable, Sendable {
    let smartServiceID: UInt64
    let controllerEntryID: UInt64
    let wholeMediaID: UInt64
    let controllerClass: String
    let wholeMediaCount: Int
    let appleSMARTServiceCount: Int
    let mediaUUID: String?
}

struct StorageTargetResolution: Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case matched, unavailable, ambiguous, unsupported
    }
    let state: State
    let binding: StorageTargetBinding?
    let reason: String
    var appleSMARTServiceCount: Int? = nil
    var physicalWholeMediaCount: Int? = nil

    /// True only when the disk itself cannot be told apart from another one
    /// (no serial or persistent identifier). An unclear FTL scope alone does
    /// not set it, so SMART history keeps recording in that case.
    var identityAmbiguous = false

    /// A unique persistent ID for the selected disk can survive an unclear
    /// controller-wide FTL scope. Never use a duplicate UUID here.
    var persistentMediaUUID: String? = nil

    func identifyingDisk(serialNumber: String?) -> Self {
        var result = self
        if let serialNumber, !serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.identityAmbiguous = false
            return result
        }
        let count = appleSMARTServiceCount ?? binding?.appleSMARTServiceCount ?? 0
        if identityAmbiguous || (count > 1 && historyMediaUUID == nil) {
            result = Self(state: .ambiguous, binding: nil,
                reason: "複数のApple SSDを長期識別できません。シリアルまたは永続識別情報が必要です",
                appleSMARTServiceCount: count,
                physicalWholeMediaCount: physicalWholeMediaCount ?? binding?.wholeMediaCount,
                identityAmbiguous: true)
        }
        return result
    }

    var historyMediaUUID: String? {
        let value = persistentMediaUUID ?? binding?.mediaUUID
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// SMART history and temperature are recorded unless the disk identity
    /// is ambiguous; FTL association is gated separately by the binding.
    var recordsSMARTHistory: Bool { !identityAmbiguous }

    static let unavailable = Self(state: .unavailable, binding: nil, reason: "取得先の対応を確認できません")
}

protocol StorageTargetResolving: Sendable {
    func resolve(devicePath: String) -> StorageTargetResolution
}

/// Pure selection logic shared by the live registry reader and graph fixtures.
struct StorageRegistryNode: Equatable, Sendable {
    let id: UInt64
    var parents: [UInt64] = []
    var smartCapable = false
    var appleANS = false
    var wholeMedia = false
    var controllerClass = ""
    var mediaUUID: String?
    var synthesized = false
}

enum StorageRegistrySelection {
    /// Whether `id` has an Apple ANS controller among its known ancestors.
    static func isBehindAppleController(_ id: UInt64, in nodes: [UInt64: StorageRegistryNode]) -> Bool {
        var current = nodes[id]
        var seen = Set<UInt64>()
        while let node = current, seen.insert(node.id).inserted {
            if node.appleANS { return true }
            current = node.parents.first.flatMap { nodes[$0] }
        }
        return false
    }

    static func resolve(startID: UInt64, nodes: [StorageRegistryNode]) -> StorageTargetResolution {
        guard Set(nodes.map(\.id)).count == nodes.count else {
            return .init(state: .ambiguous, binding: nil, reason: "IORegistryの識別情報が重複しています")
        }
        let graph = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        func ancestors(_ id: UInt64) -> [StorageRegistryNode]? {
            var chain: [StorageRegistryNode] = []
            var seen = Set<UInt64>()
            var next: UInt64? = id
            while let current = next {
                guard chain.count < 64, seen.insert(current).inserted, let node = graph[current],
                      node.parents.count <= 1 else { return nil }
                chain.append(node)
                next = node.parents.first
            }
            return chain
        }
        guard let chain = ancestors(startID), !chain.contains(where: \.synthesized),
              let service = chain.first(where: \.smartCapable),
              let controller = ancestors(service.id)?.first(where: \.appleANS) else {
            return .init(state: .unsupported, binding: nil, reason: "選択中のディスクをApple ANSのSMART取得先へ対応付けできません")
        }
        let media = nodes.filter { node in
            guard node.wholeMedia, let chain = ancestors(node.id), !chain.contains(where: \.synthesized) else { return false }
            return chain.contains(where: { $0.id == service.id })
        }
        let appleServices = nodes.filter { $0.smartCapable && ancestors($0.id)?.contains(where: \.appleANS) == true }
        let controllerServices = appleServices.filter {
            ancestors($0.id)?.first(where: \.appleANS)?.id == controller.id
        }
        let identityMedia = chain.first(where: \.wholeMedia) ?? (media.count == 1 ? media.first : nil)
        let uuid = identityMedia?.mediaUUID.flatMap { $0.isEmpty ? nil : $0 }
        let uuidOwners = uuid.map { uuid in
            nodes.filter { node in
                node.wholeMedia && node.mediaUUID == uuid &&
                    ancestors(node.id)?.contains(where: \.synthesized) == false
            }.count
        }
        let uniqueUUID = uuidOwners == 1 ? uuid : nil
        if let uuidOwners, uuidOwners != 1 {
            return .init(state: .ambiguous, binding: nil, reason: "複数の物理ディスクで永続識別情報が重複しています",
                         appleSMARTServiceCount: appleServices.count, physicalWholeMediaCount: media.count,
                         identityAmbiguous: true)
        }
        guard controllerServices.count == 1 else {
            return .init(state: .ambiguous, binding: nil, reason: "FTLの取得先に複数のディスクが対応しています。集計範囲は未確認です",
                         appleSMARTServiceCount: appleServices.count, physicalWholeMediaCount: nil,
                         persistentMediaUUID: uniqueUUID)
        }
        // Multiple namespaces under a controller-wide FTL interface cannot be
        // attached to one namespace's SMART counters without scope evidence.
        guard media.count == 1, let selectedMedia = media.first,
              chain.contains(where: { $0.id == selectedMedia.id }) || startID == service.id else {
            return .init(state: .ambiguous, binding: nil, reason: "FTLの取得先に複数のディスクが対応しています。集計範囲は未確認です",
                         appleSMARTServiceCount: appleServices.count, physicalWholeMediaCount: media.count,
                         persistentMediaUUID: uniqueUUID)
        }
        return .init(state: .matched, binding: StorageTargetBinding(
            smartServiceID: service.id, controllerEntryID: controller.id,
            wholeMediaID: selectedMedia.id, controllerClass: controller.controllerClass,
            wholeMediaCount: media.count, appleSMARTServiceCount: appleServices.count,
            mediaUUID: selectedMedia.mediaUUID), reason: "選択中のディスクから取得先を対応付けました")
    }
}

struct LocalStorageTargetResolver: StorageTargetResolving {
    func resolve(devicePath: String) -> StorageTargetResolution {
        let start: io_registry_entry_t
        if let bsdName = Self.bsdName(devicePath) {
            start = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
        } else if devicePath.hasPrefix("IOService:") {
            start = IORegistryEntryFromPath(kIOMainPortDefault, devicePath)
        } else { return .unavailable }
        guard start != 0 else { return .unavailable }
        defer { IOObjectRelease(start) }
        var startID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(start, &startID) == KERN_SUCCESS else { return .unavailable }
        var entries: [UInt64: StorageRegistryNode] = [:]
        func addChain(_ entry: io_registry_entry_t) -> Bool {
            var current = entry
            IOObjectRetain(current)
            defer { if current != 0 { IOObjectRelease(current) } }
            for _ in 0..<64 {
                var id: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(current, &id) == KERN_SUCCESS else { return false }
                if entries[id] != nil { return true }
                var parent: io_registry_entry_t = 0
                let hasParent = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS
                var parentID: UInt64 = 0
                if hasParent && IORegistryEntryGetRegistryEntryID(parent, &parentID) != KERN_SUCCESS {
                    IOObjectRelease(parent)
                    return false
                }
                let properties = Self.properties(current)
                var classBuffer = [CChar](repeating: 0, count: 128)
                IOObjectGetClass(current, &classBuffer)
                let className = String(decoding: classBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let ans = IOObjectConformsTo(current, "AppleANS2NVMeController") != 0
                    || IORegistryService.controllerClasses.contains { IOObjectConformsTo(current, $0) != 0 }
                entries[id] = StorageRegistryNode(id: id, parents: hasParent ? [parentID] : [],
                    smartCapable: (properties["NVMe SMART Capable"] as? Bool) == true,
                    appleANS: ans, wholeMedia: IOObjectConformsTo(current, "IOMedia") != 0 && (properties["Whole"] as? Bool) == true,
                    controllerClass: className,
                    mediaUUID: (properties["UUID"] as? String).flatMap(UUID.init(uuidString:))?.uuidString,
                    synthesized: className.hasPrefix("AppleAPFS") || className.hasPrefix("AppleRAID"))
                IOObjectRelease(current)
                current = hasParent ? parent : 0
                if current == 0 { return true }
            }
            return false
        }
        guard addChain(start) else { return .unavailable }
        var iterator: io_iterator_t = 0
        let matcher: [String: Any] = ["IOPropertyMatch": ["NVMe SMART Capable": true]]
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matcher as CFDictionary, &iterator) == KERN_SUCCESS else { return .unavailable }
        defer { IOObjectRelease(iterator) }
        var candidateCount = 0
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            candidateCount += 1
            guard candidateCount <= 64, addChain(service) else { return .unavailable }
            // Only services behind an Apple controller can be a target, so
            // a large third-party (for example external) drive is not walked
            // and cannot push the walk over its limit.
            var serviceID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &serviceID) == KERN_SUCCESS else { return .unavailable }
            guard StorageRegistrySelection.isBehindAppleController(serviceID, in: entries) else { continue }
            var descendants: io_iterator_t = 0
            guard IORegistryEntryCreateIterator(service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &descendants) == KERN_SUCCESS else { return .unavailable }
            defer { IOObjectRelease(descendants) }
            var childCount = 0
            while true {
                let child = IOIteratorNext(descendants)
                if child == 0 { break }
                defer { IOObjectRelease(child) }
                childCount += 1
                guard childCount <= 256, addChain(child) else { return .unavailable }
            }
            // The registry changed while walking it; the subtree may be incomplete.
            guard IOIteratorIsValid(descendants) != 0 else { return .unavailable }
        }
        guard IOIteratorIsValid(iterator) != 0 else { return .unavailable }
        return StorageRegistrySelection.resolve(startID: startID, nodes: Array(entries.values))
    }

    static func bsdName(_ path: String) -> String? {
        let name = path.hasPrefix("/dev/") ? String(path.dropFirst(5)) : path
        let normalized = name.hasPrefix("rdisk") ? String(name.dropFirst()) : name
        guard normalized.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return normalized
    }

    static func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return [:] }
        return properties?.takeRetainedValue() as? [String: Any] ?? [:]
    }
}
