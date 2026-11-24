import XCTest
@testable import NenRing

final class LocalizationTests: XCTestCase {
    func testCollectionFailureAndStaleForecastCopyIsTranslated() {
        XCTAssertEqual(UIString.text("最終成功 %@", language: "en"), "Last successful read %@")
        XCTAssertEqual(UIString.text("自動取得停止中", language: "en"), "Automatic collection stopped")
        let explanation = UIString.text("Direct FTLを2日以上取得できていません。到達日は入力後のSMART Host書込量から補正した目安です。クライアント負荷はForecast WAFでNAND消費量を推定し、WAF 3.5で換算します。", language: "en")
        XCTAssertTrue(explanation.contains("NAND consumption is estimated"))
        XCTAssertTrue(explanation.contains("WAF 3.5"))
    }

    func testReferenceMappingAndSMARTOnlyGuidanceExplainAvailableRowsInEnglish() {
        XCTAssertEqual(UIString.text("世代対応未確認の市販品参考値", language: "en"),
                       "Retail reference; NAND generation mapping unverified")
        let guidance = UIString.text("FTL未取得・SMARTからの暫定推計（%@信頼度 %@）。クライアント負荷はFTL取得後、参考基準は論理容量が取得できた場合に表示します。", language: "en")
        XCTAssertTrue(guidance.contains("Client workload needs FTL"))
        XCTAssertTrue(guidance.contains("logical capacity is available"))
    }
    func testDynamicHelpUsesRegisteredFormatBeforeInsertingValues() {
        let conditions = String(format: UIString.text("%.0f日 · %.0f°C", language: "en"), 365.0, 30.0)
        XCTAssertEqual(conditions, "365 days · 30°C")
        let help = String(format: UIString.text("電源OFFで%@の条件で保管する仮想シナリオ。TLCの保持条件を考慮した研究推計で、データ保持の保証ではありません。", language: "en"), conditions)
        XCTAssertTrue(help.contains("power-off storage"))
        XCTAssertTrue(help.contains("365 days · 30°C"))
        XCTAssertTrue(help.contains("not a data-retention guarantee"))
        for domain in ["TLC", "pSLC"] {
            let text = String(format: UIString.text("%@への推定書込量（平均P/E × 容量）。Host書込1バイトあたりの倍率を併記。", language: "en"), domain)
            XCTAssertTrue(text.contains("Estimated writes to \(domain)"))
            XCTAssertFalse(text.contains("推定"))
        }
    }
    func testMissingMeasurementCopyIsTranslatedWithoutInventingValues() {
        XCTAssertEqual(UIString.text("容量未取得", language: "en"), "Capacity unavailable")
        XCTAssertEqual(UIString.text("比較可能なFTL履歴を待機中", language: "en"), "Waiting for comparable FTL data")
        let missing = UIString.text("未取得", language: "en")
        XCTAssertEqual(String(format: UIString.text("FW %@", language: "en"), missing), "FW Not available")
        let remaining = String(format: UIString.text("%@ / %@ · 残り %@", language: "en"), missing, missing, missing)
        XCTAssertFalse(remaining.contains("未取得"))
        XCTAssertFalse(remaining.contains("0"))
    }
    func testAccessibleHeaderFormatsPreserveDeviceAndMeasurements() {
        let popup = String(format: UIString.text("%@。メイン画面を開く", language: "en"), "APPLE SSD AP0256Q")
        XCTAssertEqual(popup, "APPLE SSD AP0256Q. Open main window")
        let header = String(format: UIString.text("Host読込 %@。Host書込 %@。%@ %@。稼働時間 %@。電源投入 %@。最終取得 %@", language: "en"), "292 TB", "65 TB", "History", "37 days", "3,213 h", "580", "10/08 21:34")
        XCTAssertEqual(header, "Host reads 292 TB. Host writes 65 TB. History 37 days. Power on hours 3,213 h. Power cycles 580. Last captured 10/08 21:34")
    }
    func testLiveDashboardDiagnosticCopyIsTranslated() {
        XCTAssertEqual(UIString.text("直近%d日", language: "en"), "Last %d days")
        let window = String(format: UIString.text("*：%d日の窓のうち、実際に観測できたのは%@日です。", language: "en"), 30, "24.6")
        XCTAssertEqual(window, "*: 24.6 observed days within the 30-day window.")
        XCTAssertEqual(UIString.text("検証済み", language: "en"), "Validated")
        let source = "実行build 26A434 と研究key契約build 25G83 が未検証一致です。raw値は保持し、reliabilityの差分・相関・イベント判定を保留しています。コア損耗レーンとは独立した研究key契約です。"
        XCTAssertTrue(UIString.message(source, language: "en").contains("Runtime build 26A434"))
        XCTAssertEqual(UIString.message(source, language: "ja"), source)
        // Diagnostics saved before the wording change still translate; the new
        // wording translates too.
        let current = "実行build 26A434 と研究用keyの対応表のbuild 25G83 の組み合わせは未確認です。raw値は保持し、reliabilityの差分・相関・イベント判定を保留しています。研究用keyの対応表は、損耗の計算に使うkeyとは別のものです。"
        XCTAssertTrue(UIString.message(current, language: "en").contains("research key map from build 25G83"))
    }
    func testEnglishCatalogHasNoDuplicateKeys() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try String(contentsOf: root.appendingPathComponent(
            "Sources/NenRing/Resources/en.lproj/Localizable.strings"), encoding: .utf8)
        let expression = try NSRegularExpression(pattern: #"(?m)^"([^"]+)"\s*="#)
        var keys = Set<String>()
        for match in expression.matches(in: catalog, range: NSRange(catalog.startIndex..., in: catalog)) {
            let range = try XCTUnwrap(Range(match.range(at: 1), in: catalog))
            let key = String(catalog[range])
            XCTAssertTrue(keys.insert(key).inserted, "Duplicate translation: \(key)")
        }
    }
    func testStaticViewCopyHasEnglishResources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/NenRing")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("View.swift") }
        let expression = try NSRegularExpression(pattern: #"(?:(?:localizedText|UIString.text|Button|Label|help)\(\s*|(?:title|message|label|subtitle):\s*)"([^"\\]+)""#)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let range = Range(match.range(at: 1), in: source) else { continue }
                let key = String(source[range])
                guard key.range(of: #"[ぁ-んァ-ヶ一-龯]"#, options: .regularExpression) != nil else { continue }
                XCTAssertNotEqual(UIString.text(key, language: "en"), key, "\(file.lastPathComponent): \(key)")
                XCTAssertEqual(UIString.text(key, language: "ja"), key)
            }
        }
    }

    func testBoundaryTooltipAndReferenceBasisTranslateEveryLine() {
        let tooltip = [
            "計測器境界 · 境界検証済み",
            "2026/01/01 00:00 → 2026/01/02 00:00",
            "変更: Firmware 561 → 600 / 抽出版 1 → 2",
            "build provenance: 記録済み → 推定",
            "初回 2026/01/02 00:00: 検証済み",
            "最終判定 2026/01/03 00:00",
            "D1: PASS · 検証済み",
            "D2: 未取得",
            "率学習除外 2026/01/01 00:00 → 2026/01/04 00:00（境界後72時間を含む）",
            "D1〜D7のいずれかが不一致。rawは保持し、境界後の損耗率学習へは投入しません。",
        ].joined(separator: "\n")
        let english = UIString.readout(tooltip, language: "en")
        XCTAssertNil(english.range(of: Self.japanese, options: .regularExpression), english)
        XCTAssertTrue(english.contains("Latest assessment 2026/01/03 00:00"))

        let basis = UIString.readout("暫定：参考TBW 150 TB（600 TBW/TB・WD SN740と同世代NANDの市販品）", language: "en")
        XCTAssertEqual(basis, "Provisional: Reference TBW 150 TB (600 TBW/TB · retail drives with the same NAND generation as WD SN740)")
        XCTAssertEqual(UIString.readout("FTL allの定期取得に失敗しました: SMARTと照合できないため保存しませんでした: Host Writes未取得", language: "en")
            .hasPrefix("Scheduled FTL all read failed: The read could not be checked against SMART, so it was not saved: "), true)
        XCTAssertEqual(UIString.readout("FTL all（管理者認証）の取得・解析完了", language: "en"), "FTL all (administrator) read and analyzed")
        XCTAssertEqual(String(format: UIString.text("保存履歴（%.1f日）", language: "en"), 3.0), "Saved history (3.0 days)")
        XCTAssertEqual(String(format: UIString.text("%@日 · 平均 %@ 時間/日 · 書込 %@/日", language: "en"), "1,291", "2.6", "53 GB"),
                       "1,291 days · average 2.6 h/day · writes 53 GB/day")
    }

    /// SwiftUI looks literal titles up in the main bundle, which has no
    /// catalog, so Japanese passed this way stays Japanese in English.
    func testNoJapaneseLiteralGoesStraightToSwiftUI() throws {
        let initializer = try NSRegularExpression(pattern:
            #"(?:(?<![\w.])(?:Text|Label|Button|Toggle|Picker|DatePicker|Section|Menu|Stepper|LabeledContent|TextField|GroupBox|DisclosureGroup)|\.(?:help|accessibilityLabel|accessibilityValue|accessibilityHint|navigationTitle))\(\s*$"#)
        var leaks: [String] = []
        for (file, source, literals) in try sourceLiterals() {
            for literal in literals where literal.hasJapanese {
                let before = String(source[..<literal.start].suffix(80))
                if initializer.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)) != nil {
                    leaks.append("\(file): \(literal.text)")
                }
            }
        }
        XCTAssertEqual(leaks, [])
    }

    /// Messages handed to the translator or to a status field must translate
    /// once their interpolated values are filled in.
    func testTranslatedAndStatusMessagesLeaveNoJapaneseInEnglish() throws {
        let sink = try NSRegularExpression(pattern:
            #"(?:(?:UIString\.(?:text|message|readout)|localizedText)\(\s*|(?:[sS]tatusMessage|[eE]rrorMessage)\s*=\s*(?:[^=\n]*\?\s*)?)$"#)
        var leaks: [String] = []
        for (file, source, literals) in try sourceLiterals() where Self.userFacingSources.contains(file) {
            for literal in literals where literal.hasJapanese {
                let before = String(source[..<literal.start].suffix(120))
                guard sink.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)) != nil else { continue }
                // A slot holds either a count or a date; one of them must fit.
                let renderings = ["1", "2026/01/01 00:00"].map {
                    UIString.readout(literal.filled(with: $0), language: "en")
                }
                if let english = renderings.first, renderings.allSatisfy({
                    $0.range(of: Self.japanese, options: .regularExpression) != nil
                }) {
                    leaks.append("\(file): \(literal.text) → \(english)")
                }
            }
        }
        XCTAssertEqual(leaks, [])
    }

    private static let japanese = #"[ぁ-んァ-ヶ一-龯]"#
    /// Screens people use day to day. Research pages show raw notes on
    /// purpose and are not held to this yet.
    /// Reasons a forecast or a failed read gives are shown on the main screens.
    func testForecastAndFailureReasonsHaveEnglish() {
        for (source, english) in [
            ("Percentage Used の履歴がありません", "There is no Percentage Used history"),
            ("少なくとも30日分の変化を観測します（現在 12日）", "Needs at least 30 days of change (now 12 days)"),
            ("外部コマンドの取得がタイムアウトしました", "The external command timed out"),
            ("Critical Warning が 0x1F です", "Critical Warning is 0x1F"),
            ("FTLとSMARTのHost Writesが一致しません（比 1.100）", "FTL and S.M.A.R.T. Host Writes do not match (ratio 1.100)"),
            ("SMARTと照合できないため保存しませんでした: 同device・24時間以内のSMARTがありません",
             "The read could not be checked against SMART, so it was not saved: There is no S.M.A.R.T. read from the same device within 24 hours"),
            ("TLC／pSLCの損耗率が12.5%乖離。容量配分が未検証のため、保守側maxで総NAND予算を暫定計算しています。",
             "TLC and pSLC wear differ by 12.5%. Capacity allocation is unverified, so the total NAND budget is provisionally calculated from the conservative max.")
        ] {
            XCTAssertEqual(UIString.readout(source, language: "en"), english)
        }
    }

    private static let userFacingSources: Set<String> = [
        "DashboardShellView.swift", "ReferenceDashboardView.swift", "MonitorSettingsView.swift",
        "MenuBarMonitorView.swift", "DiskInformationView.swift", "AboutView.swift",
        "DiagnosticReportSheet.swift", "DashboardModel.swift", "DashboardModel+Scheduling.swift",
        "DashboardAnalyticsCoordinator.swift",
    ]

    private struct SourceLiteral {
        let start: String.Index
        /// The literal as written, with `\(…)` left in place.
        let text: String
        var hasJapanese: Bool { text.range(of: LocalizationTests.japanese, options: .regularExpression) != nil }

        func filled(with sample: String) -> String {
            var result = "", index = text.startIndex
            while index < text.endIndex {
                let character = text[index]
                let next = text.index(after: index)
                guard character == "\\", next < text.endIndex else {
                    result.append(character); index = next; continue
                }
                switch text[next] {
                case "(":
                    var depth = 0, cursor = next
                    repeat {
                        if text[cursor] == "(" { depth += 1 } else if text[cursor] == ")" { depth -= 1 }
                        cursor = text.index(after: cursor)
                    } while depth > 0 && cursor < text.endIndex
                    result += sample; index = cursor
                case "n": result.append("\n"); index = text.index(after: next)
                default: result.append(text[next]); index = text.index(after: next)
                }
            }
            return result
        }
    }

    /// Single-line string literals, skipping comments. Interpolations may
    /// contain further strings, which a regular expression cannot follow.
    private func sourceLiterals() throws -> [(String, String, [SourceLiteral])] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/NenRing")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { file in
            let source = try String(contentsOf: file, encoding: .utf8)
            var literals: [SourceLiteral] = []
            var index = source.startIndex
            func advance() { index = source.index(after: index) }
            /// Reads from just after an opening quote to just after the closing one.
            func readString() -> String {
                var text = ""
                while index < source.endIndex, source[index] != "\"", source[index] != "\n" {
                    if source[index] == "\\" {
                        text.append(source[index]); advance()
                        guard index < source.endIndex else { break }
                        if source[index] == "(" {
                            var depth = 0
                            repeat {
                                let character = source[index]
                                if character == "\"" {
                                    advance(); text += "\"" + readString() + "\""
                                    continue
                                }
                                if character == "(" { depth += 1 } else if character == ")" { depth -= 1 }
                                text.append(character); advance()
                            } while depth > 0 && index < source.endIndex
                            continue
                        }
                    }
                    text.append(source[index]); advance()
                }
                if index < source.endIndex, source[index] == "\"" { advance() }
                return text
            }
            while index < source.endIndex {
                if source[index...].hasPrefix("//") {
                    index = source[index...].firstIndex(of: "\n") ?? source.endIndex
                } else if source[index...].hasPrefix("\"\"\"") {
                    let rest = source.index(index, offsetBy: 3)
                    index = source[rest...].range(of: "\"\"\"")?.upperBound ?? source.endIndex
                } else if source[index] == "\"" {
                    let start = index
                    advance()
                    literals.append(SourceLiteral(start: start, text: readString()))
                } else {
                    advance()
                }
            }
            return (file.lastPathComponent, source, literals)
        }
    }

    func testDynamicUIShapesKeepDatesValuesAndOriginalMessages() {
        let cases = [
            ("2境界 / 3変更 · raw履歴は未変更", "2 boundaries / 3 changes · raw history unchanged"),
            ("要求 1024 bytes / 応答 512 bytes / 保存 512 bytes", "Requested 1024 bytes / response 512 bytes / saved 512 bytes"),
            ("保存履歴（20.6日）", "Saved history (20.6 days)"),
            ("前: OS 25G83 · FW 591", "Before: OS 25G83 · FW 591"),
            ("• 未確認", "• Unconfirmed"),
            ("温度履歴を保存できませんでした: disk full", "Could not save temperature history: disk full"),
            ("温度履歴の整理に失敗しました: disk full", "Could not trim the temperature history in memory: disk full"),
            ("温度履歴を読み込めないため、寿命予測の再計算を保留しました: disk full",
             "Forecasts were not recalculated because the temperature history could not be loaded: disk full")
        ]
        for (source, english) in cases {
            XCTAssertEqual(UIString.message(source, language: "en"), english)
            XCTAssertEqual(UIString.message(source, language: "ja"), source)
        }
        let unknown = "独自診断 / 未取得"
        XCTAssertEqual(UIString.message(unknown, language: "en"), unknown,
            "Unknown diagnostic payloads must remain intact")
        XCTAssertEqual(UIString.readout("未取得 / 未観測", language: "en"), "Not available / Not observed")
        // The amber attention state; "Validated" said the opposite.
        XCTAssertEqual(UIString.text("確認あり", language: "en"), "Check required")
        XCTAssertEqual(UIString.message("暫定・保存履歴のペースで残り約27年（2053年頃）", language: "en"),
                       "Provisional · about 27 years remaining at the recorded-history rate (around 2053)")
    }
    func testSettingsAndDiskLabelsPreserveTechnicalIdentifiers() {
        XCTAssertEqual(UIString.text(RefreshInterval.oneHour.title, language: "en"), "1 hour")
        XCTAssertEqual(UIString.text(IORegistryCollectionInterval.launchOnly.title, language: "en"), "At launch only")
        XCTAssertEqual(UIString.text("取得JSON", language: "en"), "Captured JSON")
        XCTAssertEqual(UIString.text("符号付き未同定残差", language: "en"), "Signed unidentified residual")
        let raw = #"{"model":"Apple SSD","source":"未取得","key":503}"#
        XCTAssertEqual(UIString.text(raw, language: "en"), raw)
    }
    func testExplicitResourceLookupInBothLanguages() {
        XCTAssertEqual(UIString.text("保持考慮", language: "en-US"), "With retention")
        XCTAssertEqual(UIString.text("保持考慮", language: "ja-JP"), "保持考慮")
    }

    func testUnregisteredTechnicalValueIsPreserved() {
        XCTAssertEqual(UIString.text("AppleANS3 / key 503", language: "en"), "AppleANS3 / key 503")
        XCTAssertEqual(UIString.text("25G83-core-v1", language: "ja"), "25G83-core-v1")
    }

    func testResearchFormatPreservesValuesAndEnglishWordOrder() {
        let format = UIString.text("累積 %@ · 観測 %@ · 予測 %@", language: "en")
        XCTAssertEqual(String(format: format, "1.5000", "1.7000", "1.6000"),
                       "Lifetime 1.5000 · Observed 1.7000 · Forecast 1.6000")
        XCTAssertEqual(String(format: UIString.text("%d点", language: "en"), 26),
                       "26 observations")
    }

    func testContractPresentationPreservesOriginalAndBuildIdentity() {
        let status = DirectFTLContractStatus.validated(build: "26A434", contract: "contract-v1", topologyAvailable: true, telemetryAvailable: false, hardwareReviewed: false)
        let original = status.detail
        let english = status.displayDetail(language: "en")
        XCTAssertTrue(english.contains("26A434"))
        XCTAssertTrue(english.contains("contract-v1"))
        XCTAssertTrue(english.contains("Reliability unavailable"))
        XCTAssertTrue(english.contains("SSD controller not validated"))
        XCTAssertEqual(status.displayDetail(language: "ja"), original)
        XCTAssertEqual(status.detail, original)
        XCTAssertTrue(DirectFTLContractStatus.contractMismatch(expected: "v1", actual: "v2").displayDetail(language: "en").contains("expected v1"))
        XCTAssertTrue(DirectFTLContractStatus.unsupportedBuild(expected: "25G83", actual: nil).displayDetail(language: "en").contains("Unknown"))
        XCTAssertTrue(DirectFTLContractStatus.contractUnavailable(build: "26A434").displayDetail(language: "en").contains("not interpreted or used"))
        XCTAssertTrue(DirectFTLContractStatus.noSnapshot.displayDetail(language: "en").contains("monitoring continues"))
    }

    func testErrorEnvelopePreservesRawPayloadAndUnknownMessages() {
        let raw = "/path/%@/capture.bin: EACCES 13"
        XCTAssertEqual(UIString.message("ASP probeの実行を拒否しました: " + raw, language: "en"), "ASP probe execution denied: " + raw)
        XCTAssertEqual(UIString.message("ASP probeの実行を拒否しました: " + raw, language: "ja"), "ASP probeの実行を拒否しました: " + raw)
        XCTAssertEqual(UIString.message(raw, language: "en"), raw)
        XCTAssertEqual(UIString.message("未取得\n" + raw, language: "en"), "Not available\n" + raw)
    }

    func testCrossValidationPresentationPreservesSignedValues() {
        let cases = [
            ("FTL／SMART 1.000001・保存前照合の条件内", "FTL / SMART 1.000001 · within pre-save validation limits"),
            ("FTL−SMART -2.00 h・差の変化 0.50 h／許容 2.00 h", "FTL − SMART -2.00 h · offset change 0.50 h / tolerance 2.00 h"),
            ("5.000% ／ 5.610%・差 -0.610 pp（補助観測）", "5.000% / 5.610% · difference -0.610 pp (auxiliary observation)"),
            ("実測NAND − geometry×平均P/E = +650.860 GB・未同定分を予算へ加算しません", "Measured NAND − geometry × average P/E = +650.860 GB · unidentified residual is not added to the budget"),
            ("Age refresh 未取得 ／ BG refresh 12 ／ error refresh 0・原因や単位の同一性を断定しません", "Age refresh Not available / BG refresh 12 / error refresh 0 · no claim of common cause or units"),
            ("ΔTLC ≥ 20 は未到達（現在の系列内進行 14.000）。", "ΔTLC ≥ 20 not reached (current series progression 14.000)."),
            ("連続・生涯残差レンジが連続", "Continuous · Lifetime residual ranges overlap")
        ]
        for (original, expected) in cases {
            XCTAssertEqual(UIString.message(original, language: "en"), expected)
            XCTAssertEqual(UIString.message(original, language: "ja"), original)
        }
        let unknown = "prefix FTL／SMART 1.000001・保存前照合の条件内"
        XCTAssertEqual(UIString.message(unknown, language: "en"), unknown)
    }

    func testResidualIntervalAndDatePresentation() {
        let source = "2026/10/08 14:17 → 2026/10/08 16:17：+4.622 GB（量子化範囲 −264.485 GB〜+4.622 GB）"
        XCTAssertEqual(UIString.message(source, language: "en"), "2026/10/08 14:17 → 2026/10/08 16:17: +4.622 GB (quantization range −264.485 GB to +4.622 GB)")
        let date = Date(timeIntervalSince1970: 0)
        let zone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(UIString.dateTime(date, language: "en", timeZone: zone), "1970/01/01 00:00")
        XCTAssertEqual(UIString.dateTime(nil, language: "en"), "Not available")
        XCTAssertEqual(UIString.yearMonth(date, language: "en", timeZone: zone), "Jan 1970")
        XCTAssertEqual(UIString.yearMonth(date, language: "ja", timeZone: zone), "1970年1月")
    }
}
