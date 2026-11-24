import Charts
import SwiftUI

struct NANDEnduranceDetailsView: View {
    let result: NANDEnduranceV2
    /// Histogram bins are opaque private-buffer indexes.  This is a display
    /// selection for an optional research aggregate only; it does not alter
    /// collection, reliability state, or the endurance forecast.
    @State private var histogramTailEnabled = false
    @State private var histogramTailStartBin = 0
    @State private var instrumentBoundariesExpanded = false

    private func number(_ value: Double?) -> String {
        value.map { String(format: "%.4f", $0) } ?? "未取得"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            localizedText("NAND予算モデル v2.4").font(.headline)
            Text(verbatim: result.observationEvidence.displayDetails)
                .font(.caption).foregroundStyle(AppColor.textSecondary)
            if let idle = result.idleRetentionTemperature {
                DisclosureGroup(UIString.text("保持温度の観測根拠")) {
                    Text(verbatim: idle.displaySummary(in: .celsius))
                    Text(verbatim: idle.displayEvidenceSummary(in: .celsius))
                    ForEach(Array(idle.candidates.suffix(10).enumerated()), id: \.offset) { _, candidate in
                        Text(verbatim: UIString.format("%@ → %@ · %.1f°C · %d点 · I/O %@ · %@ · 最大間隔 %@分 · %@",
                            ValueFormatter.shortDateTime(candidate.start), ValueFormatter.shortDateTime(candidate.end),
                            candidate.temperature, candidate.sampleCount, ValueFormatter.bytes(candidate.hostBytes),
                            UIString.text(candidate.effectiveIOSource.title),
                            candidate.effectiveMaximumIOIntervalSeconds.map { String(format: "%.1f", $0 / 60) } ?? UIString.text("未取得"),
                            UIString.text(candidate.stable ? "安定" : "温度安定の確認不足")
                            + (candidate.relativeLowIO == true ? " · " + UIString.text("相対低負荷") : "")))
                    }
                    localizedText("最新10区間。温度選択規則 v3。I/O差分は10分・5点以上、SMART代用は30分・4点以上。短いスリープや負荷の不存在を保証しません。")
                }
                .font(.caption)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow { localizedText("入力Host / NAND"); localizedText("\(ValueFormatter.bytes(result.host)) / \(ValueFormatter.bytes(result.nand))") }
                GridRow { localizedText("主予測の現在値"); localizedText(result.currentValueSource.isEmpty ? "未確認" : result.currentValueSource) }
                if let rawDate = result.latestRawInputDate {
                    GridRow { localizedText("最新raw snapshot"); localizedText("\(UIString.dateTime(rawDate)) · Host \(ValueFormatter.bytes(result.latestRawHost)) / NAND \(ValueFormatter.bytes(result.latestRawNAND))") }
                    GridRow { localizedText("最新raw P/E（予測入力とは別）"); localizedText("\(number(result.latestRawTLCPE)) / \(number(result.latestRawPSLCPE))") }
                }
                GridRow { localizedText("TLC / pSLC P/E"); localizedText("\(number(result.tlcPE)) / \(number(result.pslcPE))") }
                GridRow { localizedText("TLC / pSLC EOL P/E"); localizedText("\(number(result.tlcEOL)) / \(number(result.pslcEOL))") }
                if let tlcEOL = result.tlcEOL, let pslcEOL = result.pslcEOL, tlcEOL > 0, pslcEOL > 0 {
                    GridRow {
                        localizedText("P/E 1刻みの損耗率")
                        Text(verbatim: UIString.format("TLC %.4f / pSLC %.4f ポイント", 100 / tlcEOL, 100 / pslcEOL))
                    }
                }
                GridRow { localizedText("TLC / pSLC 正規化損耗"); localizedText("\(number(result.tlcWear)) / \(number(result.pslcWear))") }
                GridRow { localizedText("損耗率の統合"); localizedText("\(result.wearCombination.isEmpty ? "未取得" : result.wearCombination) · \(number(result.normalizedWear))") }
                GridRow { localizedText("TLC／pSLC損耗率の乖離"); localizedText(result.wearDivergence.map { String(format: "%.1f%%", $0 * 100) } ?? "未比較") }
                GridRow { localizedText("wearBalance pSLC / TLC"); localizedText(number(result.wearBalance)) }
                GridRow { localizedText("Direct FTLの対応状況"); localizedText(result.directContractStatus.title) }
                GridRow { localizedText("Direct FTLの対応の根拠"); localizedText(result.directContractStatus.displayDetail()) }
                GridRow { localizedText("wearBalance履歴"); localizedText(wearBalanceHistoryText) }
                GridRow { localizedText("wearBalance初回 / 最新"); localizedText("\(number(result.wearBalanceTrend.firstRatio)) / \(number(result.wearBalanceTrend.latestRatio))") }
                GridRow { localizedText("wearBalance最小 / 最大 / 傾き"); localizedText("\(number(result.wearBalanceTrend.minimumRatio)) / \(number(result.wearBalanceTrend.maximumRatio)) / \(trendSlopeText)") }
                GridRow { localizedText("ΔTLC／ΔpSLC 正規化損耗"); localizedText("\(number(result.wearBalanceTrend.observations.last?.tlcWearDelta)) / \(number(result.wearBalanceTrend.observations.last?.pslcWearDelta))") }
                GridRow { localizedText("TLC／pSLC 正規化損耗の傾き / 日"); localizedText("\(number(result.wearBalanceTrend.tlcWearChangePerDay)) / \(number(result.wearBalanceTrend.pslcWearChangePerDay))") }
                GridRow { localizedText("wearBalance 1.00横切り"); localizedText(result.wearBalanceTrend.observedCrossingAt.map { UIString.dateTime($0) } ?? "未観測（将来外挿なし）") }
                GridRow { localizedText("実効NAND容量 / 入力元"); localizedText("\(ValueFormatter.bytes(result.effectiveNANDCapacityBytes)) / \(result.capacitySource?.title ?? "未取得")") }
                GridRow { localizedText("domain予算（基準 / 現在）"); localizedText("\(ValueFormatter.bytes(result.domainBaselineBudget)) / \(ValueFormatter.bytes(result.domainActualBudget))") }
                GridRow { localizedText("domain推定使用 / 残量"); localizedText("\(ValueFormatter.bytes(result.domainUsedBytes)) / \(ValueFormatter.bytes(result.domainRemainingBytes))") }
                GridRow { localizedText("固定30°C・365日 残NAND（比較）"); localizedText(ValueFormatter.bytes(result.fixedReferenceRemainingBytes)) }
                GridRow { localizedText("従来N/u予算（比較）"); localizedText("\(ValueFormatter.bytes(result.nominalBudget)) / \(ValueFormatter.bytes(result.actualBudget))") }
                GridRow { localizedText("実測累積NAND / domain再構成"); localizedText("\(ValueFormatter.bytes(result.nand)) / \(ValueFormatter.bytes(result.domainUsedBytes))") }
                GridRow { localizedText("容量基準予算（検算のみ）"); localizedText(ValueFormatter.bytes(result.capacityDiagnosticBudget)) }
                GridRow { localizedText("容量基準TLC消費（検算のみ）"); localizedText(ValueFormatter.bytes(result.currentPhysicalBytes)) }
                GridRow { localizedText("容量基準の整合ゲート"); localizedText(capacityGateText) }
                GridRow { localizedText("累積 / 最近 / 将来WAF"); localizedText("\(number(result.longWAF)) / \(number(result.recentWAF)) / \(number(result.forecastWAF))") }
                GridRow { localizedText("最近WAFの重み"); localizedText(number(result.recentWeight)) }
                GridRow { localizedText("WAF観測Host / prior相当"); localizedText("\(ValueFormatter.bytes(result.wafObservedHostBytes)) / \(ValueFormatter.bytes(result.wafPriorEquivalentHostBytes))") }
                GridRow { localizedText("WAF観測日数"); localizedText(result.wafObservationDays.map { UIString.format("%.1f日", $0) } ?? "累積fallback") }
                GridRow { localizedText("計測器境界 / WAF学習"); localizedText(instrumentBoundaryLearningText) }
                GridRow {
                    localizedText("計測器履歴（境界 / 吸収変更）")
                    localizedText("\(result.instrumentBoundaries.count)境界 / \(result.instrumentMetadataChanges.count)変更 · raw履歴は未変更")
                }
                GridRow { localizedText("TLC Retention derating"); localizedText(number(result.retentionFactor)) }
                GridRow { localizedText("Program-temperature diagnostic"); localizedText(number(result.programFactor)) }
                GridRow { localizedText("必要保持条件"); localizedText("\(result.requiredRetentionDays.map { UIString.format("%.1f日", $0) } ?? "未算出") · \(result.requiredRetentionDaysSource.isEmpty ? "未取得" : result.requiredRetentionDaysSource)") }
                GridRow { localizedText("観測された最長無通電露出"); localizedText(result.observedLongestUnpoweredDays.map { UIString.format("%.3f日（診断のみ）", $0) } ?? "未観測") }
                GridRow { localizedText("保持補正の測定範囲外率"); localizedText(number(result.retentionExtrapolationRatio)) }
                GridRow { localizedText("保持補正の適用"); localizedText(result.retentionCorrectionSuppressed ? "数値適用なし（研究比較のみ）" : "数値適用") }
                GridRow { localizedText("日数 / 温度等の重み"); localizedText("\(number(result.retentionDaysWeight)) / \(number(result.retentionEnvironmentWeight))") }
                if let thermal = result.thermal {
                    GridRow { localizedText("Program / 保管温度proxy"); localizedText("\(number(thermal.programTemperature)) / \(number(thermal.storageTemperature)) °C") }
                    GridRow { localizedText("保管温度の由来"); localizedText(thermal.storageSource) }
                    GridRow { localizedText("Idle温度 / 温度取得率"); localizedText("\(number(thermal.idleTemperature)) °C / \(String(format: "%.0f", thermal.coverage * 100))%") }
                    GridRow { localizedText("Program − 保管温度proxy"); localizedText("\(number(thermal.programTemperature.map { $0 - thermal.storageTemperature })) °C（診断のみ・読出し温度は未実測）") }
                }
                if let date = result.inputDate {
                    GridRow { localizedText("FTL入力日時"); localizedText(UIString.dateTime(date)) }
                }
                if let topology = result.directTopology {
                    GridRow { localizedText("Direct topologyの対応表 / IORegistry"); localizedText("\(topology.contractVersion) / \(topologyMatchText)") }
                    GridRow { localizedText("partition境界 Int / User / Virtual"); localizedText("\(topology.intermediatePartitionStart) / \(topology.userPartitionStart) / \(topology.numVirtualBlocks)") }
                    GridRow { localizedText("Direct band数 pSLC / TLC"); localizedText("\(topology.intermediateBandCount) / \(topology.tlcBandCount)") }
                    GridRow { localizedText("Direct page bytes × Native / pSLC pages"); localizedText("\(topology.bytesPerPage) × \(topology.pagesPerVirtualBlock) / \(topology.pagesPerVirtualBlockSLC)") }
                    GridRow { localizedText("Direct band容量 TLC / pSLC書込可能"); localizedText("\(ValueFormatter.bytes(topology.tlcBandBytes.map { Double($0) })) / \(ValueFormatter.bytes(topology.pslcBandBytes.map { Double($0) }))") }
                    GridRow { localizedText("pSLC物理占有量 / 書込可能"); localizedText("\(ValueFormatter.bytes(topology.pslcPhysicalFootprintBytes)) / \(ValueFormatter.bytes(topology.pslcWritableCapacityBytes))") }
                } else {
                    GridRow { localizedText("Direct topology"); localizedText("未取得。中央予測はdomain配分未取得・累積損耗N/u概算") }
                }
                if let diagnostics = result.reconstructionDiagnostics {
                    GridRow { localizedText("Direct既知domain使用 / 実測NAND"); localizedText("\(ValueFormatter.bytes(diagnostics.knownDomainUsedBytes)) / \(ValueFormatter.bytes(diagnostics.measuredNANDBytes))") }
                    GridRow { localizedText("符号付き未同定残差"); localizedText(signedBytes(diagnostics.signedResidualBytes)) }
                    GridRow { localizedText("raw pSLC相当 / Directとの差"); localizedText("\(number(diagnostics.rawEquivalentPSLCBands)) / \(number(diagnostics.residualEquivalentPSLCBands)) bands") }
                    GridRow { localizedText("使用量再構成 / EOL予算比較誤差"); localizedText("\(percent(diagnostics.currentReconstructionError)) / \(percent(diagnostics.eolBudgetReconciliationError))") }
                    GridRow { localizedText("topologyの対応表 / 物理配分確認"); localizedText("\(diagnostics.topologyContractValidated ? "確認済みのkeyの対応表" : "未検証") / \(diagnostics.physicalCapacityAllocationVerified ? "確認済み" : "未検証")") }
                }
                if let allocation = result.bandAllocationProxy {
                    GridRow { localizedText("逆算band proxy TLC / pSLC（比較）"); localizedText("\(allocation.tlcBands) / \(allocation.pslcBands) / 合計 \(allocation.totalBands)") }
                    GridRow { localizedText("pSLC band数（丸め前）"); localizedText(String(format: "%.3f", allocation.rawPSLCBands)) }
                    GridRow { localizedText("geometry sector size"); localizedText("\(allocation.sectorSizeBytes) B") }
                    GridRow { localizedText("band容量 TLC / pSLC"); localizedText("\(ValueFormatter.bytes(allocation.tlcCapacityBytes)) / \(ValueFormatter.bytes(allocation.pslcCapacityBytes))") }
                    GridRow { localizedText("pSLC物理占有量 / 書込可能"); localizedText("\(ValueFormatter.bytes(allocation.pslcPhysicalFootprintBytes)) / \(ValueFormatter.bytes(allocation.pslcCapacityBytes))") }
                    GridRow { localizedText("逆算band当てはめ誤差 / 検証"); localizedText("\(String(format: "%.2f%%", allocation.relativeError * 100)) / 未検証・主計算外") }
                }
                ForEach(result.domainEstimates, id: \.domain.rawValue) { domain in
                    GridRow { localizedText("\(domain.domain.title) 容量 / 現在P/E / 目標P/E"); localizedText("\(ValueFormatter.bytes(domain.capacityBytes)) / \(String(format: "%.0f", domain.currentPE)) / \(String(format: "%.0f", domain.targetPE))") }
                    GridRow { localizedText("\(domain.domain.title) 保持補正なし予算（中央） / 研究の保持補正後"); localizedText("\(ValueFormatter.bytes(domain.baselineBudgetBytes)) / \(ValueFormatter.bytes(domain.totalBudgetBytes))") }
                    GridRow { localizedText("\(domain.domain.title) 推定使用 / 残量（研究の保持補正後）"); localizedText("\(ValueFormatter.bytes(domain.usedBytes)) / \(ValueFormatter.bytes(domain.remainingBytes))") }
                }
                GridRow { localizedText("domain再構成誤差"); localizedText(result.domainReconstructionError.map { String(format: "%.2f%%", $0 * 100) } ?? "未算出") }
                GridRow { localizedText("domain予算比較誤差"); localizedText(result.domainBudgetReconciliationError.map { String(format: "%.2f%%", $0 * 100) } ?? "未算出") }
                if let components = result.wafComponents {
                    GridRow { localizedText("WAF 全体 / Native / Intermediate"); localizedText("\(number(components.total)) / \(number(components.native)) / \(number(components.intermediate))") }
                    GridRow { localizedText("WAF成分残差 / 状態"); localizedText("\(number(components.residual)) / \(components.isConsistent == nil ? "未算出" : components.isConsistent == true ? "非負" : "負値・不整合")") }
                }
                if let evidence = result.reliabilityEvidence {
                    GridRow { localizedText("FTL reliability比較 / 状態"); localizedText("\(evidence.baselineCapturedAt?.formatted(date: .numeric, time: .shortened) ?? "初回") → \(evidence.comparedAt?.formatted(date: .numeric, time: .shortened) ?? "未取得") / \(evidence.state.title)") }
                    GridRow {
                        localizedText("FTL比較日数 / 基準")
                        localizedText("\(evidence.durationDays.map { String(format: "%.2f日", $0) } ?? "未算出") · \(evidence.durationBasis.title) / 暦 \(evidence.wallDurationDays.map { String(format: "%.2f日", $0) } ?? "未算出")")
                    }
                    GridRow { localizedText("研究試験重複"); localizedText(evidence.researchSessionOverlap ? "あり" : "なし") }
                    if let composition = evidence.hostWriteCompositionAudit {
                        GridRow {
                            localizedText("Host composition 5 / 6 / 27")
                            localizedText("\(composition.comparison.title) · \(composition.status.title) · sum \(composition.candidateSum.map(String.init) ?? "未算出") / Host \(composition.hostWrites.map(String.init) ?? "未取得")")
                        }
                        localizedText(composition.note)
                            .font(.system(size: 10))
                            .foregroundStyle(AppColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(evidence.counters) { counter in
                        GridRow { localizedText(counter.name); localizedText("+\(counter.delta) · \(rate(counter.perDay))/日 · \(rate(counter.perNANDRead))/ΔnandReads counter\(counter.isReliabilityEvent ? " · event" : "")") }
                    }
                    if let telemetry = evidence.latestTelemetry {
                        GridRow { localizedText("Refresh tier raw / total"); localizedText("\(telemetry.ageRefreshPerTier.map { $0.map(String.init).joined(separator: ", ") } ?? "未取得") / \(telemetry.ageRefreshTotal.map(String.init) ?? "未取得")") }
                        GridRow { localizedText("Write-path raw"); localizedText("Direct→TLC bands \(telemetry.directToTLCBands.map(String.init) ?? "未取得") / sectors \(telemetry.directToTLCSectors.map(String.init) ?? "未取得") / waterfall \(telemetry.fallbackToWaterfall.map(String.init) ?? "未取得")") }
                        if histogramMaximumBin > 0 {
                            GridRow {
                                localizedText("Histogram tail研究集計")
                                HStack(spacing: 10) {
                                    Toggle(UIString.text("Histogram tailを表示"), isOn: $histogramTailEnabled)
                                        .labelsHidden()
                                    if histogramTailEnabled {
                                        Stepper(UIString.format("bin %d 以上", histogramTailStartBin), value: $histogramTailStartBin, in: 0...max(histogramMaximumBin, histogramTailStartBin))
                                    } else {
                                        localizedText("未選択")
                                    }
                                }
                            }
                        }
                        ForEach(FTLResearchHistogram.allCases, id: \.rawValue) { histogram in
                            if let bins = telemetry.histogram(named: histogram) {
                                let summary = FTLHistogramSummary.summarize(bins)
                                GridRow { localizedText(histogram.title); localizedText(histogramText(summary, bins: bins)) }
                            }
                        }
                    }
                    if !evidence.unavailableCounters.isEmpty {
                        GridRow { localizedText("比較から除外したcounter"); localizedText(evidence.unavailableCounters.joined(separator: " / ")) }
                    }
                    GridRow { localizedText("未照合のFTL項目"); localizedText(evidence.unmappedItems.map { UIString.readout($0) }.joined(separator: " / ")) }
                }
                if let central = result.domainBottleneckRemaining {
                    GridRow { localizedText("中央予測の律速 / 書込/Host"); localizedText("\(central.limitingDomain.title) / \(String(format: "%.2f", central.limitingDomainBytesPerHostByte))・保持補正なし") }
                }
                if let bottleneck = result.domainBottleneck {
                    GridRow { localizedText("研究のbottleneck区間 / 分担率（中央とは別計算）"); localizedText("\(bottleneck.intervalCount) / TLC \(String(format: "%.3f", bottleneck.tlcShare))・pSLC \(String(format: "%.3f", bottleneck.pslcShare))") }
                    GridRow { localizedText("bottleneck比較残量 / 律速"); localizedText("\(ValueFormatter.bytes(bottleneck.tlcEquivalentRemainingBytes)) / \(ValueFormatter.bytes(bottleneck.pslcEquivalentRemainingBytes)) / \(bottleneck.limitingDomain?.title ?? "未算出")") }
                    GridRow { localizedText("分担率合計誤差"); localizedText(UIString.format("%.2f%%・比較値", bottleneck.distributionError * 100)) }
                    localizedText(bottleneck.note)
                        .font(.system(size: 10))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !result.domainBottleneckNote.isEmpty {
                    GridRow { localizedText("bottleneck比較"); localizedText("未算出") }
                    localizedText(result.domainBottleneckNote)
                        .font(.system(size: 10))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !instrumentHistoryItems.isEmpty {
                DisclosureGroup(isExpanded: $instrumentBoundariesExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(instrumentHistoryItems) { item in
                            switch item {
                            case let .boundary(record):
                                InstrumentBoundaryDetailRow(record: record)
                            case let .absorbedChange(record):
                                InstrumentMetadataChangeDetailRow(record: record)
                            }
                            if item.id != instrumentHistoryItems.last?.id {
                                Divider().overlay(AppColor.border.opacity(0.6))
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label(UIString.format("計測器・デバイス履歴（%d）", instrumentHistoryItems.count), systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.top, 2)
            }
            if !result.wearBalanceTrend.observations.isEmpty {
                Chart(result.wearBalanceTrend.observations) { observation in
                    LineMark(
                        x: .value("取得日", observation.capturedAt),
                        y: .value("pSLC / TLC", observation.ratio)
                    )
                    .foregroundStyle(.blue)
                    PointMark(
                        x: .value("取得日", observation.capturedAt),
                        y: .value("pSLC / TLC", observation.ratio)
                    )
                    .foregroundStyle(.blue)
                    RuleMark(y: .value("1.00", 1.0))
                        .foregroundStyle(.secondary.opacity(0.65))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    ForEach(visibleWearBalanceBoundaries, id: \.boundary.after) { record in
                        RuleMark(x: .value("計測器境界", record.boundary.after))
                            .foregroundStyle(instrumentBoundaryColor(record))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: instrumentBoundaryDash(record)))
                            .annotation(position: .top, alignment: .center, spacing: 2) {
                                InstrumentBoundaryAnnotation(record: record)
                            }
                    }
                }
                .chartYScale(domain: wearBalanceYDomain)
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 130)
                .accessibilityLabel(UIString.text("wearBalanceの時系列"))
                .accessibilityValue(UIString.readout(result.wearBalanceTrend.note))
                InstrumentBoundaryLegendView(records: visibleWearBalanceBoundaries)
            }
            localizedDiagnosticText(result.wearBalanceTrend.note)
                .font(.system(size: 10))
                .foregroundStyle(AppColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            localizedText("到達日ペース：現在 \(ValueFormatter.bytes(result.currentPaceBytesPerDay))/日 / \(result.longTermPaceBasis) \(ValueFormatter.bytes(result.longTermPaceBytesPerDay))/日").foregroundStyle(AppColor.textSecondary)
            if !result.domainModelNote.isEmpty {
                localizedText(result.domainModelNote).foregroundStyle(AppColor.textSecondary)
            }
            localizedText("中央予測：domain容量 × 各domainの目標P/E（保持補正なし）。TLC・pSLCそれぞれの残量を書込/Hostで換算し、先に尽きる方で決めます。保持補正は研究値と仮想シナリオのみに使います。逆算band配分は詳細比較のみです。")
            if let components = result.wafComponents {
                localizedText(components.note).foregroundStyle(AppColor.textSecondary)
            }
            if let evidence = result.reliabilityEvidence {
                localizedText(evidence.reason).foregroundStyle(AppColor.textSecondary)
            }
            ForEach(Array(result.notes.enumerated()), id: \.offset) { _, note in
                localizedDiagnosticText(note == result.directContractStatus.detail ? result.directContractStatus.displayDetail() : note).foregroundStyle(AppColor.textSecondary)
            }
            if let allocation = result.bandAllocationProxy {
                ForEach(Array(allocation.notes.enumerated()), id: \.offset) { _, note in
                    localizedDiagnosticText(note).foregroundStyle(AppColor.textSecondary)
                }
            }
        }
    }

    private var capacityGateText: String {
        guard let consistent = result.capacityModelConsistent else { return "未判定" }
        let divergence = result.capacityModelDivergence.map { String(format: "%.1f%%", $0 * 100) } ?? "不明"
        return consistent ? "整合（差分 \(divergence)）・検算のみ" : "不整合（差分 \(divergence)）・主経路から除外"
    }

    private var topologyMatchText: String {
        switch result.topologyMatchesIORegistryGeometry {
        case .some(true): return "整合"
        case .some(false): return "不整合・主計算保留"
        case .none: return "IORegistry比較なし"
        }
    }

    private func signedBytes(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : "−"
        return sign + ValueFormatter.bytes(abs(value))
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.2f%%", $0 * 100) } ?? "未算出"
    }

    private func rate(_ value: Double?) -> String {
        value.map { String(format: "%.3g", $0) } ?? "—"
    }

    private var wearBalanceHistoryText: String {
        let trend = result.wearBalanceTrend
        guard !trend.observations.isEmpty else { return trend.note }
        let days = trend.observationDays.map { UIString.format("%.1f日", $0) } ?? "同日"
        return "\(trend.observations.count)点 / \(days)"
    }

    private var instrumentBoundaryLearningText: String {
        guard !result.instrumentBoundaries.isEmpty else { return "なし" }
        return result.instrumentBoundaries.map { record in
            "\(ValueFormatter.shortDateTime(record.boundary.after)) \(InstrumentBoundaryPresentation.rawDataViewerSummary(for: record))"
        }.joined(separator: " / ")
    }

    private var visibleWearBalanceBoundaries: [InstrumentBoundaryRecord] {
        InstrumentBoundaryPresentation.visibleRecords(
            result.instrumentBoundaries,
            in: result.wearBalanceTrend.observations.map(\.capturedAt)
        )
    }

    private var instrumentHistoryItems: [InstrumentHistoryDisplayItem] {
        (result.instrumentBoundaries.map(InstrumentHistoryDisplayItem.boundary)
            + result.instrumentMetadataChanges.map(InstrumentHistoryDisplayItem.absorbedChange))
            .sorted { $0.date < $1.date }
    }

    private var trendSlopeText: String {
        guard let slope = result.wearBalanceTrend.changePerDay else { return "未算出" }
        return UIString.format("%+.4f/日", slope)
    }

    private var wearBalanceYDomain: ClosedRange<Double> {
        let ratios = result.wearBalanceTrend.observations.map(\.ratio) + [1.0]
        let minimum = ratios.min() ?? 0.9
        let maximum = ratios.max() ?? 1.1
        let padding = max((maximum - minimum) * 0.15, 0.02)
        return (minimum - padding)...(maximum + padding)
    }

    private var histogramMaximumBin: Int {
        guard let telemetry = result.reliabilityEvidence?.latestTelemetry else { return 0 }
        return FTLResearchHistogram.allCases
            .compactMap { telemetry.histogram(named: $0)?.indices.last }
            .max() ?? 0
    }

    private func histogramText(_ summary: FTLHistogramSummary, bins: [UInt64]) -> String {
        if summary.binCount == 0 { return "空配列" }
        if summary.allBinsZero { return "\(summary.binCount) bins・全bin 0" }
        let tail: String
        if histogramTailEnabled, let fraction = FTLHistogramSummary.tailFraction(bins, from: histogramTailStartBin) {
            tail = " · tail≥\(histogramTailStartBin) \(String(format: "%.3f", fraction))"
        } else {
            tail = ""
        }
        return "\(summary.binCount) bins · total \(summary.totalCount.map(String.init) ?? "overflow") · mean \(summary.meanBin.map { String(format: "%.2f", $0) } ?? "—") · p50/p90/p99 \(summary.p50Bin.map(String.init) ?? "—")/\(summary.p90Bin.map(String.init) ?? "—")/\(summary.p99Bin.map(String.init) ?? "—") · last \(summary.finalNonZeroBin.map(String.init) ?? "—")\(tail)"
    }
}

private struct InstrumentBoundaryDetailRow: View {
    let record: InstrumentBoundaryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                localizedText("\(UIString.dateTime(record.boundary.before)) → \(UIString.dateTime(record.boundary.after))")
                    .font(.caption.weight(.medium).monospacedDigit())
                Spacer(minLength: 8)
                localizedText(InstrumentBoundaryDisplayStatus.resolve(continuity: record.continuity, checks: record.checks).title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(instrumentBoundaryColor(record))
            }

            localizedText("前: \(identitySummary(record.boundary.beforeIdentity, provenance: record.beforeBuildProvenance))")
            localizedText("後: \(identitySummary(record.boundary.afterIdentity, provenance: record.afterBuildProvenance))")
            localizedText("変更: \(InstrumentBoundaryPresentation.changedAttributes(for: record).joined(separator: " · "))")

            if let initial = record.initialEvaluation {
                let initialStatus = InstrumentBoundaryDisplayStatus.resolve(
                    continuity: initial.continuity,
                    checks: initial.checks
                )
                localizedText("初回判定 \(UIString.dateTime(initial.evaluatedAt)) · \(initialStatus.title)")
                    .font(.caption.weight(.medium))
                if initialStatus != InstrumentBoundaryDisplayStatus.resolve(continuity: record.continuity, checks: record.checks) {
                    localizedText("最終判定 \(record.lastEvaluatedAt?.formatted(date: .numeric, time: .shortened) ?? "時刻未記録") · \(InstrumentBoundaryDisplayStatus.resolve(continuity: record.continuity, checks: record.checks).title)")
                        .font(.caption.weight(.medium))
                }
            } else {
                localizedText("判定日時 \(record.lastEvaluatedAt?.formatted(date: .numeric, time: .shortened) ?? UIString.dateTime(record.boundary.after))")
                    .font(.caption.weight(.medium))
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(InstrumentBoundaryPresentation.checkLines(record.checks), id: \.self) { line in
                    localizedText(line)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let exclusion = record.rateLearningExclusion {
                localizedText("率学習除外: \(UIString.dateTime(exclusion.start)) → \(UIString.dateTime(exclusion.end))（境界後72時間を含む）")
            } else {
                localizedText("率学習除外: なし")
            }
            localizedDiagnosticText(record.note)
                .foregroundStyle(AppColor.textSecondary)
        }
        .font(.caption)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
    }

    private func identitySummary(_ identity: InstrumentIdentity, provenance: BuildProvenance?) -> String {
        let source = identity.sourceArtifact.map(InstrumentBoundaryPresentation.sourceTitle) ?? "取得経路未記録"
        let build = identity.runtimeBuild ?? "未記録"
        let firmware = identity.firmwareEpoch ?? "未記録"
        let contract = identity.keyContractVersion ?? "未記録"
        let provenanceText = provenance.map(InstrumentBoundaryPresentation.provenanceTitle) ?? "未記録"
        return "\(source) · OS \(build) · FW \(firmware) · core \(contract) · provenance \(provenanceText)"
    }
}

private enum InstrumentHistoryDisplayItem: Identifiable {
    case boundary(InstrumentBoundaryRecord)
    case absorbedChange(InstrumentMetadataChangeRecord)

    var id: String {
        switch self {
        case let .boundary(record):
            return "boundary-\(record.boundary.before.timeIntervalSince1970)-\(record.boundary.after.timeIntervalSince1970)"
        case let .absorbedChange(record):
            return "metadata-\(record.id)"
        }
    }

    var date: Date {
        switch self {
        case let .boundary(record): return record.boundary.after
        case let .absorbedChange(record): return record.afterAt
        }
    }
}

private struct InstrumentMetadataChangeDetailRow: View {
    let record: InstrumentMetadataChangeRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                localizedText("\(UIString.dateTime(record.beforeAt)) → \(UIString.dateTime(record.afterAt))")
                    .font(.caption.weight(.medium).monospacedDigit())
                Spacer(minLength: 8)
                localizedText("同一計測器として吸収")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColor.textSecondary)
            }
            localizedText("前: \(identitySummary(record.beforeIdentity))")
            localizedText("後: \(identitySummary(record.afterIdentity))")
            localizedText("変更: \(record.changedAttributes.joined(separator: " · "))")
            localizedText("コアwear系列は継続 · 率学習除外なし")
                .foregroundStyle(AppColor.textSecondary)
        }
        .font(.caption)
        .textSelection(.enabled)
    }

    private func identitySummary(_ identity: InstrumentIdentity) -> String {
        let source = identity.sourceArtifact.map(InstrumentBoundaryPresentation.sourceTitle) ?? "取得経路未記録"
        let build = identity.runtimeBuild ?? "未記録"
        let firmware = identity.firmwareEpoch ?? "未記録"
        return "\(source) · OS \(build) · FW \(firmware)"
    }
}

struct InstrumentBoundaryAnnotation: View {
    let record: InstrumentBoundaryRecord

    var body: some View {
        Image(systemName: "info.circle.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(instrumentBoundaryColor(record))
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .help(UIString.readout(InstrumentBoundaryPresentation.tooltip(for: record)))
            .accessibilityLabel(UIString.readout(InstrumentBoundaryPresentation.tooltip(for: record)))
    }
}
