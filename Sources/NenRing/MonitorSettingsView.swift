import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case monitoring
    case endurance
    case research

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "一般"
        case .monitoring: return "監視"
        case .endurance: return "寿命予測"
        case .research: return "研究"
        }
    }
}

struct MonitorSettingsView: View {
    @ObservedObject var model: DashboardModel
    @AppStorage("appearanceMode") private var appearanceModeRaw = AppearanceMode.system.rawValue
    @AppStorage(UIString.preferenceKey) private var uiLanguage = "system"
    @AppStorage(TemperatureUnit.preferenceKey) private var temperatureUnitRaw = TemperatureUnit.system.rawValue
    @AppStorage(AppIconController.preferenceKey) private var appIconAppearanceRaw = AppIconAppearance.system.rawValue

    @State private var manualStartDateEnabled: Bool
    @State private var verifiedEnvironmentPendingRemoval: ASPToolVerifiedEnvironment?
    @State private var manualStartDate: Date
    @State private var manualRetentionTemperature: Bool
    @State private var retentionTemperatureText: String
    @State private var retentionDaysText: String
    @State private var hasEdited = false
    @State private var showsDiagnosticReportSheet = false
    @State private var isSaving = false
    @State private var pendingSave: Task<Void, Never>?
    @State private var saveErrorMessage: String?
    @State private var selectedCategory: SettingsCategory

    init(model: DashboardModel, initialCategory: SettingsCategory = .general) {
        self.model = model
        _selectedCategory = State(initialValue: initialCategory)
        let usageSettings = model.usageSettings
        _manualStartDateEnabled = State(initialValue: usageSettings.manualStartDate != nil)
        _manualStartDate = State(initialValue: usageSettings.manualStartDate ?? Date())
        _manualRetentionTemperature = State(initialValue: usageSettings.hasExplicitRetentionTemperatureOverride)
        _retentionTemperatureText = State(initialValue: Self.retentionTemperatureText(
            usageSettings.retentionStorageTemperatureCelsius, unit: .current))
        _retentionDaysText = State(initialValue: String(format: "%g", usageSettings.retentionDays ?? 365))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                localizedText(selectedCategory.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                Spacer()
                localizedText(model.snapshot?.model ?? "NVMe")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(AppColor.textMuted)
                    .lineLimit(1)
            }
            .padding(.bottom, 8)

            Picker(UIString.text("カテゴリ"), selection: $selectedCategory) {
                ForEach(SettingsCategory.allCases) { category in
                    localizedText(category.title).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.bottom, 8)

            Form {
                if selectedCategory == .general {
                Section(UIString.text("外観")) {
                    Picker(UIString.text("言語"), selection: $uiLanguage) {
                        localizedText("システムに合わせる").tag("system")
                        Text(verbatim: "日本語").tag("ja")
                        Text(verbatim: "English").tag("en")
                    }
                    localizedText("言語の変更はすぐに画面へ反映されます。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)

                    Picker(UIString.text("温度の単位"), selection: $temperatureUnitRaw) {
                        ForEach(TemperatureUnit.allCases) { unit in
                            localizedText(unit.title).tag(unit.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    localizedText("画面とメニューバーの表示に使用します。研究・診断の表示とレポートは摂氏のままです。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)

                    Picker(UIString.text("表示"), selection: $appearanceModeRaw) {
                        ForEach(AppearanceMode.allCases) { mode in
                            localizedText(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker(UIString.text("アプリアイコン"), selection: $appIconAppearanceRaw) {
                        ForEach(AppIconAppearance.allCases) { appearance in
                            localizedText(appearance.title).tag(appearance.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    localizedText("自動ではmacOSの外観に合わせて、起動中のDock／App Switcherアイコンを切り替えます。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section(UIString.text("メニューバー")) {
                    Toggle(UIString.text("温度"), isOn: $model.menuBarShowsTemperature)
                    Toggle(UIString.text("残り（%）"), isOn: $model.menuBarShowsWear)
                    Toggle(UIString.text("残り年数（保存履歴のペース）"), isOn: $model.menuBarShowsRemainingYears)
                    Toggle(UIString.text("今日の書込"), isOn: $model.menuBarShowsTodayWrites)
                    RealtimeIOSettings(monitor: model.realtimeIO)
                    localizedText("選んだ値を、メニューバーのアイコンの横に並べて表示します。問題があるときは、アイコンが警告の形に変わります。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section(UIString.text("起動と表示")) {
                    Toggle(UIString.text("ログイン時に起動"), isOn: $model.launchAtLoginEnabled)

                    if model.launchAtLoginEnabled {
                        Label(
                            UIString.readout(model.loginItemStatus.detail),
                            systemImage: loginItemStatusIcon
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(loginItemStatusColor)
                        .fixedSize(horizontal: false, vertical: true)

                        if model.loginItemStatus == .requiresApproval || model.loginItemStatus == .notFound {
                            Button(UIString.text("ログイン項目を開く")) {
                                model.openLoginItemsSettings()
                            }
                        }
                    }

                    if let loginItemErrorMessage = model.loginItemErrorMessage {
                        Label(UIString.message(loginItemErrorMessage), systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColor.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Toggle(UIString.text("Dockに表示"), isOn: $model.dockIconVisible)
                    localizedText("変更は次回起動時に反映されます。Dockを隠しても、メニューバーからメイン画面を開けます。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.dockVisibilityRequiresRestart {
                        Label(UIString.text("反映するにはNenRingを終了し、もう一度開いてください。"), systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColor.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                }

                if selectedCategory == .monitoring {
                Section(UIString.text("監視")) {
                    Toggle(UIString.text("常駐監視"), isOn: $model.backgroundMonitoringEnabled)
                    localizedText("ウィンドウを閉じてもメニューバーから定期取得を続けます。アプリを終了すると停止します。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Picker(UIString.text("取得間隔（SMART・FTL）"), selection: $model.refreshInterval) {
                        ForEach(RefreshInterval.allCases) { interval in
                            localizedText(interval.title).tag(interval)
                        }
                    }
                    .pickerStyle(.menu)

                    localizedText("SMARTとFTLを同じ周期で取得し、予測はその都度1回のみ作り直します。温度は別の周期で更新します。")
                        .font(.caption)
                        .foregroundStyle(AppColor.textSecondary)

                    Picker(UIString.text("温度計測"), selection: $model.temperatureMonitoringInterval) {
                        ForEach(TemperatureMonitoringInterval.allCases) { interval in
                            localizedText(interval.title).tag(interval)
                        }
                    }
                    .pickerStyle(.menu)

                    localizedText("SMART全体の取得とは別に、温度のみをこの間隔で記録します。常駐監視が有効なときに動作します。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Picker(UIString.text("ioreg情報"), selection: $model.ioRegistryCollectionInterval) {
                        ForEach(IORegistryCollectionInterval.allCases) { interval in
                            localizedText(interval.title).tag(interval)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack(alignment: .firstTextBaseline) {
                        localizedText("ioregの再取得")
                        Spacer()
                        Button(UIString.text("今すぐ取得")) {
                            Task { await model.refreshIORegistryNow() }
                        }
                        .disabled(model.snapshot == nil || model.isIORegistryRefreshing)
                    }

                    localizedText(model.ioRegistryCollectionInterval.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let lastAttempt = model.ioRegistryLastAttemptAt {
                        localizedText(
                            model.ioRegistryStatusMessage
                            ?? "最終試行: \(UIString.dateTime(lastAttempt))"
                        )
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(model.ioRegistryConsecutiveFailures > 0 ? AppColor.amber : AppColor.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Direct FTL applies only to Apple internal storage, so its
                    // schedule and manual read are offered only there.
                    if model.deviceCapabilities.appleDirectFTLEligible {
                        Toggle(UIString.text("FTLも自動で取得する"), isOn: $model.aspDirectFTLAutomaticCollection)

                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                localizedText("FTL all")
                                if let lastSuccess = model.aspDirectFTLLastSuccessAt {
                                    localizedText("最終成功: \(UIString.dateTime(lastSuccess))")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(AppColor.textSecondary)
                                } else {
                                    localizedText("未取得")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(AppColor.textSecondary)
                                }
                            }
                            Spacer()
                            Button(UIString.text("今すぐ取得")) {
                                Task { await model.refreshASPDirectFTLNow() }
                            }
                            .disabled(
                                model.isASPDirectFTLRefreshing ||
                                    model.isASPDirectGenerating ||
                                    model.isASPDirectInspecting
                            )
                        }

                        if model.isASPDirectFTLRefreshing {
                            Label(UIString.text("FTL allを取得中…"), systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(AppColor.textSecondary)
                        } else if let status = model.aspDirectFTLStatusMessage {
                            localizedText(status)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(AppColor.textSecondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }

                        localizedText(model.aspDirectFTLAutomaticCollection
                            ? "sysdiagnoseやsudoを使わず、SMARTと同じ周期で、FTL allを通常権限で取得します。照合に失敗したときや3回続けて失敗したときは、自動でオフになります。"
                            : "FTL allの自動取得は行いません。上の「今すぐ取得」から必要なときに取得できます。")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        localizedText("FTL直接取得は、Appleの内蔵SSDを確認できたときのみ使えます。選択中のディスクでは使いません。")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Picker(UIString.text("スリープ中"), selection: $model.sleepMonitoringMode) {
                        ForEach(SleepMonitoringMode.allCases) { mode in
                            localizedText(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    localizedText(model.sleepMonitoringMode.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section(UIString.text("簡易チェック")) {
                    Picker(UIString.text("チェックと通知"), selection: $model.reliabilityCheckSchedule) {
                        ForEach(ReliabilityCheckSchedule.allCases) { schedule in
                            localizedText(schedule.title).tag(schedule)
                        }
                    }
                    .pickerStyle(.menu)

                    localizedText("取得済みの値だけを前回のチェックと比べます。新しい取得や読み込みは行いません。SMARTの警告・エラー、内部エラー、保持処理のペース上昇が新たに見つかったときに通知します。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.reliabilityCheckSchedule != .off, model.reliabilityCheckNotificationsAllowed == false {
                        localizedText("通知が許可されていません。結果は「内部エラーと保持処理」のページに表示します。")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColor.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let check = model.lastReliabilityCheck {
                        localizedText(check.hasFindings
                            ? UIString.format("前回のチェック: %@ · 検出 %d件", UIString.dateTime(check.checkedAt), check.findings.count)
                            : UIString.format("前回のチェック: %@ · 新たな検出なし", UIString.dateTime(check.checkedAt)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(check.hasFindings ? AppColor.amber : AppColor.textMuted)
                    }
                }
                }

                if selectedCategory == .research {
                Section(UIString.text("asptoolログの照合（研究）")) {
                    localizedText("asptool_snapshot.log（sysdiagnoseに含まれます）を読み込むと、近い時刻のDirect FTLと値を比べ、基準内で一致したかを判定します。アプリがasptoolやsysdiagnoseを実行することはありません。読み込んだログは寿命予測には使用しません。照合結果はResearchの「生データ」に表示します。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            localizedText("sysdiagnose")
                            Spacer()
                            if model.sysdiagnoseWaitStartedAt != nil {
                                ProgressView()
                                    .controlSize(.small)
                                Button(UIString.text("待機を中止")) {
                                    model.cancelSysdiagnoseWait()
                                }
                            } else {
                                Button(UIString.text("ターミナルで実行…")) {
                                    model.runSysdiagnoseInTerminal()
                                }
                                Button(UIString.text("最新のsysdiagnoseから読み込む")) {
                                    Task { await model.importLatestSysdiagnose() }
                                }
                                .disabled(model.isASPToolRefreshing)
                            }
                        }
                        localizedText("「ターミナルで実行…」を押すと、ターミナルで sudo sysdiagnose を開始します。パスワード（設定によってはTouch ID）の入力と、Enterキーでの確認はターミナルで行います。NenRingはパスワードを扱いません。完了まで数分かかり、完了するとFinderに出力ファイルが表示されます。NenRingは /private/var/tmp に作成されたsysdiagnoseからasptool_snapshot.logのみを取り出して読み込みます。")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            localizedText("読み込んだログ")
                            localizedText(model.asptoolSourceName)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(AppColor.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(UIString.text("読み込む…")) {
                            Task { await model.chooseASPToolSource() }
                        }
                        .disabled(model.isASPToolExtracting)
                        if model.asptoolSourceURL != nil {
                            Button(UIString.text("再解析")) {
                                Task { await model.reimportASPToolNow() }
                            }
                            .disabled(model.isASPToolRefreshing)
                            Button(UIString.text("解除")) {
                                model.clearASPToolSource()
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    HStack(alignment: .firstTextBaseline) {
                        localizedText("状態")
                            .foregroundStyle(AppColor.textSecondary)
                        Spacer()
                        if model.isASPToolExtracting {
                            ProgressView()
                                .controlSize(.small)
                            localizedText("sysdiagnoseを展開中…")
                                .font(.system(size: 11, design: .monospaced))
                            Button(UIString.text("中止")) {
                                model.cancelASPToolExtraction()
                            }
                        } else if model.isASPToolRefreshing {
                            ProgressView()
                                .controlSize(.small)
                            localizedText("読み込み中…")
                                .font(.system(size: 11, design: .monospaced))
                        } else {
                            localizedText(model.asptoolStatusMessage ?? (model.asptoolSourceURL == nil ? "未読込" : "読み込み済み"))
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        localizedText("このMacで確認済みの環境")
                        if model.asptoolVerifiedEnvironments.isEmpty {
                            localizedText("まだありません")
                                .font(.system(size: 11))
                                .foregroundStyle(AppColor.textSecondary)
                        } else {
                            ForEach(model.asptoolVerifiedEnvironments.reversed()) { record in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    localizedText(record.summary)
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button(UIString.text("削除…")) {
                                        verifiedEnvironmentPendingRemoval = record
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        localizedText("照合が基準内で一致し、sysdiagnoseに含まれるmacOSとSSDファームウェアもDirect FTLと一致した環境を、macOSのメジャーバージョンとファームウェア系列（例：macOS 27・591）ごとに記録し、診断レポートに含めます。各行には最後に確認したmacOS build・ファームウェア・ログの日付を表示します。ログ単体を読み込んだ場合は取得元を確認できないため、記録しません。診断レポートに含めるのはmacOS build・macOSのバージョン・ファームウェア・ログの日付のみで、ログの内容は含めません。取得元が一致したログで不一致になった場合は記録を取り消します。削除した記録は、同じログで同じ判定が出ても再び追加しません。表示のための記録で、取得の可否や寿命予測には影響しません。")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .confirmationDialog(
                        UIString.text("この確認済みの記録を削除しますか？"),
                        isPresented: Binding(
                            get: { verifiedEnvironmentPendingRemoval != nil },
                            set: { if !$0 { verifiedEnvironmentPendingRemoval = nil } }
                        ),
                        presenting: verifiedEnvironmentPendingRemoval
                    ) { record in
                        Button(UIString.text("削除"), role: .destructive) {
                            model.removeASPToolVerifiedEnvironment(id: record.id)
                        }
                        Button(UIString.text("キャンセル"), role: .cancel) {}
                    } message: { record in
                        localizedText(record.summary)
                    }
                }

                Section(UIString.text("ASP直接取得（検証）")) {
                    HStack {
                        localizedText("取得先の対応")
                        Spacer()
                        localizedText(model.storageTargetResolution.reason)
                            .font(.system(size: 11))
                            .foregroundStyle(AppColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    localizedText("選択中のディスクに対応付けた固定probeで取得します。FTL allは取得先とSMARTの照合後に反映します。macOS 14・15は暫定取得対象です。対応が曖昧な値や形式未確認の値は予測に使いません。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Picker(UIString.text("取得対象"), selection: $model.aspDirectProbeRequest) {
                        ForEach(ASPDirectProbeRequest.allCases) { request in
                            localizedText(request.title).tag(request)
                        }
                    }
                    .pickerStyle(.menu)

                    localizedText(model.aspDirectProbeRequest.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        localizedText("アプリ内probe")
                            .foregroundStyle(AppColor.textSecondary)
                        Spacer()
                        Button(UIString.text("生成・取得")) {
                            Task { await model.generateASPDirectNow() }
                        }
                        .disabled(
                            model.isASPDirectGenerating ||
                                model.isASPDirectInspecting ||
                                model.isASPDirectFTLRefreshing
                        )
                        Button(UIString.text("解析")) {
                            Task { await model.analyzeCurrentASPDirectArtifact() }
                        }
                        .disabled(
                            model.aspDirectArtifactPath == nil ||
                                model.isASPDirectGenerating ||
                                model.isASPDirectInspecting ||
                                model.isASPDirectFTLRefreshing
                        )
                    }
                    .controlSize(.small)

                    if let generationStatus = model.aspDirectGenerationStatusMessage {
                        Label(UIString.message(generationStatus), systemImage: "checkmark.circle")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(AppColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            localizedText("検証データ")
                            localizedText(
                                model.aspDirectArtifactPath ??
                                    model.aspDirectInspection?.directoryPath ??
                                    (model.aspDirectFTLInspection == nil ? "未選択" : "直近のFTL統計は履歴へ保存済み")
                            )
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AppColor.textMuted)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(UIString.text("選択…")) {
                            Task { await model.chooseASPDirectArtifact() }
                        }
                        if model.aspDirectInspection != nil ||
                            model.aspDirectFTLInspection != nil ||
                            model.aspBandStatsInspection != nil ||
                            model.aspDirectOpaqueInspection != nil ||
                            model.aspDirectArtifactPath != nil {
                            Button(UIString.text("解除")) {
                                model.clearASPDirectInspection()
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    if model.isASPDirectGenerating {
                        Label(UIString.text("生成・取得中…"), systemImage: "arrow.down.circle")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(AppColor.textSecondary)
                    } else if model.isASPDirectInspecting {
                        Label(UIString.text("検証中…"), systemImage: "hourglass")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(AppColor.textSecondary)
                    } else if let inspection = model.aspDirectInspection {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(
                                    UIString.text(inspection.measurement.outcome.title),
                                    systemImage: directOutcomeIcon(inspection.measurement.outcome)
                                )
                                .foregroundStyle(directOutcomeColor(inspection.measurement.outcome))
                                Spacer()
                                localizedText(inspection.statusTitle)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(inspection.parseError == nil ? AppColor.textPrimary : AppColor.red)
                            }

                            directInspectionRow("Target", "\(inspection.measurement.build) / \(inspection.measurement.controller)")
                            directInspectionRow("Opcode", String(format: "0x%02x · %@", inspection.measurement.opcode.rawValue, inspection.measurement.opcode.title))
                            directInspectionRow("権限", "euid \(inspection.measurement.effectiveUserID)")
                            directInspectionRow(
                                "サイズ",
                                "要求 \(directBytelocalizedText(inspection.measurement.requestedBytes)) / 応答 \(directBytelocalizedText(inspection.measurement.snapshotReadResponseBytes)) / 保存 \(directBytelocalizedText(inspection.binaryByteCount))"
                            )
                            directInspectionRow(
                                "時間",
                                String(format: "size %.1f ms · read %.1f ms · total %.1f ms", inspection.measurement.sizeQueryElapsedMilliseconds, inspection.measurement.snapshotReadElapsedMilliseconds, inspection.measurement.totalElapsedMilliseconds)
                            )
                            directInspectionRow("形式", inspection.formatTitle)
                            if let capturedAt = inspection.measurement.capturedAt {
                                directInspectionRow("取得時刻", ValueFormatter.fullDate(capturedAt))
                            } else {
                                directInspectionRow("取得時刻", "未記録（現在時刻は補完していません）")
                            }

                            if let evidence = inspection.headerEvidence {
                                directInspectionRow(
                                    "0x91 header",
                                    "revision \(evidence.helperRevisionField) · declared \(directBytelocalizedText(Int(evidence.declaredSnapshotBytes))) · offset \(evidence.referencedTableOffset)"
                                )
                            }

                            ForEach(inspection.warnings, id: \.self) { warning in
                                localizedText("• \(warning)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(AppColor.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 3)
                    } else if let inspection = model.aspDirectFTLInspection {
                        directFTLInspectionView(inspection)
                    } else if let inspection = model.aspBandStatsInspection {
                        directBandStatsInspectionView(inspection)
                    } else if let inspection = model.aspDirectOpaqueInspection {
                        directOpaqueInspectionView(inspection)
                    } else {
                        Label(
                            UIString.readout(model.aspDirectStatusMessage ?? "未取得。保存済みprobeの取得フォルダを選択できます。"),
                            systemImage: "info.circle"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                }

                if selectedCategory == .endurance {
                Section(UIString.text("基準")) {
                    Toggle(UIString.text("使用開始日"), isOn: manualStartDateEnabledBinding)
                    DatePicker(
                        UIString.text("日付"),
                        selection: manualStartDateBinding,
                        displayedComponents: .date
                    )
                    .disabled(!manualStartDateEnabled)

                    if let validationMessage {
                        Label(UIString.message(validationMessage), systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(AppColor.red)
                    }

                    if let preview = usageStartPreview {
                        localizedText(preview)
                            .font(.system(size: 11))
                            .foregroundStyle(AppColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    localizedText("使用開始日は使用日数と平均値の表示に使用します。到達予測は保存履歴を基準とし、記録が7日未満の間のみ使用開始日からのペースを暫定で使用します。観測期間が短い間は書込ペースに * が付きます。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section(UIString.text("保持考慮")) {
                    Toggle(UIString.text("温度を指定"), isOn: Binding(
                        get: { manualRetentionTemperature },
                        set: { manualRetentionTemperature = $0; markEdited() }))
                    if manualRetentionTemperature {
                        TextField(UIString.format("指定温度（%@）", temperatureUnit.symbol), text: Binding(
                            get: { retentionTemperatureText },
                            set: { retentionTemperatureText = $0; markEdited() }))
                    } else {
                        Text(verbatim: UIString.format("%@を基準に、低負荷時の実測温度を自動採用。温度観測がなければ暫定%@を使います。",
                                                       referenceTemperatureText, referenceTemperatureText))
                            .font(.caption).foregroundStyle(AppColor.textSecondary)
                    }
                    Text(verbatim: UIString.format("%@は比較の基準温度です。指定しない場合、予測には基準値ではなく低負荷時の温度を使います。", referenceTemperatureText))
                        .font(.caption).foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(UIString.text("保持日数"), text: Binding(
                        get: { retentionDaysText }, set: { retentionDaysText = $0; markEdited() }))
                    localizedText("電源OFF後は通常アイドル実測より低温になります。非通電中の温度は測定していません。")
                        .font(.caption).foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section(UIString.text("自動推定の優先順")) {
                    localizedText("手動日付 → ドライブ報告値 → Power On Hours → 初回観測")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    localizedText("設定はこのMacにドライブごとに保存されます。")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)
                }

                }

                if selectedCategory == .general {
                Section(UIString.text("アプリ")) {
                    HStack {
                        localizedText("バージョン")
                        Spacer()
                        localizedText(AppVersion.detailLabel)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppColor.textSecondary)
                            .textSelection(.enabled)
                        }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            localizedText("診断レポート")
                            localizedText("ほかのMacでの動作確認に使うファイルを保存し、GitHubで共有する手順を案内します。シリアル番号とデバイスパスは含まず、自動送信もしません。")
                                .font(.caption)
                                .foregroundStyle(AppColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button(UIString.text("提供する…")) {
                            showsDiagnosticReportSheet = true
                        }
                        .sheet(isPresented: $showsDiagnosticReportSheet) {
                            DiagnosticReportSheet(model: model)
                                .environment(\.locale, UIString.locale)
                        }
                    }
                }
                }
            }
            .formStyle(.grouped)

            if selectedCategory == .endurance, let saveStatusMessage {
                Label(
                    UIString.message(saveStatusMessage),
                    systemImage: saveErrorMessage == nil ? "info.circle" : "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(saveErrorMessage == nil ? AppColor.textSecondary : AppColor.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            }

            if selectedCategory == .endurance {
                HStack {
                    Button(UIString.text("自動推定に戻す")) {
                        manualStartDateEnabled = false
                        markEdited()
                    }
                    .disabled(!manualStartDateEnabled)
                    Spacer()
                }
                .padding(.top, 12)
            }
        }
        .padding(20)
        // Opens at the ideal size; the window can be resized down to the minimum.
        .frame(minWidth: 560, idealWidth: 680, maxWidth: .infinity,
               minHeight: 520, idealHeight: 800, maxHeight: .infinity)
        .preferredColorScheme(AppearanceMode(rawValue: appearanceModeRaw)?.colorScheme)
        .task {
            model.refreshLoginItemStatus()
            AppIconController.applyCurrentPreference()
        }
        .onChange(of: appIconAppearanceRaw) { _, _ in
            AppIconController.applyCurrentPreference()
        }
        .onChange(of: temperatureUnitRaw) { oldRaw, _ in
            // Keep the typed temperature: read it in the old unit and show
            // it in the new one.
            let oldUnit = (TemperatureUnit(rawValue: oldRaw) ?? .system).resolved()
            guard let value = Self.parsedNumber(retentionTemperatureText) else { return }
            retentionTemperatureText = Self.retentionTemperatureText(oldUnit.celsius(from: value), unit: temperatureUnit)
        }
        .onChange(of: model.snapshot == nil) { _, hasNoSnapshot in
            // An edit made before the first SMART read could not be saved;
            // save it once the drive is known.
            if !hasNoSnapshot, hasEdited { save() }
        }
        .onChange(of: model.usageSettings) { _, newSettings in
            guard !hasEdited, !isSaving else { return }
            manualStartDateEnabled = newSettings.manualStartDate != nil
            manualStartDate = newSettings.manualStartDate ?? Date()
            manualRetentionTemperature = newSettings.hasExplicitRetentionTemperatureOverride
            retentionTemperatureText = Self.retentionTemperatureText(newSettings.retentionStorageTemperatureCelsius, unit: temperatureUnit)
            retentionDaysText = String(format: "%g", newSettings.retentionDays ?? 365)
        }
    }

    private var validationMessage: String? {
        if manualRetentionTemperature {
            guard let value = retentionTemperatureCelsius, (-40...85).contains(value) else {
                return UIString.format("指定温度は%@〜%@で入力してください。",
                                       temperatureUnit.text(-40, digits: 0), temperatureUnit.text(85, digits: 0))
            }
        }
        guard let days = Double(retentionDaysText), days.isFinite, days > 0 else {
            return "保持日数は正の数で入力してください。"
        }
        if manualStartDateEnabled,
           let message = UsageStartSummary.validationMessage(start: manualStartDate, snapshot: model.snapshot, now: Date()) {
            return message
        }
        return nil
    }

    private var canSave: Bool {
        validationMessage == nil && model.snapshot != nil
    }

    /// Shows what the date implies at once, so a wrong year stands out.
    private var usageStartPreview: String? {
        guard manualStartDateEnabled, validationMessage == nil, let snapshot = model.snapshot,
              let summary = UsageStartSummary(start: manualStartDate, snapshot: snapshot) else { return nil }
        return UIString.format("%@日 · 平均 %@ 時間/日 · 書込 %@/日",
                               ValueFormatter.integer(UInt64(summary.elapsedDays)),
                               summary.averagePowerOnHoursPerDay.map { String(format: "%.1f", $0) } ?? "—",
                               summary.hostBytesPerDay.map { ValueFormatter.bytes($0) } ?? "—")
    }

    private var saveStatusMessage: String? {
        if let saveErrorMessage {
            return saveErrorMessage
        }
        guard model.snapshot == nil else { return nil }
        return "ストレージを確認中のため、寿命予測の設定はまだ保存できません。"
    }

    private var loginItemStatusIcon: String {
        switch model.loginItemStatus {
        case .enabled: return "checkmark.circle.fill"
        case .requiresApproval, .notFound: return "exclamationmark.triangle.fill"
        case .unknown, .notRegistered: return "info.circle"
        }
    }

    private var loginItemStatusColor: Color {
        switch model.loginItemStatus {
        case .enabled: return AppColor.positive
        case .requiresApproval, .notFound: return AppColor.amber
        case .unknown, .notRegistered: return AppColor.textSecondary
        }
    }

    /// Settings apply as soon as they are valid, like standard macOS settings
    /// windows. Typing is debounced so each keystroke does not rewrite history.
    private func markEdited() {
        hasEdited = true
        saveErrorMessage = nil
        pendingSave?.cancel()
        pendingSave = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        guard canSave else { return }
        var settings = model.usageSettings.withStartBasis(
            manualStartDate: manualStartDateEnabled ? manualStartDate : nil
        )
        settings = settings.withRetentionInputs(
            manualTemperatureCelsius: manualRetentionTemperature ? retentionTemperatureCelsius : nil,
            days: Double(retentionDaysText))
        isSaving = true
        saveErrorMessage = nil
        Task {
            let saved = await model.updateUsageSettings(settings)
            if saved {
                // Let the form follow the stored settings again.
                hasEdited = false
            } else {
                saveErrorMessage = "寿命予測の設定を保存できませんでした。もう一度お試しください。"
            }
            isSaving = false
        }
    }

    private var manualStartDateEnabledBinding: Binding<Bool> {
        Binding(
            get: { manualStartDateEnabled },
            set: { value in
                manualStartDateEnabled = value
                markEdited()
            }
        )
    }

    private var manualStartDateBinding: Binding<Date> {
        Binding(
            get: { manualStartDate },
            set: { value in
                manualStartDate = value
                markEdited()
            }
        )
    }

    @ViewBuilder
    private func directFTLInspectionView(_ inspection: ASPToolDirectFTLParseResult) -> some View {
        let outcome: ASPDirectReadOutcome = inspection.measurement.isSuccessfulRead ? .success : .readFailed
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(
                    UIString.text(outcome.title),
                    systemImage: directOutcomeIcon(outcome)
                )
                .foregroundStyle(directOutcomeColor(outcome))
                Spacer()
                localizedText("FTL all")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppColor.textPrimary)
            }

            directInspectionRow("Target", "\(inspection.measurement.build) / GetNVMeSMARTInterface")
            directInspectionRow(
                "Method",
                "all · vtable \(String(format: "0x%x", inspection.measurement.vtableOffset))"
            )
            directInspectionRow("権限", "euid \(inspection.measurement.effectiveUserID)")
            directInspectionRow(
                "サイズ",
                "応答 \(directBytelocalizedText(inspection.measurement.responseBytes)) / capacity \(directBytelocalizedText(inspection.measurement.capacityBytes))"
            )
            directInspectionRow(
                "時間",
                String(
                    format: "read %.1f ms · total %.1f ms",
                    inspection.measurement.elapsedMilliseconds,
                    inspection.measurement.totalElapsedMilliseconds
                )
            )
            directInspectionRow("records", String(inspection.records.count))
            directInspectionRow("形式", inspection.measurement.formatStatus)
            if let capturedAt = inspection.measurement.capturedAt {
                directInspectionRow("取得時刻", ValueFormatter.fullDate(capturedAt))
            } else {
                directInspectionRow("取得時刻", "未記録（現在時刻は補完していません）")
            }

            if let snapshot = inspection.snapshot {
                directInspectionRow("hostWrites raw", ValueFormatter.integer(snapshot.hostWrites))
                directInspectionRow("nandWrites raw", ValueFormatter.integer(snapshot.nandWrites))
                directInspectionRow("Power On Hours", ValueFormatter.integer(snapshot.powerOnHours))
                directInspectionRow(
                    "Bad Blocks",
                    "Factory \(ValueFormatter.integer(snapshot.factoryBadBlocks)) / Grown \(ValueFormatter.integer(snapshot.grownBadBlocks))"
                )
                directInspectionRow("Write Amp", decimallocalizedText(snapshot.writeAmp, digits: 6))
                directInspectionRow("Intermediate WA", decimallocalizedText(snapshot.intermediateWriteAmp, digits: 6))
                directInspectionRow(
                    "TLC P/E",
                    peSummarylocalizedText(snapshot.tlcMinimumPE, snapshot.tlcAveragePE, snapshot.tlcMaximumPE, eol: snapshot.tlcEOLPE)
                )
                directInspectionRow(
                    "pSLC P/E",
                    peSummarylocalizedText(snapshot.slcMinimumPE, snapshot.slcAveragePE, snapshot.slcMaximumPE, eol: snapshot.slcEOLPE)
                )
                directInspectionRow("NAND / Host", decimallocalizedText(snapshot.writeAmplification, digits: 3))
                directInspectionRow("Units", snapshot.hostWritesUnitState.title)

                if snapshot.controllerPercentUsed != nil ||
                    snapshot.slcPercentUsed != nil ||
                    snapshot.spareAvailablePercent != nil ||
                    snapshot.numDieFailures != nil ||
                    snapshot.hostAutoWrites != nil ||
                    snapshot.hostAutoWriteTransactions != nil ||
                    snapshot.intermediateBandsProgrammed != nil ||
                    snapshot.userBandsProgrammed != nil ||
                    snapshot.intermediateNandWrites != nil ||
                    snapshot.userNandWrites != nil ||
                    snapshot.performanceUserErases != nil ||
                    snapshot.performanceIntermediateErases != nil ||
                    snapshot.intermediateBandErases != nil ||
                    snapshot.oslcTransitions != nil ||
                    snapshot.oslcBaseAveragePE != nil ||
                    snapshot.hostWriteCompositionCandidateKey5 != nil ||
                    snapshot.hostWriteCompositionCandidateKey6 != nil ||
                    snapshot.hostWriteCompositionCandidateKey27 != nil {
                    localizedText("ASP内部統計（FTL key照合 / raw表示専用）")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColor.textSecondary)
                        .padding(.top, 3)
                    directInspectionRow(
                        "Controller / pSLC %",
                        "\(snapshot.controllerPercentUsed.map { String(format: "%.0f%%", $0) } ?? "未取得") / \(snapshot.slcPercentUsed.map { String(format: "%.0f%%", $0) } ?? "未取得")"
                    )
                    directInspectionRow("Available Spare", snapshot.spareAvailablePercent.map { String(format: "%.0f%%", $0) } ?? "未取得")
                    directInspectionRow("Die Failures", ValueFormatter.integer(snapshot.numDieFailures))
                    directInspectionRow("Host Auto Writes · raw", ValueFormatter.integer(snapshot.hostAutoWrites))
                    directInspectionRow("Auto Write Xacts · raw", ValueFormatter.integer(snapshot.hostAutoWriteTransactions))
                    directInspectionRow(
                        "RxBurn Bands · raw",
                        "\(ValueFormatter.integer(snapshot.intermediateBandsProgrammed)) / \(ValueFormatter.integer(snapshot.userBandsProgrammed))"
                    )
                    directInspectionRow(
                        "RxBurn NAND · raw",
                        "\(ValueFormatter.integer(snapshot.intermediateNandWrites)) / \(ValueFormatter.integer(snapshot.userNandWrites))"
                    )
                    directInspectionRow(
                        "Perf Erases · raw",
                        "\(ValueFormatter.integer(snapshot.performanceUserErases)) / \(ValueFormatter.integer(snapshot.performanceIntermediateErases))"
                    )
                    directInspectionRow("Intermediate Band Erases · raw", ValueFormatter.integer(snapshot.intermediateBandErases))
                    directInspectionRow(
                        "oSLC Transitions / Base P/E",
                        "\(ValueFormatter.integer(snapshot.oslcTransitions)) / \(decimallocalizedText(snapshot.oslcBaseAveragePE, digits: 0))"
                    )
                    directInspectionRow(
                        "Host composition candidates 5 / 6 / 27",
                        "\(ValueFormatter.integer(snapshot.hostWriteCompositionCandidateKey5)) / \(ValueFormatter.integer(snapshot.hostWriteCompositionCandidateKey6)) / \(ValueFormatter.integer(snapshot.hostWriteCompositionCandidateKey27))"
                    )
                    localizedText("既存のASP内部統計は25G83のasptoolラベルと照合済みです。単位未確認のため、容量・寿命予測には使用しません。")
                        .font(.system(size: 10))
                        .foregroundStyle(AppColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if snapshot.hostWriteCompositionCandidateKey5 != nil ||
                        snapshot.hostWriteCompositionCandidateKey6 != nil ||
                        snapshot.hostWriteCompositionCandidateKey27 != nil {
                        localizedText("composition候補5 / 6 / 27はraw観測のみ。近接asptoolのdeltaと合計不変量を確認するまで意味付けしません。")
                            .font(.system(size: 10))
                            .foregroundStyle(AppColor.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ForEach(inspection.warnings, id: \.self) { warning in
                localizedText("• \(warning)")
                    .font(.system(size: 10))
                    .foregroundStyle(AppColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 3)
    }

    @ViewBuilder
    private func directBandStatsInspectionView(_ inspection: ASPBandStatsParseResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(
                    UIString.text(inspection.measurement.outcome.title),
                    systemImage: directOutcomeIcon(inspection.measurement.outcome)
                )
                .foregroundStyle(directOutcomeColor(inspection.measurement.outcome))
                Spacer()
                localizedText("0x106 · \(inspection.measurement.opcode.title)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppColor.textPrimary)
            }

            directInspectionRow("Target", "\(inspection.measurement.build) / \(inspection.measurement.controller)")
            directInspectionRow("Opcode", String(format: "0x%03x", inspection.measurement.opcode.rawValue))
            directInspectionRow("権限", "euid \(inspection.measurement.effectiveUserID)")
            directInspectionRow(
                "サイズ",
                "要求 \(directBytelocalizedText(inspection.measurement.requestedBytes)) / 応答 \(directBytelocalizedText(inspection.measurement.responseBytes)) / capacity \(directBytelocalizedText(inspection.measurement.capacityBytes))"
            )
            directInspectionRow(
                "時間",
                String(
                    format: "read %.1f ms · total %.1f ms",
                    inspection.measurement.elapsedMilliseconds,
                    inspection.measurement.totalElapsedMilliseconds
                )
            )
            directInspectionRow(
                "構造",
                "bands \(inspection.bandCount) · partitions \(inspection.partitionCount) · records \(inspection.records.count)"
            )
            directInspectionRow(
                "領域",
                "使用 \(directBytelocalizedText(inspection.usedBytes)) / 末尾未解析 \(directBytelocalizedText(inspection.trailingBytes))"
            )
            if let summary = inspection.eraseCycleSummary {
                directInspectionRow(
                    "erase候補",
                    "min \(summary.minimum) · avg \(String(format: "%.1f", summary.average)) · max \(summary.maximum)"
                )
                directInspectionRow("値の種類", bandEraseDistributionlocalizedText(summary))
            }
            if let capturedAt = inspection.measurement.capturedAt {
                directInspectionRow("取得時刻", ValueFormatter.fullDate(capturedAt))
            } else {
                directInspectionRow("取得時刻", "未記録（現在時刻は補完していません）")
            }
            directInspectionRow("分類", "TLC / pSLC / EoL 未確認")

            ForEach(inspection.warnings, id: \.self) { warning in
                localizedText("• \(warning)")
                    .font(.system(size: 10))
                    .foregroundStyle(AppColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 3)
    }

    private func bandEraseDistributionlocalizedText(_ summary: ASPBandEraseCycleSummary) -> String {
        summary.valueCounts.keys.sorted().map { value in
            "\(value)×\(summary.valueCounts[value] ?? 0)"
        }.joined(separator: " · ")
    }

    @ViewBuilder
    private func directOpaqueInspectionView(_ inspection: ASPDirectOpaqueInspection) -> some View {
        switch inspection {
        case let .ftl(inspection):
            let outcome: ASPDirectReadOutcome = inspection.measurement.isSuccessfulRead ? .success : .readFailed
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(UIString.text(outcome.title), systemImage: directOutcomeIcon(outcome))
                        .foregroundStyle(directOutcomeColor(outcome))
                    Spacer()
                    localizedText("FTL \(inspection.measurement.kind.rawValue) · 形式未確認")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                directInspectionRow("Target", "\(inspection.measurement.build) / GetNVMeSMARTInterface")
                directInspectionRow(
                    "Method",
                    "\(inspection.measurement.kind.rawValue) · vtable \(String(format: "0x%x", inspection.measurement.vtableOffset))"
                )
                directInspectionRow("権限", "euid \(inspection.measurement.effectiveUserID)")
                directInspectionRow(
                    "サイズ",
                    "応答 \(directBytelocalizedText(inspection.measurement.responseBytes)) / 保存 \(directBytelocalizedText(inspection.payloadByteCount)) / capacity \(directBytelocalizedText(inspection.measurement.capacityBytes))"
                )
                directInspectionRow(
                    "時間",
                    String(format: "read %.1f ms · total %.1f ms", inspection.measurement.elapsedMilliseconds, inspection.measurement.totalElapsedMilliseconds)
                )
                directInspectionRow("形式", inspection.measurement.formatStatus)
                directInspectionRow(
                    "取得時刻",
                    inspection.measurement.capturedAt.map(ValueFormatter.fullDate) ?? "未記録（現在時刻は補完していません）"
                )
                ForEach(inspection.warnings, id: \.self) { warning in
                    localizedText("• \(warning)")
                        .font(.system(size: 10))
                        .foregroundStyle(AppColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 3)

        case let .tunnel(inspection):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(
                        UIString.text(inspection.measurement.outcome.title),
                        systemImage: directOutcomeIcon(inspection.measurement.outcome)
                    )
                    .foregroundStyle(directOutcomeColor(inspection.measurement.outcome))
                    Spacer()
                    localizedText("0x\(String(format: "%03x", inspection.measurement.opcode.rawValue)) · 形式未確認")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                directInspectionRow("Target", "\(inspection.measurement.build) / \(inspection.measurement.controller)")
                directInspectionRow("Opcode", "0x\(String(format: "%03x", inspection.measurement.opcode.rawValue)) · \(inspection.measurement.opcode.title)")
                directInspectionRow("権限", "euid \(inspection.measurement.effectiveUserID)")
                if let failureResultTitle = inspection.measurement.failureResultTitle {
                    directInspectionRow("判定", failureResultTitle)
                }
                directInspectionRow(
                    "Size query",
                    String(format: "0x%08x · %@", inspection.measurement.sizeQueryResultCode, directIOReturnTitle(inspection.measurement.sizeQueryResultCode))
                )
                directInspectionRow(
                    "Read",
                    String(format: "0x%08x · %@", inspection.measurement.readResultCode, directIOReturnTitle(inspection.measurement.readResultCode))
                )
                directInspectionRow(
                    "サイズ",
                    "要求 \(directBytelocalizedText(inspection.measurement.requestedBytes)) / 応答 \(directBytelocalizedText(inspection.measurement.responseBytes)) / 保存 \(directBytelocalizedText(inspection.payloadByteCount)) / capacity \(directBytelocalizedText(inspection.measurement.capacityBytes))"
                )
                directInspectionRow(
                    "時間",
                    String(format: "read %.1f ms · total %.1f ms", inspection.measurement.elapsedMilliseconds, inspection.measurement.totalElapsedMilliseconds)
                )
                directInspectionRow("形式", inspection.measurement.formatStatus)
                directInspectionRow(
                    "取得時刻",
                    inspection.measurement.capturedAt.map(ValueFormatter.fullDate) ?? "未記録（現在時刻は補完していません）"
                )
                ForEach(inspection.warnings, id: \.self) { warning in
                    localizedText("• \(warning)")
                        .font(.system(size: 10))
                        .foregroundStyle(AppColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 3)
        }
    }

    private func directInspectionRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            localizedText(label)
                .foregroundStyle(AppColor.textSecondary)
            Spacer(minLength: 8)
            localizedText(value)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(AppColor.textPrimary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func directBytelocalizedText(_ bytes: Int?) -> String {
        guard let bytes else { return "未取得" }
        return "\(bytes.formatted()) bytes"
    }

    private func directIOReturnTitle(_ code: UInt32) -> String {
        switch code {
        case 0:
            return "success"
        case 0xe00002c1:
            return "not privileged"
        case 0xe00002c2:
            return "bad argument"
        case 0xe00002e9:
            return "device error"
        default:
            return "未確認"
        }
    }

    private func decimallocalizedText(_ value: Double?, digits: Int) -> String {
        guard let value, value.isFinite else { return "未取得" }
        return String(format: "%.\(max(0, digits))f", value)
    }

    private func peSummarylocalizedText(
        _ minimum: Double?,
        _ average: Double?,
        _ maximum: Double?,
        eol: Double?
    ) -> String {
        guard let minimum, let average, let maximum else { return "未取得" }
        let body = String(format: "%.0f / %.0f / %.0f", minimum, average, maximum)
        guard let eol else { return body }
        return "\(body) · EoL \(String(format: "%.0f", eol))"
    }

    private func directOutcomeIcon(_ outcome: ASPDirectReadOutcome) -> String {
        switch outcome {
        case .success: return "checkmark.circle.fill"
        case .readFailed: return "xmark.circle.fill"
        case .partial: return "exclamationmark.triangle.fill"
        }
    }

    private func directOutcomeColor(_ outcome: ASPDirectReadOutcome) -> Color {
        switch outcome {
        case .success: return AppColor.positive
        case .readFailed: return AppColor.red
        case .partial: return AppColor.amber
        }
    }

    private var temperatureUnit: TemperatureUnit {
        (TemperatureUnit(rawValue: temperatureUnitRaw) ?? .system).resolved()
    }

    /// The model's 30 °C reference condition, in the display unit.
    private var referenceTemperatureText: String {
        temperatureUnit.text(RetentionScenario.referenceTemperatureCelsius, digits: 0)
    }

    /// The typed temperature in Celsius, rounded to 0.01 so a converted
    /// Fahrenheit entry does not store floating-point noise.
    private var retentionTemperatureCelsius: Double? {
        guard let value = Self.parsedNumber(retentionTemperatureText) else { return nil }
        return (temperatureUnit.celsius(from: value) * 100).rounded() / 100
    }

    private static func parsedNumber(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ".")).flatMap { $0.isFinite ? $0 : nil }
    }

    private static func retentionTemperatureText(_ celsius: Double?, unit: TemperatureUnit) -> String {
        let text = formatHours(unit.value(celsius ?? RetentionScenario.referenceTemperatureCelsius))
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    private static func formatHours(_ hours: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), hours)
    }
}
