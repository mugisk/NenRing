import Foundation
import SwiftUI

private final class ResourceBundleFinder {}

/// Display-only translation. Never use translated text as a persisted key.
enum UIString {
    static let preferenceKey = "uiLanguage"
    /// Finds the package's resource bundle without SwiftPM's generated
    /// `Bundle.module`: the native build system of Swift 6.3 and earlier
    /// writes the absolute build path into that accessor, which would publish
    /// the builder's folder inside the app.
    private static let resourceBundle: Bundle? = {
        let name = "NenRing_NenRing.bundle"
        let codeBundle = Bundle(for: ResourceBundleFinder.self)
        let candidates = [
            Bundle.main.resourceURL,                       // NenRing.app
            codeBundle.resourceURL,
            Bundle.main.bundleURL,                         // command-line runs
            codeBundle.bundleURL.deletingLastPathComponent(), // swift test
        ]
        for case let directory? in candidates {
            if let bundle = Bundle(url: directory.appendingPathComponent(name)) { return bundle }
        }
        return nil
    }()

    private static let languageBundles: [String: Bundle] = {
        var bundles: [String: Bundle] = [:]
        for code in ["ja", "en"] {
            if let path = resourceBundle?.path(forResource: code, ofType: "lproj"),
               let bundle = Bundle(path: path) { bundles[code] = bundle }
        }
        return bundles
    }()

    static var selectedLanguage: String {
        #if DEBUG
        if let previewLanguage = ProcessInfo.processInfo.environment["NENRING_UI_LANGUAGE"] {
            return previewLanguage
        }
        #endif
        let stored = UserDefaults.standard.string(forKey: preferenceKey) ?? "system"
        return stored == "system" ? (Locale.preferredLanguages.first ?? "ja") : stored
    }

    static var locale: Locale {
        selectedLanguage.lowercased().hasPrefix("ja") ? Locale(identifier: "ja_JP") : Locale(identifier: "en_US")
    }

    static func text(_ source: String, language: String? = nil) -> String {
        let requested = language ?? selectedLanguage
        let code = requested.lowercased().hasPrefix("ja") ? "ja" : "en"
        guard let bundle = languageBundles[code] else { return source }
        return bundle.localizedString(forKey: source, value: source, table: "Localizable")
    }

    static func format(_ source: String, _ arguments: CVarArg...) -> String {
        String(format: text(source), locale: locale, arguments: arguments)
    }

    /// Translate registered message envelopes only; keep paths, stderr and unknown payloads intact.
    static func message(_ source: String, language: String? = nil) -> String {
        let translated = text(source, language: language)
        if translated != source { return translated }
        let prefixes = [
            "履歴を読み込めませんでした: ", "履歴を保存できませんでした: ", "温度履歴を読み込めませんでした: ",
            "温度履歴を保存できませんでした: ", "温度履歴の整理に失敗しました: ", "計測履歴を読み込めないため、寿命予測の再計算を保留しました: ","温度履歴を読み込めないため、寿命予測の再計算を保留しました: ",
            "Controller診断スナップショットを読み込めませんでした: ",
            "直接取得したFTL統計を保存できませんでした: ",
            "asptoolログの解析に失敗しました: ", "診断レポートを保存できませんでした: ",
            "診断レポートを作成できませんでした: ", "寿命予測の設定を保存できませんでした: ",
            "Reliability Event Journalを保存できませんでした: ",
            "アイドル温度の観測根拠を読み込めませんでした: ",
            "アイドル温度の観測根拠を保存できませんでした: ",
            "温度の区間の表を更新できませんでした: ",
            "通知の許可を確認できませんでした: ", "簡易チェックの結果を保存できませんでした: ",
            "簡易チェックの通知を送れませんでした: ",
            "アプリ内のASP probeが見つかりません: ", "ASP probeの実行を拒否しました: ",
            "ASP probeの保存先を準備できませんでした: ", "probeを起動できませんでした: ", "smartctl の JSON を解釈できませんでした: "
        ]
        for prefix in prefixes where source.hasPrefix(prefix) {
            return String(format: text(prefix + "%@", language: language),
                          String(source.dropFirst(prefix.count)))
        }
        if let diagnostic = DiagnosticTextTranslation.translate(source, language: language ?? selectedLanguage) {
            return diagnostic
        }
        if source.contains("\n") {
            // Each line may itself hold " · "-separated fields.
            return source.components(separatedBy: "\n").map { readout($0, language: language) }.joined(separator: "\n")
        }
        if source.hasPrefix("• ") {
            return "• " + message(String(source.dropFirst(2)), language: language)
        }
        return source
    }

    /// UI fields only. Raw JSON, stderr and exported evidence do not use this.
    static func readout(_ source: String, language: String? = nil) -> String {
        let translated = message(source, language: language)
        if translated != source { return translated }
        for separator in [" · ", " / ", " → ", " ／ ", "・"] where source.contains(separator) {
            let fields = source.components(separatedBy: separator)
            return fields.map { readout($0, language: language) }.joined(separator: separator)
        }
        return source
    }

    static func yearMonth(_ date: Date, language: String? = nil, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        let japanese = (language ?? selectedLanguage).lowercased().hasPrefix("ja")
        formatter.locale = Locale(identifier: japanese ? "ja_JP" : "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = japanese ? "yyyy年M月" : "MMM yyyy"
        return formatter.string(from: date)
    }

    static func dateTime(_ date: Date?, language: String? = nil, timeZone: TimeZone = .current) -> String {
        guard let date else { return text("未取得", language: language) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter.string(from: date)
    }
}

/// Explicit bundle lookup also works when running the executable via SwiftPM.
func localizedText(_ source: String) -> Text {
    Text(verbatim: UIString.readout(source))
}

/// Legacy diagnostics have no guaranteed stable schema. Do not silently guess
/// their meaning or hide the original when a translation is unavailable.
func localizedDiagnosticText(_ source: String) -> Text {
    let display = UIString.readout(source)
    let english = !UIString.selectedLanguage.lowercased().hasPrefix("ja")
    if english, display.range(of: #"[ぁ-んァ-ヶ一-龯]"#, options: .regularExpression) != nil {
        return Text(verbatim: UIString.format("原診断（未登録の形式）: %@", display))
    }
    return Text(verbatim: display)
}
