#if DEBUG && os(iOS)
import Foundation
@testable import Petrel
import SwiftData
import SwiftUI
import UIKit
import os

private let moderationFixtureLogger = Logger(subsystem: "blue.catbird", category: "ModerationUIFixture")

/// Offline moderation presentation fixture, launched with
/// `--moderation-ui-fixture --moderation-scene=<name>`.
///
/// It renders the production feed row (`FeedPostRow`), `ThreadViewMainPostView` and
/// `ModerationSettingsView` for synthetic Petrel models. Preferences reach the app
/// through the production load path: canned `app.bsky.actor.getPreferences` and
/// `app.bsky.labeler.getServices` responses are served by a URLProtocol that sits
/// under the real `ATProtoClient`, then `PreferencesManager.fetchPreferences` and
/// `syncPreferencesWithAppSettings` run exactly as at app start. Every other
/// HTTP(S) request is refused and recorded in the ready marker. Images are PNGs
/// the fixture renders into its temporary directory and references by file URL.
/// Nothing here authenticates, contacts a real host or writes outside the sandbox.
@MainActor
struct ModerationUIFixture: View {
  @State private var phase: Phase = .preparing
  @State private var path = NavigationPath()
  @State private var draftGuard = SettingsDraftGuard()

  private enum Phase {
    case preparing
    case ready(ModerationFixtureWorld)
    case failed(String)
  }

  var body: some View {
    Group {
      switch phase {
      case .preparing:
        ProgressView("Preparing moderation fixture")
      case .failed(let message):
        ContentUnavailableView("Moderation fixture failed", systemImage: "exclamationmark.triangle",
          description: Text(message))
          .accessibilityIdentifier("moderation.fixture.failure")
      case .ready(let world):
        ready(world)
      }
    }
    .task { await prepare() }
  }

  // MARK: - Scene layout

  @ViewBuilder
  private func ready(_ world: ModerationFixtureWorld) -> some View {
    SceneNavigationHost(appState: world.appState, appStateManager: .shared, context: world.context) {
      content(world)
    }
    .environment(\.fontManager, world.appState.fontManager)
    .modelContainer(world.container)
    .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--moderation-dark") ? .dark : .light)
  }

  @ViewBuilder
  private func content(_ world: ModerationFixtureWorld) -> some View {
    if let feedStateManager = world.feedStateManager {
      FeedCollectionViewWrapper(
        stateManager: feedStateManager,
        navigationPath: $path,
        headerView: AnyView(fixtureBanner(world))
      )
      .overlay(alignment: .topLeading) {
        if ProcessInfo.processInfo.arguments.contains("--moderation-layout-diagnostics"),
          let targetPostID = world.diagnosticPostID {
          ModerationFixtureViewportProbe(targetPostID: targetPostID)
            .frame(width: 8, height: 8)
            .allowsHitTesting(false)
        }
      }
    } else if world.scene.isSettings {
      NavigationStack {
        ModerationSettingsView(initialFocus: world.scene.settingsFocus)
          .navigationDestination(for: SettingsTarget.self) { SettingsDestinationView(target: $0) }
      }
      .environment(\.settingsDraftGuard, draftGuard)
    } else {
      VStack(spacing: 0) {
        fixtureBanner(world)
        ScrollView {
          VStack(spacing: 0) {
            ForEach(world.rows) { row in
              rowView(row, world)
            }
          }
        }
      }
    }
  }

  private func fixtureBanner(_ world: ModerationFixtureWorld) -> some View {
    Text(world.banner)
      .font(.system(size: 11, weight: .medium, design: .monospaced))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .accessibilityIdentifier("moderation.fixture.banner")
  }

  @ViewBuilder
  private func rowView(_ row: ModerationFixtureRow, _ world: ModerationFixtureWorld) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(row.caption)
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.yellow.opacity(0.55))
        .accessibilityIdentifier("moderation.fixture.caption")
      switch row.kind {
      case .feed(let viewModel):
        FeedPostRow(
          viewModel: viewModel, navigationPath: $path, feedTypeIdentifier: "timeline",
          tracksVisibilityForFeedback: false)
      case .threadMain(let post):
        ThreadViewMainPostView(post: post, showLine: false, path: $path, appState: world.appState)
          .padding(.horizontal, ThreadReplyGeometry.rowInset - ThreadReplyGeometry.postAvatarLeadingInset)
          .padding(.top, ThreadReplyGeometry.anchorAvatarTop)
          .padding(.bottom, ThreadReplyGeometry.postAvatarLeadingInset)
      }
    }
  }

  // MARK: - Preparation

  private func prepare() async {
    guard case .preparing = phase else { return }
    do {
      phase = .ready(try await ModerationFixtureWorld.make())
    } catch {
      moderationFixtureLogger.error("fixture failed: \(error.localizedDescription, privacy: .public)")
      phase = .failed(error.localizedDescription)
    }
  }
}

// MARK: - Scenes

private enum ModerationFixtureScene: String {
  case adultOnA = "adult-on-a"
  case adultOnB = "adult-on-b"
  case adultOnC = "adult-on-c"
  case mutedQuote = "muted-quote"
  case adultOffA = "adult-off-a"
  case adultOffB = "adult-off-b"
  case threadAdultOff = "thread-adult-off"
  case settingsAdultOn = "settings-adult-on"
  case settingsAdultOff = "settings-adult-off"
  /// Positive control: an unlabelled image must render, so concealment elsewhere is meaningful.
  case imageControl = "image-loading-control"

  static let argumentPrefix = "--moderation-scene="

  static var requested: ModerationFixtureScene? {
    ProcessInfo.processInfo.arguments
      .first { $0.hasPrefix(argumentPrefix) }
      .flatMap { ModerationFixtureScene(rawValue: String($0.dropFirst(argumentPrefix.count))) }
  }

  var adultContentEnabled: Bool {
    switch self {
    case .adultOnA, .adultOnB, .adultOnC, .mutedQuote, .settingsAdultOn, .imageControl: true
    case .adultOffA, .adultOffB, .threadAdultOff, .settingsAdultOff: false
    }
  }

  var isSettings: Bool { self == .settingsAdultOn || self == .settingsAdultOff }

  /// `--moderation-settings-focus=<control id>` scrolls the production form to a
  /// control the same way a Settings deep link does, so lower sections can be captured.
  var settingsFocus: SettingsControlID? {
    let prefix = "--moderation-settings-focus="
    return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
      .map { SettingsControlID(rawValue: String($0.dropFirst(prefix.count))) }
  }

  /// Stored `contentLabelPref` entries, mixing the legacy keys Catbird writes with
  /// the canonical keys bsky.app writes for the Settings scenes.
  var contentLabelPrefs: [(label: String, visibility: String)] {
    isSettings
      ? [("nsfw", "warn"), ("suggestive", "warn"), ("gore", "hide"), ("graphic-media", "hide"), ("nudity", "ignore")]
      : [("nsfw", "warn")]
  }

  var samples: [ModerationFixtureSample] {
    switch self {
    case .adultOnA, .adultOffA: [.textSexual, .imageGraphic]
    case .adultOnB: [.imagePorn, .textWarn]
    case .adultOnC: [.quotedPorn, .accountPorn]
    case .mutedQuote:
      [.imagePlain, .imagePlainLeadInA, .imagePlainLeadInB, .mutedQuote]
        + (ProcessInfo.processInfo.arguments.contains("--moderation-reveal-room-below")
          ? [.imagePlainTrailA, .imagePlainTrailB] : [])
    case .adultOffB: [.imagePorn, .quotedPorn]
    case .threadAdultOff: [.imagePorn]
    case .settingsAdultOn, .settingsAdultOff: []
    case .imageControl: [.imagePlain]
    }
  }
}

private enum ModerationFixtureSample: Int {
  case textSexual = 1, imageGraphic, imagePorn, textWarn, quotedPorn, accountPorn, imagePlain, mutedQuote
  case imagePlainLeadInA, imagePlainLeadInB
  case imagePlainTrailA, imagePlainTrailB

  var caption: String {
    switch self {
    case .textSexual: "(1) Text-only · label: sexual"
    case .imageGraphic: "(2) Image · label: graphic-media"
    case .imagePorn: "(3) Image · label: porn · nsfw=warn"
    case .textWarn: "(4) Text-only · label: !warn"
    case .quotedPorn: "(5) Text quoting porn-labelled image"
    case .accountPorn: "(6) Text · ACCOUNT labelled porn"
    case .imagePlain: "(7) Image · no labels (loading control)"
    case .mutedQuote: "(8) Muted account quote · long text + labelled image"
    case .imagePlainLeadInA: "(9) Synthetic scroll anchor lead-in A"
    case .imagePlainLeadInB: "(10) Synthetic scroll anchor lead-in B"
    case .imagePlainTrailA: "(11) Synthetic scroll range below quote A"
    case .imagePlainTrailB: "(12) Synthetic scroll range below quote B"
    }
  }
}

// MARK: - World

private struct ModerationFixtureRow: Identifiable {
  enum Kind {
    case feed(FeedPostViewModel)
    case threadMain(AppBskyFeedDefs.PostView)
  }
  let id: Int
  let caption: String
  let kind: Kind
}

@MainActor
private final class ModerationFixtureWorld {
  let scene: ModerationFixtureScene
  let appState: AppState
  let context: SceneNavigationContext
  let container: ModelContainer
  /// PreferencesManager holds its client weakly, so the world keeps it alive.
  let client: ATProtoClient
  let rows: [ModerationFixtureRow]
  let feedStateManager: FeedStateManager?
  let diagnosticPostID: String?

  var banner: String {
    "scene \(scene.rawValue) · adult content \(scene.adultContentEnabled ? "ON" : "OFF") · reduce motion \(appState.appSettings.effectiveReduceMotion ? "ON" : "OFF")"
  }

  private init(scene: ModerationFixtureScene, appState: AppState, context: SceneNavigationContext,
    container: ModelContainer, client: ATProtoClient, rows: [ModerationFixtureRow],
    feedStateManager: FeedStateManager?, diagnosticPostID: String?) {
    self.scene = scene; self.appState = appState; self.context = context
    self.container = container; self.client = client; self.rows = rows
    self.feedStateManager = feedStateManager
    self.diagnosticPostID = diagnosticPostID
  }

  static let viewerDID = "did:plc:moderationfixtureviewer"

  static func make() async throws -> ModerationFixtureWorld {
    guard let scene = ModerationFixtureScene.requested else { throw FixtureError.unknownScene }
    let art = try ModerationFixtureArt.render()
    ModerationFixtureProtocol.configure(
      preferences: ModerationFixtureData.preferencesBody(scene: scene),
      services: ModerationFixtureData.serviceViews())
    guard URLProtocol.registerClass(ModerationFixtureProtocol.self) else { throw FixtureError.transport }
    NetworkService.setNetworkTestProtocolClasses([ModerationFixtureProtocol.self])
    // 127.0.0.1 is the only host Petrel's URL policy accepts without DNS.
    let client = await ATProtoClient(baseURL: URL(string: "https://127.0.0.1")!)

    let container = try ModelContainer(
      for: AppSettingsModel.self, Preferences.self, DraftPost.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    let appSettings = AppSettingsModel(accountDID: viewerDID)
    appSettings.reduceMotion = ProcessInfo.processInfo.arguments.contains("--moderation-reduce-motion")
    container.mainContext.insert(appSettings)
    container.mainContext.insert(Preferences(accountDID: viewerDID))
    try container.mainContext.save()

    let state = AppState(userDID: viewerDID, client: client, regulatoryChecker: NoAgePrompt())
    state.composerDraftManager.configureForTesting(modelContext: container.mainContext)
    state.initializePreferencesManager(with: container.mainContext)
    state.preferencesManager.updateClient(client)
    // The same two calls AppState.initialize makes after sign-in.
    try await state.preferencesManager.fetchPreferences(forceRefresh: true)
    await state.postHidingManager.loadFromPreferences()
    try await state.preferencesManager.syncPreferencesWithAppSettings(state)

    let context = SceneNavigationContext(appState: state, sceneID: UUID())
    var rows: [ModerationFixtureRow] = []
    var feedPosts: [CachedFeedViewPost] = []
    var diagnosticPostID: String?
    for sample in scene.samples {
      let post = try ModerationFixtureData.post(sample, art: art)
      let caption = sample.caption + " · adult \(scene.adultContentEnabled ? "ON" : "OFF")"
      if scene == .threadAdultOff {
        rows.append(ModerationFixtureRow(id: sample.rawValue, caption: caption, kind: .threadMain(post)))
      } else {
        let feedItem = try ModerationFixtureData.decode(
          AppBskyFeedDefs.FeedViewPost.self, ["post": ModerationFixtureData.postJSON(sample, art: art)])
        guard let cached = CachedFeedViewPost(from: feedItem, feedType: "timeline") else {
          throw FixtureError.cachedPost
        }
        feedPosts.append(cached)
        if sample == .mutedQuote { diagnosticPostID = cached.id }
        rows.append(ModerationFixtureRow(
          id: sample.rawValue, caption: caption,
          kind: .feed(FeedPostViewModel(post: cached, appState: state))))
      }
    }
    let feedStateManager: FeedStateManager?
    if scene == .mutedQuote {
      let feedModel = FeedModel(
        feedManager: FeedManager(client: nil, fetchType: .timeline), appState: state)
      feedModel.posts = feedPosts
      let manager = FeedStateManager(appState: state, feedModel: feedModel, feedType: .timeline)
      manager.hasReachedEnd = true
      feedStateManager = manager
    } else {
      feedStateManager = nil
    }
    let world = ModerationFixtureWorld(scene: scene, appState: state, context: context,
      container: container, client: client, rows: rows, feedStateManager: feedStateManager,
      diagnosticPostID: diagnosticPostID)
    world.publishReadyMarker()
    return world
  }

  /// Written once the views have had time to run their own asynchronous policy
  /// resolution, so a capture script can poll for it instead of sleeping blindly.
  private func publishReadyMarker() {
    let scene = scene
    let state = appState
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(4))
      let stored = (try? await state.preferencesManager.getPreferences())?.contentLabelPrefs
        .map { "\($0.label)=\($0.visibility)" } ?? []
      let marker: [String: Any] = [
        "scene": scene.rawValue,
        "appStateAdultContentEnabled": state.isAdultContentEnabled,
        "storedContentLabelPrefs": stored,
        "requests": ModerationFixtureProtocol.ledger(),
      ]
      if let data = try? JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys, .prettyPrinted]) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moderation-fixture-ready.json")
        try? data.write(to: url, options: .atomic)
      }
      print("MODERATION_FIXTURE_READY scene=\(scene.rawValue) adult=\(state.isAdultContentEnabled)")
    }
  }

  private enum FixtureError: LocalizedError {
    case unknownScene, transport, cachedPost
    var errorDescription: String? {
      switch self {
      case .unknownScene: "Pass --moderation-scene=<adult-on-a|adult-on-b|adult-on-c|muted-quote|adult-off-a|adult-off-b|thread-adult-off|settings-adult-on|settings-adult-off|image-loading-control>."
      case .transport: "The fixture URLProtocol could not be registered."
      case .cachedPost: "The synthetic feed item could not be cached."
      }
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

// MARK: - Synthetic data

private enum ModerationFixtureData {
  static let moderationDID = "did:plc:ar7c4by46qjdydhdevvrndac"
  static let customLabelerDID = "did:plc:moderationfixturelabeler"

  struct Author {
    let did: String
    let handle: String
    let name: String
    let avatar: URL
  }

  static func author(_ sample: ModerationFixtureSample, art: ModerationFixtureArt) -> Author {
    switch sample {
    case .textSexual, .imagePorn: art.alice
    case .imageGraphic, .textWarn: art.ben
    case .quotedPorn: art.alice
    case .mutedQuote: art.alice
    case .accountPorn, .imagePlain, .imagePlainLeadInA, .imagePlainLeadInB,
      .imagePlainTrailA, .imagePlainTrailB: art.cara
    }
  }

  static func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
  }

  static func post(_ sample: ModerationFixtureSample, art: ModerationFixtureArt) throws -> AppBskyFeedDefs.PostView {
    try decode(AppBskyFeedDefs.PostView.self, postJSON(sample, art: art))
  }

  private static func iso(minutesAgo: Double) -> String {
    ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutesAgo * 60))
  }

  private static func cid(_ seed: String) -> String {
    CID.fromDAGCBOR(Data(seed.utf8)).string
  }

  static func label(_ value: String, subject: String, cid: String? = nil, source: String = moderationDID) -> [String: Any] {
    var label: [String: Any] = ["ver": 1, "src": source, "uri": subject, "val": value, "cts": iso(minutesAgo: 60)]
    if let cid { label["cid"] = cid }
    return label
  }

  private static func profile(
    _ author: Author,
    labels: [[String: Any]] = [],
    muted: Bool = false
  ) -> [String: Any] {
    var profile: [String: Any] = [
      "did": author.did, "handle": author.handle, "displayName": author.name,
      "avatar": author.avatar.absoluteString, "createdAt": iso(minutesAgo: 90_000),
    ]
    if !labels.isEmpty { profile["labels"] = labels }
    if muted { profile["viewer"] = ["muted": true] }
    return profile
  }

  private static func record(text: String, minutesAgo: Double) -> [String: Any] {
    ["$type": "app.bsky.feed.post", "text": text, "createdAt": iso(minutesAgo: minutesAgo), "langs": ["en"]]
  }

  private static func imagesView(_ url: URL) -> [String: Any] {
    [
      "$type": "app.bsky.embed.images#view",
      "images": [[
        "thumb": url.absoluteString, "fullsize": url.absoluteString,
        "alt": "Synthetic fixture image", "aspectRatio": ["width": 3, "height": 2],
      ]],
    ]
  }

  static func postJSON(_ sample: ModerationFixtureSample, art: ModerationFixtureArt) -> [String: Any] {
    let author = author(sample, art: art)
    let rkey = "fixture\(sample.rawValue)"
    let uri = "at://\(author.did)/app.bsky.feed.post/\(rkey)"
    let postCID = cid("moderation-fixture-post-\(sample.rawValue)")
    func postLabels(_ values: String...) -> [[String: Any]] {
      values.map { label($0, subject: uri, cid: postCID) }
    }
    var text = "Synthetic fixture post."
    var labels: [[String: Any]] = []
    var authorLabels: [[String: Any]] = []
    var embed: [String: Any]?
    switch sample {
    case .textSexual:
      text = "Text-only post labelled sexual."
      labels = postLabels("sexual")
    case .imageGraphic:
      text = "Image post labelled graphic-media."
      labels = postLabels("graphic-media")
      embed = imagesView(art.photoGraphic)
    case .imagePorn:
      text = "Image post labelled porn."
      labels = postLabels("porn")
      embed = imagesView(art.photoPorn)
    case .textWarn:
      text = "Text-only post labelled !warn."
      labels = postLabels("!warn")
    case .quotedPorn:
      text = "Quoting an image post labelled porn."
      embed = quotedEmbed(art: art)
    case .mutedQuote:
      text = "A synthetic outer post quotes an account the viewer muted. This body stays visible while the nested quote can expand."
      embed = mutedQuoteEmbed(art: art)
    case .imagePlain, .imagePlainLeadInA, .imagePlainLeadInB, .imagePlainTrailA, .imagePlainTrailB:
      text = "Unlabelled image post."
      embed = imagesView(art.photoControl)
    case .accountPorn:
      text = "Post by an account labelled porn."
      authorLabels = [label("porn", subject: "at://\(author.did)")]
    }
    var post: [String: Any] = [
      "uri": uri, "cid": postCID, "author": profile(author, labels: authorLabels),
      "record": record(text: text, minutesAgo: 7),
      "replyCount": 2, "repostCount": 1, "likeCount": 5, "quoteCount": 0, "indexedAt": iso(minutesAgo: 7),
    ]
    if !labels.isEmpty { post["labels"] = labels }
    if let embed { post["embed"] = embed }
    return post
  }

  private static func quotedEmbed(art: ModerationFixtureArt) -> [String: Any] {
    let quotedAuthor = art.ben
    let uri = "at://\(quotedAuthor.did)/app.bsky.feed.post/fixturequoted"
    let quotedCID = cid("moderation-fixture-quoted")
    return [
      "$type": "app.bsky.embed.record#view",
      "record": [
        "$type": "app.bsky.embed.record#viewRecord",
        "uri": uri, "cid": quotedCID, "author": profile(quotedAuthor),
        "value": record(text: "Quoted image post labelled porn.", minutesAgo: 30),
        "labels": [label("porn", subject: uri, cid: quotedCID)],
        "embeds": [imagesView(art.photoQuoted)],
        "indexedAt": iso(minutesAgo: 30),
      ] as [String: Any],
    ]
  }

  private static func mutedQuoteEmbed(art: ModerationFixtureArt) -> [String: Any] {
    let quotedAuthor = art.ben
    let uri = "at://\(quotedAuthor.did)/app.bsky.feed.post/fixturemutedquote"
    let quotedCID = cid("moderation-fixture-muted-quote")
    let arguments = ProcessInfo.processInfo.arguments
    let shortText = arguments.contains("--moderation-quote-short-text")
    let unlabelled = arguments.contains("--moderation-quote-without-labels")
    let text = shortText ? "Short synthetic quote." :
      "Synthetic quote text with enough words to wrap across several lines at normal phone width. Showing this post should expand only the quote content while its outer post remains at the same reading position. The fixture contains no real account content."
    return [
      "$type": "app.bsky.embed.record#view",
      "record": [
        "$type": "app.bsky.embed.record#viewRecord",
        "uri": uri, "cid": quotedCID, "author": profile(quotedAuthor, muted: true),
        "value": record(
          text: text,
          minutesAgo: 30),
        "labels": unlabelled ? [] : [
          label("!warn", subject: uri, cid: quotedCID),
          label("porn", subject: uri, cid: quotedCID),
        ],
        "embeds": arguments.contains("--moderation-quote-without-media") ? [] : [imagesView(art.photoQuoted)],
        "indexedAt": iso(minutesAgo: 30),
      ] as [String: Any],
    ]
  }

  // MARK: Served XRPC bodies

  /// Mirrors what a bsky.app + Catbird user has stored. The default moderation
  /// service is implicit; only the custom labeler is listed in `labelersPref`.
  static func preferencesBody(scene: ModerationFixtureScene) -> Data {
    var items: [[String: Any]] = [
      ["$type": "app.bsky.actor.defs#adultContentPref", "enabled": scene.adultContentEnabled],
      [
        "$type": "app.bsky.actor.defs#savedFeedsPrefV2",
        "items": [["id": "fixturefollowing", "type": "timeline", "value": "following", "pinned": true]],
      ],
      ["$type": "app.bsky.actor.defs#labelersPref", "labelers": [["did": customLabelerDID]]],
    ]
    for pref in scene.contentLabelPrefs {
      items.append(["$type": "app.bsky.actor.defs#contentLabelPref", "label": pref.label, "visibility": pref.visibility])
    }
    return (try? JSONSerialization.data(withJSONObject: ["preferences": items])) ?? Data()
  }

  static func serviceViews() -> [String: [String: Any]] {
    func view(_ did: String, handle: String, name: String, values: [String]) -> [String: Any] {
      [
        "$type": "app.bsky.labeler.defs#labelerViewDetailed",
        "uri": "at://\(did)/app.bsky.labeler.service/self", "cid": cid("moderation-fixture-labeler-\(did)"),
        "creator": [
          "did": did, "handle": handle, "displayName": name,
          "description": "Synthetic labeler used by the moderation fixture.",
        ],
        "policies": ["labelValues": values],
        "likeCount": 10, "indexedAt": iso(minutesAgo: 100_000),
      ]
    }
    return [
      moderationDID: view(moderationDID, handle: "moderation.bsky.app", name: "Bluesky Moderation Service",
        values: ["porn", "sexual", "nudity", "graphic-media"]),
      customLabelerDID: view(customLabelerDID, handle: "labeler.fixture.test", name: "Fixture Community Labeler",
        values: ["fixture-spoiler"]),
    ]
  }
}

// MARK: - Transport

/// Serves the two preference reads and refuses everything else. The ledger records
/// each HTTP(S) request the app attempted, with its outcome.
private final class ModerationFixtureProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var preferences = Data()
  nonisolated(unsafe) private static var services: [String: [String: Any]] = [:]
  nonisolated(unsafe) private static var records: [[String: String]] = []

  static func configure(preferences: Data, services: [String: [String: Any]]) {
    lock.withLock {
      self.preferences = preferences; self.services = services; records = []
    }
  }

  static func ledger() -> [[String: String]] { lock.withLock { records } }

  override class func canInit(with request: URLRequest) -> Bool {
    ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let method = (request.httpMethod ?? "GET").uppercased()
    let host = request.url?.host ?? ""
    let path = request.url?.path ?? ""
    let body = host == "127.0.0.1" && method == "GET" ? Self.body(for: path, url: request.url) : nil
    Self.lock.withLock {
      if Self.records.count < 200 {
        Self.records.append(["method": method, "host": host, "path": path, "outcome": body == nil ? "refused" : "served"])
      }
    }
    guard let body, let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}

  private static func body(for path: String, url: URL?) -> Data? {
    switch path {
    case "/xrpc/app.bsky.actor.getPreferences":
      return lock.withLock { preferences }
    case "/xrpc/app.bsky.labeler.getServices":
      let requested = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?
        .filter { $0.name == "dids" }.compactMap(\.value) ?? []
      let views = lock.withLock { requested.compactMap { services[$0] } }
      return try? JSONSerialization.data(withJSONObject: ["views": views])
    default:
      return nil
    }
  }
}

// MARK: - Synthetic images

/// Deterministic, plainly synthetic PNGs rendered once into the temporary directory.
private struct ModerationFixtureArt {
  let alice: ModerationFixtureData.Author
  let ben: ModerationFixtureData.Author
  let cara: ModerationFixtureData.Author
  let photoGraphic: URL
  let photoPorn: URL
  let photoQuoted: URL
  let photoControl: URL

  static func render() throws -> ModerationFixtureArt {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moderation-fixture", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func write(_ image: UIImage, _ name: String) throws -> URL {
      let url = directory.appendingPathComponent(name)
      guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
      try data.write(to: url, options: .atomic)
      return url
    }
    return ModerationFixtureArt(
      alice: .init(did: "did:plc:moderationfixturealice", handle: "alice.fixture.test", name: "Alice Rivera",
        avatar: try write(avatar("A", .systemBlue), "avatar-alice.png")),
      ben: .init(did: "did:plc:moderationfixtureben", handle: "ben.fixture.test", name: "Ben Okafor",
        avatar: try write(avatar("B", .systemGreen), "avatar-ben.png")),
      cara: .init(did: "did:plc:moderationfixturecara", handle: "cara.fixture.test", name: "Cara Lindqvist",
        avatar: try write(avatar("C", .systemOrange), "avatar-cara.png")),
      photoGraphic: try write(photo("label: graphic-media", .systemRed, .systemPurple), "photo-graphic-media.png"),
      photoPorn: try write(photo("label: porn", .systemPink, .systemIndigo), "photo-porn.png"),
      photoQuoted: try write(photo("quoted · label: porn", .systemTeal, .systemBlue), "photo-quoted-porn.png"),
      photoControl: try write(photo("no label", .systemYellow, .systemGreen), "photo-control.png"))
  }

  private static func render(size: CGSize, _ draw: (CGContext) -> Void) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { draw($0.cgContext) }
  }

  private static func text(_ string: String, size: CGFloat, in rect: CGRect) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (string as NSString).draw(in: rect, withAttributes: [
      .font: UIFont.systemFont(ofSize: size, weight: UIFont.Weight.heavy), .foregroundColor: UIColor.white,
      .paragraphStyle: paragraph,
    ])
  }

  private static func avatar(_ initial: String, _ color: UIColor) -> UIImage {
    render(size: CGSize(width: 192, height: 192)) { context in
      color.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 192, height: 192))
      text(initial, size: 110, in: CGRect(x: 0, y: 28, width: 192, height: 140))
    }
  }

  private static func photo(_ caption: String, _ start: UIColor, _ end: UIColor) -> UIImage {
    let size = CGSize(width: 1200, height: 800)
    return render(size: size) { context in
      let colors = [start.cgColor, end.cgColor] as CFArray
      if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
      }
      UIColor.white.withAlphaComponent(0.18).setFill()
      context.fillEllipse(in: CGRect(x: 760, y: 90, width: 520, height: 520))
      context.fillEllipse(in: CGRect(x: -140, y: 430, width: 460, height: 460))
      text("SYNTHETIC IMAGE", size: 96, in: CGRect(x: 0, y: 270, width: size.width, height: 130))
      text(caption, size: 64, in: CGRect(x: 0, y: 410, width: size.width, height: 90))
    }
  }
}
#endif
