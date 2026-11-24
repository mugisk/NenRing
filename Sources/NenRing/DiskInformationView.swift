import SwiftUI

/// Displays already collected information; opening this page never probes a
/// device or scans history. The two sources retain their own acquisition time.
struct DiskInformationView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        DiskInformationContent(snapshot: model.snapshot, profile: model.appleStorageProfile,
            counterInterval: model.analytics.smartCounterInterval)
    }
}

struct DiskInformationContent: View {
    let snapshot: DriveSnapshot?
    let profile: AppleNANDHardwareProfile?
    var counterInterval: SMARTCounterInterval = .empty

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            localizedText("ディスク情報").font(.title2.weight(.semibold))
            section("S.M.A.R.T.", timestamp: snapshot?.capturedAt) {
                if let s = snapshot {
                    row("モデル", s.model)
                    row("シリアル番号", s.serialNumber)
                    row("Firmware", s.firmware)
                    row("デバイス", s.devicePath)
                    row("論理容量", s.logicalCapacityBytes.map { ValueFormatter.decimalCapacity($0) })
                    row("smartctl", s.smartctlVersion)
                    row("健康状態", s.smartPassed.map { $0 ? "PASSED" : "FAILED" })
                    row("温度（直近の温度取得値）", s.temperatureCelsius.map { ValueFormatter.temperature($0) })
                    row("Power On Hours", s.powerOnHours.map { "\($0) h" })
                    row("Power Cycles", s.powerCycleCount.map { String($0) })
                    row("Unsafe Shutdowns", s.unsafeShutdowns.map { String($0) })
                    row("Percentage Used", s.percentageUsed.map { "\($0)%" })
                    row("Available Spare / Threshold", s.availableSpare.map { "\($0)% / \(s.availableSpareThreshold.map { "\($0)%" } ?? "未取得")" })
                    row("Critical Warning", s.criticalWarning.map { String(format: "0x%02x", $0) })
                    row("Media / Data Integrity Errors", s.mediaAndDataIntegrityErrors.map { String($0) })
                    row("Host Reads", ValueFormatter.dataUnits(s.dataUnitsRead, bytes: s.dataUnitsReadBytes))
                    row("Host Writes", ValueFormatter.dataUnits(s.dataUnitsWritten, bytes: s.dataUnitsWrittenBytes))
                    DisclosureGroup(UIString.text("取得JSON")) {
                        Text(verbatim: s.rawJSON.isEmpty ? UIString.text("原データ未保存") : s.rawJSON)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.top, 8)
                    localizedText("シリアル番号などの識別情報を含みます。共有時は除いてください。")
                        .font(.caption).foregroundStyle(AppColor.textSecondary)
                } else {
                    localizedText("未取得").foregroundStyle(AppColor.textSecondary)
                }
            }
            if let s = snapshot {
                section("S.M.A.R.T.追加統計", timestamp: s.capturedAt) {
                    row("Host Read Commands", s.additionalSMART?.hostReadCommands.map { String($0) })
                    row("Host Write Commands", s.additionalSMART?.hostWriteCommands.map { String($0) })
                    row("Controller Busy Time", s.additionalSMART?.controllerBusyMinutes.map { "\($0) min" })
                    row("Error Information Log Entries", s.additionalSMART?.errorLogEntries.map { String($0) })
                    if counterInterval.end == s.capturedAt {
                        row("比較区間", counterInterval.start.map { UIString.dateTime($0) + " → " + UIString.dateTime(s.capturedAt) })
                        row("読込コマンド増分", delta(counterInterval.readCommands))
                        row("書込コマンド増分", delta(counterInterval.writeCommands))
                        row("Busy Time増分", delta(counterInterval.busyMinutes, suffix: " min"))
                        row("エラーログ件数増分", delta(counterInterval.errorLogEntries))
                        row("平均読込要求サイズ", SMARTRequestSizeFormatter.string(counterInterval.averageReadBytes))
                        row("平均書込要求サイズ", SMARTRequestSizeFormatter.string(counterInterval.averageWriteBytes))
                    } else {
                        row("前回からの増分", UIString.text("解析待ち"))
                    }
                    localizedText("要求サイズは同一区間のHost量÷コマンド数です。ランダム／逐次アクセスの判定ではありません。Busy Timeの0は未実装値の可能性もあります。")
                        .font(.caption).foregroundStyle(AppColor.textSecondary)
                }
                section("NVMe機能情報", timestamp: s.capturedAt) {
                    row("TRIM / Deallocate（NVMe対応情報）", support(s.nvmeCapabilities?.deallocateSupported))
                    row("Device Self-test（機器の報告）", support(s.nvmeCapabilities?.selfTestSupported))
                    row("Telemetry Log（機器の報告）", support(s.nvmeCapabilities?.telemetrySupported))
                    row("Firmware Slots", s.nvmeCapabilities?.firmwareSlots.map { String($0) })
                    row("Maximum Data Transfer Pages", s.nvmeCapabilities?.maximumTransferPages.map { String($0) })
                    row("詳細エラーログ", UIString.text("未取得（定期取得なし）"))
                    localizedText("対応情報はコマンドの実行成功やTRIMの実施履歴を示しません。詳細エラー・self-test・telemetryログは自動取得しません。")
                        .font(.caption).foregroundStyle(AppColor.textSecondary)
                }
            }
            section("IORegistry", timestamp: profile?.capturedAt) {
                if let p = profile {
                    row("TRIM / Unmap（IORegistry対応情報）", support(p.unmapSupported))
                    row("モデル", p.modelNumber.isEmpty ? nil : p.modelNumber)
                    row("論理容量", p.logicalCapacityBytes > 0 ? ValueFormatter.decimalCapacity(p.logicalCapacityBytes) : nil)
                    row("接続", p.physicalInterconnect)
                    row("接続位置", p.physicalInterconnectLocation)
                    row("コントローラ", p.controllerClass)
                    row("Chip ID", p.chipID)
                    row("Firmware", p.firmwareVersion)
                    row("MSP Firmware", p.mspVersion)
                    row("NAND vendor", p.nandVendor)
                    row("NAND profile", p.nandMarketingName)
                    row("Bits / cell", p.defaultBitsPerCell.map { String($0) })
                    row("Buses", p.numBus.map { String($0) })
                    row("Dies / bus", p.diesPerBus.map { $0.map { String($0) }.joined(separator: ", ") })
                    row("CAUs / die", p.cauPerDie.map { String($0) })
                    row("Concurrent units", p.numDIP.map { String($0) })
                    row("Page size", p.pageSize.map { "\($0) B" })
                    row("Sectors / page", p.sectorsPerPage.map { String($0) })
                    row("Native pages / block", p.pagesPerBlockNative.map { String($0) })
                    row("SLC pages / block", p.pagesPerBlockSLC.map { String($0) })
                    row("Blocks / CAU", p.blocksPerCAU.map { String($0) })
                    row("Native sectors / full band", p.sectorsPerFullBand.map { String($0) })
                    row("SLC sectors / full band", p.sectorsPerFullBandSLC.map { String($0) })
                    row("Package blocks at EOL", p.packageBlocksAtEOL.map { String($0) })
                    row("NAND status", p.appleNANDStatus)
                    localizedText("保存済みの解析値。IORegistry全文は保存していません。")
                        .font(.caption).foregroundStyle(AppColor.textSecondary)
                } else {
                    localizedText("未取得。設定のIORegistry取得、または手動更新で取得します。")
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func support(_ value: Bool?) -> String? {
        value.map { UIString.text($0 ? "対応" : "非対応") }
    }

    private func delta(_ change: SMARTCounterDelta, suffix: String = "") -> String {
        change.value.map { "+\($0)" + suffix } ?? UIString.text(change.statusKey)
    }

    private func section<Content: View>(
        _ title: String, timestamp: Date?, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                localizedText(title).font(.headline)
                Spacer()
                Text(verbatim: timestamp.map { UIString.dateTime($0) } ?? UIString.text("取得時刻なし"))
                    .font(.caption).foregroundStyle(AppColor.textSecondary)
            }
            Divider()
            content()
        }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            localizedText(title).foregroundStyle(AppColor.textSecondary).frame(width: 240, alignment: .leading)
            Text(verbatim: value ?? UIString.text("未取得")).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.body)
        .padding(.vertical, 3)
    }
}
