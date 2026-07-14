import Foundation

@MainActor
final class NSENotificationProcessingLeases {
  struct Lease: Hashable {
    let id: UUID
    let startsNewGeneration: Bool
    let recipientDID: String
  }

  struct OrdinaryCleanupClaim: Hashable {
    let id: UUID
    let generationID: UUID
  }

  struct AppStopCleanupClaim: Hashable {
    let id: UUID
    let generationID: UUID
    let recipientDIDs: Set<String>
  }

  enum ReleaseDecision: Equatable {
    case stillProcessing
    case performCleanup(OrdinaryCleanupClaim)
    case cleanupAlreadyPerformed
    case cleanupOwnedElsewhere
  }

  enum AppStopDecision: Equatable {
    case performCleanup(AppStopCleanupClaim)
    case cleanupAlreadyPerformed
  }

  private var generationID = UUID()
  private var activeLeases: [UUID: String] = [:]
  private var generationRecipientDIDs: Set<String> = []
  private var cleanupInProgress = false
  private var cleanupCompletedForGeneration = true
  private var expirationCleanupClaimed = false
  private var ordinaryCleanupClaim: OrdinaryCleanupClaim?
  private var ordinaryCleanupClosing = false
  private var appStopCleanupClaim: AppStopCleanupClaim?
  private var appStopCleanupClosing = false
  private var appStopPending = false
  private var acquisitionWaiters: [CheckedContinuation<Void, Never>] = []
  private var appStopWaiters: [CheckedContinuation<AppStopDecision, Never>] = []

  var activeRecipientDIDs: Set<String> {
    Set(activeLeases.values)
  }

  func acquire(recipientDID: String) async -> Lease {
    while cleanupInProgress || appStopPending {
      await withCheckedContinuation { continuation in
        acquisitionWaiters.append(continuation)
      }
    }

    let startsNewGeneration = activeLeases.isEmpty && cleanupCompletedForGeneration
    if startsNewGeneration {
      generationID = UUID()
      generationRecipientDIDs.removeAll(keepingCapacity: true)
      cleanupCompletedForGeneration = false
      expirationCleanupClaimed = false
      ordinaryCleanupClaim = nil
      ordinaryCleanupClosing = false
      appStopCleanupClaim = nil
      appStopCleanupClosing = false
    }

    let lease = Lease(
      id: UUID(),
      startsNewGeneration: startsNewGeneration,
      recipientDID: recipientDID
    )
    activeLeases[lease.id] = recipientDID
    generationRecipientDIDs.insert(recipientDID)
    return lease
  }

  func release(_ lease: Lease) -> ReleaseDecision {
    guard activeLeases.removeValue(forKey: lease.id) != nil else {
      return .cleanupAlreadyPerformed
    }
    guard activeLeases.isEmpty else {
      return .stillProcessing
    }

    if expirationCleanupClaimed {
      completeCleanupGeneration()
      return .cleanupAlreadyPerformed
    }

    if appStopPending {
      activateAppStopCleanup()
      return .cleanupOwnedElsewhere
    }

    guard !cleanupCompletedForGeneration else {
      return .cleanupAlreadyPerformed
    }

    let claim = OrdinaryCleanupClaim(id: UUID(), generationID: generationID)
    ordinaryCleanupClaim = claim
    ordinaryCleanupClosing = false
    cleanupInProgress = true
    return .performCleanup(claim)
  }

  func ordinaryCleanupIsCurrent(_ claim: OrdinaryCleanupClaim) -> Bool {
    ordinaryCleanupClaim == claim && !cleanupCompletedForGeneration
  }

  func beginOrdinaryClose(_ claim: OrdinaryCleanupClaim) -> Bool {
    guard ordinaryCleanupIsCurrent(claim) else { return false }
    ordinaryCleanupClosing = true
    return true
  }

  func finishOrdinaryCleanup(_ claim: OrdinaryCleanupClaim) {
    guard ordinaryCleanupClaim == claim else { return }
    completeCleanupGeneration()
  }

  func claimExpirationCleanup() -> Bool {
    guard !expirationCleanupClaimed else { return false }
    guard !cleanupCompletedForGeneration else { return false }

    expirationCleanupClaimed = true
    cleanupInProgress = true
    if ordinaryCleanupClosing || appStopCleanupClosing {
      return false
    }
    ordinaryCleanupClaim = nil
    appStopCleanupClaim = nil
    return true
  }

  func finishExpirationCleanupIfIdle() {
    guard activeLeases.isEmpty else { return }
    completeCleanupGeneration()
  }

  func requestAppStopCleanup() async -> AppStopDecision {
    guard !cleanupCompletedForGeneration else {
      return .cleanupAlreadyPerformed
    }

    appStopPending = true
    if activeLeases.isEmpty && !cleanupInProgress {
      return makeAppStopCleanupDecision()
    }

    return await withCheckedContinuation { continuation in
      appStopWaiters.append(continuation)
    }
  }

  func finishAppStopCleanup(_ claim: AppStopCleanupClaim) {
    guard appStopCleanupClaim == claim else { return }
    completeCleanupGeneration()
  }

  func appStopCleanupIsCurrent(_ claim: AppStopCleanupClaim) -> Bool {
    appStopCleanupClaim == claim && !cleanupCompletedForGeneration
  }

  func beginAppStopClose(_ claim: AppStopCleanupClaim) -> Bool {
    guard appStopCleanupIsCurrent(claim) else { return false }
    appStopCleanupClosing = true
    return true
  }

  private func activateAppStopCleanup() {
    let decision = makeAppStopCleanupDecision()
    guard !appStopWaiters.isEmpty else { return }
    let owner = appStopWaiters.removeFirst()
    owner.resume(returning: decision)
    let remaining = appStopWaiters
    appStopWaiters.removeAll(keepingCapacity: true)
    for waiter in remaining {
      waiter.resume(returning: .cleanupAlreadyPerformed)
    }
  }

  private func makeAppStopCleanupDecision() -> AppStopDecision {
    cleanupInProgress = true
    appStopPending = false
    let claim = AppStopCleanupClaim(
      id: UUID(),
      generationID: generationID,
      recipientDIDs: generationRecipientDIDs
    )
    appStopCleanupClaim = claim
    appStopCleanupClosing = false
    return .performCleanup(claim)
  }

  private func completeCleanupGeneration() {
    cleanupCompletedForGeneration = true
    cleanupInProgress = false
    expirationCleanupClaimed = expirationCleanupClaimed || ordinaryCleanupClosing
    ordinaryCleanupClaim = nil
    ordinaryCleanupClosing = false
    appStopCleanupClaim = nil
    appStopCleanupClosing = false
    appStopPending = false

    let stopWaiters = appStopWaiters
    appStopWaiters.removeAll(keepingCapacity: true)
    for waiter in stopWaiters {
      waiter.resume(returning: .cleanupAlreadyPerformed)
    }

    let waiters = acquisitionWaiters
    acquisitionWaiters.removeAll(keepingCapacity: true)
    for waiter in waiters {
      waiter.resume()
    }
  }
}
