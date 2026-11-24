import Foundation

/// Hypothetical powered-off storage scenario, separate from the uncorrected
/// central forecast. This separation is a modeling choice, not evidence that
/// retention loss cannot occur while a drive is powered on.
///
/// Research anchors: 3000 P/E and an alternative 1500 P/E at 30 °C/365 days.
/// Neither anchor establishes Apple retention capability. The model assumes
/// Arrhenius temperature conversion with Ea 1.1 eV and inverse proportionality
/// between retention time and P/E (n = 1).
/// Applying the correction to TLC only is an assumption of this model;
/// it does not establish independent pSLC retention capability.
/// See docs/RETENTION_RESEARCH_ESTIMATE.md.
struct RetentionScenario: Equatable, Sendable {
    let storageTemperatureCelsius: Double
    let storageTemperatureSource: String
    let powerOffDays: Double
    /// Allowed maximum TLC P/E for the scenario, at the 3000 and 1500 anchors.
    let allowableTLCPE: Double
    let allowableTLCPELower: Double
    let remainingHostBytes: Double
    let remainingHostBytesLower: Double
    let currentTLCPE: Double

    /// A limit of the hypothetical scenario, not a measured retention failure.
    var scenarioLimitReached: Bool { currentTLCPE >= allowableTLCPE }

    static let referencePE = 3_000.0
    static let referencePELower = 1_500.0
    static let referenceTemperatureCelsius = 30.0
    static let referenceDays = 365.0
    static let activationEnergyEV = 1.1
    /// Research-model floor; lower temperatures do not increase this estimate.
    static let minimumTemperatureCelsius = 25.0
    private static let boltzmannEVPerKelvin = 8.617_333e-5

    static func accelerationFactor(storageTemperatureCelsius: Double) -> Double {
        let kelvin = max(storageTemperatureCelsius, minimumTemperatureCelsius) + 273.15
        let reference = referenceTemperatureCelsius + 273.15
        return exp(activationEnergyEV / boltzmannEVPerKelvin * (1 / reference - 1 / kelvin))
    }

    /// Allowed P/E so that the scenario consumes no more retention margin
    /// than the anchor (one year at 30 °C).
    static func allowablePE(reference: Double, eol: Double, storageTemperatureCelsius: Double, powerOffDays: Double) -> Double? {
        guard powerOffDays.isFinite, powerOffDays > 0, reference > 0, eol > 0 else { return nil }
        let stress = powerOffDays / referenceDays * accelerationFactor(storageTemperatureCelsius: storageTemperatureCelsius)
        guard stress.isFinite, stress > 0 else { return nil }
        return min(eol, reference / stress)
    }

    /// - Parameters:
    ///   - tlc: TLC domain without retention derating.
    ///   - tlcMaximumPE: the most-cycled TLC block, compared with the anchor.
    ///   - tlcWritesPerHostByte / pslcRemainingHostBytes: from the central
    ///     forecast, so only the TLC limit changes.
    static func evaluate(
        tlc: NANDDomainEstimate,
        tlcMaximumPE: Double?,
        tlcWritesPerHostByte: Double,
        pslcRemainingHostBytes: Double?,
        storageTemperatureCelsius: Double,
        storageTemperatureSource: String,
        powerOffDays: Double
    ) -> RetentionScenario? {
        guard tlcWritesPerHostByte.isFinite, tlcWritesPerHostByte > 0,
              let allowable = allowablePE(reference: referencePE, eol: tlc.eolPE,
                                          storageTemperatureCelsius: storageTemperatureCelsius, powerOffDays: powerOffDays),
              let allowableLower = allowablePE(reference: referencePELower, eol: tlc.eolPE,
                                               storageTemperatureCelsius: storageTemperatureCelsius, powerOffDays: powerOffDays)
        else { return nil }
        let current = max(tlcMaximumPE ?? tlc.currentPE, tlc.currentPE)
        func remaining(_ limit: Double) -> Double {
            let tlcHost = tlc.capacityBytes * max(0, limit - current) / tlcWritesPerHostByte
            return min(tlcHost, pslcRemainingHostBytes ?? .infinity)
        }
        return RetentionScenario(
            storageTemperatureCelsius: storageTemperatureCelsius,
            storageTemperatureSource: storageTemperatureSource,
            powerOffDays: powerOffDays,
            allowableTLCPE: allowable,
            allowableTLCPELower: allowableLower,
            remainingHostBytes: remaining(allowable),
            remainingHostBytesLower: remaining(allowableLower),
            currentTLCPE: current
        )
    }

    var title: String {
        "保持考慮"
    }

    /// Display conditions separately from the name; this is not a model input.
    var conditionSummary: String {
        String(format: "%.0f日 · %.0f°C", powerOffDays, storageTemperatureCelsius)
    }

    var explanation: String {
        "電源OFFで\(conditionSummary)の条件で保管する仮想シナリオ。TLCの保持条件を考慮した研究推計で、データ保持の保証ではありません。"
    }

    /// Display-only localization; original model descriptions remain unchanged.
    var displayConditionSummary: String {
        UIString.format("%.0f日 · %@", powerOffDays, TemperatureUnit.current.text(storageTemperatureCelsius, digits: 0))
    }

    var displayExplanation: String {
        UIString.format("%@が指定期間続くと仮定した保持予測です。TLCの保持条件を考慮した研究推計で、データ保持の保証ではありません。", UIString.format("%.0f日 · %@", powerOffDays, TemperatureUnit.current.text(storageTemperatureCelsius)))
        + "\n" + UIString.text("自動温度は読み書きの少ない区間の実測値です。電源OFF後は通常これより低温になりますが、非通電中の温度は測定していません。既定・指定温度の場合は観測値ではありません。")
    }
}
