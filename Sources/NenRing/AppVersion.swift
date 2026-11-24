import Foundation

enum AppVersion {
    private static let fallbackShortVersion = "0.2.0"

    static var shortVersion: String {
        infoValue("CFBundleShortVersionString") ?? fallbackShortVersion
    }

    static var buildNumber: String {
        infoValue("CFBundleVersion") ?? "開発"
    }

    static var sourceRevision: String? {
        infoValue("NenRingBuildCommit")
    }

    static var detailLabel: String {
        if let sourceRevision, !sourceRevision.isEmpty, sourceRevision != "dev" {
            return "\(shortVersion) (build \(buildNumber), \(sourceRevision))"
        }
        return "\(shortVersion) (build \(buildNumber))"
    }

    private static func infoValue(_ key: String) -> String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
