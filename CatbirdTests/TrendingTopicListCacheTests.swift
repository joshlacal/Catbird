import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Trending topic list cache", .serialized)
@MainActor
struct TrendingTopicListCacheTests {
  private let accountA = "did:plc:trendcachealice"
  private let accountB = "did:plc:trendcachebob"

  @Test("A graph change removes every account's stored trends, in memory and on disk")
  func graphChangeClearsDisk() async throws {
    let env = try Environment()
    defer { env.tearDown() }
    let store = env.makeStore()
    _ = try await store.fetchOrCoalesceTrends(for: accountA) { [makeTrend("alpha")] }
    _ = try await store.fetchOrCoalesceTrends(for: accountB) { [makeTrend("beta")] }
    #expect(env.storedData(for: accountA) != nil)
    #expect(env.storedData(for: accountB) != nil)

    store.invalidateForGraphChange()

    #expect(env.storedData(for: accountA) == nil)
    #expect(env.storedData(for: accountB) == nil)
    #expect(store.cachedTrends(for: accountA) == nil)
    #expect(env.makeStore().cachedTrends(for: accountA) == nil, "A relaunch must not find pre-mute trends either")
  }

  @Test("A labeler change removes stored trends")
  func labelerChangeClearsDisk() async throws {
    let env = try Environment()
    defer { env.tearDown() }
    let store = env.makeStore()
    _ = try await store.fetchOrCoalesceTrends(for: accountA) { [makeTrend("alpha")] }

    store.invalidate(labelers: "did:plc:newlabeler")

    #expect(env.storedData(for: accountA) == nil)
    #expect(store.cachedTrends(for: accountA) == nil)
  }

  @Test("A request sent before a graph change answers its caller but is never cached")
  func inFlightResponseAfterInvalidationIsNotCached() async throws {
    let env = try Environment()
    defer { env.tearDown() }
    let store = env.makeStore()
    let gate = FetchGate()
    let pending = Task { @MainActor in
      try await store.fetchOrCoalesceTrends(for: accountA) {
        await gate.wait()
        return [makeTrend("pre-mute")]
      }
    }
    try await waitUntil { gate.calls == 1 }

    store.invalidateForGraphChange()
    gate.open()

    #expect(try await pending.value == [makeTrend("pre-mute")])
    #expect(store.cachedTrends(for: accountA) == nil)
    #expect(env.storedData(for: accountA) == nil)
  }

  @Test("Leaving the foreground keeps stored trends to paint, but refreshes them on next use")
  func suspensionKeepsDiskButRefreshes() async throws {
    let env = try Environment()
    defer { env.tearDown() }
    let store = env.makeStore()
    _ = try await store.fetchOrCoalesceTrends(for: accountA) { [makeTrend("alpha")] }
    env.clock.advance(60)

    store.invalidateForSuspension()

    let cached = try #require(store.cachedTrends(for: accountA))
    #expect(cached.trends == [makeTrend("alpha")])
    #expect(!cached.isFresh)
    var fetches = 0
    let refreshed = try await store.fetchOrCoalesceTrends(for: accountA) {
      fetches += 1
      return [makeTrend("refreshed")]
    }
    #expect(fetches == 1)
    #expect(refreshed == [makeTrend("refreshed")])
  }

  @Test("Trends read back in a new launch are shown as stale and refreshed")
  func newLaunchTreatsDiskAsStale() async throws {
    let env = try Environment()
    defer { env.tearDown() }
    let firstLaunch = env.makeStore()
    _ = try await firstLaunch.fetchOrCoalesceTrends(for: accountA) { [makeTrend("alpha")] }
    env.clock.advance(9 * 60)
    #expect(firstLaunch.cachedTrends(for: accountA)?.isFresh == true)
    env.clock.advance(2 * 60)
    #expect(firstLaunch.cachedTrends(for: accountA)?.isFresh == false, "Ten minutes is the fresh window")

    env.clock.advance(-10 * 60)
    let secondLaunch = env.makeStore()
    let cached = try #require(secondLaunch.cachedTrends(for: accountA))
    #expect(cached.trends == [makeTrend("alpha")])
    #expect(!cached.isFresh, "A stored list predates anything this launch knows about mutes, blocks and labels")
  }

  @Test("Concurrent loads for one account share a single request")
  func concurrentLoadsCoalesce() async throws {
    let env = try Environment()
    defer { env.tearDown() }
    let store = env.makeStore()
    let gate = FetchGate()
    let fetch: @MainActor () async throws -> [AppBskyUnspeccedDefs.TrendView] = {
      await gate.wait()
      return [self.makeTrend("shared")]
    }
    async let first = store.fetchOrCoalesceTrends(for: accountA, fetch: fetch)
    async let second = store.fetchOrCoalesceTrends(for: accountA, fetch: fetch)
    try await waitUntil { gate.calls == 1 }
    gate.open()

    #expect(try await first == [makeTrend("shared")])
    #expect(try await second == [makeTrend("shared")])
    #expect(gate.calls == 1)
  }

  @Test("Account B never reads account A's trends")
  func accountsAreIsolated() async throws {
    let env = try Environment()
    defer { env.tearDown() }
    let store = env.makeStore()
    _ = try await store.fetchOrCoalesceTrends(for: accountA) { [makeTrend("alpha")] }

    #expect(store.cachedTrends(for: accountB) == nil)
    #expect(env.makeStore().cachedTrends(for: accountB) == nil)
    var fetchedForB = 0
    let trendsForB = try await store.fetchOrCoalesceTrends(for: accountB) {
      fetchedForB += 1
      return [makeTrend("beta")]
    }
    #expect(fetchedForB == 1, "A's fresh list must not answer B")
    #expect(trendsForB == [makeTrend("beta")])

    // An entry copied under another account's key is rejected and removed.
    let storedForA = try #require(env.storedData(for: accountA))
    env.defaults.set(storedForA, forKey: TrendingTopicsDiskCache.key(for: "did:plc:trendcachecarol"))
    #expect(env.disk.load(accountDID: "did:plc:trendcachecarol") == nil)
    #expect(env.storedData(for: "did:plc:trendcachecarol") == nil)
  }

  @Test("Sign-out and account removal delete only that account's stored trends")
  func removalDeletesKey() async throws {
    let env = try Environment()
    defer { env.tearDown() }
    let store = env.makeStore()
    _ = try await store.fetchOrCoalesceTrends(for: accountA) { [makeTrend("alpha")] }
    _ = try await store.fetchOrCoalesceTrends(for: accountB) { [makeTrend("beta")] }

    TrendingTopicsDiskCache.remove(accountDID: accountA, defaults: env.defaults)

    #expect(env.storedData(for: accountA) == nil)
    #expect(env.storedData(for: accountB) != nil)
    #expect(env.makeStore().cachedTrends(for: accountA) == nil)
  }

  @Test("Stored trends older than 24 hours, or dated in the future, are ignored and removed")
  func staleEntriesAreIgnored() throws {
    let env = try Environment()
    defer { env.tearDown() }
    let now = env.clock.now
    env.disk.store([makeTrend("almost-a-day")], accountDID: accountA, savedAt: now.addingTimeInterval(-(24 * 60 * 60 - 60)))
    #expect(env.disk.load(accountDID: accountA)?.trends == [makeTrend("almost-a-day")])

    env.disk.store([makeTrend("over-a-day")], accountDID: accountA, savedAt: now.addingTimeInterval(-(24 * 60 * 60 + 1)))
    #expect(env.disk.load(accountDID: accountA) == nil)
    #expect(env.storedData(for: accountA) == nil)
    #expect(env.makeStore().cachedTrends(for: accountA) == nil)

    env.disk.store([makeTrend("future")], accountDID: accountA, savedAt: now.addingTimeInterval(3600))
    #expect(env.disk.load(accountDID: accountA) == nil)
    #expect(env.storedData(for: accountA) == nil)
  }

  @Test("A kept list is a few KB of trend metadata; an oversized one stays in memory only")
  func payloadSize() async throws {
    let env = try Environment()
    defer { env.tearDown() }
    let trends = (0..<10).map { makeTrend("topic-\($0)", actorCount: 5) }
    env.disk.store(trends, accountDID: accountA, savedAt: env.clock.now)
    let data = try #require(env.storedData(for: accountA))
    #expect(data.count < 24 * 1024, "Ten trends with five actors each encoded to \(data.count) bytes")
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["accountDID", "trends", "savedAt"])
    #expect(env.disk.load(accountDID: accountA)?.trends == trends)

    let store = env.makeStore()
    let oversized = [makeTrend("huge", description: String(repeating: "x", count: TrendingTopicsDiskCache.maxStoredBytes))]
    _ = try await store.fetchOrCoalesceTrends(for: accountA, force: true) { oversized }
    #expect(env.storedData(for: accountA) == nil, "An oversized list replaces, never keeps, the older stored one")
    #expect(store.cachedTrends(for: accountA)?.trends == oversized)
  }

  // MARK: Helpers

  private func makeTrend(
    _ topic: String, actorCount: Int = 0, description: String? = nil
  ) -> AppBskyUnspeccedDefs.TrendView {
    let actors = (0..<actorCount).map { index in
      AppBskyActorDefs.ProfileViewBasic(
        did: try! DID(didString: "did:plc:trendactor\(index)"),
        handle: try! Handle(handleString: "actor\(index).example.invalid"),
        displayName: "Trend Actor \(index)", pronouns: nil,
        avatar: URI(uriString: "https://cdn.example.invalid/img/avatar/plain/did:plc:trendactor\(index)/bafkreiavatar\(index)@jpeg"),
        associated: nil, viewer: nil, labels: nil, createdAt: nil, verification: nil, status: nil, debug: nil)
    }
    return .init(
      topic: topic, displayName: topic.capitalized, description: description,
      link: "/profile/trending.example.invalid/feed/\(topic)",
      startedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_761_000_000)),
      postCount: 1200, status: "hot", category: "science", actors: actors)
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<500 where !condition() {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
  }
}

private final class TestClock {
  var now = Date(timeIntervalSince1970: 1_762_000_000)
  func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Holds a fetch until the test opens it.
@MainActor
private final class FetchGate {
  private(set) var calls = 0
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    calls += 1
    await withCheckedContinuation { continuation = $0 }
  }

  func open() {
    continuation?.resume()
    continuation = nil
  }
}

/// An isolated UserDefaults suite and clock shared by every store a test builds (one store per launch).
@MainActor
private struct Environment {
  let suiteName: String
  let defaults: UserDefaults
  let clock: TestClock
  let disk: TrendingTopicsDiskCache

  init() throws {
    let suiteName = "TrendingTopicListCacheTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let clock = TestClock()
    self.suiteName = suiteName
    self.defaults = defaults
    self.clock = clock
    disk = TrendingTopicsDiskCache(defaults: defaults, now: { clock.now })
  }

  func makeStore() -> TrendingTopicMediaStore {
    let clock = clock
    return TrendingTopicMediaStore(lists: TrendingTopicListCache(disk: disk, now: { clock.now }))
  }

  func storedData(for accountDID: String) -> Data? {
    defaults.data(forKey: TrendingTopicsDiskCache.key(for: accountDID))
  }

  func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
  }
}

@Suite("Trending topic cache cleanup wiring")
struct TrendingTopicCacheCleanupWiringTests {
  @Test("Every sign-out, session-end, removal and deletion path deletes the account's stored trends")
  func removalPathsDeleteStoredTrends() throws {
    let manager = try sourceFile("Catbird/Core/State/AppStateManager.swift")
    for signature in [
      "func logout(isManual: Bool = true) async",
      "private func retireSessionEndedAccount(_ did: String) async",
      "func removeAccount(_ userDID: String) async throws"
    ] {
      let body = try #require(functionBody(signature, in: manager), "Missing \(signature)")
      #expect(body.contains("TrendingTopicsDiskCache.remove(accountDID:"), "\(signature) must delete stored trends")
    }
    let removal = try #require(functionBody("func removeAccount(_ userDID: String) async throws", in: manager))
    let deleted = try #require(removal.range(of: "TrendingTopicsDiskCache.remove(accountDID:"))
    let throwingReset = try #require(removal.range(of: "MLSClient.shared.clearStorage"))
    #expect(deleted.lowerBound < throwingReset.lowerBound, "A removal that fails in the MLS reset must still drop trends")

    let deletion = try sourceFile("Catbird/Features/Settings/Models/AccountDeletionFlow.swift")
    let purge = try #require(functionBody("private static func purgeFilesystemData(forDID did: String) async", in: deletion))
    #expect(purge.contains("TrendingTopicsDiskCache.remove(accountDID: did)"))
  }

  @Test("Account suspension and retirement keep other accounts' stored trends")
  func suspensionDoesNotWipeDisk() throws {
    let appState = try sourceFile("Catbird/Core/State/AppState.swift")
    for signature in ["func suspendForAccountSwitch() async throws", "func cleanup()"] {
      let body = try #require(functionBody(signature, in: appState), "Missing \(signature)")
      #expect(body.contains("trendingTopicMediaStore.invalidateForSuspension()"))
      #expect(!body.contains("trendingTopicMediaStore.invalidateForGraphChange()"))
    }
  }

  private func sourceFile(_ relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repositoryRoot = testsDirectory.deletingLastPathComponent()
    return try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
  }

  private func functionBody(_ signature: String, in source: String) -> String? {
    guard let signatureRange = source.range(of: signature),
          let bodyStart = source[signatureRange.upperBound...].firstIndex(of: "{")
    else { return nil }
    var depth = 0
    var index = bodyStart
    while index < source.endIndex {
      switch source[index] {
      case "{": depth += 1
      case "}":
        depth -= 1
        if depth == 0 { return String(source[bodyStart...index]) }
      default: break
      }
      index = source.index(after: index)
    }
    return nil
  }
}
