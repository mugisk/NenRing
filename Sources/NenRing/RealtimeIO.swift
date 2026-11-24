import Foundation
import Combine

enum RealtimeIODisplay: String, CaseIterable, Identifiable {
    case none, read, write, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "アイコンのみ"
        case .read: "読込速度"
        case .write: "書込速度"
        case .both: "読込・書込速度"
        }
    }
}

struct RealtimeIOInterval: Identifiable, Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let read: Double
    let written: Double
    let segment: TimeInterval
    var id: TimeInterval { end }
    var duration: TimeInterval { end - start }
    var readRate: Double { read / duration }
    var writeRate: Double { written / duration }
}

/// Bounded, in-memory data only. No SMART/FTL history or analytics side effects.
struct RealtimeIOAccumulator {
    private var baseline: (BlockIOCounters, TimeInterval)?
    private(set) var intervals: [RealtimeIOInterval] = []
    private(set) var latest: RealtimeIOInterval?
    private(set) var sessionRead: Double = 0
    private(set) var sessionWritten: Double = 0

    mutating func interrupt() { baseline = nil; latest = nil }

    mutating func ingest(_ counters: BlockIOCounters?, at now: TimeInterval, maximumGap: TimeInterval) {
        intervals.removeAll { $0.end <= now - 300 }
        latest = nil
        guard now.isFinite, let counters else { baseline = nil; return }
        defer { baseline = (counters, now) }
        guard let (previous, before) = baseline,
              counters.bootTime == previous.bootTime, counters.driverID == previous.driverID,
              counters.bytesRead >= previous.bytesRead, counters.bytesWritten >= previous.bytesWritten,
              now > before, now - before <= maximumGap else { return }
        let interval = RealtimeIOInterval(start: before, end: now,
            read: Double(counters.bytesRead - previous.bytesRead),
            written: Double(counters.bytesWritten - previous.bytesWritten),
            segment: intervals.last.flatMap { $0.end == before ? $0.segment : nil } ?? before)
        latest = interval
        intervals.append(interval)
        // At most 301 entries at the fastest supported (1 second) cadence.
        if intervals.count > 301 { intervals.removeFirst(intervals.count - 301) }
        sessionRead += interval.read
        sessionWritten += interval.written
    }

    /// The boundary interval is prorated. Coverage excludes sleep/failure gaps.
    func total(seconds: TimeInterval, at now: TimeInterval) -> (read: Double, written: Double, coverage: Double) {
        var read = 0.0, written = 0.0, coverage = 0.0
        for interval in intervals {
            let overlap = max(0, min(now, interval.end) - max(now - seconds, interval.start))
            let fraction = overlap / interval.duration
            read += interval.read * fraction
            written += interval.written * fraction
            coverage += overlap
        }
        return (read, written, coverage)
    }
}

/// Separately observed by small menu views; ticks never publish DashboardModel.
@MainActor
final class RealtimeIOMonitor: ObservableObject {
    @Published private(set) var data = RealtimeIOAccumulator()
    /// Only the menu bar item depends on this; the popup always shows the
    /// rates, so sampling runs either way. The key predates that split.
    @Published var showsInMenuBar: Bool {
        didSet { preferences.set(showsInMenuBar, forKey: "realtimeIOEnabled") }
    }
    @Published var interval: Int {
        didSet {
            if ![1, 2, 5].contains(interval) { interval = 2 }
            preferences.set(interval, forKey: "realtimeIOInterval")
            reschedule()
        }
    }
    @Published var display: RealtimeIODisplay {
        didSet { preferences.set(display.rawValue, forKey: "realtimeIODisplay") }
    }
    private let preferences: UserDefaults
    private let provider: any BlockIOStatisticsProviding
    private var target: String?
    private var active = false
    private var timer: Timer?
    @Published private(set) var writeActivity: SystemWriteActivity.Rates?
    private var popupOpen = false
    private var activityGeneration = 0
    private var recentActivity = RecentWriteActivity()
    private var previousActivity: SystemWriteActivity?

    func setPopupOpen(_ open: Bool) {
        popupOpen = open
        activityGeneration += 1
        recentActivity = RecentWriteActivity()
        previousActivity = nil
        writeActivity = nil
    }

    private var reading = false
    private var generation = 0

    init(preferences: UserDefaults = .standard,
         provider: any BlockIOStatisticsProviding = IOKitBlockIOStatisticsProvider()) {
        self.preferences = preferences
        self.provider = provider
        showsInMenuBar = preferences.bool(forKey: "realtimeIOEnabled")
        let saved = preferences.integer(forKey: "realtimeIOInterval")
        interval = [1, 2, 5].contains(saved) ? saved : 2
        display = RealtimeIODisplay(rawValue: preferences.string(forKey: "realtimeIODisplay") ?? "both") ?? .both
    }

    func configure(deviceID: String?, path: String?, active: Bool) {
        let next = deviceID.flatMap { id in path.map { id + "|" + $0 } }
        if next != target {
            data = RealtimeIOAccumulator()
            provider.invalidate()
        }
        let changed = next != target || self.active != active
        target = next
        devicePath = path
        self.active = active
        if changed { reschedule() }
    }

    private var devicePath: String?

    private func reschedule() {
        setPopupOpen(popupOpen)
        generation += 1
        timer?.invalidate()
        timer = nil
        data.interrupt()
        guard active, target != nil else { return }
        // Polled without main actor tasks, which wait while the menu is open.
        let timer = Timer(timeInterval: Double(interval), repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            MainActor.assumeIsolated { self?.pollInBackground() }
        }
        timer.tolerance = Double(interval) * 0.1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        pollInBackground()
    }

    /// Reads the counters off the main thread and ingests them in the common
    /// run loop modes, so the open menu shows each new sample.
    private func pollInBackground() {
        guard active, target != nil, !reading, let devicePath else { return }
        reading = true
        let version = generation
        let provider = provider
        let activityVersion = activityGeneration
        let sampleActivity = popupOpen && (previousActivity.map { ProcessInfo.processInfo.systemUptime - $0.uptime >= 4 } ?? true)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let counters = provider.counters(devicePath: devicePath)
            let uptime = ProcessInfo.processInfo.systemUptime
            let activity = sampleActivity ? SystemWriteActivity.sample() : nil
            MainRunLoop.perform {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reading = false
                    if let activity, activityVersion == self.activityGeneration {
                        self.writeActivity = self.recentActivity.ingest(activity, after: self.previousActivity)
                        self.previousActivity = activity
                    }
                    self.ingest(counters, at: uptime, version: version)
                }
            }
        }
    }

    func poll() async {
        guard active, target != nil, !reading, let devicePath else { return }
        reading = true
        defer { reading = false }
        let version = generation
        let provider = provider
        let result = await Task.detached(priority: .utility) {
            let counters = provider.counters(devicePath: devicePath)
            return (counters, ProcessInfo.processInfo.systemUptime)
        }.value
        ingest(result.0, at: result.1, version: version)
    }

    private func ingest(_ counters: BlockIOCounters?, at uptime: TimeInterval, version: Int) {
        guard version == generation else { return }
        data.ingest(counters, at: uptime, maximumGap: Double(interval) * 3)
    }

    static func rate(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        return amount(bytes) + "/s"
    }

    static func amount(_ bytes: Double) -> String {
        guard bytes.isFinite, bytes >= 0 else { return "—" }
        if bytes < 1000 { return String(format: "%.0f B", bytes) }
        for (limit, unit) in [(1e15, "PB"), (1e12, "TB"), (1e9, "GB"), (1e6, "MB"), (1e3, "kB")] {
            if bytes >= limit { return String(format: "%.1f %@", bytes / limit, unit) }
        }
        return "—"
    }
}
