//
//  PreviewFixturesTests.swift
//  CatbirdTests
//
//  Verifies that all 35 harvested wire-JSON fixtures decode cleanly against
//  current Petrel types, records do not demote to `.unknownType`,
//  `OfflineFixtureURLProtocol` serves offline responses and blocks live
//  requests, and `CatbirdCatalogLaunchConfig` parses all surfaces/profiles.
//

import Foundation
import Petrel
import Testing
@testable import Catbird

#if DEBUG

@Suite("PreviewFixtures decode & offline catalog config")
struct PreviewFixturesTests {

  @Test("Timeline fixture decodes non-empty feed")
  func timelineDecodes() {
    let timeline = PreviewFixtures.timeline
    #expect(timeline != nil)
    #expect(!(timeline?.feed.isEmpty ?? true))
  }

  @Test("Every FixtureManifest stem is loadable on disk or bundle")
  func everyManifestFixtureIsLoadable() throws {
    let data = try #require(PreviewFixtures.loadData("FixtureManifest"))
    let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let fixtures = try #require(manifest?["fixtures"] as? [String: Any])
    #expect(fixtures.count >= 35)
    for stem in fixtures.keys.sorted() {
      #expect(PreviewFixtures.loadData(stem) != nil, "missing fixture \(stem)")
    }
  }

  @Test("Every PostShape resolves from posts-shapes.json", arguments: PreviewFixtures.PostShape.allCases)
  func postShape(_ shape: PreviewFixtures.PostShape) {
    // gallery_6 may be nil if AppView omitted the overlay embed — assert presence for all others.
    if shape != .gallery6 {
      #expect(PreviewFixtures.post(shape) != nil, "missing shape \(shape.rawValue)")
    }
  }

  @Test("Petrel record guard canary: every fixture post record decodes as known AppBskyFeedPost")
  func everyPostRecordIsKnownType() throws {
    let posts = try #require(PreviewFixtures.postShapes?.posts)
    #expect(!posts.isEmpty)
    for post in posts {
      guard case .knownType(let value) = post.record, value is AppBskyFeedPost else {
        Issue.record("record demoted for \(post.uri.uriString()): \(post.record)")
        continue
      }
    }
  }

  @Test("Post shapes cover all 4 primary embed union kinds")
  func embedUnionsCovered() throws {
    let posts = try #require(PreviewFixtures.postShapes?.posts)
    var kinds = Set<String>()
    for post in posts {
      switch post.embed {
      case .appBskyEmbedImagesView: kinds.insert("images")
      case .appBskyEmbedExternalView: kinds.insert("external")
      case .appBskyEmbedRecordView: kinds.insert("record")
      case .appBskyEmbedRecordWithMediaView: kinds.insert("rwm")
      default: break
      }
    }
    #expect(kinds.isSuperset(of: ["images", "external", "record", "rwm"]))
  }

  @Test("Notifications fixture covers all core reason kinds")
  func notificationsCoverReasons() throws {
    let reasons = Set(try #require(PreviewFixtures.notifications?.notifications).map(\.reason))
    #expect(reasons.isSuperset(of: ["like", "follow", "repost", "reply", "mention", "quote"]))
  }

  @Test("Threads, profiles, feeds, graph, search, chat, and bookmarks decode cleanly")
  func allTypedFixturesDecode() {
    #expect(PreviewFixtures.authorFeedBot != nil)
    #expect(PreviewFixtures.authorFeedWithReposts != nil)
    #expect(PreviewFixtures.authorFeedVideos != nil)
    #expect(PreviewFixtures.threadV2 != nil)
    #expect(PreviewFixtures.threadClassic != nil)
    #expect(PreviewFixtures.videoPost != nil)
    #expect(PreviewFixtures.profileBot != nil)
    #expect(PreviewFixtures.profileReal != nil)
    #expect(PreviewFixtures.profiles != nil)
    #expect(PreviewFixtures.followers != nil)
    #expect(PreviewFixtures.follows != nil)
    #expect(PreviewFixtures.list != nil)
    #expect(PreviewFixtures.lists != nil)
    #expect(PreviewFixtures.starterPack != nil)
    #expect(PreviewFixtures.feedGenerators != nil)
    #expect(PreviewFixtures.discoverFeed != nil)
    #expect(PreviewFixtures.popularFeedGenerators != nil)
    #expect(PreviewFixtures.likes != nil)
    #expect(PreviewFixtures.repostedBy != nil)
    #expect(PreviewFixtures.quotes != nil)
    #expect(PreviewFixtures.searchPosts != nil)
    #expect(PreviewFixtures.searchPostsMedia != nil)
    #expect(PreviewFixtures.searchActors != nil)
    #expect(PreviewFixtures.trends != nil)
    #expect(PreviewFixtures.trendingTopics != nil)
    #expect(PreviewFixtures.taggedSuggestions != nil)
    #expect(PreviewFixtures.suggestions != nil)
    #expect(PreviewFixtures.labelerServices != nil)
    #expect(PreviewFixtures.preferences != nil)
    #expect(PreviewFixtures.chatConvos != nil)
    #expect(PreviewFixtures.chatMessages != nil)
    #expect(PreviewFixtures.bookmarks != nil)
  }

  @Test("OfflineFixtureURLProtocol serves XRPC & media offline and blocks unhandled hosts")
  func offlineProtocolBlocksLiveRequests() async throws {
    await OfflineFixtureURLProtocol.install(strict: true)
    OfflineFixtureURLProtocol.reset(clearCustomResponses: true)

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OfflineFixtureURLProtocol.self]
    let session = URLSession(configuration: config)

    let (timelineData, timelineResponse) = try await session.data(
      from: URL(string: "https://127.0.0.1/xrpc/app.bsky.feed.getTimeline?limit=10")!
    )
    let httpTimeline = try #require(timelineResponse as? HTTPURLResponse)
    #expect(httpTimeline.statusCode == 200)
    #expect(!timelineData.isEmpty)

    let (imageData, imageResponse) = try await session.data(
      from: URL(string: "https://cdn.bsky.app/img/avatar/plain/did:plc:test/cid@jpeg")!
    )
    let httpImage = try #require(imageResponse as? HTTPURLResponse)
    #expect(httpImage.statusCode == 200)
    #expect(imageData.starts(with: [0x89, 0x50, 0x4E, 0x47])) // PNG magic header

    #expect(OfflineFixtureURLProtocol.unhandledRequests.isEmpty)

    var didFailUnexpected = false
    do {
      _ = try await session.data(from: URL(string: "https://example.com/unexpected-live-endpoint")!)
    } catch {
      didFailUnexpected = true
    }
    #expect(didFailUnexpected)
    #expect(OfflineFixtureURLProtocol.unhandledRequests.count == 1)
    OfflineFixtureURLProtocol.reset()
  }

  @Test("CatbirdCatalogLaunchConfig parses profiles, surfaces, explicit overrides, and catalog URLs")
  func catalogLaunchConfigParsing() throws {
    let args = [
      "Catbird",
      "-CatbirdCatalog", "all",
      "-CatbirdProfile", "oled-font-trap",
      "-CatbirdAccent", "sunrise",
      "-CatbirdDT", "AX3",
      "-CatbirdReduceTransparency", "1",
      "-CatbirdInspector", "1",
      "-CatbirdCatalogClean", "1"
    ]
    #expect(CatbirdCatalogLaunchConfig.isRequested(in: args))

    let config = CatbirdCatalogLaunchConfig.fromProcessArguments(args)
    #expect(config.sweepAll)
    #expect(config.surface == .kit)
    #expect(config.profile == .oledFontTrap)
    #expect(config.theme == "dark")
    #expect(config.darkThemeMode == "black")
    #expect(config.accentColor == "sunrise")
    #expect(config.fontStyle == "monospaced")
    #expect(config.fontSize == "large")
    #expect(config.lineSpacing == "tight")
    #expect(config.dynamicType == .accessibility3)
    #expect(config.reduceTransparency)
    #expect(config.inspectorEnabled)
    #expect(config.hideChrome)

    let routeURL = try #require(
      URL(string: "blue.catbird://catalog?surface=ask-catbird&profile=dim-accent-trap&inspector=0")
    )
    let routed = try #require(config.applying(catalogURL: routeURL))
    #expect(routed.surface == .askCatbird)
    #expect(routed.profile == .dimAccentTrap)
    #expect(routed.accentColor == "sunrise")
    #expect(routed.darkThemeMode == "dim")
    #expect(!routed.inspectorEnabled)
  }
}

#endif
