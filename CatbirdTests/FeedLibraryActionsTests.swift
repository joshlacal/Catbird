import Foundation
import Petrel
import Testing
@testable import Catbird

@MainActor
struct FeedLibraryActionsTests {
  private let did = "did:plc:librarytest"
  private func uri(_ key: String = "new") throws -> ATProtocolURI {
    try ATProtocolURI(uriString: "at://did:plc:feedcreator/app.bsky.feed.generator/\(key)")
  }

  @Test func addPreservesDefaultAndOtherFields() async throws {
    let prefs = Preferences(accountDID: did)
    prefs.pinnedFeeds = ["following", "existing"]
    prefs.savedFeeds = ["saved"]
    prefs.primaryLanguage = "fr"
    prefs.adultContentEnabled = true
    let actions = FeedLibraryActions(accountDID: did, read: { prefs }, persist: { _ in .synced })
    let feed = try uri()
    #expect(try await actions.add(feed) == .saved)
    #expect(prefs.pinnedFeeds == ["following", "existing"])
    #expect(prefs.savedFeeds == ["saved", feed.uriString()])
    #expect(prefs.primaryLanguage == "fr")
    #expect(prefs.adultContentEnabled)
  }

  @Test func addingExistingFeedIsIdempotent() async throws {
    let prefs = Preferences(accountDID: did)
    let feed = try uri()
    prefs.savedFeeds = [feed.uriString()]
    var writes = 0
    let actions = FeedLibraryActions(accountDID: did, read: { prefs }, persist: { _ in
      writes += 1
      return .synced
    })
    #expect(try await actions.add(feed) == .saved)
    #expect(writes == 0)
  }

  @Test func pinPreservesOtherPinnedOrder() async throws {
    let prefs = Preferences(accountDID: did)
    let feed = try uri()
    prefs.pinnedFeeds = ["other", "following", "last"]
    prefs.savedFeeds = ["saved", feed.uriString()]
    let actions = FeedLibraryActions(accountDID: did, read: { prefs }, persist: { _ in .synced })
    #expect(try await actions.add(feed, to: .pinned) == .pinned)
    #expect(prefs.pinnedFeeds == ["other", "following", "last", feed.uriString()])
    #expect(prefs.savedFeeds == ["saved"])
  }

  @Test func saveFailureDoesNotReportSuccess() async throws {
    let prefs = Preferences(accountDID: did)
    prefs.savedFeeds = ["existing"]
    let actions = FeedLibraryActions(accountDID: did, read: { prefs }, persist: { _ in
      throw NSError(domain: "LocalWrite", code: 1)
    })
    let feed = try uri()
    do { _ = try await actions.add(feed); Issue.record("Local failure returned success") } catch {}
    #expect(prefs.savedFeeds == ["existing"])
    #expect(actions.membership(for: feed) == .absent)
    guard case .failed = actions.state(for: feed) else { Issue.record("Missing failure state"); return }
  }

  @Test func pendingSyncRetainsLocalMembershipAndRetries() async throws {
    let prefs = Preferences(accountDID: did)
    var writes = 0
    var notifications = 0
    let actions = FeedLibraryActions(accountDID: did, read: { prefs }, persist: { _ in
      writes += 1
      return writes == 1 ? .pendingSync("Offline") : .synced
    }, invalidate: { notifications += 1 })
    let feed = try uri()
    do { _ = try await actions.add(feed); Issue.record("Pending sync returned success") } catch {}
    #expect(actions.membership(for: feed) == .saved)
    #expect(actions.state(for: feed) == .pendingSync("Offline"))
    #expect(notifications == 1)
    #expect(try await actions.add(feed) == .saved)
    #expect(writes == 2)
    #expect(notifications == 2)
    #expect(prefs.savedFeeds == [feed.uriString()])
  }

  @Test func rapidSameFeedAddsPerformOneWrite() async throws {
    let prefs = Preferences(accountDID: did)
    let gate = LibraryWriteGate()
    var writes = 0
    let actions = FeedLibraryActions(accountDID: did, read: { prefs }, persist: { _ in
      writes += 1
      await gate.wait()
      return .synced
    })
    let feed = try uri()
    let first = Task { try await actions.add(feed) }
    while writes == 0 { await Task.yield() }
    let second = Task { try await actions.add(feed) }
    await Task.yield()
    gate.release()
    #expect(try await first.value == .saved)
    #expect(try await second.value == .saved)
    #expect(writes == 1)
    #expect(prefs.savedFeeds == [feed.uriString()])
  }

  @Test func concurrentDifferentFeedsPreserveBothWrites() async throws {
    let prefs = Preferences(accountDID: did)
    let gate = LibraryWriteGate()
    var writes = 0
    let actions = FeedLibraryActions(accountDID: did, read: { prefs }, persist: { _ in
      writes += 1
      if writes == 1 { await gate.wait() }
      return .synced
    })
    let a = try uri("a"), b = try uri("b")
    let first = Task { try await actions.add(a) }
    while writes == 0 { await Task.yield() }
    let second = Task { try await actions.add(b) }
    await Task.yield()
    #expect(writes == 1)
    gate.release()
    _ = try await first.value
    _ = try await second.value
    #expect(prefs.savedFeeds == [a.uriString(), b.uriString()])
  }

  @Test func retryRetainsRemovalIntent() async throws {
    let prefs = Preferences(accountDID: did)
    let feed = try uri()
    prefs.savedFeeds = [feed.uriString()]
    var writes = 0
    let actions = FeedLibraryActions(accountDID: did, read: { prefs }, persist: { _ in
      writes += 1
      return writes == 1 ? .pendingSync("Offline") : .synced
    })
    do { try await actions.remove(feed); Issue.record("Pending sync returned success") } catch {}
    try await actions.retry(feed)
    #expect(writes == 2)
    #expect(prefs.savedFeeds.isEmpty)
    #expect(actions.state(for: feed) == .success(.absent))
  }

  @Test func pendingIntentSurvivesRecreationAndServerRefresh() async throws {
    let defaults = UserDefaults(suiteName: "FeedLibraryTests.\(UUID().uuidString)")!
    let store = FeedLibraryPendingStore(defaults: defaults)
    let prefs = Preferences(accountDID: did)
    prefs.pinnedFeeds = ["following", "old"]
    let feed = try uri()
    let original = FeedLibraryActions(accountDID: did, pendingStore: store, read: { prefs },
      persist: { _ in .pendingSync("Offline") })
    do { _ = try await original.add(feed, to: .pinned) } catch {}
    // The manager applies this exact overlay before saving a server refresh.
    var serverPinned = ["following", "remote-new", "old"]
    var serverSaved = ["remote-saved"]
    let recreatedStore = FeedLibraryPendingStore(defaults: defaults)
    recreatedStore.reconcile(accountDID: did, pinned: &serverPinned, saved: &serverSaved)
    #expect(serverPinned == ["following", "remote-new", "old", feed.uriString()])
    #expect(serverSaved == ["remote-saved"])
    prefs.pinnedFeeds = serverPinned
    prefs.savedFeeds = serverSaved
    var writes = 0
    let recreated = FeedLibraryActions(accountDID: did, pendingStore: recreatedStore, read: { prefs },
      persist: { _ in writes += 1; return .synced })
    await recreated.refresh()
    guard case .pendingSync = recreated.state(for: feed) else { Issue.record("Lost pending state"); return }
    try await recreated.retry(feed)
    #expect(writes == 1)
    #expect(recreatedStore.entries(accountDID: did).isEmpty)
    #expect(prefs.pinnedFeeds == serverPinned)
  }

  @Test func durableIntentsAreAccountScopedAndRevisionChecked() throws {
    let defaults = UserDefaults(suiteName: "FeedLibraryTests.\(UUID().uuidString)")!
    let store = FeedLibraryPendingStore(defaults: defaults)
    let key = try uri().uriString()
    let first = store.record(uri: key, intent: .saved, accountDID: did)
    let second = store.record(uri: key, intent: .removed, accountDID: did)
    store.complete(first, accountDID: did)
    #expect(store.entries(accountDID: did) == [second])
    #expect(store.entries(accountDID: "another").isEmpty)
    var pinned = ["following", key, "last"], saved = ["other", key]
    store.reconcile(accountDID: did, pinned: &pinned, saved: &saved)
    #expect(pinned == ["following", "last"])
    #expect(saved == ["other"])
  }

  @Test func localFailureRestoresPreviousDurableIntent() async throws {
    let defaults = UserDefaults(suiteName: "FeedLibraryTests.\(UUID().uuidString)")!
    let store = FeedLibraryPendingStore(defaults: defaults)
    let feed = try uri()
    let previous = store.record(uri: feed.uriString(), intent: .saved, accountDID: did)
    let prefs = Preferences(accountDID: did)
    prefs.savedFeeds = [feed.uriString()]
    let actions = FeedLibraryActions(accountDID: did, pendingStore: store, read: { prefs }, persist: { _ in
      throw NSError(domain: "Local", code: 1)
    })
    do { _ = try await actions.add(feed, to: .pinned) } catch {}
    #expect(store.entries(accountDID: did) == [previous])
    #expect(prefs.savedFeeds == [feed.uriString()])
  }

  @Test func legacyRemovalSupersedesOfflineAdd() throws {
    let defaults = UserDefaults(suiteName: "FeedLibraryTests.\(UUID().uuidString)")!
    let store = FeedLibraryPendingStore(defaults: defaults)
    let key = try uri().uriString()
    store.record(uri: key, intent: .saved, accountDID: did)
    store.supersedePending(accountDID: did, pinned: ["following"], saved: [])
    var pinned = ["following"], saved = ["remote", key]
    store.reconcile(accountDID: did, pinned: &pinned, saved: &saved)
    #expect(saved == ["remote"])
    #expect(store.entries(accountDID: did).first?.intent == .removed)
  }

  @Test func legacyUnpinSupersedesOfflinePin() throws {
    let defaults = UserDefaults(suiteName: "FeedLibraryTests.\(UUID().uuidString)")!
    let store = FeedLibraryPendingStore(defaults: defaults)
    let key = try uri().uriString()
    store.record(uri: key, intent: .pinned, accountDID: did)
    store.supersedePending(accountDID: did, pinned: ["following"], saved: [key])
    var pinned = ["following", key], saved = ["remote"]
    store.reconcile(accountDID: did, pinned: &pinned, saved: &saved)
    #expect(pinned == ["following"])
    #expect(saved == ["remote", key])
    #expect(store.entries(accountDID: did).first?.intent == .unpinned)
  }

  @Test func serverMergePreservesRemoteFeedsIDsTypesAndOrder() {
    let intents = [FeedLibraryPendingStore.Entry(uri: "new", intent: .saved, revision: UUID()),
      .init(uri: "target", intent: .pinned, revision: UUID())]
    let feeds: [AppBskyActorDefs.SavedFeed] = [
      .init(id: "timeline-id", type: "timeline", value: "following", pinned: true),
      .init(id: "remote-id", type: "list", value: "remote", pinned: true),
      .init(id: "target-id", type: "feed", value: "target", pinned: false)]
    let result = FeedLibraryServerMerge.apply(intents, to: feeds, newIDs: ["new": "new-id"])
    #expect(result.map(\.value) == ["following", "remote", "new", "target"])
    #expect(result.map(\.id) == ["timeline-id", "remote-id", "new-id", "target-id"])
    #expect(result.map(\.type) == ["timeline", "list", "feed", "feed"])
    #expect(result.map(\.pinned) == [true, true, false, true])
  }

  @Test func pinMixedServerOrderPreservesDefault() {
    let entry = FeedLibraryPendingStore.Entry(uri: "saved", intent: .pinned, revision: UUID())
    let feeds: [AppBskyActorDefs.SavedFeed] = [
      .init(id: "s", type: "feed", value: "saved", pinned: false),
      .init(id: "d", type: "timeline", value: "following", pinned: true)]
    let result = FeedLibraryServerMerge.apply([entry], to: feeds, newIDs: [:])
    #expect(result.filter(\.pinned).map(\.value) == ["following", "saved"])
  }

  @Test func liveRetryUsesSupersedingLegacyRemoval() async throws {
    let defaults = UserDefaults(suiteName: "FeedLibraryTests.\(UUID().uuidString)")!
    let store = FeedLibraryPendingStore(defaults: defaults)
    let prefs = Preferences(accountDID: did)
    let feed = try uri()
    var writes = 0
    let actions = FeedLibraryActions(accountDID: did, pendingStore: store, read: { prefs }, persist: { _ in
      writes += 1; return writes == 1 ? .pendingSync("Offline") : .synced
    })
    do { _ = try await actions.add(feed) } catch {}
    prefs.savedFeeds = []
    store.supersedePending(accountDID: did, pinned: prefs.pinnedFeeds, saved: [])
    try await actions.retry(feed)
    #expect(prefs.savedFeeds.isEmpty)
    #expect(actions.state(for: feed) == .success(.absent))
  }

  @Test func failedLegacySaveRestoresPriorPendingRevision() throws {
    let defaults = UserDefaults(suiteName: "FeedLibraryTests.\(UUID().uuidString)")!
    let store = FeedLibraryPendingStore(defaults: defaults)
    let key = try uri().uriString()
    let prior = store.record(uri: key, intent: .saved, accountDID: did)
    let changes = store.supersedePending(accountDID: did, pinned: [], saved: [])
    for change in changes {
      store.complete(change.replacement, accountDID: did, restoring: change.previous)
    }
    #expect(store.entries(accountDID: did) == [prior])
  }

  @Test func acknowledgedIntentCannotBeRecreatedByStaleRetry() async throws {
    let defaults = UserDefaults(suiteName: "FeedLibraryTests.\(UUID().uuidString)")!
    let store = FeedLibraryPendingStore(defaults: defaults)
    let prefs = Preferences(accountDID: did)
    let feed = try uri()
    var writes = 0
    let actions = FeedLibraryActions(accountDID: did, pendingStore: store, read: { prefs }, persist: { _ in
      writes += 1; return .pendingSync("Offline")
    })
    do { _ = try await actions.add(feed) } catch {}
    for entry in store.entries(accountDID: did) { store.complete(entry, accountDID: did) }
    prefs.savedFeeds = []
    try await actions.retry(feed)
    #expect(writes == 1)
    #expect(actions.membership(for: feed) == .absent)
    #expect(actions.state(for: feed) == .idle)
  }

  @Test func v1MigrationPreservesTimelinePlacementAndListType() {
    let list = "at://did:plc:creator/app.bsky.graph.list/list"
    let result = FeedLibraryServerMerge.migrateV1(pinned: ["first", list],
      saved: ["first", list, "saved"], timelineIndex: 1,
      newIDs: ["first": "a", list: "b", "saved": "c", "following": "d"])
    #expect(result.map(\.value) == ["first", "following", list, "saved"])
    #expect(result.map(\.type) == ["feed", "timeline", "list", "feed"])
    #expect(result.map(\.pinned) == [true, true, true, false])
    let clamped = FeedLibraryServerMerge.migrateV1(pinned: ["first"], saved: [], timelineIndex: 99,
      newIDs: ["first": "a", "following": "d"])
    #expect(clamped.map(\.value) == ["first", "following"])
  }

  @Test func legacyConfirmationDoesNotOverlayLaterRemoteMembership() {
    let defaults = UserDefaults(suiteName: "FeedLibraryTests.\(UUID().uuidString)")!
    let store = FeedLibraryPendingStore(defaults: defaults)
    store.record(uri: "removed", intent: .removed, accountDID: did)
    let captured = store.entries(accountDID: did)
    for entry in captured { store.complete(entry, accountDID: did) }
    var pinned = ["following"], saved = ["removed", "remote"]
    store.reconcile(accountDID: did, pinned: &pinned, saved: &saved)
    #expect(saved == ["removed", "remote"])
  }

  @Test func emptyServerLibraryKeepsFollowingDefaultWhenSavingAndPinning() {
    let saved = FeedLibraryPendingStore.Entry(uri: "new", intent: .saved, revision: UUID())
    let result = FeedLibraryServerMerge.apply([saved], to: [],
      newIDs: ["following": "timeline-id", "new": "new-id"])
    #expect(result.map(\.value) == ["following", "new"])
    #expect(result.map(\.pinned) == [true, false])
    let pin = FeedLibraryPendingStore.Entry(uri: "new", intent: .pinned, revision: UUID())
    let pinned = FeedLibraryServerMerge.apply([pin], to: result, newIDs: ["following": "unused"])
    #expect(pinned.filter(\.pinned).map(\.value) == ["following", "new"])
    let directlyPinned = FeedLibraryServerMerge.apply([pin], to: [],
      newIDs: ["following": "timeline-id", "new": "new-id"])
    #expect(directlyPinned.filter(\.pinned).map(\.value) == ["following", "new"])
  }

  @Test func missingTimelineDoesNotReplaceExistingPinnedDefault() {
    let entry = FeedLibraryPendingStore.Entry(uri: "new", intent: .pinned, revision: UUID())
    let result = FeedLibraryServerMerge.apply([entry], to: [
      .init(id: "existing-id", type: "feed", value: "existing-default", pinned: true)],
      newIDs: ["following": "timeline-id", "new": "new-id"])
    #expect(result.filter(\.pinned).map(\.value) == ["existing-default", "following", "new"])
  }

  @Test func wrongAccountCannotWrite() async throws {
    let prefs = Preferences(accountDID: "did:plc:another")
    var writes = 0
    let actions = FeedLibraryActions(accountDID: did, read: { prefs }, persist: { _ in
      writes += 1
      return .synced
    })
    do { _ = try await actions.add(try uri()); Issue.record("Wrong account accepted") } catch {}
    #expect(writes == 0)
  }
}

@MainActor
private final class LibraryWriteGate {
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async { await withCheckedContinuation { continuation = $0 } }
  func release() { continuation?.resume(); continuation = nil }
}
