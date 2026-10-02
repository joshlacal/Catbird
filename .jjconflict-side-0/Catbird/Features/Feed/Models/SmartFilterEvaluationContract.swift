import Foundation

enum SmartFilterEvaluationContract {
    static let compilerExactMatchMinimum = 0.95
    static let hidePrecisionMinimum = 0.98
    static let hideRecallMinimum = 0.60
    static let collapsePrecisionMinimum = 0.90
    static let collapseRecallMinimum = 0.70
    static let mustShowHiddenMaximum = 0
    static let confirmedActionPrecisionMinimum = 1.0
    static let nonCandidatePageOverheadP95Milliseconds = 10.0
    static let cachedDecisionP95Milliseconds = 2.0
    static let pendingPresentationP95Milliseconds = 100.0
}
