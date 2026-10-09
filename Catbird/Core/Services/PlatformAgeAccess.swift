import Foundation
import Observation

/// One account's transient platform restriction decisions and presentation work.
/// Age bands are consumed inside a decision and never retained on this object.
@MainActor
@Observable
final class PlatformAgeAccess {
  enum AccessError: Error, Equatable, Sendable, LocalizedError {
    case restricted(AgeRestrictedOperation)

    var errorDescription: String? {
      "This action is unavailable under the current age requirements."
    }
  }

  private(set) var signal: PlatformAgeSignal = .none
  private(set) var isCheckingRequirement = false
  private(set) var isRequesting = false
  private(set) var revision: UInt64 = 0

  @ObservationIgnored var decisionDidChange: (@MainActor () -> Void)?
  @ObservationIgnored private let checker: any AgeRegulatoryChecking
  @ObservationIgnored private var preflightTask: Task<Void, Never>?
  @ObservationIgnored private var requestTask: Task<Void, Never>?
  @ObservationIgnored private var requestID: UUID?
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var hasClaimedAutomaticRequest = false

  private var isSuspended = false
  private var hasCompletedPreflight = false
  private var hasRequiredCheck = false
  private var ordinaryAccessAllowed = true
  private var hidesMatureContent = false

  /// True until a required check has produced a decision permitting covered ordinary use.
  /// A completed check never changes the provider's adult-content preference.
  var requiresCheck: Bool { hasRequiredCheck && !ordinaryAccessAllowed }

  /// An additional ceiling only; false is not permission to bypass moderation preferences.
  var restrictsMatureContent: Bool {
    isSuspended || blocksForRequirementCheck || !ordinaryAccessAllowed || hidesMatureContent
  }

  /// A neutral foreground refresh preserves the last resolved decision. Only the first lookup
  /// (including a resumed account) or a known obligation must block while the OS is consulted.
  private var blocksForRequirementCheck: Bool {
    isCheckingRequirement && (!hasCompletedPreflight || hasRequiredCheck)
  }

  init(checker: any AgeRegulatoryChecking = AppleAgeRangeAdapter.shared) {
    self.checker = checker
  }

  /// Evaluates only this platform restriction; callers still enforce provider/moderation policy.
  func allows(_ operation: AgeRestrictedOperation) -> Bool {
    guard !isSuspended, !blocksForRequirementCheck, ordinaryAccessAllowed else { return false }
    return operation != .matureContent || !restrictsMatureContent
  }

  func require(_ operation: AgeRestrictedOperation) throws {
    guard allows(operation) else { throw AccessError.restricted(operation) }
  }

  /// All scenes share one automatic attempt for an unresolved requirement. A declined or
  /// cancelled prompt remains explicitly retryable without surprising a second window.
  func claimAutomaticRequest() -> Bool {
    guard !isSuspended, !isCheckingRequirement, !isRequesting,
          requiresCheck, !hasClaimedAutomaticRequest else { return false }
    hasClaimedAutomaticRequest = true
    return true
  }

  /// Starts a tracked, passive lookup. Concurrent scenes share one lookup or active prompt.
  func startPreflight() {
    _ = beginPreflightIfNeeded()
  }

  /// One scene cancelling its wait must not cancel another scene's shared passive lookup.
  func refreshRequirements() async {
    guard !Task.isCancelled else { return }
    await beginPreflightIfNeeded()?.value
  }

  func resume() {
    startPreflight()
  }

  func retry() {
    startPreflight()
  }

  /// Account-wide suspension. A scene cancels only its own request task instead.
  func suspend() {
    updateDecision {
      self.isSuspended = true
      self.hasCompletedPreflight = false
      self.hasClaimedAutomaticRequest = false
      self.invalidateWork()
      self.isCheckingRequirement = false
      if self.hasRequiredCheck {
        self.ordinaryAccessAllowed = false
        self.hidesMatureContent = true
      }
    }
  }

  /// Requests a band only for an affirmative unresolved requirement. The presenter and the
  /// current-account/scene predicate belong to the calling scene, never a global key window.
  func request(
    using requestBand: @escaping @MainActor () async throws -> AgeBand?,
    isCurrent: @escaping @MainActor () -> Bool
  ) async {
    guard !Task.isCancelled, !isSuspended, !isCheckingRequirement,
          requiresCheck, !isRequesting, isCurrent() else { return }

    // An explicit attempt also prevents another scene from automatically repeating it.
    hasClaimedAutomaticRequest = true
    generation &+= 1
    let requestGeneration = generation
    let requestID = UUID()
    self.requestID = requestID
    isRequesting = true
    let task = Task { @MainActor [weak self] in
      defer { self?.finishRequestActivity(id: requestID) }
      do {
        try Task.checkCancellation()
        guard isCurrent() else { return }
        let band = try await requestBand()
        guard !Task.isCancelled, isCurrent() else { return }
        self?.finishRequest(band: band, generation: requestGeneration)
      } catch {
        // No raw error/Apple response is retained or logged. Required use stays unavailable.
      }
    }
    requestTask = task

    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
      Task { @MainActor [weak self] in
        self?.cancelRequest(id: requestID, generation: requestGeneration)
      }
    }
  }

  private func beginPreflightIfNeeded() -> Task<Void, Never>? {
    if isCheckingRequirement { return preflightTask }
    // A second active window must not cancel the first window's system prompt.
    // After cancellation, passive checks can resume while the old system UI winds down.
    if let requestTask, !requestTask.isCancelled { return nil }

    updateDecision {
      self.isSuspended = false
      self.invalidateWork()
      self.isCheckingRequirement = true
      if self.hasRequiredCheck {
        self.ordinaryAccessAllowed = false
        self.hidesMatureContent = true
      }
    }
    let lookupGeneration = generation
    let checker = self.checker
    let task = Task { @MainActor [weak self] in
      let result = await checker.preflight()
      guard !Task.isCancelled else { return }
      self?.finishPreflight(result, generation: lookupGeneration)
    }
    preflightTask = task
    return task
  }

  private func finishPreflight(_ result: PlatformAgeSignal, generation: UInt64) {
    guard generation == self.generation, !isSuspended else { return }
    updateDecision {
      self.preflightTask = nil
      self.isCheckingRequirement = false
      self.hasCompletedPreflight = true
      switch result.requirement {
      case .unavailable:
        // Preserve an established obligation and any restrictive derived decision.
        self.signal = PlatformAgeSignal(
          requirement: self.hasRequiredCheck ? .ageCheckRequired : .unavailable,
          significantChangeConsentRequired: self.signal.significantChangeConsentRequired)
        if self.hasRequiredCheck {
          self.ordinaryAccessAllowed = false
          self.hidesMatureContent = true
        }
      case .none, .ageCheckRequired:
        self.hasRequiredCheck = result.requirement == .ageCheckRequired
        if !self.hasRequiredCheck { self.hasClaimedAutomaticRequest = false }
        self.signal = PlatformAgeSignal(
          requirement: result.requirement,
          significantChangeConsentRequired: result.significantChangeConsentRequired)
        // Synthetic checks may supply a band; consume it here just like a native response.
        self.consume(band: result.ageBand)
      }
    }
  }

  private func finishRequest(band: AgeBand?, generation: UInt64) {
    guard generation == self.generation, !isSuspended, isRequesting else { return }
    updateDecision {
      self.consume(band: band)
    }
  }

  private func finishRequestActivity(id: UUID) {
    guard requestID == id else { return }
    requestID = nil
    requestTask = nil
    isRequesting = false
  }

  private func cancelRequest(id: UUID, generation: UInt64) {
    guard requestID == id else { return }
    if generation == self.generation { self.generation &+= 1 }
    requestTask?.cancel()
    // Cancellation is cooperative. Keep the presentation latch until the actual call returns.
  }

  /// This synchronous method is the only place the response bounds affect retained state.
  /// Only the resulting access/ceiling booleans leave it.
  private func consume(band: AgeBand?) {
    let decision = AgePolicy.decision(
      for: .platform(PlatformAgeSignal(
        requirement: hasRequiredCheck ? .ageCheckRequired : .none,
        ageBand: band)),
      context: .ordinaryUse)
    ordinaryAccessAllowed = decision == .allow
    if ordinaryAccessAllowed { hasClaimedAutomaticRequest = false }
    if let band {
      hidesMatureContent = !band.isAdult
    } else {
      hidesMatureContent = hasRequiredCheck
    }
  }

  private func invalidateWork() {
    generation &+= 1
    preflightTask?.cancel()
    preflightTask = nil
    requestTask?.cancel()
  }

  private struct AccessSnapshot: Equatable {
    let ordinaryAllowed: Bool
    let requiresCheck: Bool
    let restrictsMatureContent: Bool
  }

  private var accessSnapshot: AccessSnapshot {
    AccessSnapshot(
      ordinaryAllowed: allows(.generalContent),
      requiresCheck: requiresCheck,
      restrictsMatureContent: restrictsMatureContent)
  }

  private func updateDecision(_ changes: () -> Void) {
    let before = accessSnapshot
    changes()
    guard before != accessSnapshot else { return }
    revision &+= 1
    decisionDidChange?()
  }
}
