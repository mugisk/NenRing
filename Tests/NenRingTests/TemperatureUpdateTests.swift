import AppKit
import SwiftUI
import XCTest
@testable import NenRing

final class TemperatureUpdateTests: XCTestCase {
    @MainActor
    func testExplanationWrapsDespiteInheritedSingleLineLimit() throws {
        for explanation in [
            "電源OFFで365日・30°Cの条件で保管する仮想シナリオ。TLCの保持条件を考慮した研究推計で、データ保持の保証ではありません。",
            "A hypothetical power-off storage scenario at 365 days and 30°C. This research estimate accounts for TLC retention conditions; it is not a data-retention guarantee."
        ] {
            let wrapped = NSHostingView(rootView: ForecastExplanationContent(title: "保持考慮", explanation: explanation).lineLimit(1))
            let wrappedBody = NSHostingView(rootView: ForecastExplanationBody(title: "保持考慮", explanation: explanation).frame(width: 380).lineLimit(1))
            let shortBody = NSHostingView(rootView: ForecastExplanationBody(title: "保持考慮", explanation: "Short").frame(width: 380).lineLimit(1))
            XCTAssertEqual(wrapped.fittingSize.width, 380, accuracy: 1)
            XCTAssertGreaterThan(wrappedBody.fittingSize.height, shortBody.fittingSize.height + 5)
            if let root = ProcessInfo.processInfo.environment["NENRING_EXPLANATION_PREVIEW_ROOT"] {
                let directory = URL(fileURLWithPath: root)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try render(ForecastExplanationContent(title: "保持考慮", explanation: explanation)
                    .lineLimit(1).background(Color.white).preferredColorScheme(.light),
                           to: directory.appendingPathComponent(explanation.hasPrefix("電源") ? "ja.png" : "en.png"))
            }
        }
    }

    @MainActor
    func testOptInEmptyStatePreview() throws {
        guard let root = ProcessInfo.processInfo.environment["NENRING_EMPTY_PREVIEW_ROOT"] else {
            throw XCTSkip("Empty-state rendering requires an explicit output directory")
        }
        let directory = URL(fileURLWithPath: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "NenRing-empty-preview-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DashboardModel(preferences: preferences)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            try render(ReferenceDashboardView(model: model, onNavigate: { _ in })
                .frame(width: 1220).padding(16).environment(\.locale, UIString.locale)
                .background(AppColor.canvas).preferredColorScheme(scheme),
                to: directory.appendingPathComponent("empty-dashboard-\(name).png"))
            try render(MenuBarMonitorView(model: model, startsMonitoring: false)
                .environment(\.locale, UIString.locale).preferredColorScheme(scheme),
                to: directory.appendingPathComponent("empty-menubar-\(name).png"))
        }
        try render(DiskInformationContent(snapshot: nil, profile: nil)
            .frame(width: 900).padding(24).environment(\.locale, UIString.locale),
            to: directory.appendingPathComponent("empty-disk.png"))
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertTrue(model.asptoolSnapshots.isEmpty)
        XCTAssertNil(model.snapshot)
    }
    func testTemperatureOnlyUpdatePreservesAllOtherAnalytics() {
        let now = Date()
        var result = DashboardAnalyticsSnapshot.empty
        let original = result
        result.updateTemperatureChart(
            analyzer: HistoryAnalyzer(), history: [],
            temperatureHistory: [
                TemperatureSample(capturedAt: now, deviceID: "disk", temperatureCelsius: 42),
                TemperatureSample(capturedAt: now, deviceID: "other", temperatureCelsius: 90)
            ], deviceID: "disk", now: now
        )
        XCTAssertEqual(result.temperaturePoints.map(\.celsius), [42])
        result.temperaturePoints = original.temperaturePoints
        XCTAssertEqual(result, original, "Temperature polling must not change wear/retention/WAF/journal results")
    }

    func testExtendedSMARTIntervalsAndLegacySetting() {
        XCTAssertEqual(RefreshInterval(rawValue: 900), .fifteenMinutes)
        for seconds in [1800, 3600] {
            XCTAssertEqual(RefreshInterval(rawValue: seconds)?.seconds, Double(seconds))
        }
        // Longer intervals saved by earlier builds are read as one hour.
        for seconds in [10800, 21600, 43200, 86400] {
            XCTAssertEqual(RefreshInterval(savedSeconds: seconds), .oneHour)
        }
    }

    @MainActor
    func testOptInDiskInformationPreview() throws {
        guard let root = ProcessInfo.processInfo.environment["NENRING_UI_PREVIEW_ROOT"],
              let historyPath = ProcessInfo.processInfo.environment["NENRING_LOCAL_HISTORY_DIR"] else {
            throw XCTSkip("UI preview requires explicit local read-only input and output paths")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: URL(fileURLWithPath: historyPath).appendingPathComponent("history.jsonl"))
        let smart = try XCTUnwrap(data.split(separator: 10).compactMap {
            try? decoder.decode(DriveSnapshot.self, from: Data($0))
        }.max { $0.capturedAt < $1.capturedAt })
        let ioreg = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("ioreg-preview.txt"))
        let profile = try IORegistryProfileParser().parse(data: ioreg, modelNumber: smart.model, capturedAt: Date())
        XCTAssertNotNil(profile)
        try render(DiskInformationContent(snapshot: smart, profile: profile)
            .padding(24).frame(width: 1000).background(Color.white).preferredColorScheme(.light),
            to: URL(fileURLWithPath: root).appendingPathComponent("disk-information-preview.png"))

        let suite = "NenRing-UI-preview-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DashboardModel(preferences: preferences)
        for category in SettingsCategory.allCases {
            try render(MonitorSettingsView(model: model, initialCategory: category)
                .environment(\.locale, UIString.locale).preferredColorScheme(.light),
                to: URL(fileURLWithPath: root).appendingPathComponent("\(category.rawValue)-settings-preview.png"))
        }
        try render(AboutView().environment(\.locale, UIString.locale).preferredColorScheme(.light),
            to: URL(fileURLWithPath: root).appendingPathComponent("about-preview.png"))
    }

    @MainActor
    func testOptInForecastCopyPreview() throws {
        guard let root = ProcessInfo.processInfo.environment["NENRING_UI_PREVIEW_ROOT"],
              let historyPath = ProcessInfo.processInfo.environment["NENRING_LOCAL_HISTORY_DIR"] else {
            throw XCTSkip("Forecast preview requires explicit read-only history and output paths")
        }
        let directory = URL(fileURLWithPath: historyPath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func read<T: Decodable>(_ name: String, _: T.Type) throws -> [T] {
            try Data(contentsOf: directory.appendingPathComponent(name)).split(separator: 10)
                .map { try decoder.decode(T.self, from: Data($0)) }
        }
        let history = try read("history.jsonl", DriveSnapshot.self)
        let smart = try XCTUnwrap(history.max { $0.capturedAt < $1.capturedAt })
        let settings = try decoder.decode([String: UsageSettings].self,
            from: Data(contentsOf: directory.appendingPathComponent("usage-settings.json")))
        let profile: AppleNANDHardwareProfile?
        if let path = ProcessInfo.processInfo.environment["NENRING_IOREG_PROFILE_PATH"] {
            profile = try IORegistryProfileParser().parse(
                data: Data(contentsOf: URL(fileURLWithPath: path)),
                modelNumber: smart.model, capturedAt: smart.capturedAt)
        } else {
            profile = nil
        }
        var selectedSettings = settings[smart.deviceID] ?? UsageSettings()
        if ProcessInfo.processInfo.environment["NENRING_PREVIEW_IDLE_AUTOMATIC"] == "1" {
            selectedSettings.retentionStorageTemperatureCelsius = nil
        }
        let analytics = DashboardAnalyticsSnapshot.build(
            analyzer: HistoryAnalyzer(), history: history,
            temperatureHistory: try read("temperature-history.jsonl", TemperatureSample.self),
            deviceID: smart.deviceID, period: .day, profile: profile,
            settings: selectedSettings, now: smart.capturedAt,
            asptoolSnapshots: try read("asptool-snapshots.jsonl", ASPToolDiagnosticsSnapshot.self),
            researchSessions: try read("research-sessions.jsonl", ResearchSession.self)
        )
        XCTAssertNotNil(analytics.nandEndurance.retentionScenario)
        let suite = "NenRing-forecast-preview-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DashboardModel(preferences: preferences, initialAnalytics: analytics)
        if ProcessInfo.processInfo.environment["NENRING_FORECAST_ONLY"] == "1" {
            try render(ReferenceStorageHeadroomCard(capacity: SSDCapacityProfile(snapshot: smart, hardwareProfile: profile))
                .frame(width: 310).padding(16).environment(\.locale, UIString.locale)
                .background(AppColor.canvas).preferredColorScheme(.light),
                to: URL(fileURLWithPath: root).appendingPathComponent("headroom-light.png"))
            if let idle = analytics.nandEndurance.idleRetentionTemperature {
                print("IDLE_PREVIEW source=\(idle.source) temperature=\(idle.temperature) days=\(idle.observedDays) hours=\(idle.observedSeconds / 3600) confidence=\(idle.confidence)")
                print("IDLE_HISTORY days=\(idle.historySpanDays) samples=\(idle.historySampleCount) relative=\(idle.relativeLowIO) limitMiBs=\(idle.ioThresholdBytesPerSecond / 1048576)")
                let range = idle.temperatureRange.map {
                    UIString.format("日別代表温度 %@〜%@。", TemperatureUnit.current.text($0.lowerBound), TemperatureUnit.current.text($0.upperBound))
                } ?? ""
                print("IDLE_TEMPERATURE_RANGE \(range)")
                try render(ForecastExplanationContent(title: UIString.text("保持温度の観測根拠"),
                    explanation: idle.displayEvidenceSummary(in: .current) + "\n" + range)
                    .padding(16).background(AppColor.canvas).preferredColorScheme(.light),
                    to: URL(fileURLWithPath: root).appendingPathComponent("temperature-evidence.png"))
            }
            let forecast = analytics.nandEndurance
            print("FORECAST_EVIDENCE \(forecast.observationEvidence.displayDetails)")
            if let scenario = forecast.retentionScenario {
                print("RETENTION_PREVIEW remainingTB=\(scenario.remainingHostBytes / 1e12) allowancePE=\(scenario.allowableTLCPE)")
            }
            for width in [760.0, 640.0] {
                for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                    try render(ReferenceForecastCard(model: model)
                        .frame(width: width).padding(16).environment(\.locale, UIString.locale)
                        .background(AppColor.canvas).preferredColorScheme(scheme),
                        to: URL(fileURLWithPath: root).appendingPathComponent("forecast-\(Int(width))-\(name).png"))
                }
            }
            return
        }
        try render(NANDEnduranceDetailsView(result: analytics.nandEndurance)
            .padding(24).frame(width: 1100)
            .environment(\.locale, UIString.locale)
            .background(AppColor.canvas).preferredColorScheme(.light),
            to: URL(fileURLWithPath: root).appendingPathComponent("nand-details.png"))
        for destination in ResearchDestination.allCases {
            try render(ResearchView(model: model, destination: destination)
                .padding(24).frame(width: 1100).environment(\.locale, UIString.locale)
                .background(AppColor.canvas).preferredColorScheme(.light),
                to: URL(fileURLWithPath: root).appendingPathComponent("research-\(destination.rawValue).png"))
        }
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            try render(ReferenceForecastCard(model: model)
                .frame(width: 760).padding(16)
                .background(AppColor.canvas).preferredColorScheme(scheme),
                to: URL(fileURLWithPath: root).appendingPathComponent("forecast-\(name).png"))
        }
    }

    @MainActor
    private func render<V: View>(_ content: V, to url: URL) throws {
        let view = NSHostingView(rootView: content)
        let size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = window.contentLayoutRect
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
