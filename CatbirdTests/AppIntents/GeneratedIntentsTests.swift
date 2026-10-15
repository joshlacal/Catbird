//
//  GeneratedIntentsTests.swift
//  CatbirdTests
//
//  Pure-unit coverage for Catbird/AppIntents/Generated/ and its hand-written
//  Support/ dependencies. Everything here is network-free:
//   - AppEntity.displayRepresentation for each Generated/Entities/*.swift type,
//     driven off fixture Petrel view structs constructed directly (no decoding).
//   - unwrapIntentResponse(_:) status-code -> IntentError mapping.
//   - IntentAccountResolver "no active account" behavior (see note below).
//
//  AppIntentsTesting availability: verified `import AppIntentsTesting` compiles
//  and links against this Xcode's iOS Simulator SDK (Xcode 27 / iOS 27 SDK).
//  It is NOT used below: every API it exposes (IntentDefinitions,
//  AppEntityDefinition, AnyAppEntity, ...) is gated `@available(iOS 27.0, *)`
//  and is built around resolving intents/entities through the compiled
//  AppIntents metadata (by bundle identifier + type identifier), i.e.
//  end-to-end discoverability testing. It has no bearing on unit-testing a
//  plain `init(from:)` transform or a `displayRepresentation` computed
//  property, and gating these tests to iOS 27+ would make them skip entirely
//  on this project's iOS 18 minimum deployment target for no benefit. Plain
//  Swift Testing (as used everywhere else in CatbirdTests) is the right tool
//  here.
//

import CoreSpotlight
import Foundation
import Testing
import AppIntents
import Petrel
#if canImport(UIKit)
import UIKit
#endif
@testable import Catbird

// MARK: - Fixture builders

private enum Fixture {

  static func profileViewBasic(
    did: String = "did:plc:author1234567890123456",
    handle: String = "author.bsky.social",
    displayName: String? = "Author Name",
    avatar: URI? = nil
  ) throws -> AppBskyActorDefs.ProfileViewBasic {
    AppBskyActorDefs.ProfileViewBasic(
      did: try DID(didString: did),
      handle: try Handle(handleString: handle),
      displayName: displayName,
      pronouns: nil,
      avatar: avatar,
      associated: nil,
      viewer: nil,
      labels: nil,
      createdAt: nil,
      verification: nil,
      status: nil,
      debug: nil
    )
  }

  static func profileView(
    did: String = "did:plc:creator1234567890123456",
    handle: String = "creator.bsky.social",
    displayName: String? = "Creator Name",
    description: String? = "Creator bio",
    avatar: URI? = nil
  ) throws -> AppBskyActorDefs.ProfileView {
    AppBskyActorDefs.ProfileView(
      did: try DID(didString: did),
      handle: try Handle(handleString: handle),
      displayName: displayName,
      pronouns: nil,
      description: description,
      avatar: avatar,
      associated: nil,
      indexedAt: nil,
      createdAt: nil,
      viewer: nil,
      labels: nil,
      verification: nil,
      status: nil,
      debug: nil
    )
  }

  static func profileViewDetailed(
    did: String = "did:plc:detailed1234567890123",
    handle: String = "detailed.bsky.social",
    displayName: String? = "Detailed Name",
    description: String? = "Detailed bio",
    avatar: URI? = nil
  ) throws -> AppBskyActorDefs.ProfileViewDetailed {
    AppBskyActorDefs.ProfileViewDetailed(
      did: try DID(didString: did),
      handle: try Handle(handleString: handle),
      displayName: displayName,
      description: description,
      pronouns: nil,
      website: nil,
      avatar: avatar,
      banner: nil,
      followersCount: nil,
      followsCount: nil,
      postsCount: nil,
      associated: nil,
      joinedViaStarterPack: nil,
      indexedAt: nil,
      createdAt: nil,
      viewer: nil,
      labels: nil,
      pinnedPost: nil,
      verification: nil,
      status: nil,
      debug: nil
    )
  }

  static func generatorView(
    displayName: String = "Cool Feed",
    description: String? = "A feed about cool things",
    avatar: URI? = nil,
    creator: AppBskyActorDefs.ProfileView? = nil
  ) throws -> AppBskyFeedDefs.GeneratorView {
    AppBskyFeedDefs.GeneratorView(
      uri: try ATProtocolURI(uriString: "at://did:plc:creator1234567890123456/app.bsky.feed.generator/myfeed"),
      cid: CID.fromBlob(Data("generator-fixture".utf8)),
      did: try DID(didString: "did:plc:feedservice1234567890"),
      creator: try creator ?? profileView(),
      displayName: displayName,
      description: description,
      descriptionFacets: nil,
      avatar: avatar,
      likeCount: nil,
      acceptsInteractions: nil,
      labels: nil,
      viewer: nil,
      contentMode: nil,
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_700_000_000))
    )
  }

  static func postView(
    author: AppBskyActorDefs.ProfileViewBasic? = nil,
    text: String? = "Fixture post text",
    likeCount: Int? = nil,
    indexedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    rkey: String = "abc123"
  ) throws -> AppBskyFeedDefs.PostView {
    let record: ATProtocolValueContainer =
      text.map {
        .knownType(AppBskyFeedPost(
          text: $0, entities: nil, facets: nil, reply: nil, embed: nil,
          langs: nil, labels: nil, tags: nil,
          createdAt: ATProtocolDate(date: indexedAt)))
      } ?? .string("post-record-fixture")
    return AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:author1234567890123456/app.bsky.feed.post/\(rkey)"),
      cid: CID.fromBlob(Data("post-fixture".utf8)),
      author: try author ?? profileViewBasic(),
      record: record,
      embed: nil,
      bookmarkCount: nil,
      replyCount: nil,
      repostCount: nil,
      likeCount: likeCount,
      quoteCount: nil,
      indexedAt: ATProtocolDate(date: indexedAt),
      viewer: nil,
      labels: nil,
      threadgate: nil,
      debug: nil
    )
  }
}

// MARK: - Active account

/// A passive age check with a fixed answer; it never prompts.
private struct FixedAgeRequirement: AgeRegulatoryChecking {
  let requirement: PlatformAgeSignal.Requirement
  func preflight() async -> PlatformAgeSignal { PlatformAgeSignal(requirement: requirement) }
  #if canImport(UIKit)
  @MainActor
  func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  #endif
}

/// Runs `body` with an active account, as the app provides one to intent queries: the resolver
/// reads its DID from a private store bound for the task (never the shared app group), and the
/// account's `AppState` is the active one with a settled passive age check, whose decision
/// `IntentClientProvider.requireCoveredUse` reuses.
@MainActor
private func withActiveAccount(
  _ did: String, ageRequirement: PlatformAgeSignal.Requirement = .none,
  _ body: () async throws -> Void
) async throws {
  let suiteName = "test.app-intents.active-account.\(UUID().uuidString)"
  let store = try #require(UserDefaults(suiteName: suiteName))
  defer { store.removePersistentDomain(forName: suiteName) }
  store.set(did, forKey: IntentAccountResolver.activeAccountDIDKey)
  let client = await ATProtoClient(baseURL: try #require(URL(string: "https://intents-fixture.invalid")))
  let state = AppState(userDID: did, client: client, regulatoryChecker: FixedAgeRequirement(requirement: ageRequirement))
  let previousLifecycle = AppStateManager.shared.lifecycle
  AppStateManager.shared.setLifecycleForTesting(.authenticated(state))
  defer { AppStateManager.shared.setLifecycleForTesting(previousLifecycle) }
  defer { state.cleanup() }
  for _ in 0..<200 where state.ageAccess.isCheckingRequirement || state.platformAgeSignal.requirement != ageRequirement {
    try await Task.sleep(for: .milliseconds(10))
  }
  try #require(!state.ageAccess.isCheckingRequirement && state.platformAgeSignal.requirement == ageRequirement)
  try await IntentAccountResolver.$store.withValue(store) { try await body() }
}

// All suites below are nested inside a single top-level `GeneratedIntentsTests`
// type so `-only-testing:CatbirdTests/GeneratedIntentsTests` (matching this
// file's name, per repo convention) resolves to one Swift Testing type and
// picks up every nested suite/test.
@Suite("Generated App Intents (pure-unit)")
struct GeneratedIntentsTests {

  // MARK: - FeedGeneratorEntity

  @Suite("FeedGeneratorEntity DisplayRepresentation")
  struct FeedGeneratorDisplayRepresentationTests {

    @Test("Full fields: title, subtitle, and image are all populated from the view")
    func fullFields() throws {
      let avatarURI: URI = "https://example.com/feed-avatar.png"
      let view = try Fixture.generatorView(
        displayName: "Cool Feed",
        description: "A feed about cool things",
        avatar: avatarURI
      )
      let entity = FeedGeneratorEntity(from: view)

      #expect(entity.id == view.uri.uriString())
      #expect(entity.displayName == "Cool Feed")
      #expect(entity.description == "A feed about cool things")
      #expect(entity.avatar == avatarURI.url)

      let rep = entity.displayRepresentation
      #expect(String(localized: rep.title) == "Cool Feed")
      #expect(rep.subtitle.map { String(localized: $0) } == "A feed about cool things")
      #expect(rep.image == avatarURI.url.map { DisplayRepresentation.Image(url: $0) })
    }

    @Test("Missing description and avatar: subtitle and image are both nil")
    func missingOptionalFields() throws {
      let view = try Fixture.generatorView(displayName: "Bare Feed", description: nil, avatar: nil)
      let entity = FeedGeneratorEntity(from: view)

      #expect(entity.description == nil)
      #expect(entity.avatar == nil)

      let rep = entity.displayRepresentation
      #expect(String(localized: rep.title) == "Bare Feed")
      #expect(rep.subtitle == nil)
      #expect(rep.image == nil)
    }
  }

  // MARK: - PostEntity

  @Suite("PostEntity DisplayRepresentation")
  struct PostEntityDisplayRepresentationTests {

    @Test("Title is the author, subtitle the post text, image the author's avatar")
    func titleIsAuthorSubtitleIsText() throws {
      let avatar: URI = "https://cdn.bsky.app/img/avatar/plain/author.jpg"
      let author = try Fixture.profileViewBasic(avatar: avatar)
      let entity = PostEntity(from: try Fixture.postView(author: author, text: "Hello Bluesky"))
      let rep = entity.displayRepresentation
      #expect(entity.text == "Hello Bluesky")
      #expect(String(localized: rep.title) == "Author Name")
      #expect(rep.subtitle.map { String(localized: $0) } == "Hello Bluesky")
      #expect(rep.image == avatar.url.map { DisplayRepresentation.Image(url: $0) })
    }

    @Test("Title falls back to the author handle without a display name")
    func titleFallsBackToHandle() throws {
      let author = try Fixture.profileViewBasic(displayName: nil)
      let entity = PostEntity(from: try Fixture.postView(author: author, text: nil))
      #expect(entity.text == nil)
      #expect(String(localized: entity.displayRepresentation.title) == "author.bsky.social")
      #expect(entity.displayRepresentation.subtitle == nil)
      #expect(entity.displayRepresentation.image == nil)
    }

    @Test("Counts and rkey project from the view")
    func scalarProjections() throws {
      let entity = PostEntity(from: try Fixture.postView(likeCount: 42))
      #expect(entity.likeCount == 42)
      #expect(entity.rkey == "abc123")
    }

    @Test("Author display name and handle project from the view")
    func authorFieldsProject() throws {
      let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
      let view = try Fixture.postView(indexedAt: fixedDate)
      let entity = PostEntity(from: view)

      #expect(entity.id == view.uri.uriString())
      #expect(entity.authorDisplayName == "Author Name")
      #expect(entity.authorHandle == "author.bsky.social")
      #expect(entity.indexedAt == fixedDate)
      #expect(entity.displayRepresentation.image == nil)
    }
  }

  // MARK: - ProfileEntity

  @Suite("ProfileEntity DisplayRepresentation")
  struct ProfileEntityDisplayRepresentationTests {

    @Test("From ProfileViewDetailed: title uses displayName, subtitle is handle, image from avatar")
    func fromProfileViewDetailedWithDisplayName() throws {
      let avatarURI: URI = "https://example.com/detailed-avatar.png"
      let view = try Fixture.profileViewDetailed(
        handle: "detailed.bsky.social",
        displayName: "Detailed Name",
        avatar: avatarURI
      )
      let entity = ProfileEntity(from: view)

      #expect(entity.id == view.did.didString())
      #expect(entity.handle == "detailed.bsky.social")
      #expect(entity.displayName == "Detailed Name")
      #expect(entity.avatar == avatarURI.url)

      let rep = entity.displayRepresentation
      #expect(String(localized: rep.title) == "Detailed Name")
      #expect(String(localized: rep.subtitle!) == "detailed.bsky.social")
      #expect(rep.image == avatarURI.url.map { DisplayRepresentation.Image(url: $0) })
    }

    @Test("From ProfileViewDetailed: nil displayName falls back to handle for the title")
    func fromProfileViewDetailedWithoutDisplayName() throws {
      let view = try Fixture.profileViewDetailed(handle: "nodisplayname.bsky.social", displayName: nil, avatar: nil)
      let entity = ProfileEntity(from: view)

      let rep = entity.displayRepresentation
      #expect(String(localized: rep.title) == "nodisplayname.bsky.social")
      #expect(rep.image == nil)
    }

    @Test("From ProfileView: title uses displayName, subtitle is handle, image from avatar")
    func fromProfileViewWithDisplayName() throws {
      let avatarURI: URI = "https://example.com/view-avatar.png"
      let view = try Fixture.profileView(
        handle: "creator.bsky.social",
        displayName: "Creator Name",
        avatar: avatarURI
      )
      let entity = ProfileEntity(from: view)

      #expect(entity.id == view.did.didString())
      #expect(entity.handle == "creator.bsky.social")

      let rep = entity.displayRepresentation
      #expect(String(localized: rep.title) == "Creator Name")
      #expect(String(localized: rep.subtitle!) == "creator.bsky.social")
      #expect(rep.image == avatarURI.url.map { DisplayRepresentation.Image(url: $0) })
    }

    @Test("From ProfileView: nil displayName falls back to handle for the title")
    func fromProfileViewWithoutDisplayName() throws {
      let view = try Fixture.profileView(handle: "nodisplayname.bsky.social", displayName: nil, avatar: nil)
      let entity = ProfileEntity(from: view)

      let rep = entity.displayRepresentation
      #expect(String(localized: rep.title) == "nodisplayname.bsky.social")
      #expect(rep.image == nil)
    }
  }

  // MARK: - unwrapIntentResponse

  @Suite("unwrapIntentResponse error mapping")
  struct UnwrapIntentResponseTests {

    @Test("2xx response with data returns the payload")
    func successReturnsPayload() throws {
      let result = try unwrapIntentResponse((responseCode: 200, data: "payload"))
      #expect(result == "payload")
    }

    @Test("Boundary of the 2xx range (299) still succeeds")
    func upperBoundaryOfSuccessRangeSucceeds() throws {
      let result = try unwrapIntentResponse((responseCode: 299, data: 42))
      #expect(result == 42)
    }

    @Test("2xx response with nil data throws .emptyResponse")
    func successWithNilDataThrowsEmptyResponse() {
      #expect {
        _ = try unwrapIntentResponse((responseCode: 200, data: String?.none))
      } throws: { error in
        guard case IntentError.emptyResponse = error else { return false }
        return true
      }
    }

    @Test(
      "Non-2xx response codes throw .httpError with the original code",
      arguments: [100, 199, 300, 404, 500]
    )
    func nonSuccessCodeThrowsHTTPError(code: Int) {
      #expect {
        _ = try unwrapIntentResponse((responseCode: code, data: "ignored"))
      } throws: { error in
        guard case IntentError.httpError(let mappedCode) = error else { return false }
        return mappedCode == code
      }
    }

    @Test("Non-2xx response takes priority over nil data (still .httpError, not .emptyResponse)")
    func nonSuccessCodeWithNilDataStillThrowsHTTPError() {
      #expect {
        _ = try unwrapIntentResponse((responseCode: 500, data: String?.none))
      } throws: { error in
        guard case IntentError.httpError(let mappedCode) = error else { return false }
        return mappedCode == 500
      }
    }
  }

  // MARK: - IntentEntityBridges

  @Suite("IntentEntityBridges")
  struct IntentEntityBridgesTests {

    @Test("postText decodes the record text")
    func postTextFromKnownRecord() throws {
      let view = try Fixture.postView(text: "Hello Bluesky")
      #expect(IntentEntityBridges.postText(view) == "Hello Bluesky")
    }

    @Test("postText is nil when the record is not a decodable post")
    func postTextNilForOpaqueRecord() throws {
      let view = try Fixture.postView(text: nil)
      #expect(IntentEntityBridges.postText(view) == nil)
    }

    @Test("postText is nil for a decodable post with empty text")
    func postTextNilForEmptyText() throws {
      let view = try Fixture.postView(text: "")
      #expect(IntentEntityBridges.postText(view) == nil)
    }

    @Test("recordKey extracts the at-uri rkey")
    func recordKeyParses() throws {
      let uri = try ATProtocolURI(uriString: "at://did:plc:author1234567890123456/app.bsky.feed.post/abc123")
      #expect(IntentEntityBridges.recordKey(uri) == "abc123")
    }
  }

  // MARK: - PostEntity discovery surface

  @Suite("PostEntity Discovery")
  struct PostEntityDiscoveryTests {

    @Test("attributeSet carries post text and author for semantic search")
    func attributeSetContent() throws {
      let entity = PostEntity(from: try Fixture.postView(text: "Searchable words"))
      let set = entity.attributeSet
      #expect(set.textContent == "Searchable words")
      #expect(set.contentDescription == "Searchable words")
      #expect(set.authorNames == ["Author Name"])
      #expect(set.title == "Author Name")
      #expect(set.keywords == ["author.bsky.social", "Author Name"])
      #expect(set.url?.absoluteString == "https://bsky.app/profile/author.bsky.social/post/abc123")
    }

    @Test("webURL is the bsky.app permalink")
    func webURL() throws {
      let entity = PostEntity(from: try Fixture.postView())
      #expect(entity.webURL?.absoluteString == "https://bsky.app/profile/author.bsky.social/post/abc123")
    }
  }

  // MARK: - ProfileEntity discovery surface

  @Suite("ProfileEntity Discovery")
  struct ProfileEntityDiscoveryTests {

    @Test("attributeSet carries bio and handle keywords")
    func attributeSetContent() throws {
      let entity = ProfileEntity(from: try Fixture.profileViewDetailed())
      let set = entity.attributeSet
      #expect(set.contentDescription == "Detailed bio")
      #expect(set.keywords?.contains("detailed.bsky.social") == true)
      #expect(set.keywords?.contains("Detailed Name") == true)
      #expect(set.title == "Detailed Name")  // merged from defaultAttributeSet
    }

    @Test("webURL is the bsky.app profile permalink")
    func webURL() throws {
      let entity = ProfileEntity(from: try Fixture.profileViewDetailed())
      #expect(entity.webURL?.absoluteString == "https://bsky.app/profile/did:plc:detailed1234567890123")
    }
  }

  // MARK: - PostEntityStore

  @Suite("PostEntityStore")
  struct PostEntityStoreTests {

    @Test("Cached posts resolve through the query without the network")
    func cacheHitResolution() async throws {
      let view = try Fixture.postView(text: "Cached for Siri")
      // A full cache hit returns before the query ever bootstraps a client —
      // this would throw in the test environment if it fell through to XRPC.
      // The query still requires a signed-in account that passes the age check.
      try await withActiveAccount("did:plc:intentpostcachefixture") {
        await PostEntityStore.shared.store(view)
        let entities = try await PostEntityQuery().entities(for: [view.uri.uriString()])
        #expect(entities.count == 1)
        #expect(entities.first?.text == "Cached for Siri")
      }
    }

    @Test("A cached post is not returned to an account that requires an age check")
    func cacheHitRequiresCoveredUse() async throws {
      let view = try Fixture.postView(text: "Cached behind the age check")
      try await withActiveAccount("did:plc:intentpostagefixture", ageRequirement: .ageCheckRequired) {
        // Cached after the age decision settled (which purges exported posts), so the query's own
        // gate is what withholds it.
        await PostEntityStore.shared.store(view)
        #expect(await PostEntityStore.shared.entities(for: [view.uri.uriString()]).count == 1)
        do {
          let entities = try await PostEntityQuery().entities(for: [view.uri.uriString()])
          Issue.record("The query returned \(entities.count) cached post(s) without covered use")
        } catch IntentError.serviceUnavailable {
          // The covered-use gate withheld the cached post.
        }
      }
    }

    @Test("Unknown identifiers are omitted from store lookups")
    func missOmitted() async throws {
      let hits = await PostEntityStore.shared.entities(
        for: ["at://did:plc:unknown9999999999999999/app.bsky.feed.post/nope"])
      #expect(hits.isEmpty)
    }

    @Test("Duplicate identifiers resolve without crashing")
    func duplicateIdentifiers() async throws {
      let view = try Fixture.postView(text: "Duplicated onscreen annotation")
      let store = PostEntityStore(defaults: nil)
      await store.store(view)

      let id = view.uri.uriString()
      let entities = await store.entities(for: [id, id])

      #expect(entities.map(\.id) == [id, id])
    }

    @Test("A fresh store resolves posts persisted by another process")
    func persistentRoundTrip() async throws {
      let suiteName = "test.app-intents.post-cache.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let view = try Fixture.postView(text: "Persisted for Siri")
      let writer = PostEntityStore(defaults: defaults)
      await writer.store(view)
      await writer.flushPendingWrites()

      // A separate UserDefaults instance stands in for the extension process:
      // it shares the suite's stored data but none of the writer's buffer.
      let readerDefaults = try #require(UserDefaults(suiteName: suiteName))
      let reader = PostEntityStore(defaults: readerDefaults)
      let entities = await reader.entities(for: [view.uri.uriString()])
      #expect(entities.count == 1)
      #expect(entities.first?.text == "Persisted for Siri")
    }

    @Test("Stores buffer the App Group write instead of writing through")
    func writesAreBuffered() async throws {
      let suiteName = "test.app-intents.post-cache.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let view = try Fixture.postView(text: "Buffered for Siri")
      let writer = PostEntityStore(defaults: defaults)
      await writer.store(view)

      #expect(defaults.data(forKey: PostEntityCache.storageKey) == nil)
      let otherProcessDefaults = try #require(UserDefaults(suiteName: suiteName))
      let otherProcess = PostEntityStore(defaults: otherProcessDefaults)
      #expect(await otherProcess.entities(for: [view.uri.uriString()]).isEmpty)

      await writer.flushPendingWrites()
      #expect(defaults.data(forKey: PostEntityCache.storageKey) != nil)
      #expect(await otherProcess.entities(for: [view.uri.uriString()]).count == 1)
    }

    @Test("removeAll forgets posts in memory, in the App Group and still buffered")
    func removeAllForgetsPosts() async throws {
      let suiteName = "test.app-intents.post-cache.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let flushed = try Fixture.postView(text: "Signed-out account's post", rkey: "flushed1")
      let buffered = try Fixture.postView(text: "Signed-out account's unflushed post", rkey: "buffered1")
      let writer = PostEntityStore(defaults: defaults)
      await writer.store(flushed)
      await writer.flushPendingWrites()
      await writer.store(buffered)
      let ids = [flushed.uri.uriString(), buffered.uri.uriString()]
      #expect(await writer.entities(for: ids).count == 2)

      await writer.removeAll()

      #expect(await writer.entities(for: ids).isEmpty)
      #expect(defaults.data(forKey: PostEntityCache.storageKey) == nil)
      await writer.flushPendingWrites()
      let reader = PostEntityStore(defaults: try #require(UserDefaults(suiteName: suiteName)))
      #expect(await reader.entities(for: ids).isEmpty)
    }

    @Test("Persisted reads in the writing process include unflushed entries")
    func persistedReadsMergePendingEntries() throws {
      let suiteName = "test.app-intents.post-cache.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let view = try Fixture.postView(text: "Seeded by a thread snapshot")
      PostEntityCache.upsert([view], defaults: defaults)

      #expect(defaults.data(forKey: PostEntityCache.storageKey) == nil)
      let entities = PostEntityCache.entities(for: [view.uri.uriString()], defaults: defaults)
      #expect(entities.map(\.text) == ["Seeded by a thread snapshot"])
    }

    @Test("A thread snapshot larger than the cache persists only its first entries")
    func upsertKeepsNewestCapacityEntries() throws {
      let suiteName = "test.app-intents.post-cache.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let views = try (0..<(PostEntityCache.capacity + 10)).map { index in
        try Fixture.postView(text: "Row \(index)", rkey: "row\(index)")
      }
      PostEntityCache.upsert(views + [views[0]], defaults: defaults)
      PostEntityCache.flushPendingWrites(defaults: defaults)

      let otherProcess = try #require(UserDefaults(suiteName: suiteName))
      let ids = views.map { $0.uri.uriString() }
      let persisted = PostEntityCache.entities(for: ids, defaults: otherProcess)
      #expect(persisted.map(\.id) == Array(ids.prefix(PostEntityCache.capacity)))
    }
  }

  @Suite("AppGroupEntityWriteBuffer")
  struct AppGroupEntityWriteBufferTests {
    struct Entry: Codable, Equatable, Sendable {
      let id: String
      let value: Int
    }

    private func makeBuffer(
      _ defaults: UserDefaults, flushDelay: TimeInterval = 60,
      lifecycleNotifications: [Notification.Name] = []
    ) -> AppGroupEntityWriteBuffer<Entry> {
      AppGroupEntityWriteBuffer(
        defaults: defaults, storageKey: "entries", capacity: 3, flushDelay: flushDelay,
        lifecycleNotifications: lifecycleNotifications, id: { $0.id })
    }

    @Test("Batches merge newest first, de-duplicated and trimmed to capacity")
    func mergeOrder() throws {
      let suiteName = "test.app-intents.write-buffer.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let buffer = makeBuffer(defaults)
      buffer.enqueue([Entry(id: "a", value: 1), Entry(id: "b", value: 1)])
      buffer.flush()
      buffer.enqueue([Entry(id: "c", value: 1)])
      buffer.enqueue([Entry(id: "a", value: 2), Entry(id: "c", value: 9), Entry(id: "c", value: 3)])

      #expect(buffer.entries().map(\.id) == ["a", "c", "b"])
      #expect(buffer.entries().map(\.value) == [2, 9, 1])
      buffer.flush()
      let stored = makeBuffer(try #require(UserDefaults(suiteName: suiteName))).entries()
      #expect(stored == [Entry(id: "a", value: 2), Entry(id: "c", value: 9), Entry(id: "b", value: 1)])
    }

    @Test("Pending writes flush on their own after the delay")
    func flushesAfterDelay() async throws {
      let suiteName = "test.app-intents.write-buffer.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let buffer = makeBuffer(defaults, flushDelay: 0.05)
      buffer.enqueue([Entry(id: "a", value: 1)])
      #expect(defaults.data(forKey: "entries") == nil)

      for _ in 0..<40 where defaults.data(forKey: "entries") == nil {
        try await Task.sleep(for: .milliseconds(50))
      }
      #expect(defaults.data(forKey: "entries") != nil)
    }

    @Test("A lifecycle notification flushes synchronously")
    func lifecycleNotificationFlushes() throws {
      let suiteName = "test.app-intents.write-buffer.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let notification = Notification.Name("test.app-intents.write-buffer.lifecycle.\(UUID().uuidString)")
      let buffer = makeBuffer(defaults, lifecycleNotifications: [notification])
      buffer.enqueue([Entry(id: "a", value: 1)])
      #expect(defaults.data(forKey: "entries") == nil)

      NotificationCenter.default.post(name: notification, object: nil)
      #expect(defaults.data(forKey: "entries") != nil)
    }

    @Test("removeAll drops stored and buffered entries, and a scheduled flush writes nothing back")
    func removeAllClearsEverything() async throws {
      let suiteName = "test.app-intents.write-buffer.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let buffer = makeBuffer(defaults, flushDelay: 0.05)
      buffer.enqueue([Entry(id: "a", value: 1)])
      buffer.flush()
      buffer.enqueue([Entry(id: "b", value: 1)])
      #expect(defaults.data(forKey: "entries") != nil)

      buffer.removeAll()

      #expect(defaults.data(forKey: "entries") == nil)
      #expect(buffer.entries().isEmpty)
      // The flush "b" scheduled must not bring the signed-out entries back.
      try await Task.sleep(for: .milliseconds(300))
      #expect(defaults.data(forKey: "entries") == nil)
      buffer.enqueue([Entry(id: "c", value: 1)])
      buffer.flush()
      let stored = makeBuffer(try #require(UserDefaults(suiteName: suiteName))).entries()
      #expect(stored == [Entry(id: "c", value: 1)])
    }
  }

  @Suite("ProfileEntityStore")
  struct ProfileEntityStoreTests {

    @Test("Post-author (basic) profiles resolve through the query without the network")
    func cacheHitResolutionFromBasicView() async throws {
      let author = try Fixture.profileViewBasic()
      try await withActiveAccount("did:plc:intentprofilecachefixture") {
        await ProfileEntityStore.shared.store(ProfileEntity(from: author))
        let entities = try await ProfileEntityQuery().entities(for: [author.did.didString()])
        #expect(entities.count == 1)
        #expect(entities.first?.handle == "author.bsky.social")
        #expect(entities.first?.description == nil)  // basic views carry no bio
      }
    }

    @Test("A fresh store resolves profiles persisted by another process")
    func persistentRoundTrip() async throws {
      let suiteName = "test.app-intents.profile-cache.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let profile = ProfileEntity(from: try Fixture.profileViewBasic())
      let writer = ProfileEntityStore(defaults: defaults)
      await writer.store(profile)
      await writer.flushPendingWrites()

      let readerDefaults = try #require(UserDefaults(suiteName: suiteName))
      let reader = ProfileEntityStore(defaults: readerDefaults)
      let entities = await reader.entities(for: [profile.id])
      #expect(entities.count == 1)
      #expect(entities.first?.handle == "author.bsky.social")
    }

    @Test("removeAll forgets profiles in memory and in the App Group")
    func removeAllForgetsProfiles() async throws {
      let suiteName = "test.app-intents.profile-cache.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let profile = ProfileEntity(from: try Fixture.profileViewBasic())
      let writer = ProfileEntityStore(defaults: defaults)
      await writer.store(profile)
      await writer.flushPendingWrites()
      #expect(await writer.entities(for: [profile.id]).count == 1)

      await writer.removeAll()

      #expect(await writer.entities(for: [profile.id]).isEmpty)
      let reader = ProfileEntityStore(defaults: try #require(UserDefaults(suiteName: suiteName)))
      #expect(await reader.entities(for: [profile.id]).isEmpty)
    }

    @Test("Profile stores buffer the App Group write instead of writing through")
    func writesAreBuffered() async throws {
      let suiteName = "test.app-intents.profile-cache.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let profile = ProfileEntity(from: try Fixture.profileViewBasic())
      let writer = ProfileEntityStore(defaults: defaults)
      await writer.store(entities: [profile])

      #expect(defaults.data(forKey: "recentProfileEntities.v1") == nil)
      let otherProcessDefaults = try #require(UserDefaults(suiteName: suiteName))
      let otherProcess = ProfileEntityStore(defaults: otherProcessDefaults)
      #expect(await otherProcess.entities(for: [profile.id]).isEmpty)

      await writer.flushPendingWrites()
      #expect(await otherProcess.entities(for: [profile.id]).map(\.handle) == ["author.bsky.social"])
    }
  }

  // MARK: - IntentAccountResolver

  @Suite("IntentAccountResolver")
  struct IntentAccountResolverTests {

    // Each case binds a private store for its task, never the app group the app, widgets and
    // extensions share.
    @Test("The active account is read from the bound store, and an empty store has none")
    func activeDIDFromStore() throws {
      let suiteName = "test.app-intents.resolver.\(UUID().uuidString)"
      let store = try #require(UserDefaults(suiteName: suiteName))
      defer { store.removePersistentDomain(forName: suiteName) }
      IntentAccountResolver.$store.withValue(store) {
        #expect(IntentAccountResolver.activeDID() == nil)
        store.set("did:plc:intentresolverfixture", forKey: IntentAccountResolver.activeAccountDIDKey)
        #expect(IntentAccountResolver.activeDID() == "did:plc:intentresolverfixture")
      }
    }
  }

} // GeneratedIntentsTests
