import Foundation
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

@Suite("Community Intelligence Onboarding & Per-Author Repost Tamer")
struct OnboardingIntelligenceTests {
  // MARK: - Synthetic Builders (Zero PII)

  private static func makeScene(
    id: Int = 10,
    slug: String = "swift_apple",
    title: String = "iOS & Apple Craft",
    category: String = "software_ai_tech"
  ) -> BlueCatbirdIntelDefs.SceneGroup {
    BlueCatbirdIntelDefs.SceneGroup(
      sceneId: id,
      sceneSlug: slug,
      sceneTitle: title,
      macroCategory: category,
      symbolName: "swift",
      cardCount: 2,
      totalEligibleAccounts: 80,
      topCommunityIds: [497, 2421]
    )
  }

  private static func makeCommunity(
    id: Int,
    title: String,
    sceneSlug: String = "swift_apple",
    category: String = "software_ai_tech"
  ) throws -> BlueCatbirdIntelDefs.CommunitySummary {
    let postURI = try ATProtocolURI(uriString: "at://did:plc:synthauthor\(id)/app.bsky.feed.post/3lsynth\(id)")
    let did = try DID(didString: "did:plc:synthauthor\(id)")
    return BlueCatbirdIntelDefs.CommunitySummary(
      communityId: id,
      title: title,
      description: "Synthetic test community \(title).",
      sceneId: 10,
      sceneSlug: sceneSlug,
      sceneTitle: "iOS & Apple Craft",
      macroCategory: category,
      symbolName: "swift",
      eligibleCount: 42,
      postCoherenceBps: 7100,
      socialCoherenceBps: 6800,
      curatedListTags: ["swiftui", "indiedev"],
      neighborCommunityIds: [2421],
      samplePostUris: [postURI],
      sampleAccountDids: [did],
      feedGeneratorUris: [],
      starterPackUris: []
    )
  }

  @MainActor
  private final class MockIntelligenceService: @unchecked Sendable, CatbirdIntelligenceServicing {
    var shouldThrowUnavailable = false
    var seedFollows: [String] = ["did:plc:synthseed1"]
    var lastSearchQuery: String?
    var lastMacroCategory: String?
    var lastSolveInput: BlueCatbirdOnboardingSolveBundle.Input?
    var committedFollows: [String] = []
    var committedOriginalsOnly: Set<String> = []
    var committedPinnedFeeds: [String] = []

    func fetchSeedFollowDIDs(limit: Int) async -> [String] {
      seedFollows
    }

    func getCatalog(
      seedFollowDIDs: [String],
      query: String?,
      macroCategory: String?,
      limit: Int
    ) async throws -> BlueCatbirdOnboardingGetCatalog.Output {
      if shouldThrowUnavailable {
        throw CatbirdIntelligenceError.serviceUnavailable
      }
      let c1 = try OnboardingIntelligenceTests.makeCommunity(id: 497, title: "iOS & SwiftUI Builders")
      let c2 = try OnboardingIntelligenceTests.makeCommunity(
        id: 2421,
        title: "Indie Game Makers",
        sceneSlug: "indie_games",
        category: "games_interactive"
      )
      let warm = seedFollowDIDs.isEmpty ? [] : [c1]
      return BlueCatbirdOnboardingGetCatalog.Output(
        catalogVersion: "s17_rev6_synth",
        totalCommunities: 1016,
        scenes: [OnboardingIntelligenceTests.makeScene()],
        featuredCommunities: [c1, c2],
        warmStartCommunities: warm
      )
    }

    func listCommunities(
      query: String?,
      macroCategory: String?,
      sceneSlug: String?,
      limit: Int,
      cursor: String?
    ) async throws -> BlueCatbirdIntelListCommunities.Output {
      lastSearchQuery = query
      lastMacroCategory = macroCategory
      let c1 = try OnboardingIntelligenceTests.makeCommunity(id: 497, title: "iOS & SwiftUI Builders")
      let c2 = try OnboardingIntelligenceTests.makeCommunity(
        id: 2421,
        title: "Indie Game Makers",
        sceneSlug: "indie_games",
        category: "games_interactive"
      )
      let filtered = [c1, c2].filter { item in
        if let macroCategory, item.macroCategory != macroCategory { return false }
        if let query, !query.isEmpty {
          return item.title.localizedCaseInsensitiveContains(query)
        }
        return true
      }
      return BlueCatbirdIntelListCommunities.Output(
        catalogVersion: "s17_rev6_synth",
        totalCount: filtered.count,
        cursor: nil,
        scenes: [OnboardingIntelligenceTests.makeScene()],
        communities: filtered
      )
    }

    func getCommunity(communityId: Int) async throws -> BlueCatbirdIntelGetCommunity.Output {
      let comm = try OnboardingIntelligenceTests.makeCommunity(id: communityId, title: "iOS & SwiftUI Builders")
      let memberDID = try DID(didString: "did:plc:synthmember1")
      let postURI = try ATProtocolURI(uriString: "at://did:plc:synthmember1/app.bsky.feed.post/3lpeek1")
      return BlueCatbirdIntelGetCommunity.Output(
        catalogVersion: "s17_rev6_synth",
        community: comm,
        members: [
          BlueCatbirdIntelDefs.CommunityMemberRef(
            did: memberDID,
            role: "anchor_creator",
            recommendedMode: "follow_all",
            whyPicked: "Trusted voice in iOS & SwiftUI Builders",
            rankScoreBps: 9200,
            repostShareBps: 800,
            mediaShareBps: 3000,
            estimatedPostsPerWeek: 10,
            samplePostUri: postURI
          )
        ],
        samplePosts: [
          BlueCatbirdIntelDefs.PostSkeletonItem(
            post: postURI,
            communityId: communityId,
            communityTitle: comm.title,
            authorRole: "anchor_creator"
          )
        ],
        neighborCommunities: []
      )
    }

    func getCalibrationSwipes(
      selections: [BlueCatbirdOnboardingDefs.CommunitySelection],
      seedFollowDIDs: [String],
      maxSwipes: Int
    ) async throws -> BlueCatbirdOnboardingGetCalibrationSwipes.Output {
      let uriA = try ATProtocolURI(uriString: "at://did:plc:synthduela/app.bsky.feed.post/3lduela")
      let uriB = try ATProtocolURI(uriString: "at://did:plc:synthduelb/app.bsky.feed.post/3lduelb")
      let card = BlueCatbirdOnboardingDefs.CalibrationSwipeCard(
        swipeId: "duel_swift_497_vs_0",
        step: 1,
        kind: "ambiguity_split",
        prompt: "Which kind of Swift posts belong in your daily feed?",
        optionA: .init(
          communityId: 497,
          title: "iOS & SwiftUI Builders",
          subtitle: "Apple platform code, Xcode tips, and native UI craft.",
          sceneTitle: "iOS & Apple Craft",
          samplePostUris: [uriA]
        ),
        optionB: .init(
          communityId: 900,
          title: "Pop Tour & Lyric Fandom",
          subtitle: "Concert livestreams and album release threads.",
          sceneTitle: "Pop Fandom",
          samplePostUris: [uriB]
        )
      )
      return BlueCatbirdOnboardingGetCalibrationSwipes.Output(
        catalogVersion: "s17_rev6_synth",
        swipes: [card]
      )
    }

    func previewTimeline(
      selections: [BlueCatbirdOnboardingDefs.CommunitySelection],
      swipes: [BlueCatbirdOnboardingDefs.CalibrationSwipeAnswer],
      controls: BlueCatbirdOnboardingDefs.BundleControls,
      limit: Int
    ) async throws -> BlueCatbirdOnboardingPreviewTimeline.Output {
      let uri = try ATProtocolURI(uriString: "at://did:plc:synthpreview1/app.bsky.feed.post/3lprev1")
      let daily = controls.pace == .value_calm ? 22 : (controls.pace == .value_lively ? 88 : 46)
      return BlueCatbirdOnboardingPreviewTimeline.Output(
        catalogVersion: "s17_rev6_synth",
        items: [
          BlueCatbirdIntelDefs.PostSkeletonItem(
            post: uri,
            communityId: 497,
            communityTitle: "iOS & SwiftUI Builders",
            authorRole: "visual_maker"
          )
        ],
        estimatedDailyPosts: daily
      )
    }

    func solveBundle(
      input: BlueCatbirdOnboardingSolveBundle.Input
    ) async throws -> BlueCatbirdOnboardingSolveBundle.Output {
      lastSolveInput = input
      let excludedSet = Set((input.excludedDids ?? []).map { $0.didString() })

      let candidates: [(String, String, String, Bool, Int)] = [
        ("did:plc:synthanchor1", "anchor_creator", "follow_all", false, 10),
        ("did:plc:synthmaker1", "visual_maker", "follow_all", false, 14),
        ("did:plc:synthconvo1", "conversationalist", "follow_all", false, 18),
        ("did:plc:synthcurator1", "scene_curator", "originals_only", true, 28),
        ("did:plc:synthbackup1", "visual_maker", "follow_all", false, 12),
      ]

      var follows: [BlueCatbirdOnboardingDefs.RecommendedFollow] = []
      for (didStr, role, mode, hideRT, perWeek) in candidates where !excludedSet.contains(didStr) {
        let did = try DID(didString: didStr)
        let effectiveHideRT = (input.controls?.originalsOnlyForHeavyReposters ?? true) && hideRT
        follows.append(
          BlueCatbirdOnboardingDefs.RecommendedFollow(
            did: did,
            communityId: 497,
            communityTitle: "iOS & SwiftUI Builders",
            role: role,
            deliveryMode: effectiveHideRT ? "originals_only" : mode,
            hideReposts: effectiveHideRT,
            whyPicked: "Selected for \(role) balance",
            estimatedPostsPerWeek: perWeek,
            samplePostUri: nil
          )
        )
      }

      let feedURI = try ATProtocolURI(uriString: "at://did:plc:synthfeedgen/app.bsky.feed.generator/swiftui")
      let neighbor = try OnboardingIntelligenceTests.makeCommunity(
        id: 3109,
        title: "macOS App Craft"
      )
      return BlueCatbirdOnboardingSolveBundle.Output(
        sessionId: "sess_synth_1",
        catalogVersion: "s17_rev6_synth",
        solveMs: 4,
        summary: .init(
          totalFollows: follows.count,
          anchorCount: 1,
          makerCount: 2,
          conversationalCount: 1,
          curatorCount: 1,
          originalsOnlyCount: follows.filter(\.hideReposts).count,
          estimatedDailyPosts: 11,
          coveredCommunities: 1
        ),
        follows: follows,
        feeds: [
          .init(uri: feedURI, communityId: 497, communityTitle: "iOS & SwiftUI Builders")
        ],
        starterPacks: [],
        harmoniousNeighbors: [neighbor]
      )
    }

    func hydratePosts(
      uris: [ATProtocolURI],
      attributionByURI: [String: PostAttributionMetadata]
    ) async -> [HydratedSamplePost] {
      uris.map { uri in
        let key = uri.uriString()
        let attr = attributionByURI[key]
        return HydratedSamplePost(
          uri: key,
          authorDID: "did:plc:synthpreview1",
          authorHandle: "synthmaker.example",
          authorDisplayName: "Synth Maker",
          text: "Shipped a smooth Liquid Glass sheet transition in SwiftUI today.",
          likeCount: 48,
          repostCount: 6,
          replyCount: 5,
          communityId: attr?.communityId,
          communityTitle: attr?.communityTitle,
          authorRole: attr?.authorRole
        )
      }
    }

    func hydrateProfiles(dids: [DID]) async -> [String: HydratedRecommendedProfile] {
      var out: [String: HydratedRecommendedProfile] = [:]
      for did in dids {
        let key = did.didString()
        out[key] = HydratedRecommendedProfile(
          did: key,
          handle: "\(key.suffix(8)).example",
          displayName: "Creator \(key.suffix(6))",
          bio: "Building thoughtful apps and sharing notes."
        )
      }
      return out
    }

    func hydrateFeeds(
      recommended: [BlueCatbirdOnboardingDefs.RecommendedFeed]
    ) async -> [HydratedFeedOption] {
      recommended.map {
        HydratedFeedOption(
          uri: $0.uri.uriString(),
          displayName: "SwiftUI Craft Feed",
          creatorHandle: "synthfeed.example",
          description: "Curated SwiftUI posts.",
          likeCount: 320,
          communityTitle: $0.communityTitle
        )
      }
    }

    func hydrateStarterPacks(
      recommended: [BlueCatbirdOnboardingDefs.RecommendedStarterPack]
    ) async -> [HydratedStarterPackOption] {
      []
    }

    func commitLineup(
      followDIDs: [String],
      originalsOnlyDIDs: Set<String>,
      pinnedFeedURIs: [String]
    ) async throws -> OnboardingCommitReceipt {
      committedFollows = followDIDs
      committedOriginalsOnly = originalsOnlyDIDs
      committedPinnedFeeds = pinnedFeedURIs
      let batches = followDIDs.isEmpty ? 0 : (followDIDs.count + 24) / 25
      return OnboardingCommitReceipt(
        followedCount: followDIDs.count,
        batchCount: batches,
        originalsOnlyCount: originalsOnlyDIDs.count,
        pinnedFeedsCount: pinnedFeedURIs.count
      )
    }
  }

  // MARK: - Tests

  @Test("Graceful 503 fallback marks shouldFallbackToLegacySuggested during new-account onboarding")
  @MainActor
  func graceful503FallbackInNewAccountOnboarding() async {
    let mock = MockIntelligenceService()
    mock.shouldThrowUnavailable = true
    let vm = SceneOnboardingViewModel(service: mock, mode: .newAccountOnboarding)

    await vm.loadInitialCatalog()

    #expect(vm.shouldFallbackToLegacySuggested == true)
    #expect(vm.featuredCommunities.isEmpty)
  }

  @Test("Explorer loads warm-start orbit, supports 1x pick / 2x heart-boost, and runs hybrid search")
  @MainActor
  func explorerWarmStartPickBoostAndSearch() async throws {
    let mock = MockIntelligenceService()
    let vm = SceneOnboardingViewModel(service: mock, mode: .newAccountOnboarding)

    await vm.loadInitialCatalog()
    #expect(vm.totalCommunitiesCount == 1016)
    #expect(vm.warmStartCommunities.count == 1)
    #expect(vm.featuredCommunities.count == 2)

    let swiftComm = try #require(vm.featuredCommunities.first)
    vm.toggleCommunity(swiftComm)
    #expect(vm.selectedCount == 1)
    #expect(vm.boostedCount == 0)
    #expect(vm.selectionWeight(for: swiftComm.communityId) == 1)

    vm.toggleHeartBoost(for: swiftComm)
    #expect(vm.boostedCount == 1)
    #expect(vm.selectionWeight(for: swiftComm.communityId) == 2)

    vm.searchQuery = "Indie"
    await vm.performSearchNow()
    #expect(mock.lastSearchQuery == "Indie")
    #expect(vm.displayedCommunities.count == 1)
    #expect(vm.displayedCommunities.first?.communityId == 2421)
  }

  @Test("Peek sheet hydrates sample posts & members, and full 5-beat flow solves, swaps, and commits lineup")
  @MainActor
  func fullFiveBeatFlowSolveSwapAndCommit() async throws {
    let mock = MockIntelligenceService()
    let vm = SceneOnboardingViewModel(service: mock, mode: .newAccountOnboarding)
    await vm.loadInitialCatalog()

    let comm = try #require(vm.featuredCommunities.first)
    await vm.openPeek(for: comm)
    #expect(vm.activePeek?.isLoading == false)
    #expect(vm.activePeek?.posts.count == 1)
    #expect(vm.activePeek?.members.count == 1)
    vm.closePeek()

    // Beat 1 -> Beat 2 (Calibration Duels)
    vm.toggleHeartBoost(for: comm)
    await vm.advanceFromExplorerToCalibration()
    #expect(vm.currentBeat == .calibration)
    #expect(vm.calibrationCards.count == 1)
    #expect(!vm.duelPostsByURI.isEmpty)

    // Answer duel -> automatically advances to Beat 3 (Live Future Timeline Preview)
    await vm.answerCurrentDuel(.value_a)
    #expect(vm.currentBeat == .preview)
    #expect(vm.swipeAnswers.count == 1)
    #expect(vm.previewPosts.count == 1)
    #expect(vm.previewEstimatedDailyPosts == 46)

    // Pin preview post author & adjust pace to Calm
    vm.togglePinAuthor(did: "did:plc:synthpreview1")
    #expect(vm.isAuthorPinned("did:plc:synthpreview1"))
    await vm.updatePace(.value_calm)
    #expect(vm.previewEstimatedDailyPosts == 22)

    // Advance to Beat 4 (Starting Lineup)
    await vm.advanceToStartingLineup()
    #expect(vm.currentBeat == .lineup)
    #expect(vm.lineupRoleSections.count == 4)
    #expect(vm.activeFollowCount == 5)
    #expect(vm.activeOriginalsOnlyCount == 1)
    #expect(vm.originalsOnlyDIDs.contains("did:plc:synthcurator1"))

    // Swap out one account -> re-solves cleanly excluding that DID
    await vm.excludeAndSwapAccount("did:plc:synthconvo1")
    #expect(vm.excludedDIDs.contains("did:plc:synthconvo1"))
    #expect(vm.activeFollowCount == 4)
    #expect(
      mock.lastSolveInput?.pinnedDids?.map { $0.didString() } == ["did:plc:synthpreview1"]
    )

    // Commit -> Beat 5 (Celebration)
    await vm.commitStartingLineup()
    #expect(vm.currentBeat == .celebration)
    #expect(vm.commitReceipt?.followedCount == 4)
    #expect(vm.commitReceipt?.originalsOnlyCount == 1)
    #expect(vm.commitReceipt?.pinnedFeedsCount == 1)
    #expect(mock.committedOriginalsOnly == Set(["did:plc:synthcurator1"]))
  }

  @Test("FeedFilterSettings MutedRepostAuthorProcessor persists per-author Originals-Only DIDs")
  func perAuthorRepostTamerPersistsScopedSettings() throws {
    let suiteName = "test.repost.tamer.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = FeedFilterSettings(accountDID: "did:plc:synthviewer", defaults: defaults)
    #expect(settings.mutedRepostAuthorDIDs.isEmpty)

    settings.mergeMutedRepostAuthors(["did:plc:synthcurator1", "did:plc:synthcurator2"])
    #expect(settings.isRepostMuted(for: "did:plc:synthcurator1"))
    #expect(settings.activeFilters.contains(where: { $0.name == "Content Filter" }))

    // Reload from same UserDefaults suite to verify persistence
    let reloaded = FeedFilterSettings(accountDID: "did:plc:synthviewer", defaults: defaults)
    #expect(reloaded.isRepostMuted(for: "did:plc:synthcurator1"))
    #expect(reloaded.isRepostMuted(for: "did:plc:synthcurator2"))

    reloaded.setRepostMuted(false, for: "did:plc:synthcurator1")
    #expect(!reloaded.isRepostMuted(for: "did:plc:synthcurator1"))
    #expect(reloaded.isRepostMuted(for: "did:plc:synthcurator2"))

    // Unscoped empty accountDID must never read or write global UserDefaults keys
    let unscoped = FeedFilterSettings(accountDID: "", defaults: defaults)
    unscoped.mergeMutedRepostAuthors(["did:plc:synthcurator99"])
    #expect(unscoped.mutedRepostAuthorDIDs.isEmpty)
    #expect(defaults.stringArray(forKey: "MutedRepostAuthorDIDs") == nil)
  }

  @Test("Selection, pin, and exclusion caps match BlueCatbirdOnboarding lexicon array limits")
  @MainActor
  func selectionPinAndExclusionCapsMatchLexiconLimits() async throws {
    let mock = MockIntelligenceService()
    let vm = SceneOnboardingViewModel(service: mock, mode: .newAccountOnboarding)
    await vm.loadInitialCatalog()

    for idx in 1...SceneOnboardingViewModel.maxSelectedCommunities {
      let comm = try Self.makeCommunity(id: 1000 + idx, title: "Scene \(idx)")
      vm.toggleCommunity(comm)
    }
    #expect(vm.selectedCount == 24)
    #expect(vm.errorBannerMessage == nil)

    // 25th community is rejected cleanly without exceeding lexicon maxLength=24
    let overflowComm = try Self.makeCommunity(id: 9999, title: "Scene 25 Overflow")
    vm.toggleCommunity(overflowComm)
    #expect(vm.selectedCount == 24)
    #expect(vm.selectionWeight(for: 9999) == 0)
    #expect(vm.errorBannerMessage != nil)

    // Boosting an already-selected community among the 24 still works
    let firstPicked = try Self.makeCommunity(id: 1001, title: "Scene 1")
    vm.toggleHeartBoost(for: firstPicked)
    #expect(vm.selectionWeight(for: 1001) == 2)
    #expect(vm.currentSelectionsPayload.count == 24)

    // Unpicking one clears the limit banner and opens room again
    vm.toggleCommunity(firstPicked)
    #expect(vm.selectedCount == 23)
    #expect(vm.errorBannerMessage == nil)

    // Pin cap = 30
    for idx in 1...SceneOnboardingViewModel.maxPinnedAuthors {
      vm.togglePinAuthor(did: "did:plc:synthpin\(idx)")
    }
    #expect(vm.pinnedDIDs.count == 30)
    vm.togglePinAuthor(did: "did:plc:synthpin31")
    #expect(vm.pinnedDIDs.count == 30)
    #expect(!vm.isAuthorPinned("did:plc:synthpin31"))

    // Exclusion cap = 100 (FIFO eviction preserves bounded payload)
    for idx in 1...105 {
      await vm.excludeAndSwapAccount("did:plc:synthexcl\(idx)")
    }
    #expect(vm.excludedDIDs.count == 100)
    #expect(mock.lastSolveInput?.excludedDids?.count == 100)
    #expect(!vm.excludedDIDs.contains("did:plc:synthexcl1"))
    #expect(vm.excludedDIDs.contains("did:plc:synthexcl105"))
  }

  @Test("Out-of-order listCommunities responses cannot overwrite newer search queries or resets")
  @MainActor
  func staleOutOfOrderSearchResponsesAreDiscarded() async throws {
    @MainActor
    final class ControlledSearchService: @unchecked Sendable, CatbirdIntelligenceServicing {
      var slowSearchContinuation: CheckedContinuation<Void, Never>?

      func fetchSeedFollowDIDs(limit: Int) async -> [String] { [] }

      func getCatalog(
        seedFollowDIDs: [String],
        query: String?,
        macroCategory: String?,
        limit: Int
      ) async throws -> BlueCatbirdOnboardingGetCatalog.Output {
        let featured = try OnboardingIntelligenceTests.makeCommunity(id: 497, title: "Featured Swift")
        return .init(
          catalogVersion: "s17_rev6_synth",
          totalCommunities: 1,
          scenes: [],
          featuredCommunities: [featured],
          warmStartCommunities: []
        )
      }

      func listCommunities(
        query: String?,
        macroCategory: String?,
        sceneSlug: String?,
        limit: Int,
        cursor: String?
      ) async throws -> BlueCatbirdIntelListCommunities.Output {
        if query == "SlowStale" {
          await withCheckedContinuation { cont in
            self.slowSearchContinuation = cont
          }
          let stale = try OnboardingIntelligenceTests.makeCommunity(id: 777, title: "Stale Result")
          return .init(
            catalogVersion: "s17_rev6_synth",
            totalCount: 1,
            cursor: nil,
            scenes: [],
            communities: [stale]
          )
        }
        let fresh = try OnboardingIntelligenceTests.makeCommunity(id: 2421, title: "Fresh Indie Result")
        return .init(
          catalogVersion: "s17_rev6_synth",
          totalCount: 1,
          cursor: nil,
          scenes: [],
          communities: [fresh]
        )
      }

      func getCommunity(communityId: Int) async throws -> BlueCatbirdIntelGetCommunity.Output {
        throw CatbirdIntelligenceError.serviceUnavailable
      }
      func getCalibrationSwipes(
        selections: [BlueCatbirdOnboardingDefs.CommunitySelection],
        seedFollowDIDs: [String],
        maxSwipes: Int
      ) async throws -> BlueCatbirdOnboardingGetCalibrationSwipes.Output {
        throw CatbirdIntelligenceError.serviceUnavailable
      }
      func previewTimeline(
        selections: [BlueCatbirdOnboardingDefs.CommunitySelection],
        swipes: [BlueCatbirdOnboardingDefs.CalibrationSwipeAnswer],
        controls: BlueCatbirdOnboardingDefs.BundleControls,
        limit: Int
      ) async throws -> BlueCatbirdOnboardingPreviewTimeline.Output {
        throw CatbirdIntelligenceError.serviceUnavailable
      }
      func solveBundle(
        input: BlueCatbirdOnboardingSolveBundle.Input
      ) async throws -> BlueCatbirdOnboardingSolveBundle.Output {
        throw CatbirdIntelligenceError.serviceUnavailable
      }
      func hydratePosts(
        uris: [ATProtocolURI],
        attributionByURI: [String: PostAttributionMetadata]
      ) async -> [HydratedSamplePost] { [] }
      func hydrateProfiles(dids: [DID]) async -> [String: HydratedRecommendedProfile] { [:] }
      func hydrateFeeds(recommended: [BlueCatbirdOnboardingDefs.RecommendedFeed]) async -> [HydratedFeedOption] { [] }
      func hydrateStarterPacks(recommended: [BlueCatbirdOnboardingDefs.RecommendedStarterPack]) async -> [HydratedStarterPackOption] { [] }
      func commitLineup(
        followDIDs: [String],
        originalsOnlyDIDs: Set<String>,
        pinnedFeedURIs: [String]
      ) async throws -> OnboardingCommitReceipt {
        .init(followedCount: 0, batchCount: 0, originalsOnlyCount: 0, pinnedFeedsCount: 0)
      }
    }

    let svc = ControlledSearchService()
    let vm = SceneOnboardingViewModel(service: svc, mode: .newAccountOnboarding)
    await vm.loadInitialCatalog()

    vm.searchQuery = "SlowStale"
    let staleTask = Task { @MainActor in
      await vm.performSearchNow()
    }
    while svc.slowSearchContinuation == nil {
      await Task.yield()
    }

    // Newer search completes while SlowStale is still suspended
    vm.searchQuery = "FreshIndie"
    await vm.performSearchNow()
    #expect(vm.displayedCommunities.map(\.communityId) == [2421])
    #expect(vm.isSearching == false)

    // Now release the stale response and ensure it is discarded
    svc.slowSearchContinuation?.resume()
    await staleTask.value
    #expect(vm.displayedCommunities.map(\.communityId) == [2421])
    #expect(vm.isSearching == false)
  }

  @Test("Account context guard fails closed across account switches and collision_trap duel copy matches backend")
  func accountContextGuardAndCollisionTrapCopy() {
    #expect(
      LiveCatbirdIntelligenceService.isAccountContextActive(
        expectedDID: "did:plc:synthacct1",
        activeUserDID: "did:plc:synthacct1",
        isAccountSwitchSuspended: false,
        isSameClient: true,
        clientDID: "did:plc:synthacct1"
      ) == true
    )
    #expect(
      LiveCatbirdIntelligenceService.isAccountContextActive(
        expectedDID: "",
        activeUserDID: "",
        isAccountSwitchSuspended: false,
        isSameClient: true,
        clientDID: ""
      ) == false
    )
    #expect(
      LiveCatbirdIntelligenceService.isAccountContextActive(
        expectedDID: "did:plc:synthacct1",
        activeUserDID: "did:plc:synthacct1",
        isAccountSwitchSuspended: true,
        isSameClient: true,
        clientDID: "did:plc:synthacct1"
      ) == false
    )
    #expect(
      LiveCatbirdIntelligenceService.isAccountContextActive(
        expectedDID: "did:plc:synthacct1",
        activeUserDID: "did:plc:synthacct2",
        isAccountSwitchSuspended: false,
        isSameClient: true,
        clientDID: "did:plc:synthacct1"
      ) == false
    )
    #expect(
      LiveCatbirdIntelligenceService.isAccountContextActive(
        expectedDID: "did:plc:synthacct1",
        activeUserDID: "did:plc:synthacct1",
        isAccountSwitchSuspended: false,
        isSameClient: false,
        clientDID: "did:plc:synthacct1"
      ) == false
    )
    #expect(
      LiveCatbirdIntelligenceService.isAccountContextActive(
        expectedDID: "did:plc:synthacct1",
        activeUserDID: "did:plc:synthacct1",
        isAccountSwitchSuspended: false,
        isSameClient: true,
        clientDID: "did:plc:synthacct2"
      ) == false
    )

    #expect(
      TasteCalibrationBeatView.duelKindSubtitle(for: "collision_trap")
        .contains("Disambiguates lookalike search terms")
    )
    #expect(
      TasteCalibrationBeatView.duelKindSubtitle(for: "subscene_split")
        .contains("neighboring sub-communities")
    )
  }
}
