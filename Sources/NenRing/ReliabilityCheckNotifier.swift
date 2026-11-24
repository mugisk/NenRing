import Foundation
import UserNotifications

/// Posts the light check's new findings as a macOS notification. The
/// notification centre needs an app bundle, so outside one (tests, `swift
/// run`) this does nothing.
struct ReliabilityCheckNotifier: Sendable {
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil || Bundle.main.bundleURL.pathExtension != "app"
            ? nil : UNUserNotificationCenter.current()
    }

    /// Asked when the user turns the check on, not at launch.
    func requestAuthorization() async throws -> Bool {
        guard let center else { return false }
        return try await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Returns false when notifications are not allowed, so the caller can
    /// say so instead of the check looking silent.
    @discardableResult
    func post(_ findings: [ReliabilityCheckFinding]) async throws -> Bool {
        guard let center, !findings.isEmpty else { return false }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return false }
        let content = UNMutableNotificationContent()
        content.title = UIString.text("NenRing 簡易チェック")
        content.body = findings.map(\.message).joined(separator: "\n")
        let request = UNNotificationRequest(identifier: "reliability-check-\(UUID().uuidString)",
                                            content: content, trigger: nil)
        try await center.add(request)
        return true
    }
}
