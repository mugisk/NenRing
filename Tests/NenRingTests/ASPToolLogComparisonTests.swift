import Foundation
import XCTest
@testable import NenRing

final class ASPToolLogComparisonTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(
        hours: Double,
        artifact: ASPToolSourceArtifact,
        host: UInt64,
        nand: UInt64,
        powerOnHours: UInt64,
        tlcPE: Double = 170,
        pslcPE: Double = 5_600,
        firmware: String? = nil,
        sourceBuild: String? = nil
    ) -> ASPToolDiagnosticsSnapshot {
        ASPToolDiagnosticsSnapshot(
            capturedAt: base.addingTimeInterval(hours * 3_600),
            deviceID: "serial:test",
            sourceArtifact: artifact,
            sourceBuild: sourceBuild,
            hostWrites: host,
            nandWrites: nand,
            tlcAveragePE: tlcPE,
            tlcEOLPE: 3_000,
            slcAveragePE: pslcPE,
            slcEOLPE: 100_000,
            powerOnHours: powerOnHours,
            firmware: firmware
        )
    }

    private func detail(_ comparison: ASPToolLogComparison, _ title: String) -> String? {
        comparison.rows.first { $0.title == title }?.detail
    }

    func testInterpolatesCountersBetweenTheDirectReadsAroundTheLog() {
        // Direct reads 2 h before and 2 h after; the log sits exactly halfway.
        let before = snapshot(hours: 0, artifact: .directFTL, host: 1_000_000, nand: 1_500_000, powerOnHours: 100)
        let after = snapshot(hours: 4, artifact: .directFTL, host: 1_200_000, nand: 1_800_000, powerOnHours: 104)
        let log = snapshot(hours: 2, artifact: .importedFixture, host: 1_100_000, nand: 1_650_000, powerOnHours: 102)

        let comparison = ASPToolLogComparison.build(snapshots: [after, log, before])

        XCTAssertEqual(detail(comparison, "Host Writes"), "4.51 GB ／ 4.51 GB・差 +0.000%")
        XCTAssertEqual(detail(comparison, "NAND Writes"), "6.76 GB ／ 6.76 GB・差 +0.000%")
        XCTAssertEqual(detail(comparison, "Power On Hours"), "102 h ／ 102 h・差 +0.00")
        XCTAssertTrue(detail(comparison, "Direct FTL")?.contains("の間で補間") == true)
    }

    func testUsesTheNearestDirectReadWhenOnlyOneSideExists() {
        let direct = snapshot(hours: 3, artifact: .directFTL, host: 1_000_000, nand: 1_500_000, powerOnHours: 103, tlcPE: 171)
        let log = snapshot(hours: 0, artifact: .extractedASPTool, host: 990_000, nand: 1_480_000, powerOnHours: 100, tlcPE: 170)

        let comparison = ASPToolLogComparison.build(snapshots: [direct, log])

        XCTAssertTrue(detail(comparison, "Direct FTL")?.contains("時刻差 +3.0時間") == true)
        XCTAssertEqual(detail(comparison, "TLC 平均P/E"), "170.0 ／ 171.0・差 -1.00")
        XCTAssertEqual(detail(comparison, "TLC EOL"), "3000 ／ 3000・差 +0.00")
    }

    func testDoesNotInterpolateAcrossCounterResetOrFirmwareChange() {
        let before = snapshot(hours: 0, artifact: .directFTL, host: 1_000_000,
                              nand: 2_000_000, powerOnHours: 100, firmware: "old")
        let reset = snapshot(hours: 4, artifact: .directFTL, host: 100_000,
                             nand: 200_000, powerOnHours: 104, firmware: "old")
        let log = snapshot(hours: 2, artifact: .importedFixture, host: 550_000,
                           nand: 1_100_000, powerOnHours: 102)
        let afterUpdate = snapshot(hours: 4, artifact: .directFTL, host: 1_200_000,
                                   nand: 2_200_000, powerOnHours: 104, firmware: "new")

        for end in [reset, afterUpdate] {
            let comparison = ASPToolLogComparison.build(snapshots: [before, log, end])
            XCTAssertTrue(detail(comparison, "照合")?.contains("連続性を確認できません") == true)
            XCTAssertNil(detail(comparison, "Host Writes"))
        }
    }

    func testDoesNotCompareAStaleDirectReadOrLongInterpolationGap() {
        let direct = snapshot(hours: 0, artifact: .directFTL, host: 1_000_000,
                              nand: 2_000_000, powerOnHours: 100)
        let distant = snapshot(hours: 100, artifact: .directFTL, host: 1_200_000,
                               nand: 2_200_000, powerOnHours: 104)
        let log = snapshot(hours: 50, artifact: .importedFixture, host: 1_100_000,
                           nand: 2_100_000, powerOnHours: 102)

        XCTAssertTrue(detail(ASPToolLogComparison.build(snapshots: [direct, log]), "照合")?
            .contains("近接する") == true)
        XCTAssertTrue(detail(ASPToolLogComparison.build(snapshots: [direct, log, distant]), "照合")?
            .contains("連続性を確認できません") == true)
    }

    func testDoesNotCompareAReadExcludedFromTheVerifiedContinuityLane() {
        let before = snapshot(hours: 0, artifact: .directFTL, host: 1_000_000,
                              nand: 2_000_000, powerOnHours: 100)
        let after = snapshot(hours: 4, artifact: .directFTL, host: 1_200_000,
                             nand: 2_200_000, powerOnHours: 104)
        let log = snapshot(hours: 2, artifact: .importedFixture, host: 1_100_000,
                           nand: 2_100_000, powerOnHours: 102)
        let comparison = ASPToolLogComparison.build(snapshots: [before, log, after],
                                                    acceptedDirectIDs: [before.id])
        XCTAssertTrue(detail(comparison, "照合")?.contains("連続性を確認できません") == true)
        XCTAssertNil(detail(comparison, "Host Writes"))
        let noAcceptedHistory = ASPToolLogComparison.build(snapshots: [before, log, after],
                                                           acceptedDirectIDs: [])
        XCTAssertTrue(detail(noAcceptedHistory, "照合")?.contains("連続性を確認できません") == true)
    }

    func testExactTimeReadDoesNotDependOnAStaleFutureSample() {
        let direct = snapshot(hours: 0, artifact: .directFTL, host: 1_000_000,
                              nand: 2_000_000, powerOnHours: 100)
        let log = snapshot(hours: 0, artifact: .importedFixture, host: 1_000_000,
                           nand: 2_000_000, powerOnHours: 100)
        let later = snapshot(hours: 100, artifact: .directFTL, host: 100,
                             nand: 200, powerOnHours: 10)

        let comparison = ASPToolLogComparison.build(snapshots: [direct, log, later],
                                                    acceptedDirectIDs: [direct.id])
        XCTAssertTrue(detail(comparison, "Host Writes")?.contains("+0.000%") == true)
        XCTAssertTrue(detail(comparison, "Direct FTL")?.contains("時刻差 +0.0時間") == true)
    }

    func testRetainsBothAcquisitionRoutesWithIdenticalCounters() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("build/.asptool-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ASPToolSnapshotStore(fileURL: directory.appendingPathComponent("asptool.jsonl"))
        let direct = snapshot(hours: 0, artifact: .directFTL, host: 1_000_000,
                              nand: 2_000_000, powerOnHours: 100)
        let log = snapshot(hours: 0, artifact: .importedFixture, host: 1_000_000,
                           nand: 2_000_000, powerOnHours: 100)

        let directAdded = try await store.appendIfNew(direct)
        let logAdded = try await store.appendIfNew(log)
        let reimportedLog = snapshot(hours: 0, artifact: .importedFixture, host: 1_000_000,
                                     nand: 2_000_000, powerOnHours: 100)
        let duplicateAdded = try await store.appendIfNew(reimportedLog)
        let records = try await store.records()
        XCTAssertTrue(directAdded)
        XCTAssertTrue(logAdded)
        XCTAssertFalse(duplicateAdded)
        XCTAssertEqual(records.count, 2)
    }

    func testReportsMissingInputsWithoutGuessing() {
        XCTAssertEqual(ASPToolLogComparison.build(snapshots: []).rows.first?.detail, "未読込")
        let log = snapshot(hours: 0, artifact: .importedFixture, host: 1, nand: 1, powerOnHours: 1)
        XCTAssertEqual(detail(ASPToolLogComparison.build(snapshots: [log]), "照合"), "比較するDirect FTLの取得がありません")
    }

    private func direct(hours: Double, host: UInt64, nand: UInt64, powerOnHours: UInt64,
                        tlcPE: Double = 170, firmware: String? = "591.40.3",
                        build: String? = "26B123") -> ASPToolDiagnosticsSnapshot {
        snapshot(hours: hours, artifact: .directFTL, host: host, nand: nand, powerOnHours: powerOnHours,
                 tlcPE: tlcPE, firmware: firmware, sourceBuild: build)
    }

    func testVerdictPassesWithinTheCriteriaAndNamesTheEnvironment() {
        let before = direct(hours: 0, host: 1_000_000, nand: 1_500_000, powerOnHours: 100, tlcPE: 170)
        let after = direct(hours: 4, host: 1_200_000, nand: 1_800_000, powerOnHours: 104, tlcPE: 171)
        // 0.05% above the interpolated Host value, still within ±0.1%.
        let log = snapshot(hours: 2, artifact: .importedFixture, host: 1_100_550, nand: 1_650_000,
                           powerOnHours: 102, tlcPE: 171)

        let comparison = ASPToolLogComparison.build(snapshots: [before, log, after])

        XCTAssertEqual(comparison.verdict?.outcome, .passed)
        XCTAssertEqual(comparison.verdict?.sourceBuild, "26B123")
        XCTAssertEqual(comparison.verdict?.firmware, "591.40.3")
        XCTAssertEqual(detail(comparison, "判定"), "基準内で一致")
    }

    func testVerdictFailsOutsideTheCriteria() {
        let before = direct(hours: 0, host: 1_000_000, nand: 1_500_000, powerOnHours: 100, tlcPE: 170)
        let after = direct(hours: 4, host: 1_200_000, nand: 1_800_000, powerOnHours: 104, tlcPE: 170)
        let log = snapshot(hours: 2, artifact: .importedFixture, host: 1_105_500, nand: 1_650_000,
                           powerOnHours: 105, tlcPE: 172)

        let comparison = ASPToolLogComparison.build(snapshots: [before, log, after])

        XCTAssertEqual(comparison.verdict?.outcome, .failed)
        XCTAssertEqual(comparison.verdict?.reasons, [
            "Host Writes 差 +0.500%（基準 ±0.1%）",
            "Power On Hours 差 +3.0 h（基準 ±1 h）",
            "TLC 平均P/E 172.0 がDirect FTLの値（170.0）と一致しません"
        ])
        XCTAssertTrue(detail(comparison, "判定")?.hasPrefix("不一致: Host Writes") == true)
    }

    func testVerdictIsInconclusiveWithoutEnoughEvidence() {
        let log = snapshot(hours: 0, artifact: .importedFixture, host: 1_000_000, nand: 1_500_000, powerOnHours: 100)

        // Only one Direct read, two hours away.
        let distantRead = direct(hours: 2, host: 1_000_000, nand: 1_500_000, powerOnHours: 102)
        let distant = ASPToolLogComparison.build(snapshots: [log, distantRead], logSource: source(for: log))
        XCTAssertEqual(distant.verdict?.outcome, .inconclusive)
        XCTAssertEqual(distant.verdict?.reasons, ["前後のDirect FTL取得、または30分以内の取得が必要です"])

        // A Direct read within 30 minutes is enough on its own only when the
        // log's time was recorded in the archive, not taken from the file.
        let closeRead = direct(hours: 0.25, host: 1_000_000, nand: 1_500_000, powerOnHours: 100)
        let close = ASPToolLogComparison.build(snapshots: [log, closeRead])
        XCTAssertEqual(close.verdict?.outcome, .inconclusive)
        XCTAssertEqual(close.verdict?.reasons, ["ファイルの更新日時で照合するため、前後のDirect FTL取得が必要です"])
        let archived = ASPToolLogComparison.build(snapshots: [log, closeRead], logSource: source(for: log))
        XCTAssertEqual(archived.verdict?.outcome, .passed)

        let noFirmware = ASPToolLogComparison.build(snapshots: [
            log, direct(hours: 0, host: 1_000_000, nand: 1_500_000, powerOnHours: 100, firmware: nil)])
        XCTAssertEqual(noFirmware.verdict?.outcome, .inconclusive)

        let otherBuildLog = snapshot(hours: 0, artifact: .importedFixture, host: 1_000_000, nand: 1_500_000,
                                     powerOnHours: 100, sourceBuild: "26A100")
        let otherBuild = ASPToolLogComparison.build(snapshots: [
            otherBuildLog, direct(hours: 0, host: 1_000_000, nand: 1_500_000, powerOnHours: 100)])
        XCTAssertEqual(otherBuild.verdict?.reasons, ["asptoolログとDirect FTLのmacOS buildが異なります"])

        XCTAssertNil(ASPToolLogComparison.build(snapshots: [log]).verdict)
    }

    private func source(for log: ASPToolDiagnosticsSnapshot, build: String? = "26B123",
                        firmware: String? = "591.40.3") -> ASPToolLogSourceIdentity {
        ASPToolLogSourceIdentity(logWrittenAt: log.capturedAt, macOSBuild: build, macOSVersion: "27.2",
                                 ssdModel: "APPLE SSD AP0256Q", ssdFirmware: firmware)
    }

    func testSourceIsConfirmedSeparatelyFromTheNumbers() {
        let before = direct(hours: 0, host: 1_000_000, nand: 1_500_000, powerOnHours: 100)
        let after = direct(hours: 4, host: 1_200_000, nand: 1_800_000, powerOnHours: 104)
        let log = snapshot(hours: 2, artifact: .importedFixture, host: 1_100_000, nand: 1_650_000, powerOnHours: 102)

        // Matching numbers without the sysdiagnose files: the source stays unconfirmed.
        let loose = ASPToolLogComparison.build(snapshots: [before, log, after])
        XCTAssertEqual(loose.verdict?.outcome, .passed)
        XCTAssertEqual(loose.verdict?.sourceCheck, .unconfirmed)
        XCTAssertTrue(detail(loose, "取得元")?.hasPrefix("未確認") == true)
        XCTAssertEqual(detail(loose, "時刻の根拠"), "ファイルの更新日時（コピーで変わることがあります）")

        // Another build and a point release in the same major version and lineage still match.
        let sameLineage = ASPToolLogComparison.build(snapshots: [before, log, after],
                                                     logSource: source(for: log, build: "26B200", firmware: "591.50.1"))
        XCTAssertEqual(sameLineage.verdict?.outcome, .passed)
        XCTAssertEqual(sameLineage.verdict?.sourceCheck, .confirmed)
        XCTAssertEqual(detail(sameLineage, "時刻の根拠"), "アーカイブに記録された出力時刻")

        for (build, firmware) in [("25G83", "591.40.3"), ("26B123", "600.1")] {
            let other = ASPToolLogComparison.build(snapshots: [before, log, after],
                                                   logSource: source(for: log, build: build, firmware: firmware))
            XCTAssertEqual(other.verdict?.outcome, .inconclusive, "\(build) \(firmware)")
            XCTAssertEqual(other.verdict?.sourceCheck, .mismatched)
            XCTAssertEqual(other.verdict?.reasons, ["sysdiagnoseのmacOSまたはSSDファームウェアがDirect FTLと異なります"])
        }

        // A sysdiagnose missing either file leaves the source unconfirmed.
        for partial in [source(for: log, build: nil), source(for: log, firmware: nil)] {
            XCTAssertEqual(ASPToolLogComparison.build(snapshots: [before, log, after], logSource: partial)
                .verdict?.sourceCheck, .unconfirmed)
        }

        // An identity read with another log does not describe this one.
        let otherLog = ASPToolLogSourceIdentity(logWrittenAt: log.capturedAt.addingTimeInterval(120), macOSBuild: "26B123",
                                                macOSVersion: "27.2", ssdModel: nil, ssdFirmware: "591.40.3")
        let stale = ASPToolLogComparison.build(snapshots: [before, log, after], logSource: otherLog)
        XCTAssertEqual(stale.verdict?.sourceCheck, .unconfirmed)
        XCTAssertEqual(detail(stale, "時刻の根拠"), "ファイルの更新日時（コピーで変わることがあります）")
    }

    func testVerifiedEnvironmentRecordFollowsTheVerdict() {
        let now = base
        let pass = ASPToolLogVerdict(outcome: .passed, reasons: [], logCapturedAt: base,
                                     sourceBuild: "26B123", firmware: "591.40.3", sourceCheck: .confirmed)
        let recorded = ASPToolVerifiedEnvironment.applying(pass, to: [], macOSVersion: "27.2", now: now)
        XCTAssertEqual(recorded.map(\.id), ["macOS 27|591"])
        XCTAssertEqual(recorded.first?.summary.hasPrefix("macOS 27.2（26B123）・ファームウェア 591.40.3・ログ "), true)

        // Re-evaluating the same log keeps the original record date.
        let again = ASPToolVerifiedEnvironment.applying(pass, to: recorded, macOSVersion: "27.2",
                                                        now: now.addingTimeInterval(60))
        XCTAssertEqual(again, recorded)

        let inconclusive = ASPToolLogVerdict(outcome: .inconclusive, reasons: ["x"], logCapturedAt: base,
                                             sourceBuild: "26B123", firmware: "591.40.3", sourceCheck: .confirmed)
        XCTAssertEqual(ASPToolVerifiedEnvironment.applying(inconclusive, to: recorded, macOSVersion: nil, now: now), recorded)
        XCTAssertEqual(ASPToolVerifiedEnvironment.applying(nil, to: recorded, macOSVersion: nil, now: now), recorded)

        let otherFirmware = ASPToolLogVerdict(outcome: .failed, reasons: ["x"], logCapturedAt: base,
                                              sourceBuild: "26B123", firmware: "600.0", sourceCheck: .confirmed)
        XCTAssertEqual(ASPToolVerifiedEnvironment.applying(otherFirmware, to: recorded, macOSVersion: nil, now: now), recorded)

        // Without a confirmed source, neither a pass nor a failure changes the records.
        for outcome in [ASPToolLogVerdict.Outcome.passed, .failed] {
            for check in [ASPToolLogVerdict.SourceCheck.unconfirmed, .mismatched] {
                let verdict = ASPToolLogVerdict(outcome: outcome, reasons: [], logCapturedAt: base.addingTimeInterval(600),
                                                sourceBuild: "26B123", firmware: "591.40.3", sourceCheck: check)
                XCTAssertEqual(ASPToolVerifiedEnvironment.applying(verdict, to: recorded, macOSVersion: nil, now: now),
                               recorded, "\(outcome) \(check)")
                XCTAssertEqual(ASPToolVerifiedEnvironment.applying(verdict, to: [], macOSVersion: nil, now: now), [])
            }
        }

        // A newer log from another build in the same major version and lineage replaces the record.
        let pointRelease = ASPToolLogVerdict(outcome: .passed, reasons: [], logCapturedAt: base.addingTimeInterval(3_600),
                                             sourceBuild: "26B200", firmware: "591.50.1", sourceCheck: .confirmed)
        let replaced = ASPToolVerifiedEnvironment.applying(pointRelease, to: recorded, macOSVersion: "27.3", now: now)
        XCTAssertEqual(replaced.map(\.sourceBuild), ["26B200"])
        XCTAssertEqual(replaced.map(\.firmware), ["591.50.1"])

        let fail = ASPToolLogVerdict(outcome: .failed, reasons: ["x"], logCapturedAt: base,
                                     sourceBuild: "26B200", firmware: "591.40.3", sourceCheck: .confirmed)
        XCTAssertEqual(ASPToolVerifiedEnvironment.applying(fail, to: recorded, macOSVersion: nil, now: now), [])

        // A deleted record comes back only when another result is judged.
        XCTAssertEqual(pass.recordKey, ASPToolLogVerdict(outcome: .passed, reasons: [], logCapturedAt: base,
                                                         sourceBuild: "26B123", firmware: "591.40.3",
                                                         sourceCheck: .confirmed).recordKey)
        XCTAssertNotEqual(pass.recordKey, inconclusive.recordKey)
        XCTAssertNotEqual(pass.recordKey, ASPToolLogVerdict(outcome: .passed, reasons: [], logCapturedAt: base,
                                                            sourceBuild: "26B123", firmware: "591.40.3").recordKey)
        XCTAssertNotEqual(pass.recordKey, ASPToolLogVerdict(outcome: .passed, reasons: [],
            logCapturedAt: base.addingTimeInterval(60), sourceBuild: "26B123", firmware: "591.40.3").recordKey)
    }

    func testRecordsSavedPerBuildCollapseToTheNewestPerLineage() {
        func record(_ build: String, _ firmware: String, hours: Double) -> ASPToolVerifiedEnvironment {
            ASPToolVerifiedEnvironment(sourceBuild: build, firmware: firmware, macOSVersion: nil,
                                       logCapturedAt: base.addingTimeInterval(hours * 3_600),
                                       recordedAt: base.addingTimeInterval(hours * 3_600))
        }
        let saved = [record("26A428", "591", hours: 0), record("26B123", "591.40.3", hours: 5),
                     record("25G83", "561.100", hours: 1)]
        let collapsed = ASPToolVerifiedEnvironment.deduplicated(saved)
        XCTAssertEqual(collapsed.map(\.sourceBuild), ["25G83", "26B123"])
        XCTAssertEqual(collapsed.map(\.id), ["macOS 26|561", "macOS 27|591"])
    }

    func testEnglishUITranslatesTheVerdict() {
        let japanese = #"[ぁ-んァ-ヶ一-龯]"#
        let samples = [
            "基準内で一致",
            ASPToolLogVerdict.criteria,
            "不一致: Host Writes 差 +0.500%（基準 ±0.1%） / Power On Hours 差 +3.0 h（基準 ±1 h） / TLC 平均P/E 172.0 がDirect FTLの値（170.0〜171.0）と一致しません / TLC EOL 3000 ／ 2900",
            "判定できません: 比較値がありません（TLC 平均P/E・pSLC EOL）",
            "判定できません: 前後のDirect FTL取得、または30分以内の取得が必要です",
            "macOS 27.2（26B123）・ファームウェア 591.40.3・ログ 2026/11/07 23:15",
            "sysdiagnoseからasptool_snapshot.logを取り出せませんでした（終了コード1）",
            "判定できません: ファイルの更新日時で照合するため、前後のDirect FTL取得が必要です",
            "判定できません: sysdiagnoseのmacOSまたはSSDファームウェアがDirect FTLと異なります",
            "時刻の根拠", "取得元",
            "ファイルの更新日時（コピーで変わることがあります）", "アーカイブに記録された出力時刻",
            ASPToolLogVerdict(outcome: .passed, reasons: [], logCapturedAt: base, sourceBuild: nil, firmware: nil,
                              sourceCheck: .confirmed).sourceDetail,
            ASPToolLogVerdict(outcome: .passed, reasons: [], logCapturedAt: base, sourceBuild: nil, firmware: nil,
                              sourceCheck: .unconfirmed).sourceDetail,
            ASPToolLogVerdict(outcome: .passed, reasons: [], logCapturedAt: base, sourceBuild: nil, firmware: nil,
                              sourceCheck: .mismatched).sourceDetail
        ]
        for sample in samples {
            let english = UIString.readout(sample, language: "en")
            XCTAssertNil(english.range(of: japanese, options: .regularExpression), english)
        }
        XCTAssertEqual(UIString.readout("macOS 27.2（26B123）・ファームウェア 591.40.3・ログ 2026/11/07 23:15", language: "en"),
                       "macOS 27.2 (26B123)・Firmware 591.40.3・Log 2026/11/07 23:15")
    }

    func testEnglishUITranslatesTheComparisonRows() {
        XCTAssertEqual(UIString.readout("4.51 GB ／ 4.52 GB・差 -0.221%", language: "en"), "4.51 GB / 4.52 GB · difference -0.221%")
        XCTAssertEqual(UIString.readout("170.0 ／ 171.0・差 -1.00", language: "en"), "170.0 / 171.0 · difference -1.00")
        XCTAssertEqual(UIString.readout("比較値未取得", language: "en"), "Comparison value unavailable")
    }
}
