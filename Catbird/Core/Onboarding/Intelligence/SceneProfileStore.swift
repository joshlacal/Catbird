import Foundation
import Observation
import Petrel

/// Profiles for the accounts the scene cards and the scene sheet show, shared by both so an account
/// seen on a card is already there when its sheet opens.
///
/// Requests from many views in the same moment (every card a grid lays out at once) are gathered
/// into one queue and sent in batches no larger than the profile lookup accepts, so a screen of
/// cards costs a few lookups rather than one per card. Each account is looked up at most once.
@MainActor
@Observable
public final class SceneProfileStore {
  /// The most accounts one lookup asks for.
  public static let batchSize = LiveCatbirdIntelligenceService.maxBatchSize

  public private(set) var profilesByDID: [String: HydratedRecommendedProfile] = [:]
  /// Accounts queued or being looked up right now.
  public private(set) var loadingDIDs: Set<String> = []

  @ObservationIgnored private let hydrate: @Sendable ([DID]) async -> [String: HydratedRecommendedProfile]
  @ObservationIgnored private let coalescingDelay: Duration
  @ObservationIgnored private var queue: [DID] = []
  @ObservationIgnored private var attempted: Set<String> = []
  @ObservationIgnored private var scheduledFlush: Task<Void, Never>?

  public init(
    coalescingDelay: Duration = .milliseconds(60),
    hydrate: @escaping @Sendable ([DID]) async -> [String: HydratedRecommendedProfile]
  ) {
    self.coalescingDelay = coalescingDelay
    self.hydrate = hydrate
  }

  /// Queues accounts for lookup and sends the queue shortly, together with whatever other views
  /// ask for in the meantime. Accounts already looked up, or already queued, are skipped.
  public func request(_ dids: [DID]) {
    guard enqueue(dids) else { return }
    guard scheduledFlush == nil else { return }
    let delay = coalescingDelay
    scheduledFlush = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      guard let self else { return }
      self.scheduledFlush = nil
      await self.flush()
    }
  }

  /// Queues accounts and sends the queue now, returning once those lookups finish.
  public func load(_ dids: [DID]) async {
    enqueue(dids)
    await flush()
  }

  /// Sends everything queued, in batches of at most `batchSize`.
  public func flush() async {
    while !queue.isEmpty {
      let batch = Array(queue.prefix(Self.batchSize))
      queue.removeFirst(batch.count)
      let found = await hydrate(batch)
      profilesByDID.merge(found) { _, fresh in fresh }
      loadingDIDs.subtract(batch.map { $0.didString() })
    }
  }

  /// Whether the lookup for `did` is over, found or not. False before anyone has asked for it.
  public func isSettled(_ did: DID) -> Bool {
    let key = did.didString()
    if profilesByDID[key] != nil { return true }
    return attempted.contains(key) && !loadingDIDs.contains(key)
  }

  /// The looked-up profiles for `dids`, in the same order, keeping only accounts a pick would add:
  /// accounts not found yet, accounts the viewer already follows, and accounts the viewer blocks or
  /// mutes are left out.
  public func profilesToFollow(for dids: [DID]) -> [HydratedRecommendedProfile] {
    dids.compactMap { did in
      guard let profile = profilesByDID[did.didString()],
            !profile.isBlockedOrMuted,
            !profile.alreadyFollowing else { return nil }
      return profile
    }
  }

  @discardableResult
  private func enqueue(_ dids: [DID]) -> Bool {
    var added = false
    for did in dids {
      let key = did.didString()
      guard profilesByDID[key] == nil, attempted.insert(key).inserted else { continue }
      queue.append(did)
      loadingDIDs.insert(key)
      added = true
    }
    return added
  }
}
