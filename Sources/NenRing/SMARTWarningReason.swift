/// The existing SMART warning rules, presented individually so a PASSED
/// summary cannot hide a warning counter. No new vendor thresholds are added.
enum SMARTWarningReason: Hashable, Sendable {
    case criticalWarning
    case spareBelowThreshold
    case mediaErrors
    case selfAssessmentFailed

    var title: String {
        switch self {
        case .criticalWarning: return "Critical Warning"
        case .spareBelowThreshold: return "予備領域の閾値割れ"
        case .mediaErrors: return "Media / Data Errors"
        case .selfAssessmentFailed: return "総合判定がPASSEDではありません"
        }
    }

    static func collect(from snapshot: DriveSnapshot?) -> [Self] {
        guard let snapshot else { return [] }
        var reasons: [Self] = []
        if let warning = snapshot.criticalWarning, warning != 0 { reasons.append(.criticalWarning) }
        if let spare = snapshot.availableSpare, let threshold = snapshot.availableSpareThreshold,
           spare < threshold { reasons.append(.spareBelowThreshold) }
        if let errors = snapshot.mediaAndDataIntegrityErrors, errors > 0 { reasons.append(.mediaErrors) }
        if snapshot.smartPassed == false { reasons.append(.selfAssessmentFailed) }
        return reasons
    }
}
