import Foundation
import OSLog
import Petrel
import PetrelCatbird

// MARK: - Domain Value Types

public enum OnboardingMacroCategory: String, CaseIterable, Identifiable, Sendable {
  case all
  case softwareAITech = "software_ai_tech"
  case scienceNature = "science_nature"
  case newsCivicsHistory = "news_civics_history"
  case artsIllustration = "arts_illustration"
  case gamesInteractive = "games_interactive"
  case musicAudio = "music_audio"
  case filmTVAnime = "film_tv_anime"
  case booksWritingComics = "books_writing_comics"
  case queerFandomHangout = "queer_fandom_hangout"
  case sportsMotorsport = "sports_motorsport"
  case citiesCraftFood = "cities_craft_food"
  case worldLanguages = "world_languages"

  public var id: String { rawValue }

  public var queryValue: String? {
    self == .all ? nil : rawValue
  }

  public var title: String {
    switch self {
    case .all: "All Scenes"
    case .softwareAITech: "Tech & Code"
    case .scienceNature: "Science & Nature"
    case .newsCivicsHistory: "News & History"
    case .artsIllustration: "Art & Photo"
    case .gamesInteractive: "Games & Play"
    case .musicAudio: "Music & Sound"
    case .filmTVAnime: "Film, TV & Anime"
    case .booksWritingComics: "Books & Comics"
    case .queerFandomHangout: "Fandom & Hangout"
    case .sportsMotorsport: "Sports"
    case .citiesCraftFood: "Cities, Craft & Food"
    case .worldLanguages: "Global Scenes"
    }
  }

  public var symbolName: String {
    switch self {
    case .all: "sparkles"
    case .softwareAITech: "chevron.left.forwardslash.chevron.right"
    case .scienceNature: "atom"
    case .newsCivicsHistory: "newspaper.fill"
    case .artsIllustration: "paintbrush.pointed.fill"
    case .gamesInteractive: "gamecontroller.fill"
    case .musicAudio: "music.quarternote.3"
    case .filmTVAnime: "film.stack.fill"
    case .booksWritingComics: "book.pages.fill"
    case .queerFandomHangout: "sparkles.tv.fill"
    case .sportsMotorsport: "figure.run"
    case .citiesCraftFood: "building.2.crop.circle.fill"
    case .worldLanguages: "globe.americas.fill"
    }
  }
}

public enum CommunityRole: String, CaseIterable, Identifiable, Hashable, Sendable {
  case anchorCreator = "anchor_creator"
  case visualMaker = "visual_maker"
  case conversationalist = "conversationalist"
  case sceneCurator = "scene_curator"
  case projectOrStudio = "project_or_studio"

  public var id: String { rawValue }

  public init(rawRole: String?) {
    switch rawRole?.lowercased() {
    case "anchor_creator", "anchor":
      self = .anchorCreator
    case "visual_maker", "maker":
      self = .visualMaker
    case "conversationalist":
      self = .conversationalist
    case "scene_curator", "curator", "curator_scout":
      self = .sceneCurator
    case "project_or_studio", "wildcard", "bridge":
      self = .projectOrStudio
    default:
      self = .anchorCreator
    }
  }

  public var displayTitle: String {
    switch self {
    case .anchorCreator: "Community Anchors"
    case .visualMaker: "Original Makers"
    case .conversationalist: "Warm Conversationalists"
    case .sceneCurator: "High-Signal Curators"
    case .projectOrStudio: "Projects & Studios"
    }
  }

  public var badgeTitle: String {
    switch self {
    case .anchorCreator: "Anchor"
    case .visualMaker: "Maker"
    case .conversationalist: "Conversational"
    case .sceneCurator: "Curator"
    case .projectOrStudio: "Project / Studio"
    }
  }

  public var subtitle: String {
    switch self {
    case .anchorCreator: "Trusted pillars widely followed across the community"
    case .visualMaker: "Original craft, demos, photography, art, and dispatches"
    case .conversationalist: "Friendly voices who spark real threads and replies"
    case .sceneCurator: "Finds great work across the network (ideal in Originals Only)"
    case .projectOrStudio: "Official tools, collectives, journals, and indie studios"
    }
  }

  public var symbolName: String {
    switch self {
    case .anchorCreator: "shield.checkered"
    case .visualMaker: "hammer.fill"
    case .conversationalist: "bubble.left.and.bubble.right.fill"
    case .sceneCurator: "safari.fill"
    case .projectOrStudio: "building.columns.fill"
    }
  }
}

public struct HydratedSamplePost: Identifiable, Hashable, Sendable {
  public let id: String
  public let uri: String
  public let authorDID: String
  public let authorHandle: String
  public let authorDisplayName: String
  public let authorAvatarURL: URL?
  public let text: String
  public let createdAt: Date?
  public let likeCount: Int
  public let repostCount: Int
  public let replyCount: Int
  public let imageThumbURLs: [URL]
  public let communityId: Int?
  public let communityTitle: String?
  public let authorRole: CommunityRole?

  public init(
    uri: String,
    authorDID: String,
    authorHandle: String,
    authorDisplayName: String,
    authorAvatarURL: URL? = nil,
    text: String,
    createdAt: Date? = nil,
    likeCount: Int = 0,
    repostCount: Int = 0,
    replyCount: Int = 0,
    imageThumbURLs: [URL] = [],
    communityId: Int? = nil,
    communityTitle: String? = nil,
    authorRole: CommunityRole? = nil
  ) {
    self.id = uri
    self.uri = uri
    self.authorDID = authorDID
    self.authorHandle = authorHandle
    self.authorDisplayName = authorDisplayName
    self.authorAvatarURL = authorAvatarURL
    self.text = text
    self.createdAt = createdAt
    self.likeCount = likeCount
    self.repostCount = repostCount
    self.replyCount = replyCount
    self.imageThumbURLs = imageThumbURLs
    self.communityId = communityId
    self.communityTitle = communityTitle
    self.authorRole = authorRole
  }

  public func withAttribution(
    communityId: Int?,
    communityTitle: String?,
    authorRole: CommunityRole?
  ) -> HydratedSamplePost {
    HydratedSamplePost(
      uri: uri,
      authorDID: authorDID,
      authorHandle: authorHandle,
      authorDisplayName: authorDisplayName,
      authorAvatarURL: authorAvatarURL,
      text: text,
      createdAt: createdAt,
      likeCount: likeCount,
      repostCount: repostCount,
      replyCount: replyCount,
      imageThumbURLs: imageThumbURLs,
      communityId: communityId ?? self.communityId,
      communityTitle: communityTitle ?? self.communityTitle,
      authorRole: authorRole ?? self.authorRole
    )
  }
}

public struct HydratedRecommendedProfile: Identifiable, Hashable, Sendable {
  public let id: String
  public let did: String
  public let handle: String
  public let displayName: String
  public let bio: String
  public let avatarURL: URL?
  public let followersCount: Int?
  public let alreadyFollowing: Bool
  public let isBlockedOrMuted: Bool

  public init(
    did: String,
    handle: String,
    displayName: String,
    bio: String,
    avatarURL: URL? = nil,
    followersCount: Int? = nil,
    alreadyFollowing: Bool = false,
    isBlockedOrMuted: Bool = false
  ) {
    self.id = did
    self.did = did
    self.handle = handle
    self.displayName = displayName
    self.bio = bio
    self.avatarURL = avatarURL
    self.followersCount = followersCount
    self.alreadyFollowing = alreadyFollowing
    self.isBlockedOrMuted = isBlockedOrMuted
  }
}

public struct HydratedFeedOption: Identifiable, Hashable, Sendable {
  public let id: String
  public let uri: String
  public let displayName: String
  public let creatorHandle: String
  public let description: String
  public let avatarURL: URL?
  public let likeCount: Int
  public let communityTitle: String

  public init(
    uri: String,
    displayName: String,
    creatorHandle: String,
    description: String,
    avatarURL: URL? = nil,
    likeCount: Int = 0,
    communityTitle: String
  ) {
    self.id = uri
    self.uri = uri
    self.displayName = displayName
    self.creatorHandle = creatorHandle
    self.description = description
    self.avatarURL = avatarURL
    self.likeCount = likeCount
    self.communityTitle = communityTitle
  }
}

public struct HydratedStarterPackOption: Identifiable, Hashable, Sendable {
  public let id: String
  public let uri: String
  public let name: String
  public let creatorHandle: String
  public let joinedAllTimeCount: Int
  public let communityTitle: String

  public init(
    uri: String,
    name: String,
    creatorHandle: String,
    joinedAllTimeCount: Int = 0,
    communityTitle: String
  ) {
    self.id = uri
    self.uri = uri
    self.name = name
    self.creatorHandle = creatorHandle
    self.joinedAllTimeCount = joinedAllTimeCount
    self.communityTitle = communityTitle
  }
}

public struct OnboardingCommitReceipt: Equatable, Sendable {
  public let followedCount: Int
  public let batchCount: Int
  public let originalsOnlyCount: Int
  public let pinnedFeedsCount: Int

  public init(
    followedCount: Int,
    batchCount: Int,
    originalsOnlyCount: Int,
    pinnedFeedsCount: Int
  ) {
    self.followedCount = followedCount
    self.batchCount = batchCount
    self.originalsOnlyCount = originalsOnlyCount
    self.pinnedFeedsCount = pinnedFeedsCount
  }
}

public enum CatbirdIntelligenceError: LocalizedError, Equatable, Sendable {
  case clientUnavailable
  case serviceUnavailable
  case invalidResponse(Int)
  case commitFailed(String)

  public var errorDescription: String? {
    switch self {
    case .clientUnavailable:
      "Sign in to load community recommendations."
    case .serviceUnavailable:
      "Scene recommendations are temporarily unavailable."
    case .invalidResponse(let code):
      "Couldn’t load community intelligence (HTTP \(code))."
    case .commitFailed(let reason):
      reason
    }
  }
}

public struct PostAttributionMetadata: Sendable {
  public let communityId: Int?
  public let communityTitle: String?
  public let authorRole: CommunityRole?

  public init(communityId: Int? = nil, communityTitle: String? = nil, authorRole: CommunityRole? = nil) {
    self.communityId = communityId
    self.communityTitle = communityTitle
    self.authorRole = authorRole
  }
}

// MARK: - Service Protocol

public protocol CatbirdIntelligenceServicing: Sendable {
  func fetchSeedFollowDIDs(limit: Int) async -> [String]
  func getCatalog(
    seedFollowDIDs: [String],
    query: String?,
    macroCategory: String?,
    limit: Int
  ) async throws -> BlueCatbirdOnboardingGetCatalog.Output
  func listCommunities(
    query: String?,
    macroCategory: String?,
    sceneSlug: String?,
    limit: Int,
    cursor: String?
  ) async throws -> BlueCatbirdIntelListCommunities.Output
  func getCommunity(communityId: Int) async throws -> BlueCatbirdIntelGetCommunity.Output
  func getCalibrationSwipes(
    selections: [BlueCatbirdOnboardingDefs.CommunitySelection],
    seedFollowDIDs: [String],
    maxSwipes: Int
  ) async throws -> BlueCatbirdOnboardingGetCalibrationSwipes.Output
  func previewTimeline(
    selections: [BlueCatbirdOnboardingDefs.CommunitySelection],
    swipes: [BlueCatbirdOnboardingDefs.CalibrationSwipeAnswer],
    controls: BlueCatbirdOnboardingDefs.BundleControls,
    limit: Int
  ) async throws -> BlueCatbirdOnboardingPreviewTimeline.Output
  func solveBundle(
    input: BlueCatbirdOnboardingSolveBundle.Input
  ) async throws -> BlueCatbirdOnboardingSolveBundle.Output
  func hydratePosts(
    uris: [ATProtocolURI],
    attributionByURI: [String: PostAttributionMetadata]
  ) async -> [HydratedSamplePost]
  func hydrateProfiles(dids: [DID]) async -> [String: HydratedRecommendedProfile]
  func hydrateFeeds(recommended: [BlueCatbirdOnboardingDefs.RecommendedFeed]) async -> [HydratedFeedOption]
  func hydrateStarterPacks(recommended: [BlueCatbirdOnboardingDefs.RecommendedStarterPack]) async -> [HydratedStarterPackOption]
  @MainActor
  func commitLineup(
    followDIDs: [String],
    originalsOnlyDIDs: Set<String>,
    pinnedFeedURIs: [String]
  ) async throws -> OnboardingCommitReceipt
}

// MARK: - Shared Hydration Cache & Moderation Safety Helpers

actor OnboardingHydrationCache {
  private var posts: [String: HydratedSamplePost] = [:]
  private var profiles: [String: HydratedRecommendedProfile] = [:]
  private var feeds: [String: HydratedFeedOption] = [:]
  private var starterPacks: [String: HydratedStarterPackOption] = [:]
  private var hasRegisteredServiceDIDs = false

  func markServiceDIDsRegistered() -> Bool {
    let wasRegistered = hasRegisteredServiceDIDs
    hasRegisteredServiceDIDs = true
    return wasRegistered
  }

  func cachedPost(for uri: String) -> HydratedSamplePost? { posts[uri] }
  func storePosts(_ items: [HydratedSamplePost]) {
    for item in items { posts[item.uri] = item }
  }

  func cachedProfile(for did: String) -> HydratedRecommendedProfile? { profiles[did] }
  func storeProfiles(_ items: [HydratedRecommendedProfile]) {
    for item in items { profiles[item.did] = item }
  }

  func cachedFeed(for uri: String) -> HydratedFeedOption? { feeds[uri] }
  func storeFeeds(_ items: [HydratedFeedOption]) {
    for item in items { feeds[item.uri] = item }
  }

  func cachedStarterPack(for uri: String) -> HydratedStarterPackOption? { starterPacks[uri] }
  func storeStarterPacks(_ items: [HydratedStarterPackOption]) {
    for item in items { starterPacks[item.uri] = item }
  }
}

enum OnboardingHydrationMapper {
  private static let adultLabels: Set<String> = [
    "porn", "sexual", "nudity", "graphic-media", "nsfw", "!hide", "!warn"
  ]

  static func hasBlockedLabels(_ labels: [ComAtprotoLabelDefs.Label]?) -> Bool {
    guard let labels else { return false }
    for label in labels {
      if label.neg == true { continue }
      if adultLabels.contains(label.val.lowercased()) {
        return true
      }
    }
    return false
  }

  static func isViewerBlockedOrMuted(_ viewer: AppBskyActorDefs.ViewerState?) -> Bool {
    guard let viewer else { return false }
    return viewer.muted == true
      || viewer.mutedByList != nil
      || viewer.blocking != nil
      || viewer.blockingByList != nil
      || viewer.blockedBy == true
  }

  static func mapPostView(
    _ postView: AppBskyFeedDefs.PostView,
    currentUserDID: String
  ) -> HydratedSamplePost? {
    let authorDID = postView.author.did.didString()
    if authorDID == currentUserDID { return nil }
    if isViewerBlockedOrMuted(postView.author.viewer) { return nil }
    if hasBlockedLabels(postView.labels) || hasBlockedLabels(postView.author.labels) { return nil }

    guard case .knownType(let rawRecord) = postView.record,
          let feedPost = rawRecord as? AppBskyFeedPost else {
      return nil
    }
    let trimmed = feedPost.text.trimmingCharacters(in: .whitespacesAndNewlines)
    var thumbs: [URL] = []
    if let embed = postView.embed {
      switch embed {
      case .appBskyEmbedImagesView(let imagesView):
        thumbs = imagesView.images.compactMap { URL(string: $0.thumb.uriString()) }
      case .appBskyEmbedRecordWithMediaView(let rwm):
        if case .appBskyEmbedImagesView(let imagesView) = rwm.media {
          thumbs = imagesView.images.compactMap { URL(string: $0.thumb.uriString()) }
        }
      default:
        break
      }
    }
    guard !trimmed.isEmpty || !thumbs.isEmpty else { return nil }

    let display = (postView.author.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let avatarURL = postView.author.avatar.flatMap { URL(string: $0.uriString()) }
    return HydratedSamplePost(
      uri: postView.uri.uriString(),
      authorDID: authorDID,
      authorHandle: postView.author.handle.value,
      authorDisplayName: display.isEmpty ? postView.author.handle.value : display,
      authorAvatarURL: avatarURL,
      text: trimmed,
      createdAt: feedPost.createdAt.date,
      likeCount: postView.likeCount ?? 0,
      repostCount: postView.repostCount ?? 0,
      replyCount: postView.replyCount ?? 0,
      imageThumbURLs: Array(thumbs.prefix(2))
    )
  }

  static func mapProfileDetailed(
    _ profile: AppBskyActorDefs.ProfileViewDetailed,
    currentUserDID: String
  ) -> HydratedRecommendedProfile? {
    let did = profile.did.didString()
    if did == currentUserDID { return nil }
    if hasBlockedLabels(profile.labels) { return nil }
    let blockedOrMuted = isViewerBlockedOrMuted(profile.viewer)
    let display = (profile.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let bio = (profile.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return HydratedRecommendedProfile(
      did: did,
      handle: profile.handle.value,
      displayName: display.isEmpty ? profile.handle.value : display,
      bio: bio,
      avatarURL: profile.avatar.flatMap { URL(string: $0.uriString()) },
      followersCount: profile.followersCount,
      alreadyFollowing: profile.viewer?.following != nil,
      isBlockedOrMuted: blockedOrMuted
    )
  }
}

// MARK: - Live Authenticated CatbirdIntelligenceService

public final class LiveCatbirdIntelligenceService: CatbirdIntelligenceServicing {
  public static let maxBatchSize = 25

  private let client: ATProtoClient
  private let currentUserDID: String
  @MainActor private weak var appState: AppState?
  private let cache = OnboardingHydrationCache()
  private let logger = Logger(subsystem: "blue.catbird", category: "CatbirdIntelligence")

  @MainActor
  init(appState: AppState, client: ATProtoClient) {
    self.appState = appState
    self.client = client
    self.currentUserDID = appState.userDID
  }

  private func ensureGatewayServiceDIDs() async {
    let alreadyRegistered = await cache.markServiceDIDsRegistered()
    guard !alreadyRegistered else { return }
    let nestDID = CatbirdGatewayConfiguration.current.serviceDID
    await client.setServiceDID(nestDID, for: "blue.catbird.intel")
    await client.setServiceDID(nestDID, for: "blue.catbird.onboarding")
  }

  private func unwrap<T>(code: Int, data: T?) throws -> T {
    if code == 503 || code == 502 || code == 404 {
      throw CatbirdIntelligenceError.serviceUnavailable
    }
    guard (200..<300).contains(code), let data else {
      throw CatbirdIntelligenceError.invalidResponse(code)
    }
    return data
  }

  private func mapError(_ error: Error) -> Error {
    if let intelError = error as? CatbirdIntelligenceError {
      return intelError
    }
    let desc = String(describing: error)
    if desc.contains("503") || desc.contains("UpstreamUnavailable") || desc.contains("502") {
      return CatbirdIntelligenceError.serviceUnavailable
    }
    return error
  }

  public func fetchSeedFollowDIDs(limit: Int = 50) async -> [String] {
    guard !currentUserDID.isEmpty else { return [] }
    do {
      let actor = try ATIdentifier(string: currentUserDID)
      let (code, response) = try await client.app.bsky.graph.getFollows(
        input: .init(actor: actor, limit: min(max(1, limit), 100))
      )
      guard (200..<300).contains(code), let response else { return [] }
      return response.follows.map { $0.did.didString() }
    } catch {
      logger.debug("Seed follow lookup skipped: \(error.localizedDescription)")
      return []
    }
  }

  public func getCatalog(
    seedFollowDIDs: [String],
    query: String?,
    macroCategory: String?,
    limit: Int = 48
  ) async throws -> BlueCatbirdOnboardingGetCatalog.Output {
    await ensureGatewayServiceDIDs()
    let dids = seedFollowDIDs.compactMap { try? DID(didString: $0) }
    do {
      let (code, data) = try await client.blue.catbird.onboarding.getCatalog(
        input: .init(
          seedFollowDids: dids.isEmpty ? nil : dids,
          q: query,
          macroCategory: macroCategory,
          limit: limit
        )
      )
      return try unwrap(code: code, data: data)
    } catch {
      throw mapError(error)
    }
  }

  public func listCommunities(
    query: String?,
    macroCategory: String?,
    sceneSlug: String?,
    limit: Int = 40,
    cursor: String? = nil
  ) async throws -> BlueCatbirdIntelListCommunities.Output {
    await ensureGatewayServiceDIDs()
    do {
      let (code, data) = try await client.blue.catbird.intel.listCommunities(
        input: .init(
          q: query,
          macroCategory: macroCategory,
          sceneSlug: sceneSlug,
          limit: limit,
          cursor: cursor
        )
      )
      return try unwrap(code: code, data: data)
    } catch {
      throw mapError(error)
    }
  }

  public func getCommunity(communityId: Int) async throws -> BlueCatbirdIntelGetCommunity.Output {
    await ensureGatewayServiceDIDs()
    do {
      let (code, data) = try await client.blue.catbird.intel.getCommunity(
        input: .init(communityId: communityId)
      )
      return try unwrap(code: code, data: data)
    } catch {
      throw mapError(error)
    }
  }

  public func getCalibrationSwipes(
    selections: [BlueCatbirdOnboardingDefs.CommunitySelection],
    seedFollowDIDs: [String],
    maxSwipes: Int = 4
  ) async throws -> BlueCatbirdOnboardingGetCalibrationSwipes.Output {
    await ensureGatewayServiceDIDs()
    let dids = seedFollowDIDs.compactMap { try? DID(didString: $0) }
    do {
      let (code, data) = try await client.blue.catbird.onboarding.getCalibrationSwipes(
        input: .init(
          selections: selections,
          seedFollowDids: dids.isEmpty ? nil : dids,
          maxSwipes: maxSwipes
        )
      )
      return try unwrap(code: code, data: data)
    } catch {
      throw mapError(error)
    }
  }

  public func previewTimeline(
    selections: [BlueCatbirdOnboardingDefs.CommunitySelection],
    swipes: [BlueCatbirdOnboardingDefs.CalibrationSwipeAnswer],
    controls: BlueCatbirdOnboardingDefs.BundleControls,
    limit: Int = 16
  ) async throws -> BlueCatbirdOnboardingPreviewTimeline.Output {
    await ensureGatewayServiceDIDs()
    do {
      let (code, data) = try await client.blue.catbird.onboarding.previewTimeline(
        input: .init(
          selections: selections,
          swipes: swipes.isEmpty ? nil : swipes,
          controls: controls,
          limit: limit
        )
      )
      return try unwrap(code: code, data: data)
    } catch {
      throw mapError(error)
    }
  }

  public func solveBundle(
    input: BlueCatbirdOnboardingSolveBundle.Input
  ) async throws -> BlueCatbirdOnboardingSolveBundle.Output {
    await ensureGatewayServiceDIDs()
    do {
      let (code, data) = try await client.blue.catbird.onboarding.solveBundle(input: input)
      return try unwrap(code: code, data: data)
    } catch {
      throw mapError(error)
    }
  }

  public func hydratePosts(
    uris: [ATProtocolURI],
    attributionByURI: [String: PostAttributionMetadata] = [:]
  ) async -> [HydratedSamplePost] {
    await Self.hydratePostsWithClient(
      client: client,
      cache: cache,
      currentUserDID: currentUserDID,
      uris: uris,
      attributionByURI: attributionByURI,
      interBatchDelayMs: 0
    )
  }

  public func hydrateProfiles(dids: [DID]) async -> [String: HydratedRecommendedProfile] {
    await Self.hydrateProfilesWithClient(
      client: client,
      cache: cache,
      currentUserDID: currentUserDID,
      dids: dids,
      interBatchDelayMs: 0
    )
  }

  public func hydrateFeeds(
    recommended: [BlueCatbirdOnboardingDefs.RecommendedFeed]
  ) async -> [HydratedFeedOption] {
    await Self.hydrateFeedsWithClient(
      client: client,
      cache: cache,
      recommended: recommended,
      interBatchDelayMs: 0
    )
  }

  public func hydrateStarterPacks(
    recommended: [BlueCatbirdOnboardingDefs.RecommendedStarterPack]
  ) async -> [HydratedStarterPackOption] {
    await Self.hydrateStarterPacksWithClient(
      client: client,
      cache: cache,
      recommended: recommended,
      interBatchDelayMs: 0
    )
  }

  @MainActor
  public func commitLineup(
    followDIDs: [String],
    originalsOnlyDIDs: Set<String>,
    pinnedFeedURIs: [String]
  ) async throws -> OnboardingCommitReceipt {
    guard let appState else {
      throw CatbirdIntelligenceError.clientUnavailable
    }
    let parsedDIDs = followDIDs.compactMap { try? DID(didString: $0) }
    var followedCount = 0
    let batchCount = parsedDIDs.isEmpty
      ? 0
      : (parsedDIDs.count + Self.maxBatchSize - 1) / Self.maxBatchSize

    if !parsedDIDs.isEmpty {
      do {
        followedCount = try await StarterPackService.shared.bulkFollow(
          client: client,
          dids: parsedDIDs,
          via: nil,
          accountDID: appState.userDID,
          batchSize: Self.maxBatchSize
        )
      } catch {
        throw CatbirdIntelligenceError.commitFailed(error.localizedDescription)
      }
    }

    let activeOriginalsOnly = originalsOnlyDIDs.intersection(Set(followDIDs))
    if !activeOriginalsOnly.isEmpty {
      appState.feedFilterSettings.mergeMutedRepostAuthors(activeOriginalsOnly)
    }

    var pinnedCount = 0
    for uriString in pinnedFeedURIs {
      guard let uri = try? ATProtocolURI(uriString: uriString) else { continue }
      if (try? await appState.feedLibraryActions.add(uri, to: .pinned)) != nil {
        pinnedCount += 1
      }
    }

    return OnboardingCommitReceipt(
      followedCount: followedCount,
      batchCount: batchCount,
      originalsOnlyCount: activeOriginalsOnly.count,
      pinnedFeedsCount: pinnedCount
    )
  }

  // MARK: - Shared Chunked Hydration Helpers (<= 25 per batch)

  static func hydratePostsWithClient(
    client: ATProtoClient,
    cache: OnboardingHydrationCache,
    currentUserDID: String,
    uris: [ATProtocolURI],
    attributionByURI: [String: PostAttributionMetadata],
    interBatchDelayMs: UInt64
  ) async -> [HydratedSamplePost] {
    var orderedUnique: [ATProtocolURI] = []
    var seen = Set<String>()
    for uri in uris {
      let key = uri.uriString()
      if seen.insert(key).inserted {
        orderedUnique.append(uri)
      }
    }

    var missing: [ATProtocolURI] = []
    for uri in orderedUnique {
      if await cache.cachedPost(for: uri.uriString()) == nil {
        missing.append(uri)
      }
    }

    for start in stride(from: 0, to: missing.count, by: maxBatchSize) {
      if start > 0 && interBatchDelayMs > 0 {
        try? await Task.sleep(for: .milliseconds(interBatchDelayMs))
      }
      let batch = Array(missing[start..<min(start + maxBatchSize, missing.count)])
      guard let (code, output) = try? await client.app.bsky.feed.getPosts(input: .init(uris: batch)),
            (200..<300).contains(code),
            let posts = output?.posts else {
        continue
      }
      let mapped = posts.compactMap { OnboardingHydrationMapper.mapPostView($0, currentUserDID: currentUserDID) }
      await cache.storePosts(mapped)
    }

    var result: [HydratedSamplePost] = []
    for uri in orderedUnique {
      let key = uri.uriString()
      if let post = await cache.cachedPost(for: key) {
        if let attr = attributionByURI[key] {
          result.append(post.withAttribution(
            communityId: attr.communityId,
            communityTitle: attr.communityTitle,
            authorRole: attr.authorRole
          ))
        } else {
          result.append(post)
        }
      }
    }
    return result
  }

  static func hydrateProfilesWithClient(
    client: ATProtoClient,
    cache: OnboardingHydrationCache,
    currentUserDID: String,
    dids: [DID],
    interBatchDelayMs: UInt64
  ) async -> [String: HydratedRecommendedProfile] {
    var uniqueDIDs: [DID] = []
    var seen = Set<String>()
    for did in dids {
      let key = did.didString()
      if seen.insert(key).inserted {
        uniqueDIDs.append(did)
      }
    }

    var missing: [DID] = []
    for did in uniqueDIDs {
      if await cache.cachedProfile(for: did.didString()) == nil {
        missing.append(did)
      }
    }

    for start in stride(from: 0, to: missing.count, by: maxBatchSize) {
      if start > 0 && interBatchDelayMs > 0 {
        try? await Task.sleep(for: .milliseconds(interBatchDelayMs))
      }
      let batch = Array(missing[start..<min(start + maxBatchSize, missing.count)])
      let actors = batch.compactMap { try? ATIdentifier(string: $0.didString()) }
      guard !actors.isEmpty,
            let (code, output) = try? await client.app.bsky.actor.getProfiles(input: .init(actors: actors)),
            (200..<300).contains(code),
            let profiles = output?.profiles else {
        continue
      }
      let mapped = profiles.compactMap { OnboardingHydrationMapper.mapProfileDetailed($0, currentUserDID: currentUserDID) }
      await cache.storeProfiles(mapped)
    }

    var map: [String: HydratedRecommendedProfile] = [:]
    for did in uniqueDIDs {
      let key = did.didString()
      if let prof = await cache.cachedProfile(for: key), !prof.isBlockedOrMuted {
        map[key] = prof
      }
    }
    return map
  }

  static func hydrateFeedsWithClient(
    client: ATProtoClient,
    cache: OnboardingHydrationCache,
    recommended: [BlueCatbirdOnboardingDefs.RecommendedFeed],
    interBatchDelayMs: UInt64
  ) async -> [HydratedFeedOption] {
    var titleByURI: [String: String] = [:]
    var uniqueURIs: [ATProtocolURI] = []
    for item in recommended {
      let key = item.uri.uriString()
      if titleByURI[key] == nil {
        titleByURI[key] = item.communityTitle
        uniqueURIs.append(item.uri)
      }
    }

    var missing: [ATProtocolURI] = []
    for uri in uniqueURIs {
      if await cache.cachedFeed(for: uri.uriString()) == nil {
        missing.append(uri)
      }
    }

    for start in stride(from: 0, to: missing.count, by: maxBatchSize) {
      if start > 0 && interBatchDelayMs > 0 {
        try? await Task.sleep(for: .milliseconds(interBatchDelayMs))
      }
      let batch = Array(missing[start..<min(start + maxBatchSize, missing.count)])
      guard let (code, output) = try? await client.app.bsky.feed.getFeedGenerators(input: .init(feeds: batch)),
            (200..<300).contains(code),
            let feeds = output?.feeds else {
        continue
      }
      let mapped: [HydratedFeedOption] = feeds.compactMap { gen in
        if OnboardingHydrationMapper.hasBlockedLabels(gen.labels) { return nil }
        let key = gen.uri.uriString()
        return HydratedFeedOption(
          uri: key,
          displayName: gen.displayName,
          creatorHandle: gen.creator.handle.value,
          description: (gen.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
          avatarURL: gen.avatar.flatMap { URL(string: $0.uriString()) },
          likeCount: gen.likeCount ?? 0,
          communityTitle: titleByURI[key] ?? "Scene Feed"
        )
      }
      await cache.storeFeeds(mapped)
    }

    var out: [HydratedFeedOption] = []
    for uri in uniqueURIs {
      if let item = await cache.cachedFeed(for: uri.uriString()) {
        out.append(item)
      }
    }
    return out
  }

  static func hydrateStarterPacksWithClient(
    client: ATProtoClient,
    cache: OnboardingHydrationCache,
    recommended: [BlueCatbirdOnboardingDefs.RecommendedStarterPack],
    interBatchDelayMs: UInt64
  ) async -> [HydratedStarterPackOption] {
    var titleByURI: [String: String] = [:]
    var uniqueURIs: [ATProtocolURI] = []
    for item in recommended {
      let key = item.uri.uriString()
      if titleByURI[key] == nil {
        titleByURI[key] = item.communityTitle
        uniqueURIs.append(item.uri)
      }
    }

    var missing: [ATProtocolURI] = []
    for uri in uniqueURIs {
      if await cache.cachedStarterPack(for: uri.uriString()) == nil {
        missing.append(uri)
      }
    }

    for start in stride(from: 0, to: missing.count, by: maxBatchSize) {
      if start > 0 && interBatchDelayMs > 0 {
        try? await Task.sleep(for: .milliseconds(interBatchDelayMs))
      }
      let batch = Array(missing[start..<min(start + maxBatchSize, missing.count)])
      guard let (code, output) = try? await client.app.bsky.graph.getStarterPacks(input: .init(uris: batch)),
            (200..<300).contains(code),
            let packs = output?.starterPacks else {
        continue
      }
      let mapped: [HydratedStarterPackOption] = packs.compactMap { (pack) -> HydratedStarterPackOption? in
        if OnboardingHydrationMapper.hasBlockedLabels(pack.labels) { return nil }
        let key = pack.uri.uriString()
        var packName = "Starter Pack"
        if case .knownType(let rawRec) = pack.record, let spRec = rawRec as? AppBskyGraphStarterpack {
          let trimmed = spRec.name.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty { packName = trimmed }
        }
        return HydratedStarterPackOption(
          uri: key,
          name: packName,
          creatorHandle: pack.creator.handle.value,
          joinedAllTimeCount: pack.joinedAllTimeCount ?? 0,
          communityTitle: titleByURI[key] ?? "Community Pack"
        )
      }
      await cache.storeStarterPacks(mapped)
    }

    var out: [HydratedStarterPackOption] = []
    for uri in uniqueURIs {
      if let item = await cache.cachedStarterPack(for: uri.uriString()) {
        out.append(item)
      }
    }
    return out
  }
}

public struct UnavailableCatbirdIntelligenceService: CatbirdIntelligenceServicing {
  public init() {}
  public func fetchSeedFollowDIDs(limit: Int) async -> [String] { [] }
  public func getCatalog(
    seedFollowDIDs: [String],
    query: String?,
    macroCategory: String?,
    limit: Int
  ) async throws -> BlueCatbirdOnboardingGetCatalog.Output {
    throw CatbirdIntelligenceError.clientUnavailable
  }
  public func listCommunities(
    query: String?,
    macroCategory: String?,
    sceneSlug: String?,
    limit: Int,
    cursor: String?
  ) async throws -> BlueCatbirdIntelListCommunities.Output {
    throw CatbirdIntelligenceError.clientUnavailable
  }
  public func getCommunity(communityId: Int) async throws -> BlueCatbirdIntelGetCommunity.Output {
    throw CatbirdIntelligenceError.clientUnavailable
  }
  public func getCalibrationSwipes(
    selections: [BlueCatbirdOnboardingDefs.CommunitySelection],
    seedFollowDIDs: [String],
    maxSwipes: Int
  ) async throws -> BlueCatbirdOnboardingGetCalibrationSwipes.Output {
    throw CatbirdIntelligenceError.clientUnavailable
  }
  public func previewTimeline(
    selections: [BlueCatbirdOnboardingDefs.CommunitySelection],
    swipes: [BlueCatbirdOnboardingDefs.CalibrationSwipeAnswer],
    controls: BlueCatbirdOnboardingDefs.BundleControls,
    limit: Int
  ) async throws -> BlueCatbirdOnboardingPreviewTimeline.Output {
    throw CatbirdIntelligenceError.clientUnavailable
  }
  public func solveBundle(
    input: BlueCatbirdOnboardingSolveBundle.Input
  ) async throws -> BlueCatbirdOnboardingSolveBundle.Output {
    throw CatbirdIntelligenceError.clientUnavailable
  }
  public func hydratePosts(
    uris: [ATProtocolURI],
    attributionByURI: [String: PostAttributionMetadata]
  ) async -> [HydratedSamplePost] { [] }
  public func hydrateProfiles(dids: [DID]) async -> [String: HydratedRecommendedProfile] { [:] }
  public func hydrateFeeds(
    recommended: [BlueCatbirdOnboardingDefs.RecommendedFeed]
  ) async -> [HydratedFeedOption] { [] }
  public func hydrateStarterPacks(
    recommended: [BlueCatbirdOnboardingDefs.RecommendedStarterPack]
  ) async -> [HydratedStarterPackOption] { [] }
  @MainActor
  public func commitLineup(
    followDIDs: [String],
    originalsOnlyDIDs: Set<String>,
    pinnedFeedURIs: [String]
  ) async throws -> OnboardingCommitReceipt {
    throw CatbirdIntelligenceError.clientUnavailable
  }
}

#if DEBUG
// MARK: - Loopback Showcase Intelligence Service (DEBUG Simulator Fixture Only)

public final class LoopbackShowcaseIntelligenceService: CatbirdIntelligenceServicing {
  private let intelOrigin: URL
  private let publicAppViewClient: ATProtoClient
  private let currentUserDID: String
  @MainActor private weak var appState: AppState?
  private let cache = OnboardingHydrationCache()
  private let session: URLSession

  @MainActor
  init(
    intelOrigin: URL,
    publicAppViewClient: ATProtoClient,
    appState: AppState
  ) {
    self.intelOrigin = intelOrigin
    self.publicAppViewClient = publicAppViewClient
    self.currentUserDID = appState.userDID
    self.appState = appState
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 10
    self.session = URLSession(configuration: config)
  }

  private func getXRPC<Out: Decodable>(_ nsid: String, queryItems: [URLQueryItem]) async throws -> Out {
    var comps = URLComponents(url: intelOrigin.appendingPathComponent("xrpc/\(nsid)"), resolvingAgainstBaseURL: false)!
    comps.queryItems = queryItems.isEmpty ? nil : queryItems
    var req = URLRequest(url: comps.url!)
    req.httpMethod = "GET"
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 500
    if code == 503 { throw CatbirdIntelligenceError.serviceUnavailable }
    guard (200..<300).contains(code) else { throw CatbirdIntelligenceError.invalidResponse(code) }
    return try JSONDecoder().decode(Out.self, from: data)
  }

  private func postXRPC<In: Encodable, Out: Decodable>(_ nsid: String, body: In) async throws -> Out {
    let url = intelOrigin.appendingPathComponent("xrpc/\(nsid)")
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.httpBody = try JSONEncoder().encode(body)
    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 500
    if code == 503 { throw CatbirdIntelligenceError.serviceUnavailable }
    guard (200..<300).contains(code) else { throw CatbirdIntelligenceError.invalidResponse(code) }
    return try JSONDecoder().decode(Out.self, from: data)
  }

  public func fetchSeedFollowDIDs(limit: Int) async -> [String] { [] }

  public func getCatalog(
    seedFollowDIDs: [String],
    query: String?,
    macroCategory: String?,
    limit: Int
  ) async throws -> BlueCatbirdOnboardingGetCatalog.Output {
    var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
    for did in seedFollowDIDs { items.append(URLQueryItem(name: "seedFollowDids", value: did)) }
    if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
    if let macroCategory, !macroCategory.isEmpty { items.append(URLQueryItem(name: "macroCategory", value: macroCategory)) }
    return try await getXRPC("blue.catbird.onboarding.getCatalog", queryItems: items)
  }

  public func listCommunities(
    query: String?,
    macroCategory: String?,
    sceneSlug: String?,
    limit: Int,
    cursor: String?
  ) async throws -> BlueCatbirdIntelListCommunities.Output {
    var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
    if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
    if let macroCategory, !macroCategory.isEmpty { items.append(URLQueryItem(name: "macroCategory", value: macroCategory)) }
    if let sceneSlug, !sceneSlug.isEmpty { items.append(URLQueryItem(name: "sceneSlug", value: sceneSlug)) }
    if let cursor, !cursor.isEmpty { items.append(URLQueryItem(name: "cursor", value: cursor)) }
    return try await getXRPC("blue.catbird.intel.listCommunities", queryItems: items)
  }

  public func getCommunity(communityId: Int) async throws -> BlueCatbirdIntelGetCommunity.Output {
    try await getXRPC(
      "blue.catbird.intel.getCommunity",
      queryItems: [URLQueryItem(name: "communityId", value: String(communityId))]
    )
  }

  public func getCalibrationSwipes(
    selections: [BlueCatbirdOnboardingDefs.CommunitySelection],
    seedFollowDIDs: [String],
    maxSwipes: Int
  ) async throws -> BlueCatbirdOnboardingGetCalibrationSwipes.Output {
    let dids = seedFollowDIDs.compactMap { try? DID(didString: $0) }
    return try await postXRPC(
      "blue.catbird.onboarding.getCalibrationSwipes",
      body: BlueCatbirdOnboardingGetCalibrationSwipes.Input(
        selections: selections,
        seedFollowDids: dids.isEmpty ? nil : dids,
        maxSwipes: maxSwipes
      )
    )
  }

  public func previewTimeline(
    selections: [BlueCatbirdOnboardingDefs.CommunitySelection],
    swipes: [BlueCatbirdOnboardingDefs.CalibrationSwipeAnswer],
    controls: BlueCatbirdOnboardingDefs.BundleControls,
    limit: Int
  ) async throws -> BlueCatbirdOnboardingPreviewTimeline.Output {
    try await postXRPC(
      "blue.catbird.onboarding.previewTimeline",
      body: BlueCatbirdOnboardingPreviewTimeline.Input(
        selections: selections,
        swipes: swipes.isEmpty ? nil : swipes,
        controls: controls,
        limit: limit
      )
    )
  }

  public func solveBundle(
    input: BlueCatbirdOnboardingSolveBundle.Input
  ) async throws -> BlueCatbirdOnboardingSolveBundle.Output {
    try await postXRPC("blue.catbird.onboarding.solveBundle", body: input)
  }

  public func hydratePosts(
    uris: [ATProtocolURI],
    attributionByURI: [String: PostAttributionMetadata]
  ) async -> [HydratedSamplePost] {
    await LiveCatbirdIntelligenceService.hydratePostsWithClient(
      client: publicAppViewClient,
      cache: cache,
      currentUserDID: currentUserDID,
      uris: uris,
      attributionByURI: attributionByURI,
      interBatchDelayMs: 260
    )
  }

  public func hydrateProfiles(dids: [DID]) async -> [String: HydratedRecommendedProfile] {
    await LiveCatbirdIntelligenceService.hydrateProfilesWithClient(
      client: publicAppViewClient,
      cache: cache,
      currentUserDID: currentUserDID,
      dids: dids,
      interBatchDelayMs: 260
    )
  }

  public func hydrateFeeds(
    recommended: [BlueCatbirdOnboardingDefs.RecommendedFeed]
  ) async -> [HydratedFeedOption] {
    await LiveCatbirdIntelligenceService.hydrateFeedsWithClient(
      client: publicAppViewClient,
      cache: cache,
      recommended: recommended,
      interBatchDelayMs: 260
    )
  }

  public func hydrateStarterPacks(
    recommended: [BlueCatbirdOnboardingDefs.RecommendedStarterPack]
  ) async -> [HydratedStarterPackOption] {
    await LiveCatbirdIntelligenceService.hydrateStarterPacksWithClient(
      client: publicAppViewClient,
      cache: cache,
      recommended: recommended,
      interBatchDelayMs: 260
    )
  }

  @MainActor
  public func commitLineup(
    followDIDs: [String],
    originalsOnlyDIDs: Set<String>,
    pinnedFeedURIs: [String]
  ) async throws -> OnboardingCommitReceipt {
    let batchCount = followDIDs.isEmpty
      ? 0
      : (followDIDs.count + LiveCatbirdIntelligenceService.maxBatchSize - 1) / LiveCatbirdIntelligenceService.maxBatchSize
    let activeOriginalsOnly = originalsOnlyDIDs.intersection(Set(followDIDs))
    if let appState, !activeOriginalsOnly.isEmpty {
      appState.feedFilterSettings.mergeMutedRepostAuthors(activeOriginalsOnly)
    }
    return OnboardingCommitReceipt(
      followedCount: followDIDs.count,
      batchCount: batchCount,
      originalsOnlyCount: activeOriginalsOnly.count,
      pinnedFeedsCount: pinnedFeedURIs.count
    )
  }
}
#endif
