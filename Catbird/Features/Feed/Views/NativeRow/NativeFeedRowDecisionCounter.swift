#if os(iOS)
import OSLog

private let decisionLogger = Logger(subsystem: "blue.catbird", category: "NativeFeedRows")

// MARK: - Native Feed Row Decision Counter

/// Counts how the posts of the current feed render: natively, or hosted for each
/// `NativeFeedRowSupport.Reason`. A summary is logged at `.info` every `summaryInterval`
/// decisions and when the feed is reset, so a device run can read the real reason distribution
/// from the log.
///
/// Every decision the coordinator makes is counted, including a post decided again after its
/// content or the row settings changed: the counts are per decision, not per post, so a reading
/// over a session with refreshes includes posts decided more than once. The summary holds only
/// outcome names and counts, never post content, URIs or DIDs.
@MainActor
final class NativeFeedRowDecisionCounter {
  enum Outcome: Hashable, Sendable {
    case native
    case hosted(NativeFeedRowSupport.Reason)
  }

  static let summaryInterval = 100

  private(set) var counts: [Outcome: Int] = [:]
  private(set) var total = 0

  func record(_ outcome: Outcome) {
    counts[outcome, default: 0] += 1
    total += 1
    if total.isMultiple(of: Self.summaryInterval) { log("progress") }
  }

  /// Logs the finished feed's summary, if it made any decisions, and starts counting from zero.
  func reset() {
    if total > 0 { log("feed reset") }
    counts.removeAll()
    total = 0
  }

  /// "native=82 embed=10 replyContext=8": the outcomes with a count, native first, then the
  /// reasons in `classify`'s order.
  var summary: String {
    let outcomes = [Outcome.native] + NativeFeedRowSupport.Reason.allCases.map(Outcome.hosted)
    return outcomes.compactMap { outcome in
      counts[outcome].map { "\(outcome.name)=\($0)" }
    }.joined(separator: " ")
  }

  private func log(_ event: String) {
    let total = total
    let summary = summary
    decisionLogger.info(
      "Native feed row decisions (\(event, privacy: .public)): \(total, privacy: .public) total, \(summary, privacy: .public)")
  }
}

extension NativeFeedRowDecisionCounter.Outcome {
  init(_ decision: NativeFeedRowCoordinator.Decision) {
    switch decision {
    case .native: self = .native
    case .hosted(let reason): self = .hosted(reason)
    }
  }

  var name: String {
    switch self {
    case .native: "native"
    case .hosted(let reason): reason.rawValue
    }
  }
}
#endif
