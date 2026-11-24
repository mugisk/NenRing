import Darwin
import Foundation
import IOKit

/// Cumulative host reads and writes of the SSD's block storage driver, read
/// with each temperature sample. Counters restart when the driver is created;
/// boot time and (for new samples) registry identity delimit comparisons.
struct BlockIOCounters: Codable, Equatable, Sendable {
    let bytesRead: UInt64
    let bytesWritten: UInt64
    let bootTime: Date
    var driverID: UInt64? = nil
    /// Monotonic awake time at collection, absent in previously saved readings.
    var observedUptime: TimeInterval? = nil
}

protocol BlockIOStatisticsProviding: Sendable {
    func counters(devicePath: String) -> BlockIOCounters?
    func invalidate()
}

extension BlockIOStatisticsProviding {
    func invalidate() {}
}

/// Reads the `Statistics` of the IOBlockStorageDriver that belongs to the
/// SMART device. A device path is either an IORegistry path to the NVMe
/// namespace (searched downward) or a `/dev/(r)diskN` path (searched upward
/// from its IOMedia). Returns nil unless exactly one driver is found.
final class IOKitBlockIOStatisticsProvider: BlockIOStatisticsProviding, @unchecked Sendable {
    // Access is serialized even when temperature and realtime reads overlap.
    private let lock = NSLock()
    private var cachedPath: String?
    private var cachedDriver: io_registry_entry_t = IO_OBJECT_NULL

    deinit { if cachedDriver != IO_OBJECT_NULL { IOObjectRelease(cachedDriver) } }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        invalidateDriver()
    }

    func counters(devicePath: String) -> BlockIOCounters? {
        lock.lock()
        defer { lock.unlock() }
        if cachedPath != devicePath {
            invalidateDriver()
            cachedPath = devicePath
        }
        if cachedDriver == IO_OBJECT_NULL { cachedDriver = Self.driver(for: devicePath) ?? IO_OBJECT_NULL }
        let driver = cachedDriver
        guard driver != IO_OBJECT_NULL, let bootTime = Self.bootTime() else { return nil }
        var driverID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(driver, &driverID) == KERN_SUCCESS else {
            invalidateDriver()
            return nil
        }
        // A retained registry object may outlive its attachment to the tree.
        var parent: io_registry_entry_t = IO_OBJECT_NULL
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &parent) == KERN_SUCCESS else {
            invalidateDriver()
            return nil
        }
        IOObjectRelease(parent)
        guard let statistics = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
              let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value,
              let written = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value else {
            invalidateDriver()
            return nil
        }
        return BlockIOCounters(bytesRead: read, bytesWritten: written, bootTime: bootTime, driverID: driverID,
                               observedUptime: ProcessInfo.processInfo.systemUptime)
    }

    private func invalidateDriver() {
        if cachedDriver != IO_OBJECT_NULL { IOObjectRelease(cachedDriver) }
        cachedDriver = IO_OBJECT_NULL
    }

    private static func driver(for devicePath: String) -> io_registry_entry_t? {
        if devicePath.hasPrefix("IOService:") {
            let start = IORegistryEntryFromPath(kIOMainPortDefault, devicePath)
            guard start != IO_OBJECT_NULL else { return nil }
            defer { IOObjectRelease(start) }
            var found: [io_registry_entry_t] = []
            collectDrivers(below: start, depth: 6, into: &found)
            guard found.count == 1 else {
                found.forEach { IOObjectRelease($0) }
                return nil
            }
            return found[0]
        }
        var name = (devicePath as NSString).lastPathComponent
        if name.hasPrefix("rdisk") { name.removeFirst() }
        guard name.hasPrefix("disk"), let matching = IOBSDNameMatching(kIOMainPortDefault, 0, name) else { return nil }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        while entry != IO_OBJECT_NULL {
            if IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0 { return entry }
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard result == KERN_SUCCESS else { return nil }
            entry = parent
        }
        return nil
    }

    private static func collectDrivers(below entry: io_registry_entry_t, depth: Int,
                                       into found: inout [io_registry_entry_t]) {
        guard depth > 0 else { return }
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != IO_OBJECT_NULL {
            if IOObjectConformsTo(child, "IOBlockStorageDriver") != 0 {
                found.append(child)
            } else {
                collectDrivers(below: child, depth: depth - 1, into: &found)
                IOObjectRelease(child)
            }
        }
    }

    private static func bootTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }
}
