import Darwin
import Foundation

/// OS-wide counters. Neither source identifies the destination SSD.
struct SystemWriteActivity: Sendable {
    struct Writer: Sendable {
        let start: UInt64
        let bytes: UInt64
        let name: String
    }

    let uptime: TimeInterval
    let writers: [Int32: Writer]
    let swapPages: UInt64?

    static func sample() -> Self {
        let capacity = max(64, Int(proc_listallpids(nil, 0)) + 128)
        var pids = [Int32](repeating: 0, count: capacity)
        let count = proc_listallpids(&pids, Int32(capacity * MemoryLayout<Int32>.stride))
        var writers = [Int32: Writer]()
        for pid in pids.prefix(min(capacity, max(0, Int(count)))) where pid > 0 {
            var usage = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &usage) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
            }
            guard result == 0 else { continue }
            var name = [CChar](repeating: 0, count: 256)
            let length = proc_name(pid, &name, UInt32(name.count))
            let label = String(decoding: name.prefix(Int(max(0, length))).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            writers[pid] = Writer(start: usage.ri_proc_start_abstime, bytes: usage.ri_diskio_byteswritten,
                                  name: label.isEmpty ? "PID \(pid)" : label)
        }
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout.size(ofValue: stats) / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &stats) {
            host_statistics64(host, HOST_VM_INFO64, UnsafeMutableRawPointer($0).assumingMemoryBound(to: integer_t.self), &size)
        }
        return Self(uptime: ProcessInfo.processInfo.systemUptime, writers: writers,
                    swapPages: result == KERN_SUCCESS ? stats.swapouts : nil)
    }

    struct Identity: Hashable, Sendable {
        let pid: Int32
        let start: UInt64
    }

    struct Entry: Sendable {
        let id: Identity
        let name: String
        let rate: Double
    }

    struct Rates: Sendable {
        var writers: [Entry]
        var swap: Double?
        var comparable: Bool
    }

    func rates(since previous: Self) -> Rates? {
        let seconds = uptime - previous.uptime
        guard seconds > 0, seconds <= 20 else { return nil }
        var result = Rates(writers: [], comparable: false)
        for (pid, writer) in writers {
            guard let old = previous.writers[pid], old.start == writer.start, writer.bytes >= old.bytes else { continue }
            result.comparable = true
            if writer.bytes > old.bytes {
                result.writers.append(Entry(id: Identity(pid: pid, start: writer.start), name: writer.name,
                                            rate: Double(writer.bytes - old.bytes) / seconds))
            }
        }
        result.writers.sort { $0.rate > $1.rate }
        if let swapPages, let old = previous.swapPages, swapPages >= old {
            result.swap = Double(swapPages - old) * Double(getpagesize()) / seconds
        }
        return result
    }
}

/// Average over observed intervals, retaining short bursts after the writer exits.
struct RecentWriteActivity {
    private var intervals: [(start: TimeInterval, end: TimeInterval, rates: SystemWriteActivity.Rates)] = []

    mutating func ingest(_ current: SystemWriteActivity, after previous: SystemWriteActivity?) -> SystemWriteActivity.Rates? {
        guard let previous, let rates = current.rates(since: previous) else {
            intervals.removeAll()
            return nil
        }
        let cutoff = current.uptime - 30
        intervals.removeAll { $0.end <= cutoff }
        intervals.append((previous.uptime, current.uptime, rates))
        var bytes = [SystemWriteActivity.Identity: Double]()
        var names = [SystemWriteActivity.Identity: String]()
        var writerSeconds = 0.0, swapSeconds = 0.0, swapBytes = 0.0
        for interval in intervals {
            let duration = interval.end - max(interval.start, cutoff)
            if interval.rates.comparable { writerSeconds += duration }
            for writer in interval.rates.writers {
                bytes[writer.id, default: 0] += writer.rate * duration
                names[writer.id] = writer.name
            }
            if let rate = interval.rates.swap {
                swapBytes += rate * duration
                swapSeconds += duration
            }
        }
        var writers: [SystemWriteActivity.Entry] = bytes.map { id, amount in
            SystemWriteActivity.Entry(id: id, name: names[id] ?? "PID \(id.pid)", rate: amount / writerSeconds)
        }
        writers.sort { lhs, rhs in
            if lhs.rate == rhs.rate { return lhs.id.pid < rhs.id.pid }
            return lhs.rate > rhs.rate
        }
        return SystemWriteActivity.Rates(writers: Array(writers.prefix(3)),
                                         swap: swapSeconds > 0 ? swapBytes / swapSeconds : nil,
                                         comparable: writerSeconds > 0)
    }
}
