import Foundation
import Petrel
import OSLog

/// Resolves blocked-author DIDs to profiles (handle, display name, avatar).
/// Batches lookups (25 per getProfiles call) behind a short coalescing window
/// and caches results for the session. Identity hydration only — this type
/// must never fetch post content.
actor BlockedAuthorHydrator {
  typealias ProfilesFetcher = @Sendable ([String]) async throws -> [AppBskyActorDefs.ProfileViewDetailed]

  private let fetchProfiles: ProfilesFetcher
  private let coalesceNanos: UInt64
  private var cache: [String: AppBskyActorDefs.ProfileViewDetailed] = [:]
  /// DIDs that resolved to nothing (deactivated/taken down) — cached to avoid refetch loops.
  private var unresolvable: Set<String> = []
  private var queue: Set<String> = []
  private var flushTask: Task<Void, Never>?
  /// Bumped by `invalidateAll()`. `flush()` awaits `fetchProfiles` per-chunk, which
  /// reintroduces actor reentrancy — `invalidateAll()` can run between chunk N
  /// completing and chunk N+1 starting, wiping chunk N's freshly-cached profiles
  /// before `profile(for:)` observes them. A generation mismatch after a flush lets
  /// `profile(for:)` tell "genuinely unresolved" apart from "wiped mid-flight" and
  /// retry once instead of surfacing a spurious nil for a resolvable DID.
  private var generation: UInt64 = 0
  private let logger = Logger(subsystem: "blue.catbird", category: "BlockedAuthorHydrator")

  init(coalesceNanos: UInt64 = 100_000_000, fetchProfiles: @escaping ProfilesFetcher) {
    self.coalesceNanos = coalesceNanos
    self.fetchProfiles = fetchProfiles
  }

  func profile(for did: String) async -> AppBskyActorDefs.ProfileViewDetailed? {
    if let hit = cache[did] { return hit }
    if unresolvable.contains(did) { return nil }
    let observedGeneration = generation
    queue.insert(did)
    await currentFlushTask().value
    if let hit = cache[did] { return hit }
    guard generation != observedGeneration else {
      // No invalidation raced this call — a genuine miss (unresolvable).
      return nil
    }
    // invalidateAll() ran mid-flush and may have wiped a result that already
    // landed for `did`. Retry once against the post-invalidation state rather
    // than report nil for a DID that was actually resolvable.
    if unresolvable.contains(did) { return nil }
    queue.insert(did)
    await currentFlushTask().value
    return cache[did]
  }

  func prefetch(dids: [String]) async {
    let missing = dids.filter { self.cache[$0] == nil && !self.unresolvable.contains($0) }
    guard !missing.isEmpty else { return }
    queue.formUnion(missing)
    await currentFlushTask().value
  }

  func invalidateAll() {
    cache.removeAll()
    unresolvable.removeAll()
    generation &+= 1
  }

  private func currentFlushTask() -> Task<Void, Never> {
    if let flushTask { return flushTask }
    let task = Task {
      try? await Task.sleep(nanoseconds: self.coalesceNanos)
      await self.flush()
    }
    flushTask = task
    return task
  }

  private func flush() async {
    flushTask = nil
    let dids = Array(queue)
    queue.removeAll()
    guard !dids.isEmpty else { return }
    for chunk in stride(from: 0, to: dids.count, by: 25).map({ Array(dids[$0..<min($0 + 25, dids.count)]) }) {
      do {
        let profiles = try await fetchProfiles(chunk)
        for profile in profiles { cache[profile.did.didString()] = profile }
        let returned = Set(profiles.map { $0.did.didString() })
        unresolvable.formUnion(chunk.filter { !returned.contains($0) })
      } catch {
        logger.warning("profile hydration batch failed: \(error.localizedDescription)")
        // Not marked unresolvable — transient failures may succeed on a later screen.
      }
    }
  }
}
