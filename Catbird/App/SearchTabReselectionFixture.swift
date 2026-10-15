#if DEBUG && os(iOS)
import Foundation
import Nuke
@testable import Petrel
import SwiftData
import SwiftUI
import UIKit

/// Runs the production tab container and Search with local transport data.
/// Home receives the local timeline through its ordinary cached-post restore API;
/// this fixture has no authenticated account and does not qualify feed refresh.
/// Use a disposable simulator container; ordinary account-scoped preferences still run.
@MainActor
struct SearchTabReselectionFixture: View {
  static let launchArgument = "--search-tab-reselection-ui-fixture"
  nonisolated static let accountDID = "did:plc:searchtabfixtureviewer"
  /// Adds typeahead profiles and feed discovery data for visual checks of Search
  /// and Discover Feeds. Search history is seeded with `historyArgument`, else cleared.
  static let visualArgument = "--search-visual-fixture"
  static let historyArgument = "--search-visual-history"
  static let overflowHistoryArgument = "--search-visual-history-overflow"
  static let shortHistoryArgument = "--search-visual-history-short"
  static let topicsArgument = "--search-visual-large-topics"
  static let hashtagArgument = "--search-visual-hashtag"
  static let moderatedHashtagArgument = "--search-visual-hashtag-moderated-page"
  static let profileArgument = "--search-visual-profile"

  @State private var account: AppState?
  @State private var context: SceneNavigationContext?
  @State private var storage: ModelContainer?
  @State private var selectedTab = 0
  @State private var lastTappedTab: Int?
  @State private var failure: String?
  @State private var preparationStage = "starting"

  var body: some View {
    Group {
      if let account, let context, let storage {
        SceneNavigationHost(appState: account, appStateManager: .shared, context: context) {
          MainContentView(selectedTab: $selectedTab, lastTappedTab: $lastTappedTab)
            .overlay(alignment: .top) {
              if selectedTab == 1 && !ProcessInfo.processInfo.arguments.contains(Self.hashtagArgument) {
                // Exercises the production binding consumer independently of
                // iOS 26's compact tab-to-search-field transformation.
                Button("Reselect Search") { lastTappedTab = 1 }
                  .font(.caption)
                  .buttonStyle(.bordered)
                  .accessibilityIdentifier("search-tabs.reselect")
              }
            }
            .overlay(alignment: .topLeading) {
              SearchTabNativeProbe(context: context, selectedTab: selectedTab)
                .frame(width: 2, height: 2)
            }
        }
        .modelContainer(storage)
        .environment(\.fontManager, account.fontManager)
      } else if let failure {
        Text(failure).accessibilityIdentifier("search-tabs.failure")
      } else {
        ProgressView("Preparing local search: \(preparationStage)")
          .accessibilityIdentifier("search-tabs.preparing")
      }
    }
    .preferredColorScheme(.light)
    .task { await prepare() }
    .onDisappear { context?.invalidate() }
  }

  private func prepare() async {
    guard account == nil else { return }
    do {
      let arguments = ProcessInfo.processInfo.arguments
      let visual = arguments.contains(Self.visualArgument), topics = arguments.contains(Self.topicsArgument)
      let hashtag = arguments.contains(Self.hashtagArgument)
      let moderatedHashtag = arguments.contains(Self.moderatedHashtagArgument)
      let profile = arguments.contains(Self.profileArgument)
      // Each launch starts on the timeline; Home otherwise restores the previous run's feed.
      UserDefaults.standard.removeObject(forKey: "lastSelectedFeed_\(Self.accountDID)")
      preparationStage = "local transport"
      try SearchTabLocalProtocol.prepare(visual: visual, topics: topics,
                                         hashtag: hashtag, moderatedHashtag: moderatedHashtag,
                                         profile: profile)
      if visual {
        let queryCount = arguments.contains(Self.shortHistoryArgument) ? 1
          : arguments.contains(Self.overflowHistoryArgument) ? 10 : nil
        try SearchVisualHistory.apply(seeded: arguments.contains(Self.historyArgument),
                                      queryCount: queryCount, did: Self.accountDID)
      }
      guard URLProtocol.registerClass(SearchTabLocalProtocol.self) else {
        throw URLError(.cannotLoadFromNetwork)
      }
      await NetworkService.setNetworkTestProtocolClasses([SearchTabLocalProtocol.self])
      preparationStage = "client initialization"
      let client = await ATProtoClient(baseURL: URL(string: "https://127.0.0.1")!)
      preparationStage = "app state"
      let state = AppState(userDID: Self.accountDID, client: client, regulatoryChecker: NoAgePrompt())
      state.currentUserProfile = try JSONDecoder().decode(AppBskyActorDefs.ProfileViewBasic.self,
        from: Data(#"{"did":"did:plc:searchtabfixtureviewer","handle":"search-viewer.test","displayName":"Local Search Viewer"}"#.utf8))
      preparationStage = "memory storage"
      let memory = try CatbirdSwiftDataStore.makeContainer(
        configuration: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
      PersistentFeedStateManager.initialize(with: memory)
      state.composerDraftManager.configureForTesting(modelContext: memory.mainContext)
      if topics || hashtag || profile {
        state.preferencesManager.configure(accountDID: state.userDID)
        state.preferencesManager.updateClient(client)
      }
      state.preferencesManager.setModelContext(memory.mainContext)
      preparationStage = "local preferences"
      if hashtag {
        preparationStage = "hashtag preferences"
        try await state.preferencesManager.fetchPreferences(forceRefresh: true)
        guard try state.preferencesManager.confirmedFeedFilterPreferences()?.accountDID == state.userDID else {
          throw URLError(.cannotDecodeContentData)
        }
      }
      let preferences = try await state.preferencesManager.getPreferences()
      preferences.nuxStates = []
      if visual {
        let pinned = "at://did:plc:searchvisualcreator/app.bsky.feed.generator/feed0"
        preferences.savedFeeds = [pinned]
        preferences.pinnedFeeds = [pinned]
      }
      preparationStage = "optional topic seed"
      if topics { try await SearchTrendingPayloads.seed(in: state, client: client) }
      if hashtag {
        preparationStage = "hashtag moderation seed"
        state.appSettings.hideNonPreferredLanguages = false
        // Populate the production moderation cache through its normal read API.
        // author.viewer.muted alone is not consulted by ContentFilterService.
        let mutes = try await state.graphManager.refreshMuteCache()
        guard mutes == (moderatedHashtag ? Set([SearchHashtagPayloads.mutedDID]) : Set<String>()) else {
          throw URLError(.cannotDecodeContentData)
        }
      }
      state.onboardingManager.showWelcomeSheet = false
      // The live feed's initial load intentionally requires an authenticated
      // session. Restore local rows through its production cache API instead.
      preparationStage = "timeline request"
      let (status, timeline) = try await client.app.bsky.feed.getTimeline(input: .init(limit: 50))
      guard status == 200, let timeline else { throw URLError(.cannotParseResponse) }
      let rows = timeline.feed.enumerated().compactMap { index, post in
        CachedFeedViewPost(from: post, feedType: FetchType.timeline.identifier, feedOrder: index)
      }
      guard rows.count == timeline.feed.count, !rows.isEmpty else { throw URLError(.cannotDecodeContentData) }
      let home = FeedStateStore.shared.stateManager(for: .timeline, appState: state)
      preparationStage = "timeline restore"
      await home.restorePersistedPosts(rows, cursor: nil)
      preparationStage = "scene context"
      let scene = SceneNavigationContext(appState: state, sceneID: UUID())
      if profile {
        scene.navigationManager.navigate(to: .profile(Self.accountDID), in: 0)
        scene.navigationManager.updateCurrentTab(0)
        selectedTab = 0
      } else if hashtag {
        scene.navigationManager.navigate(to: .hashtag("localtopic"), in: 1)
        scene.navigationManager.updateCurrentTab(1)
        selectedTab = 1
      }
      guard !Task.isCancelled else { return }
      storage = memory
      context = scene
      account = state
    } catch {
      failure = "Search tab fixture failed: \(error.localizedDescription)"
    }
  }

  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal {
      PlatformAgeSignal(requirement: .none, ageBand: nil, significantChangeConsentRequired: false)
    }
    @MainActor
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }
}

/// Intercepts every HTTP(S) request. Only declared reads receive fixture data;
/// unexpected reads and all writes fail locally without reaching a real service.
private final class SearchTabLocalProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var responses: [String: Data] = [:]
  nonisolated(unsafe) private static var images: [String: Data] = [:]
  nonisolated(unsafe) private static var searches = 0
  nonisolated(unsafe) private static var timelineReads = 0
  nonisolated(unsafe) private static var hashtagResponses: [String: Data] = [:]
  nonisolated(unsafe) private static var hashtagRequests: [[String: String]] = []

  @MainActor
  static func prepare(visual: Bool = false, topics: Bool = false,
                      hashtag: Bool = false, moderatedHashtag: Bool = false,
                      profile: Bool = false) throws {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    func post(_ index: Int, text: String) -> [String: Any] {
      ["uri": "at://did:plc:searchtabfixtureauthor/app.bsky.feed.post/row\(index)",
       "cid": CID.fromDAGCBOR(Data("search-tab-row-\(index)".utf8)).string,
       "author": ["did": "did:plc:searchtabfixtureauthor", "handle": "search-author.test",
                  "displayName": "Local Search Author"],
       "record": ["$type": "app.bsky.feed.post", "text": text, "createdAt": timestamp],
       "indexedAt": timestamp, "replyCount": 0, "repostCount": 0, "likeCount": 0]
    }
    let result = post(100, text: "Search fixture preserved result.")
    let feed = (0..<32).map { index in
      ["post": post(index, text: String(format: "Home fixture row %02d. Scroll through this local timeline to check the existing Home tab action.", index))]
    }
    let payloads: [String: [String: Any]] = [
      "app.bsky.feed.getTimeline": ["feed": feed],
      "app.bsky.feed.searchPostsV2": ["posts": [result], "hitsTotal": 1],
      "app.bsky.feed.getPosts": ["posts": [result]],
      "app.bsky.feed.getPostThread": ["thread": ["$type": "app.bsky.feed.defs#threadViewPost", "post": result, "replies": []]],
      "app.bsky.feed.getFeed": ["feed": []],
      "app.bsky.actor.searchActorsTypeahead": ["actors": []],
      "app.bsky.actor.searchActors": ["actors": []],
      "app.bsky.actor.getPreferences": ["preferences": []],
      "app.bsky.unspecced.getTrends": ["trends": []],
      "app.bsky.unspecced.getSuggestedUsers": ["actors": []],
      "app.bsky.notification.listNotifications": ["notifications": []],
      "app.bsky.notification.getUnreadCount": ["count": 0],
      "app.bsky.bookmark.getBookmarks": ["bookmarks": []]
    ]
    var merged = visual ? payloads.merging(SearchVisualPayloads.make(timestamp: timestamp, post: post)) { $1 } : payloads
    if topics { merged.merge(SearchTrendingPayloads.make(post: post)) { $1 } }
    if hashtag {
      merged["app.bsky.graph.getMutes"] = [
        "mutes": moderatedHashtag ? [SearchHashtagPayloads.mutedProfile] : []
      ]
    }
    if profile {
      let detailedProfile: [String: Any] = [
        "did": SearchTabReselectionFixture.accountDID,
        "handle": "search-viewer.test",
        "displayName": "Local Search Viewer",
        "description": "Visual fixture account for profile collection stack verification.",
        "followersCount": 42,
        "followsCount": 18,
        "postsCount": 32,
        "indexedAt": timestamp
      ]
      merged["app.bsky.actor.getProfile"] = detailedProfile
      merged["app.bsky.feed.getAuthorFeed"] = ["feed": feed]
      merged["app.bsky.graph.getKnownFollowers"] = ["followers": []]
    }
    let encoded = try merged.mapValues { try JSONSerialization.data(withJSONObject: $0) }
    let hashtagData = hashtag
      ? try SearchHashtagPayloads.make(timestamp: timestamp, moderated: moderatedHashtag, post: post)
        .mapValues { try JSONSerialization.data(withJSONObject: $0) }
      : [:]
    let localImages = topics ? SearchTrendingPayloads.images().compactMapValues { $0.pngData() } : [:]
    lock.withLock {
      responses = encoded; images = localImages; searches = 0; timelineReads = 0
      hashtagResponses = hashtagData; hashtagRequests = []
    }
  }

  static var counts: (searches: Int, timelineReads: Int) {
    lock.withLock { (searches, timelineReads) }
  }

  static var hashtagReceipt: (requests: [[String: String]], displayCount: Int, last: [String: String]) {
    lock.withLock {
      let display = hashtagRequests.filter { $0["limit"] == "30" }
      return (hashtagRequests, display.count, display.last ?? [:])
    }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, url.scheme == "https", url.host == "127.0.0.1",
          url.port == nil, url.user == nil, url.password == nil,
          request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    if let image = Self.lock.withLock({ Self.images[url.path] }) {
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "image/png"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: image)
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    guard url.path.hasPrefix("/xrpc/") else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    let method = String(url.path.dropFirst("/xrpc/".count))
    let data = Self.lock.withLock {
      if method == "app.bsky.feed.searchPosts", !Self.hashtagResponses.isEmpty {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // Capture the actual wire values rather than reading the view's bindings.
        let query = Dictionary(uniqueKeysWithValues: ["q", "sort", "lang", "cursor", "limit"].map { name in
          (name, items.first(where: { $0.name == name })?.value ?? "")
        })
        Self.hashtagRequests.append(query)
        let key = SearchHashtagPayloads.responseKey(query)
        return Self.hashtagResponses[key]
      }
      guard let data = Self.responses[method] else { return Data?.none }
      if method == "app.bsky.feed.searchPostsV2" { Self.searches += 1 }
      if method == "app.bsky.feed.getTimeline" { Self.timelineReads += 1 }
      return data
    }
    guard let data else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// Seeds or clears the viewer's local search history (app group defaults).
private enum SearchVisualHistory {
  static func apply(seeded: Bool, queryCount: Int? = nil, did: String) throws {
    let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")
    let history = SearchHistoryManager()
    history.clearRecentSearches(for: did)
    defaults?.removeObject(forKey: "recentProfileSearches_\(did)")
    guard seeded else { return }
    if let queryCount {
      // These query-only variants isolate row dragging at ordinary and accessibility sizes.
      // Keep the existing visual fixture's four queries and six profiles unchanged below.
      for index in (1...queryCount).reversed() {
        history.saveRecentSearch(query: String(format: "Scroll fixture query %02d", index),
                                 filters: SearchFilterState(), userDID: did)
      }
      return
    }
    var filtered = SearchFilterState()
    filtered.author = "pfrazee.com"
    for (query, filters) in [("tmz", SearchFilterState()), ("liquid glass", filtered),
                             ("from:noahweinberger2003.bsky.social jazz recommendations", SearchFilterState()),
                             ("#photography", SearchFilterState())].reversed() {
      history.saveRecentSearch(query: query, filters: filters, userDID: did)
    }
    let names = [("geesawra", "geesawra.test"), ("Will Stancil", "willstancil.test"),
                 ("P(aul) Frazee", "pfrazee.test"), ("Tessa Brown", "tessa.test"),
                 ("xan", "xan.test"), ("Alexandria Ocasio-Cortez", "aoc.test")]
    let profiles = try names.enumerated().map { index, item in
      RecentProfileSearch(did: try DID(didString: "did:plc:searchvisualprofile\(index)"),
                          handle: try Handle(handleString: item.1), displayName: item.0,
                          avatarURL: nil, labels: nil)
    }
    defaults?.set(try JSONEncoder().encode(profiles), forKey: "recentProfileSearches_\(did)")
  }
}

/// Typeahead profiles, popular feeds, a pinned saved feed and preview posts.
private enum SearchVisualPayloads {
  static func make(timestamp: String, post: (Int, String) -> [String: Any]) -> [String: [String: Any]] {
    let creator: [String: Any] = ["did": "did:plc:searchvisualcreator", "handle": "spacecowboy17.test",
                                  "displayName": "Space Cowboy"]
    func feed(_ index: Int, _ name: String, _ description: String) -> [String: Any] {
      ["uri": "at://did:plc:searchvisualcreator/app.bsky.feed.generator/feed\(index)",
       "cid": CID.fromDAGCBOR(Data("search-visual-feed-\(index)".utf8)).string,
       "did": "did:web:feeds.search-visual.test", "creator": creator, "displayName": name,
       "description": description, "likeCount": 1200 - index * 100, "indexedAt": timestamp]
    }
    let feeds = [
      feed(0, "For You", "A personalized algorithmic feed based on your likes."),
      feed(1, "Quiet Posters", "Posts from people you follow who post less often, so they don’t get lost in the timeline."),
      feed(2, "Science", "Research, papers and field notes from working scientists.")
    ]
    let texts = [
      "last pic in the van! gg",
      "new pds who this\n\n(my account is now on a new host!!!)",
      "Reading list for the weekend: three long essays on cities, transit and the people who build them.",
      "Tiny bug fixes are the best kind of shipping.",
      "Sunset over the bay tonight was unreal."
    ]
    let posts = texts.enumerated().map { index, text in ["post": post(200 + index, text)] }
    let actors = [("maxwell", "mfzx.test"), ("Maxwell Frost", "maxwellfrost.test"),
                  ("Max Kennerly", "maxkennerly.test")].enumerated().map { index, item in
      ["did": "did:plc:searchvisualactor\(index)", "handle": item.1, "displayName": item.0]
    }
    let saved: [String: Any] = [
      "$type": "app.bsky.actor.defs#savedFeedsPrefV2",
      "items": [["id": "search-visual-pinned", "type": "feed", "pinned": true,
                 "value": "at://did:plc:searchvisualcreator/app.bsky.feed.generator/feed0"]]
    ]
    return [
      "app.bsky.actor.searchActorsTypeahead": ["actors": actors],
      "app.bsky.unspecced.getPopularFeedGenerators": ["feeds": feeds],
      "app.bsky.feed.getFeed": ["feed": posts],
      "app.bsky.actor.getPreferences": ["preferences": [saved]]
    ]
  }
}

/// Deterministic search pages selected by the real query, sort, language and cursor.
/// Only the hashtag variant uses these reads; unrelated fixture modes are unchanged.
private enum SearchHashtagPayloads {
  static let mutedDID = "did:plc:searchhashtagmuted"
  static let mutedProfile: [String: String] = [
    "did": mutedDID, "handle": "muted-hashtag.test", "displayName": "Muted Local Author"
  ]

  static func responseKey(_ query: [String: String]) -> String {
    if query["limit"] != "30" { return "related|" + (query["q"] ?? "") }
    return [query["q"] ?? "", query["sort"] ?? "", query["lang"] ?? "", query["cursor"] ?? ""]
      .joined(separator: "|")
  }

  static func make(timestamp: String, moderated: Bool,
                   post: (Int, String) -> [String: Any]) -> [String: [String: Any]] {
    let epoch = ISO8601DateFormatter().date(from: timestamp) ?? Date()
    var payloads: [String: [String: Any]] = [:]
    for (tagIndex, tag) in ["localtopic", "relatedtopic"].enumerated() {
      let otherTag = tag == "localtopic" ? "relatedtopic" : "localtopic"
      payloads["related|#" + tag] = ["posts": [post(8000 + tagIndex, "Local related tags. #\(otherTag)")]]
      for sort in ["latest", "top"] {
        for (languageIndex, language) in ["", "en", "ja"].enumerated() {
          for cursor in ["", "hashtag-next"] {
            let page = cursor.isEmpty ? "" : " page 2"
            let languageName = language.isEmpty ? "any" : language
            let pageOffset = cursor.isEmpty ? 0 : 30
            let posts: [[String: Any]] = (1...24).map { rank in
              // Latest orders newer timestamps first; Top reverses the same
              // source order so the most-liked post arrives first.
              let sourceOrdinal = sort == "latest" ? rank : 25 - rank
              // Mode-specific identities prevent the post cache from retaining
              // an earlier response's intentionally different fixture marker.
              let sortOffset = sort == "top" ? 10000 : 0
              let index = sortOffset + 1000 + tagIndex * 1000 + languageIndex * 100 + pageOffset + sourceOrdinal
              let text = String(format: "Hashtag %@ %@%@ row %02d. Local trail notes. #%@ #%@",
                                sort, languageName, page, rank, tag, otherTag)
              var item = post(index, text)
              var record = item["record"] as? [String: Any] ?? [:]
              let postedAt = ISO8601DateFormatter().string(from: epoch.addingTimeInterval(-Double(sourceOrdinal * 60)))
              record["createdAt"] = postedAt
              record["langs"] = [language.isEmpty ? (sourceOrdinal.isMultiple(of: 2) ? "ja" : "en") : language]
              item["record"] = record
              item["indexedAt"] = postedAt
              item["likeCount"] = sourceOrdinal * 11
              return item
            }
            var output: [String: Any] = ["posts": posts]
            if moderated && cursor.isEmpty {
              var hidden = post(9900, "Muted hashtag fixture post. #\(tag)")
              hidden["author"] = mutedProfile
              hidden["uri"] = "at://\(mutedDID)/app.bsky.feed.post/hidden"
              output = ["posts": [hidden], "cursor": "hashtag-next"]
            }
            payloads["#\(tag)|\(sort)|\(language)|\(cursor)"] = output
          }
        }
      }
    }
    return payloads
  }
}

/// Optional local trend cards, with real bitmap cache entries and no external image requests.
private enum SearchTrendingPayloads {
  static let title = "Local Night Sky"
  static let link = "/profile/did:plc:searchtrendcreator/feed/localtopic"

  static func make(post: (Int, String) -> [String: Any]) -> [String: [String: Any]] {
    let actors: [[String: Any]] = (0..<3).map { index in
      ["did": "did:plc:searchtrendactor\(index)", "handle": "observer\(index).test",
       "displayName": "Local Observer \(index + 1)",
       "avatar": "https://127.0.0.1/fixture/trend-avatar-\(index).png"]
    }
    let trend: [String: Any] = [
      "topic": "local-night-sky", "displayName": title, "link": link,
      "description": "Local observers share clear views of the night sky, compare telescope notes, and explain how to spot the brightest planets from the city.",
      "startedAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200)),
      "postCount": 12400, "status": "hot", "category": "science", "actors": actors
    ]
    let posts: [[String: Any]] = (0..<3).map { index in
      var item = post(300 + index, "Local topic preview \(index + 1)")
      item["author"] = actors[index]
      let imageURL = "https://127.0.0.1/fixture/trend-media-\(index).png"
      item["embed"] = ["$type": "app.bsky.embed.images#view", "images": [
        ["thumb": imageURL, "fullsize": imageURL, "alt": "Local night-sky illustration \(index + 1)"]
      ]]
      return ["post": item]
    }
    return ["app.bsky.unspecced.getTrends": ["trends": [trend]],
            "app.bsky.feed.getFeed": ["feed": posts]]
  }

  @MainActor
  static func images() -> [String: UIImage] {
    var result: [String: UIImage] = [:]
    let colors: [UIColor] = [.systemIndigo, .systemTeal, .systemOrange]
    let symbols = ["moon.stars.fill", "sparkles", "sun.max.fill"]
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    for index in 0..<3 {
      for kind in ["media", "avatar"] {
        let size = CGSize(width: 124, height: kind == "media" ? 144 : 124)
        result["/fixture/trend-\(kind)-\(index).png"] = UIGraphicsImageRenderer(size: size, format: format).image { context in
          colors[index].setFill()
          context.fill(CGRect(origin: .zero, size: size))
          let symbol = UIImage(systemName: kind == "media" ? symbols[index] : "person.fill")?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
          symbol?.draw(in: CGRect(x: 30, y: (size.height - 64) / 2, width: 64, height: 64))
        }
      }
    }
    return result
  }

  @MainActor
  static func seed(in state: AppState, client: ATProtoClient) async throws {
    // Apply the fixture response through the real labeler-header and moderation gates.
    state.appSettings.showTrendingTopics = true
    try await state.preferencesManager.fetchPreferences(forceRefresh: true)
    guard state.topicPreviewLabelerScopeIsCurrent else { throw URLError(.cannotParseResponse) }
    let (status, response) = try await client.app.bsky.feed.getFeed(
      input: .init(feed: try ATProtocolURI(uriString: "at://did:plc:searchtrendcreator/app.bsky.feed.generator/localtopic"), limit: 3))
    guard status == 200, let posts = response?.feed, posts.count == 3 else {
      throw URLError(.cannotDecodeContentData)
    }
    let store = state.trendingTopicMediaStore
    store.invalidate(labelers: state.topicPreviewLabelers)
    store.setLabelDefinitions([:], for: state.topicPreviewLabelers)
    await store.load(key: state.topicPreviewLabelers + "|" + link) { posts }
    for (path, image) in images() {
      let url = URL(string: "https://127.0.0.1" + path)!
      let size = path.contains("avatar") ? TrendingTopicImageRequests.avatarSize : TrendingTopicImageRequests.cardSize
      for scale in [CGFloat(1), 2, 3] {
        let request = TrendingTopicImageRequests.request(url, size: size, displayScale: scale)
        ImageLoadingManager.shared.pipeline.cache[request] = ImageContainer(image: image)
        store.retainImage(image, for: request, revision: store.revision)
      }
    }
    let preview = state.topicPreview(for: link)
    guard preview.media.count == 3, preview.participants.count == 3 else {
      throw URLError(.cannotDecodeContentData)
    }
  }
}

/// Read-only observations of native controls and the real scene path. It cannot
/// focus, select tabs, change search contents or drive scroll position.
private struct SearchTabNativeProbe: UIViewRepresentable {
  let context: SceneNavigationContext
  let selectedTab: Int

  func makeUIView(context: Context) -> ProbeView { ProbeView() }
  func updateUIView(_ uiView: ProbeView, context: Context) {
    uiView.scene = self.context
    uiView.selectedTab = selectedTab
    uiView.publish()
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: ProbeView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 2, height: proposal.height ?? 2)
  }
  static func dismantleUIView(_ uiView: ProbeView, coordinator: ()) { uiView.stop() }

  @MainActor
  final class ProbeView: UIView {
    weak var scene: SceneNavigationContext?
    var selectedTab = 0
    private var timer: Timer?
    private var wasSearchFocused = false
    private var searchScrollStartOffsets: [ObjectIdentifier: CGFloat] = [:]
    private var maximumSearchVerticalPan: CGFloat = 0
    private var maximumSearchOffsetAdvance: CGFloat = 0
    private var lastActiveSearchScroll: [String: Any] = [:]
    /// The keyboard's top in window coordinates, including the input assistant bar above the keys
    /// (XCUITest's keyboard element frame leaves that bar out).
    private var keyboardTop: CGFloat?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      stop()
      guard window != nil else { return }
      isAccessibilityElement = true
      accessibilityIdentifier = "search-tabs.probe"
      accessibilityLabel = "Search tab native state"
      accessibilityTraits = .staticText
      isUserInteractionEnabled = false
      let observationTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.publish() }
      }
      timer = observationTimer
      // Observe while UIKit is tracking a drag as well as while the UI is idle.
      RunLoop.main.add(observationTimer, forMode: .common)
      NotificationCenter.default.addObserver(
        self, selector: #selector(keyboardFrameWillChange(_:)),
        name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
      publish()
    }

    func stop() {
      timer?.invalidate()
      timer = nil
      NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    @objc private func keyboardFrameWillChange(_ notification: Notification) {
      guard let window, let screen = window.windowScene?.screen,
            let end = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
      else { return }
      let frame = window.convert(end, from: screen.coordinateSpace)
      keyboardTop = frame.minY < window.bounds.maxY ? frame.minY : nil
      publish()
    }

    func publish() {
      guard let window, let surface = window.rootViewController?.view, let scene else { return }
      let views = descendants(surface)
      let fields = views.compactMap { $0 as? UISearchTextField }
      let field = fields.first(where: \.isFirstResponder) ?? fields.first(where: isVisible)
      let searchFocused = field?.isFirstResponder ?? false
      let scrollViews = views.compactMap { $0 as? UIScrollView }.filter(isVisible)
      if searchFocused && !wasSearchFocused {
        searchScrollStartOffsets = Dictionary(uniqueKeysWithValues: scrollViews.map {
          (ObjectIdentifier($0), $0.contentOffset.y + $0.adjustedContentInset.top)
        })
        maximumSearchVerticalPan = 0
        maximumSearchOffsetAdvance = 0
        lastActiveSearchScroll = [:]
      }
      wasSearchFocused = searchFocused
      if selectedTab == 1, scene.navigationManager.tabPaths[1]?.isEmpty != false {
        for scrollView in scrollViews where scrollView.bounds.width > surface.bounds.width / 2 {
          let pan = scrollView.panGestureRecognizer
          guard pan.state == .began || pan.state == .changed else { continue }
          let translation = pan.translation(in: scrollView)
          guard abs(translation.y) > abs(translation.x) else { continue }
          let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
          let identity = ObjectIdentifier(scrollView)
          let startOffset = searchScrollStartOffsets[identity] ?? offset
          searchScrollStartOffsets[identity] = startOffset
          lastActiveSearchScroll = [
            "type": NSStringFromClass(type(of: scrollView)),
            "keyboardDismissMode": scrollView.keyboardDismissMode.rawValue,
            "alwaysBounceVertical": scrollView.alwaysBounceVertical,
            "bounces": scrollView.bounces,
            "offset": offset, "startOffset": startOffset,
            "frameHeight": scrollView.bounds.height, "contentHeight": scrollView.contentSize.height,
            "contentSizeCategory": scrollView.traitCollection.preferredContentSizeCategory.rawValue
          ]
          maximumSearchVerticalPan = max(maximumSearchVerticalPan, abs(translation.y))
          maximumSearchOffsetAdvance = max(maximumSearchOffsetAdvance, offset - startOffset)
        }
      }
      let collection = views.compactMap { $0 as? UICollectionView }
        .filter { isVisible($0) && $0.contentSize.height > $0.bounds.height }
        .max { $0.bounds.height < $1.bounds.height }
      let counts = SearchTabLocalProtocol.counts
      let hashtag = SearchTabLocalProtocol.hashtagReceipt
      let hashtagRoot = views.first { $0.accessibilityIdentifier == "hashtag.posts" && isVisible($0) }
      let identifiedList = hashtagRoot.flatMap { root in
        descendants(root).compactMap { $0 as? UIScrollView }.filter(isVisible)
          .max { $0.bounds.height < $1.bounds.height }
      }
      let hashtagList = identifiedList ?? scrollViews.filter {
        $0.bounds.width > surface.bounds.width / 2 && $0.contentSize.height > $0.bounds.height
      }.max { $0.bounds.height < $1.bounds.height }
      let value: [String: Any] = [
        "selectedTab": selectedTab,
        "searchDepth": scene.navigationManager.tabPaths[1]?.count ?? 0,
        "searchFocused": searchFocused,
        "searchText": field?.text ?? "",
        "searchVerticalPanDistance": maximumSearchVerticalPan,
        "searchScrollOffsetAdvance": maximumSearchOffsetAdvance,
        "activeSearchScroll": lastActiveSearchScroll,
        "keyboardTop": keyboardTop ?? -1,
        "windowContentSizeCategory": window.traitCollection.preferredContentSizeCategory.rawValue,
        "contentSizeCategory": field?.traitCollection.preferredContentSizeCategory.rawValue
          ?? traitCollection.preferredContentSizeCategory.rawValue,
        "homeOffset": selectedTab == 0 ? collection.map { $0.contentOffset.y + $0.adjustedContentInset.top } ?? -1 : -1,
        "searchRequests": counts.searches,
        "timelineReads": counts.timelineReads,
        "hashtagRequests": hashtag.requests,
        "hashtagDisplayRequests": hashtag.displayCount,
        "hashtagLastRequest": hashtag.last,
        "hashtagScrollSource": identifiedList == nil ? "geometry" : "identifier",
        "hashtagScrollOffset": selectedTab == 1 && scene.navigationManager.hasItems(in: 1)
          ? hashtagList.map { $0.contentOffset.y + $0.adjustedContentInset.top } ?? 0 : 0
      ]
      if let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) {
        accessibilityValue = String(data: data, encoding: .utf8)
      }
    }

    private func descendants(_ view: UIView) -> [UIView] {
      [view] + view.subviews.flatMap(descendants)
    }
    private func isVisible(_ view: UIView) -> Bool {
      guard let window = view.window, view.convert(view.bounds, to: window).intersects(window.bounds) else { return false }
      var current: UIView? = view
      while let item = current {
        if item.isHidden || item.alpha < 0.01 { return false }
        current = item.superview
      }
      return true
    }
  }
}
#endif
