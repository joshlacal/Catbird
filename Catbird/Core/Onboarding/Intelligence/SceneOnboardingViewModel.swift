import Foundation
import Observation
import OSLog
import Petrel
import PetrelCatbird

@MainActor
@Observable
public final class SceneOnboardingViewModel {
  public enum ExperienceMode: Sendable {
    case newAccountOnboarding
    case tuneExistingFeed
  }

  public enum Beat: Int, CaseIterable, Identifiable, Sendable {
    case explorer = 0
    case calibration = 1
    case preview = 2
    case lineup = 3
    case celebration = 4

    public var id: Int { rawValue }

    public var title: String {
      switch self {
      case .explorer: "Explore Scenes"
      case .calibration: "Taste Duels"
      case .preview: "Future Feed"
      case .lineup: "Starting Lineup"
      case .celebration: "Ready to Fly"
      }
    }

    public var shortNumberLabel: String {
      "Step \(rawValue + 1) of \(Self.allCases.count)"
    }
  }

  public struct PeekSheetState: Identifiable, Sendable {
    public var id: Int { community.communityId }
    public let community: BlueCatbirdIntelDefs.CommunitySummary
    public var members: [BlueCatbirdIntelDefs.CommunityMemberRef]
    public var profilesByDID: [String: HydratedRecommendedProfile]
    public var posts: [HydratedSamplePost]
    public var neighbors: [BlueCatbirdIntelDefs.CommunitySummary]
    public var isLoading: Bool
  }

  public struct LineupRoleSection: Identifiable, Sendable {
    public var id: CommunityRole { role }
    public let role: CommunityRole
    public let items: [BlueCatbirdOnboardingDefs.RecommendedFollow]
  }

  // MARK: - Dependencies & Mode

  public static let maxSelectedCommunities = 24
  public static let maxPinnedAuthors = 30
  public static let maxExcludedAuthors = 100
  public static let maxSeedFollows = 100

  public let mode: ExperienceMode
  public let initialInterests: [String]
  @ObservationIgnored private let service: any CatbirdIntelligenceServicing
  @ObservationIgnored private let logger = Logger(subsystem: "blue.catbird", category: "SceneOnboardingVM")
  @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?
  @ObservationIgnored private var searchGeneration: UInt64 = 0
  @ObservationIgnored private var orderedPinnedDIDs: [String] = []
  @ObservationIgnored private var orderedExcludedDIDs: [String] = []

  // MARK: - Navigation & Service Availability

  public var currentBeat: Beat = .explorer
  public private(set) var isLoadingCatalog: Bool = false
  public private(set) var shouldFallbackToLegacySuggested: Bool = false
  public var errorBannerMessage: String?

  // MARK: - Beat 1: Explorer State

  public private(set) var catalogVersion: String = ""
  public private(set) var totalCommunitiesCount: Int = 0
  public private(set) var scenes: [BlueCatbirdIntelDefs.SceneGroup] = []
  public private(set) var featuredCommunities: [BlueCatbirdIntelDefs.CommunitySummary] = []
  public private(set) var warmStartCommunities: [BlueCatbirdIntelDefs.CommunitySummary] = []
  public private(set) var displayedCommunities: [BlueCatbirdIntelDefs.CommunitySummary] = []
  public private(set) var seedFollowDIDs: [String] = []

  public var searchQuery: String = ""
  public var selectedMacroCategory: OnboardingMacroCategory = .all
  public var selectedSceneSlug: String?
  public private(set) var isSearching: Bool = false

  /// Ordered community IDs in the order the user picked them
  public private(set) var orderedSelectedCommunityIds: [Int] = []
  /// Weight per community (`1` = picked, `2` = heart-boosted)
  public private(set) var selectionWeights: [Int: Int] = [:]
  public private(set) var knownCommunitiesById: [Int: BlueCatbirdIntelDefs.CommunitySummary] = [:]

  /// Peek sheet state
  public var activePeek: PeekSheetState?

  // MARK: - Beat 2: Calibration Duels & Rhythm Controls

  public private(set) var isLoadingSwipes: Bool = false
  public private(set) var calibrationCards: [BlueCatbirdOnboardingDefs.CalibrationSwipeCard] = []
  public private(set) var activeDuelIndex: Int = 0
  public private(set) var swipeAnswers: [BlueCatbirdOnboardingDefs.CalibrationSwipeAnswer] = []
  public private(set) var duelPostsByURI: [String: HydratedSamplePost] = [:]

  public var pace: BlueCatbirdOnboardingDefs.BundleControlsPace = .value_balanced
  public var originalsOnlyForHeavyReposters: Bool = true

  // MARK: - Beat 3: Live Future Timeline Preview

  public private(set) var isLoadingPreview: Bool = false
  public private(set) var previewPosts: [HydratedSamplePost] = []
  public private(set) var previewEstimatedDailyPosts: Int = 0

  // MARK: - Beat 4: Role-Grouped Starting Lineup

  public private(set) var isSolvingBundle: Bool = false
  public private(set) var solvedBundle: BlueCatbirdOnboardingSolveBundle.Output?
  public private(set) var lineupProfilesByDID: [String: HydratedRecommendedProfile] = [:]
  public private(set) var hydratedFeeds: [HydratedFeedOption] = []
  public private(set) var hydratedStarterPacks: [HydratedStarterPackOption] = []

  public private(set) var pinnedDIDs: Set<String> = []
  public private(set) var excludedDIDs: Set<String> = []
  public private(set) var enabledFollowDIDs: Set<String> = []
  public private(set) var originalsOnlyDIDs: Set<String> = []
  public private(set) var selectedFeedURIs: Set<String> = []

  // MARK: - Beat 5: Commit & Celebration

  public private(set) var isCommitting: Bool = false
  public private(set) var commitReceipt: OnboardingCommitReceipt?

  // MARK: - Init

  public init(
    service: any CatbirdIntelligenceServicing,
    mode: ExperienceMode = .newAccountOnboarding,
    initialInterests: [String] = []
  ) {
    self.service = service
    self.mode = mode
    self.initialInterests = initialInterests
  }

  // MARK: - Computed Properties

  public var selectedCount: Int {
    orderedSelectedCommunityIds.count
  }

  public var boostedCount: Int {
    selectionWeights.values.filter { $0 >= 2 }.count
  }

  public var canAdvanceFromExplorer: Bool {
    !orderedSelectedCommunityIds.isEmpty
  }

  public var selectedCommunities: [BlueCatbirdIntelDefs.CommunitySummary] {
    orderedSelectedCommunityIds.compactMap { knownCommunitiesById[$0] }
  }

  public var currentSelectionsPayload: [BlueCatbirdOnboardingDefs.CommunitySelection] {
    orderedSelectedCommunityIds
      .prefix(Self.maxSelectedCommunities)
      .compactMap { cid in
        guard let w = selectionWeights[cid], w > 0 else { return nil }
        return BlueCatbirdOnboardingDefs.CommunitySelection(communityId: cid, weight: w)
      }
  }

  public var currentBundleControls: BlueCatbirdOnboardingDefs.BundleControls {
    BlueCatbirdOnboardingDefs.BundleControls(
      pace: pace,
      originalsOnlyForHeavyReposters: originalsOnlyForHeavyReposters
    )
  }

  public var targetBundleSize: Int {
    switch pace {
    case .value_calm: 18
    case .value_balanced: 25
    case .value_lively: 34
    }
  }

  public var activeDuelCard: BlueCatbirdOnboardingDefs.CalibrationSwipeCard? {
    guard calibrationCards.indices.contains(activeDuelIndex) else { return nil }
    return calibrationCards[activeDuelIndex]
  }

  public var lineupRoleSections: [LineupRoleSection] {
    guard let follows = solvedBundle?.follows else { return [] }
    var grouped: [CommunityRole: [BlueCatbirdOnboardingDefs.RecommendedFollow]] = [:]
    for follow in follows {
      let role = CommunityRole(rawRole: follow.role)
      grouped[role, default: []].append(follow)
    }
    return CommunityRole.allCases.compactMap { role in
      guard let items = grouped[role], !items.isEmpty else { return nil }
      return LineupRoleSection(role: role, items: items)
    }
  }

  public var activeFollowCount: Int {
    guard let follows = solvedBundle?.follows else { return 0 }
    return follows.filter { enabledFollowDIDs.contains($0.did.didString()) }.count
  }

  public var activeOriginalsOnlyCount: Int {
    guard let follows = solvedBundle?.follows else { return 0 }
    return follows.filter {
      let did = $0.did.didString()
      return enabledFollowDIDs.contains(did) && originalsOnlyDIDs.contains(did)
    }.count
  }

  public var activeEstimatedDailyPosts: Int {
    guard let follows = solvedBundle?.follows else { return 0 }
    var weeklySum = 0.0
    for item in follows {
      let did = item.did.didString()
      guard enabledFollowDIDs.contains(did) else { continue }
      let factor = originalsOnlyDIDs.contains(did) ? 0.55 : 1.0
      weeklySum += Double(item.estimatedPostsPerWeek) * factor
    }
    return max(1, Int((weeklySum / 7.0).rounded()))
  }

  public var filteredScenes: [BlueCatbirdIntelDefs.SceneGroup] {
    guard let cat = selectedMacroCategory.queryValue else { return scenes }
    return scenes.filter { $0.macroCategory == cat }
  }

  // MARK: - Beat 1 Actions: Load, Filter, Search, Pick, Boost, Peek

  public func loadInitialCatalog() async {
    guard catalogVersion.isEmpty, !isLoadingCatalog else { return }
    isLoadingCatalog = true
    errorBannerMessage = nil
    defer { isLoadingCatalog = false }

    let seeds = Array(await service.fetchSeedFollowDIDs(limit: 50).prefix(Self.maxSeedFollows))
    self.seedFollowDIDs = seeds

    do {
      let output = try await service.getCatalog(
        seedFollowDIDs: seeds,
        query: nil,
        macroCategory: nil,
        limit: 60
      )
      self.catalogVersion = output.catalogVersion
      self.totalCommunitiesCount = output.totalCommunities
      self.scenes = output.scenes
      self.featuredCommunities = output.featuredCommunities
      self.warmStartCommunities = output.warmStartCommunities
      if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && selectedMacroCategory == .all
          && selectedSceneSlug == nil {
        self.displayedCommunities = output.featuredCommunities
      }
      indexCommunities(output.featuredCommunities)
      indexCommunities(output.warmStartCommunities)
    } catch CatbirdIntelligenceError.serviceUnavailable {
      logger.info("Community Intelligence XRPC unavailable (503); falling back to legacy suggestions.")
      if mode == .newAccountOnboarding {
        self.shouldFallbackToLegacySuggested = true
      } else {
        self.errorBannerMessage = CatbirdIntelligenceError.serviceUnavailable.errorDescription
      }
    } catch {
      logger.error("Failed to load scene catalog: \(error.localizedDescription)")
      if mode == .newAccountOnboarding {
        self.shouldFallbackToLegacySuggested = true
      } else {
        self.errorBannerMessage = "Couldn’t load community scenes right now. Try again."
      }
    }
  }

  private func indexCommunities(_ items: [BlueCatbirdIntelDefs.CommunitySummary]) {
    for item in items {
      knownCommunitiesById[item.communityId] = item
    }
  }

  public func selectionWeight(for communityId: Int) -> Int {
    selectionWeights[communityId] ?? 0
  }

  /// Toggles between 0 (unpicked) and 1 (picked). If boosted (2), tapping card body unpicks cleanly.
  public func toggleCommunity(_ community: BlueCatbirdIntelDefs.CommunitySummary) {
    knownCommunitiesById[community.communityId] = community
    let cid = community.communityId
    if selectionWeights[cid] != nil {
      selectionWeights.removeValue(forKey: cid)
      orderedSelectedCommunityIds.removeAll { $0 == cid }
      if errorBannerMessage?.contains("up to \(Self.maxSelectedCommunities)") == true {
        errorBannerMessage = nil
      }
    } else {
      guard orderedSelectedCommunityIds.count < Self.maxSelectedCommunities else {
        errorBannerMessage = "You can pick up to \(Self.maxSelectedCommunities) scenes at once."
        return
      }
      selectionWeights[cid] = 1
      orderedSelectedCommunityIds.append(cid)
    }
  }

  /// Cycles Heart-Boost: unpicked -> 2x boosted; 1x picked -> 2x boosted; 2x boosted -> 1x picked.
  public func toggleHeartBoost(for community: BlueCatbirdIntelDefs.CommunitySummary) {
    knownCommunitiesById[community.communityId] = community
    let cid = community.communityId
    let current = selectionWeights[cid] ?? 0
    if current == 0 {
      guard orderedSelectedCommunityIds.count < Self.maxSelectedCommunities else {
        errorBannerMessage = "You can pick up to \(Self.maxSelectedCommunities) scenes at once."
        return
      }
      selectionWeights[cid] = 2
      orderedSelectedCommunityIds.append(cid)
    } else if current == 1 {
      selectionWeights[cid] = 2
    } else {
      selectionWeights[cid] = 1
    }
  }

  public func removeSelection(communityId: Int) {
    selectionWeights.removeValue(forKey: communityId)
    orderedSelectedCommunityIds.removeAll { $0 == communityId }
    if errorBannerMessage?.contains("up to \(Self.maxSelectedCommunities)") == true {
      errorBannerMessage = nil
    }
  }

  public func selectMacroCategory(_ category: OnboardingMacroCategory) async {
    selectedMacroCategory = category
    selectedSceneSlug = nil
    await performSearchNow()
  }

  public func selectSceneFilter(slug: String?) async {
    if selectedSceneSlug == slug {
      selectedSceneSlug = nil
    } else {
      selectedSceneSlug = slug
    }
    await performSearchNow()
  }

  public func updateSearchQuery(_ query: String) {
    searchQuery = query
    searchDebounceTask?.cancel()
    searchGeneration &+= 1
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty && selectedMacroCategory == .all && selectedSceneSlug == nil {
      displayedCommunities = featuredCommunities
      isSearching = false
      return
    }
    let scheduledGeneration = searchGeneration
    searchDebounceTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled, let self, self.searchGeneration == scheduledGeneration else { return }
      await self.performSearchNow()
    }
  }

  public func performSearchNow() async {
    searchDebounceTask?.cancel()
    searchGeneration &+= 1
    let generation = searchGeneration
    let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty && selectedMacroCategory == .all && selectedSceneSlug == nil {
      displayedCommunities = featuredCommunities
      isSearching = false
      return
    }

    isSearching = true
    defer {
      if self.searchGeneration == generation {
        isSearching = false
      }
    }

    do {
      let out = try await service.listCommunities(
        query: trimmed.isEmpty ? nil : trimmed,
        macroCategory: selectedMacroCategory.queryValue,
        sceneSlug: selectedSceneSlug,
        limit: 48,
        cursor: nil
      )
      guard !Task.isCancelled, self.searchGeneration == generation else { return }
      indexCommunities(out.communities)
      displayedCommunities = out.communities
    } catch {
      guard !Task.isCancelled, self.searchGeneration == generation else { return }
      logger.error("Community search failed: \(error.localizedDescription)")
    }
  }

  public func openPeek(for summary: BlueCatbirdIntelDefs.CommunitySummary) async {
    knownCommunitiesById[summary.communityId] = summary
    activePeek = PeekSheetState(
      community: summary,
      members: [],
      profilesByDID: [:],
      posts: [],
      neighbors: [],
      isLoading: true
    )

    do {
      let detail = try await service.getCommunity(communityId: summary.communityId)
      indexCommunities([detail.community])
      indexCommunities(detail.neighborCommunities)

      var attrMap: [String: PostAttributionMetadata] = [:]
      let postURIs = detail.samplePosts.map { item -> ATProtocolURI in
        attrMap[item.post.uriString()] = PostAttributionMetadata(
          communityId: item.communityId,
          communityTitle: item.communityTitle,
          authorRole: item.authorRole.map { CommunityRole(rawRole: $0) }
        )
        return item.post
      }
      let topMemberDIDs = Array(detail.members.prefix(12).map(\.did))

      async let postsTask = service.hydratePosts(uris: postURIs, attributionByURI: attrMap)
      async let profilesTask = service.hydrateProfiles(dids: topMemberDIDs)
      let (hydratedPosts, hydratedProfiles) = await (postsTask, profilesTask)

      guard activePeek?.community.communityId == summary.communityId else { return }
      activePeek = PeekSheetState(
        community: detail.community,
        members: Array(detail.members.prefix(12)),
        profilesByDID: hydratedProfiles,
        posts: hydratedPosts,
        neighbors: detail.neighborCommunities,
        isLoading: false
      )
    } catch {
      logger.error("Failed to load peek for community \(summary.communityId): \(error.localizedDescription)")
      if activePeek?.community.communityId == summary.communityId {
        activePeek?.isLoading = false
      }
    }
  }

  public func closePeek() {
    activePeek = nil
  }

  // MARK: - Beat Transitions

  public func advanceFromExplorerToCalibration() async {
    guard canAdvanceFromExplorer else { return }
    currentBeat = .calibration
    await loadCalibrationSwipes()
  }

  public func loadCalibrationSwipes() async {
    let selections = currentSelectionsPayload
    guard !selections.isEmpty else { return }
    isLoadingSwipes = true
    defer { isLoadingSwipes = false }

    do {
      let output = try await service.getCalibrationSwipes(
        selections: selections,
        seedFollowDIDs: seedFollowDIDs,
        maxSwipes: 4
      )
      self.calibrationCards = output.swipes
      self.activeDuelIndex = 0
      self.swipeAnswers = []

      // Pre-hydrate sample posts for all duel options in a single bounded batch
      var uris: [ATProtocolURI] = []
      var attr: [String: PostAttributionMetadata] = [:]
      for card in output.swipes {
        for uri in card.optionA.samplePostUris.prefix(2) {
          uris.append(uri)
          attr[uri.uriString()] = PostAttributionMetadata(
            communityId: card.optionA.communityId,
            communityTitle: card.optionA.title
          )
        }
        for uri in card.optionB.samplePostUris.prefix(2) {
          uris.append(uri)
          attr[uri.uriString()] = PostAttributionMetadata(
            communityId: card.optionB.communityId,
            communityTitle: card.optionB.title
          )
        }
      }
      let hydrated = await service.hydratePosts(uris: uris, attributionByURI: attr)
      var byURI: [String: HydratedSamplePost] = [:]
      for post in hydrated {
        byURI[post.uri] = post
      }
      self.duelPostsByURI = byURI
    } catch {
      logger.error("Calibration swipes load failed: \(error.localizedDescription)")
      self.calibrationCards = []
    }
  }

  public func answerCurrentDuel(_ choice: BlueCatbirdOnboardingDefs.CalibrationSwipeAnswerChoice) async {
    guard let card = activeDuelCard else {
      await advanceToPreview()
      return
    }
    let answer = BlueCatbirdOnboardingDefs.CalibrationSwipeAnswer(
      swipeId: card.swipeId,
      communityA: card.optionA.communityId,
      communityB: card.optionB.communityId,
      choice: choice
    )
    swipeAnswers.removeAll { $0.swipeId == card.swipeId }
    swipeAnswers.append(answer)

    if activeDuelIndex + 1 < calibrationCards.count {
      activeDuelIndex += 1
    } else {
      await advanceToPreview()
    }
  }

  public func skipCalibrationDuels() async {
    await advanceToPreview()
  }

  public func advanceToPreview() async {
    currentBeat = .preview
    await loadTimelinePreview()
  }

  public func loadTimelinePreview() async {
    let selections = currentSelectionsPayload
    guard !selections.isEmpty else { return }
    isLoadingPreview = true
    defer { isLoadingPreview = false }

    do {
      let out = try await service.previewTimeline(
        selections: selections,
        swipes: swipeAnswers,
        controls: currentBundleControls,
        limit: 16
      )
      self.previewEstimatedDailyPosts = out.estimatedDailyPosts
      var attr: [String: PostAttributionMetadata] = [:]
      let uris = out.items.map { item -> ATProtocolURI in
        attr[item.post.uriString()] = PostAttributionMetadata(
          communityId: item.communityId,
          communityTitle: item.communityTitle,
          authorRole: item.authorRole.map { CommunityRole(rawRole: $0) }
        )
        return item.post
      }
      self.previewPosts = await service.hydratePosts(uris: uris, attributionByURI: attr)
    } catch {
      logger.error("Preview timeline load failed: \(error.localizedDescription)")
      self.previewPosts = []
    }
  }

  public func updatePace(_ newPace: BlueCatbirdOnboardingDefs.BundleControlsPace) async {
    guard pace != newPace else { return }
    pace = newPace
    if currentBeat == .preview {
      await loadTimelinePreview()
    } else if currentBeat == .lineup {
      await solveStartingLineup()
    }
  }

  public func setSmartRepostTamer(_ enabled: Bool) async {
    guard originalsOnlyForHeavyReposters != enabled else { return }
    originalsOnlyForHeavyReposters = enabled
    if currentBeat == .preview {
      await loadTimelinePreview()
    } else if currentBeat == .lineup {
      await solveStartingLineup()
    }
  }

  public func togglePinAuthor(did: String) {
    guard !did.isEmpty else { return }
    if pinnedDIDs.contains(did) {
      pinnedDIDs.remove(did)
      orderedPinnedDIDs.removeAll { $0 == did }
      if errorBannerMessage?.contains("up to \(Self.maxPinnedAuthors)") == true {
        errorBannerMessage = nil
      }
    } else {
      guard pinnedDIDs.count < Self.maxPinnedAuthors else {
        errorBannerMessage = "You can pin up to \(Self.maxPinnedAuthors) voices."
        return
      }
      pinnedDIDs.insert(did)
      orderedPinnedDIDs.removeAll { $0 == did }
      orderedPinnedDIDs.append(did)
      excludedDIDs.remove(did)
      orderedExcludedDIDs.removeAll { $0 == did }
    }
  }

  public func isAuthorPinned(_ did: String) -> Bool {
    pinnedDIDs.contains(did)
  }

  public func advanceToStartingLineup() async {
    currentBeat = .lineup
    await solveStartingLineup()
  }

  public func goBackOneBeat() {
    switch currentBeat {
    case .explorer:
      break
    case .calibration:
      currentBeat = .explorer
    case .preview:
      currentBeat = .calibration
    case .lineup:
      currentBeat = .preview
    case .celebration:
      break
    }
  }

  // MARK: - Beat 4 Actions: Solve Bundle, Toggle Accounts, Originals-Only, Swap, Pin Feeds

  public func solveStartingLineup() async {
    let selections = currentSelectionsPayload
    guard !selections.isEmpty else { return }
    isSolvingBundle = true
    errorBannerMessage = nil
    defer { isSolvingBundle = false }

    let pinnedSource = orderedPinnedDIDs.isEmpty ? pinnedDIDs.sorted() : orderedPinnedDIDs
    let excludedSource = orderedExcludedDIDs.isEmpty ? excludedDIDs.sorted() : orderedExcludedDIDs
    let pinned = pinnedSource.prefix(Self.maxPinnedAuthors).compactMap { try? DID(didString: $0) }
    let excluded = excludedSource.prefix(Self.maxExcludedAuthors).compactMap { try? DID(didString: $0) }
    let seeds = seedFollowDIDs.prefix(Self.maxSeedFollows).compactMap { try? DID(didString: $0) }

    do {
      let input = BlueCatbirdOnboardingSolveBundle.Input(
        selections: selections,
        swipes: swipeAnswers.isEmpty ? nil : Array(swipeAnswers.prefix(8)),
        controls: currentBundleControls,
        targetSize: targetBundleSize,
        pinnedDids: pinned.isEmpty ? nil : pinned,
        excludedDids: excluded.isEmpty ? nil : excluded,
        seedFollowDids: seeds.isEmpty ? nil : seeds
      )
      let output = try await service.solveBundle(input: input)
      self.solvedBundle = output
      indexCommunities(output.harmoniousNeighbors)

      let followDIDObjects = output.follows.map(\.did)
      async let profilesTask = service.hydrateProfiles(dids: followDIDObjects)
      async let feedsTask = service.hydrateFeeds(recommended: output.feeds)
      async let packsTask = service.hydrateStarterPacks(recommended: output.starterPacks)
      let (profiles, feeds, packs) = await (profilesTask, feedsTask, packsTask)

      self.lineupProfilesByDID = profiles
      self.hydratedFeeds = feeds
      self.hydratedStarterPacks = packs

      // Default enabled accounts: all solved accounts that aren't already followed or blocked/muted
      var nextEnabled = Set<String>()
      var nextOriginalsOnly = Set<String>()
      for rec in output.follows {
        let didStr = rec.did.didString()
        if let hydrated = profiles[didStr], hydrated.alreadyFollowing || hydrated.isBlockedOrMuted {
          continue
        }
        nextEnabled.insert(didStr)
        if rec.hideReposts || rec.deliveryMode == "originals_only" {
          nextOriginalsOnly.insert(didStr)
        }
      }
      self.enabledFollowDIDs = nextEnabled
      self.originalsOnlyDIDs = nextOriginalsOnly
      if self.selectedFeedURIs.isEmpty {
        self.selectedFeedURIs = Set(feeds.prefix(2).map(\.uri))
      }
    } catch {
      logger.error("Failed to solve starting lineup: \(error.localizedDescription)")
      errorBannerMessage = "Couldn’t assemble your starting lineup. Try again."
    }
  }

  public func toggleFollowAccount(_ did: String) {
    if enabledFollowDIDs.contains(did) {
      enabledFollowDIDs.remove(did)
    } else {
      enabledFollowDIDs.insert(did)
    }
  }

  public func toggleOriginalsOnly(for did: String) {
    if originalsOnlyDIDs.contains(did) {
      originalsOnlyDIDs.remove(did)
    } else {
      originalsOnlyDIDs.insert(did)
    }
  }

  public func excludeAndSwapAccount(_ did: String) async {
    guard !did.isEmpty else { return }
    orderedExcludedDIDs.removeAll { $0 == did }
    orderedExcludedDIDs.append(did)
    if orderedExcludedDIDs.count > Self.maxExcludedAuthors {
      let evicted = orderedExcludedDIDs.removeFirst()
      excludedDIDs.remove(evicted)
    }
    excludedDIDs.insert(did)
    pinnedDIDs.remove(did)
    orderedPinnedDIDs.removeAll { $0 == did }
    enabledFollowDIDs.remove(did)
    originalsOnlyDIDs.remove(did)
    await solveStartingLineup()
  }

  public func addHarmoniousNeighborAndResolve(_ neighbor: BlueCatbirdIntelDefs.CommunitySummary) async {
    knownCommunitiesById[neighbor.communityId] = neighbor
    if selectionWeights[neighbor.communityId] == nil {
      guard orderedSelectedCommunityIds.count < Self.maxSelectedCommunities else {
        errorBannerMessage = "You can pick up to \(Self.maxSelectedCommunities) scenes at once."
        return
      }
      selectionWeights[neighbor.communityId] = 1
      orderedSelectedCommunityIds.append(neighbor.communityId)
    }
    await solveStartingLineup()
  }

  public func togglePinnedFeed(_ uri: String) {
    if selectedFeedURIs.contains(uri) {
      selectedFeedURIs.remove(uri)
    } else {
      selectedFeedURIs.insert(uri)
    }
  }

  // MARK: - Beat 5 Actions: Commit & Celebration

  public func commitStartingLineup() async {
    guard let bundle = solvedBundle, !isCommitting else { return }
    isCommitting = true
    errorBannerMessage = nil
    defer { isCommitting = false }

    // Preserve deterministic bundle rank order
    let orderedFollows = bundle.follows
      .map { $0.did.didString() }
      .filter { enabledFollowDIDs.contains($0) }
    let orderedFeeds = hydratedFeeds
      .map(\.uri)
      .filter { selectedFeedURIs.contains($0) }

    do {
      let receipt = try await service.commitLineup(
        followDIDs: orderedFollows,
        originalsOnlyDIDs: originalsOnlyDIDs.intersection(Set(orderedFollows)),
        pinnedFeedURIs: orderedFeeds
      )
      self.commitReceipt = receipt
      self.currentBeat = .celebration
    } catch {
      logger.error("Failed to commit starting lineup: \(error.localizedDescription)")
      errorBannerMessage = error.localizedDescription
    }
  }
}
