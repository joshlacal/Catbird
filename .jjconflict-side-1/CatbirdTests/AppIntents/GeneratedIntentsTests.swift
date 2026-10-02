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
    indexedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws -> AppBskyFeedDefs.PostView {
    let record: ATProtocolValueContainer =
      text.map {
        .knownType(AppBskyFeedPost(
          text: $0, entities: nil, facets: nil, reply: nil, embed: nil,
          langs: nil, labels: nil, tags: nil,
          createdAt: ATProtocolDate(date: indexedAt)))
      } ?? .string("post-record-fixture")
    return AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:author1234567890123456/app.bsky.feed.post/abc123"),
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

    @Test("Title is the post text when the record decodes")
    func titleUsesText() throws {
      let entity = PostEntity(from: try Fixture.postView(text: "Hello Bluesky"))
      #expect(entity.text == "Hello Bluesky")
      #expect(String(localized: entity.displayRepresentation.title) == "Hello Bluesky")
      #expect(entity.displayRepresentation.subtitle.map { String(localized: $0) } == "author.bsky.social")
    }

    @Test("Title falls back to the author handle for opaque records")
    func titleFallsBackToHandle() throws {
      let entity = PostEntity(from: try Fixture.postView(text: nil))
      #expect(entity.text == nil)
      #expect(String(localized: entity.displayRepresentation.title) == "author.bsky.social")
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
      #expect(set.title == "Searchable words")  // merged from defaultAttributeSet
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
      await PostEntityStore.shared.store(view)
      // A full cache hit returns before the query ever bootstraps a client —
      // this would throw in the test environment if it fell through to XRPC.
      let entities = try await PostEntityQuery().entities(for: [view.uri.uriString()])
      #expect(entities.count == 1)
      #expect(entities.first?.text == "Cached for Siri")
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

      let reader = PostEntityStore(defaults: defaults)
      let entities = await reader.entities(for: [view.uri.uriString()])
      #expect(entities.count == 1)
      #expect(entities.first?.text == "Persisted for Siri")
    }
  }

  @Suite("ProfileEntityStore")
  struct ProfileEntityStoreTests {

    @Test("Post-author (basic) profiles resolve through the query without the network")
    func cacheHitResolutionFromBasicView() async throws {
      let author = try Fixture.profileViewBasic()
      await ProfileEntityStore.shared.store(ProfileEntity(from: author))
      let entities = try await ProfileEntityQuery().entities(for: [author.did.didString()])
      #expect(entities.count == 1)
      #expect(entities.first?.handle == "author.bsky.social")
      #expect(entities.first?.description == nil)  // basic views carry no bio
    }

    @Test("A fresh store resolves profiles persisted by another process")
    func persistentRoundTrip() async throws {
      let suiteName = "test.app-intents.profile-cache.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let profile = ProfileEntity(from: try Fixture.profileViewBasic())
      let writer = ProfileEntityStore(defaults: defaults)
      await writer.store(profile)

      let reader = ProfileEntityStore(defaults: defaults)
      let entities = await reader.entities(for: [profile.id])
      #expect(entities.count == 1)
      #expect(entities.first?.handle == "author.bsky.social")
    }
  }

  // MARK: - IntentAccountResolver

  @Suite("IntentAccountResolver")
  struct IntentAccountResolverTests {

    // `IntentAccountResolver.activeDID()` reads directly from
    // `UserDefaults(suiteName: "group.blue.catbird.shared")` -- there is no
    // injection seam (the suite name is a hardcoded `static let`, and the type
    // has no initializer or protocol to substitute a test double). Unit tests
    // run in-process inside the CatbirdTests host app, which shares the real
    // app-group entitlement, so `UserDefaults(suiteName:)` for the real group
    // *does* succeed here -- but mutating `activeAccountDID` in that live,
    // shared app-group store to force the "absent" case would touch the same
    // storage the main app, widgets, and NotificationServiceExtension read/
    // write, with no safe way to snapshot/restore it around the test. That's
    // an unacceptable side effect for an automated unit test, so per the task
    // instructions this behavior is intentionally left uncovered here rather
    // than exercised against production-shared state. Covering it properly
    // would need `IntentAccountResolver` refactored to accept an injected
    // `UserDefaults` (e.g. a suite name or store passed to `activeDID()`),
    // which is a production-code change outside this test-only task.
  }

} // GeneratedIntentsTests
