import Foundation
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

// MARK: - Scene Members on Cards and in the Scene Sheet

extension OnboardingIntelligenceTests {
  /// Records the lookups a `SceneProfileStore` sends, in order.
  actor HydrateRecorder {
    private(set) var calls: [[String]] = []

    func record(_ dids: [DID]) -> [String: HydratedRecommendedProfile] {
      calls.append(dids.map { $0.didString() })
      var out: [String: HydratedRecommendedProfile] = [:]
      for did in dids {
        let key = did.didString()
        out[key] = HydratedRecommendedProfile(
          did: key,
          handle: "\(key.suffix(6)).example",
          displayName: "Member \(key.suffix(6))",
          bio: "",
          alreadyFollowing: key.hasSuffix("followed"),
          isBlockedOrMuted: key.hasSuffix("blocked")
        )
      }
      return out
    }
  }

  static let sceneCommunityId = 2704

  static func sceneMemberDIDs(_ count: Int) -> [String] {
    (0..<count).map { "did:plc:scenemember\($0)" }
  }

  static func dids(_ strings: [String]) throws -> [DID] {
    try strings.map { try DID(didString: $0) }
  }

  /// A view model whose server is live, with the scene sheet open on a scene of `memberCount`
  /// ordered members.
  @MainActor
  static func liveViewModelWithOpenSheet(
    memberCount: Int,
    configure: (MockIntelligenceService) -> Void = { _ in }
  ) async throws -> (SceneOnboardingViewModel, MockIntelligenceService, BlueCatbirdIntelDefs.CommunitySummary) {
    let mock = MockIntelligenceService()
    mock.liveMode = true
    let tiers = ["headliner", "core", "rising", nil]
    mock.peekMembers = sceneMemberDIDs(memberCount).enumerated().map { index, did in
      (did: did, tier: tiers[index % tiers.count])
    }
    configure(mock)
    let vm = SceneOnboardingViewModel(service: mock)
    let community = try makeCommunity(id: sceneCommunityId, title: "iOS & SwiftUI Builders")
    await vm.openPeek(for: community)
    return (vm, mock, community)
  }

  // MARK: - Profile Store

  @Test("Profile store looks accounts up in batches of 25 and only once each")
  @MainActor
  func profileStoreBatchesAndCaches() async throws {
    let recorder = HydrateRecorder()
    let store = SceneProfileStore { dids in await recorder.record(dids) }
    let members = try Self.dids(Self.sceneMemberDIDs(30))

    #expect(!store.isSettled(members[0]))
    await store.load(members)
    #expect(await recorder.calls.map(\.count) == [25, 5])
    #expect(store.loadingDIDs.isEmpty)
    #expect(members.allSatisfy { store.isSettled($0) })

    await store.load(members)
    store.request(Array(members.prefix(10)))
    await store.flush()
    #expect(await recorder.calls.count == 2)
  }

  @Test("Profile store sends requests made in the same moment as one lookup")
  @MainActor
  func profileStoreCoalescesRequests() async throws {
    let recorder = HydrateRecorder()
    let store = SceneProfileStore(coalescingDelay: .zero) { dids in await recorder.record(dids) }
    let first = try Self.dids(["did:plc:cardone1", "did:plc:cardone2"])
    let second = try Self.dids(["did:plc:cardtwo1", "did:plc:cardone2"])

    store.request(first)
    store.request(second)
    #expect(store.loadingDIDs.count == 3)
    for _ in 0..<200 where !store.loadingDIDs.isEmpty {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(store.loadingDIDs.isEmpty)
    #expect(await recorder.calls == [["did:plc:cardone1", "did:plc:cardone2", "did:plc:cardtwo1"]])
  }

  @Test("Profile store marks an account settled even when the lookup does not find it")
  @MainActor
  func profileStoreSettlesMissingAccounts() async throws {
    let store = SceneProfileStore { _ in [:] }
    let missing = try DID(didString: "did:plc:gonemember1")
    await store.load([missing])
    #expect(store.isSettled(missing))
    #expect(store.profilesByDID.isEmpty)
    #expect(store.profilesToFollow(for: [missing]).isEmpty)
  }

  @Test("Profiles to follow keep the given order and leave out followed and blocked accounts")
  @MainActor
  func profileStoreFiltersFollowedAndBlocked() async throws {
    let recorder = HydrateRecorder()
    let store = SceneProfileStore { dids in await recorder.record(dids) }
    let ordered = try Self.dids([
      "did:plc:memberc",
      "did:plc:memberfollowed",
      "did:plc:membera",
      "did:plc:memberblocked",
      "did:plc:memberb"
    ])
    await store.load(ordered)
    let kept = store.profilesToFollow(for: ordered).map(\.did)
    #expect(kept == ["did:plc:memberc", "did:plc:membera", "did:plc:memberb"])
  }

  @Test("Profile store asks again for accounts whose lookup failed outright")
  @MainActor
  func profileStoreRetriesFailedLookups() async throws {
    actor Flaky {
      var calls = 0
      func answer(_ dids: [DID]) -> [String: HydratedRecommendedProfile] {
        calls += 1
        guard calls > 1 else { return [:] }
        var out: [String: HydratedRecommendedProfile] = [:]
        for did in dids {
          let key = did.didString()
          out[key] = HydratedRecommendedProfile(did: key, handle: "member.example", displayName: "Member", bio: "")
        }
        return out
      }
    }
    let flaky = Flaky()
    let store = SceneProfileStore { dids in await flaky.answer(dids) }
    let member = try DID(didString: "did:plc:flakymember1")
    await store.load([member])
    #expect(store.profilesByDID.isEmpty)
    await store.load([member])
    #expect(store.profilesByDID["did:plc:flakymember1"] != nil)
    #expect(await flaky.calls == 2)
  }

  @Test("An account swapped out of the lineup is not offered again in the scene sheet")
  func peekSectionsLeaveOutSwappedAccounts() throws {
    let members = try Self.sceneMemberDIDs(8).map { did in
      BlueCatbirdIntelDefs.CommunityMemberRef(
        did: try DID(didString: did),
        role: "community_member",
        recommendedMode: "follow_all",
        whyPicked: "Posts often",
        rankScoreBps: 5000,
        repostShareBps: 1000,
        mediaShareBps: 2000,
        estimatedPostsPerWeek: 5
      )
    }
    let swapped = Self.sceneMemberDIDs(8)[1]
    let sections = SceneOnboardingViewModel.splitPeekMembers(
      members,
      lineupCount: 6,
      profilesByDID: [:],
      excludedDIDs: [swapped]
    )
    #expect(sections.lineup.count == 6)
    #expect(sections.more.count == 1)
    #expect(!(sections.lineup + sections.more).contains { $0.did.didString() == swapped })
  }

  // MARK: - Scene Sheet Sections

  @Test("Opening a scene looks up its first 25 members in one batch")
  @MainActor
  func openPeekHydratesFirstMemberBatch() async throws {
    let (vm, mock, _) = try await Self.liveViewModelWithOpenSheet(memberCount: 30)
    #expect(mock.hydrateCalls.count == 1)
    #expect(mock.hydrateCalls.first == Array(Self.sceneMemberDIDs(30).prefix(25)))
    #expect(vm.activePeek?.members.count == 30)
    #expect(vm.activePeek?.defaultLineupCount == 6)
    #expect(vm.activePeek?.boostedLineupCount == 12)
  }

  @Test("Rows further down the sheet look up the batch that holds them")
  @MainActor
  func peekRowRequestsItsBatch() async throws {
    let (vm, mock, _) = try await Self.liveViewModelWithOpenSheet(memberCount: 30)
    let members = Self.sceneMemberDIDs(30)

    vm.requestPeekProfiles(aroundMember: members[27])
    await vm.sceneProfiles.flush()
    #expect(mock.hydrateCalls.count == 2)
    #expect(mock.hydrateCalls.last == Array(members[25..<30]))

    vm.requestPeekProfiles(aroundMember: members[3])
    vm.requestPeekProfiles(aroundMember: members[29])
    await vm.sceneProfiles.flush()
    #expect(mock.hydrateCalls.count == 2)
  }

  @Test("The sheet splits members at the lineup size for an unpicked and a picked scene")
  @MainActor
  func peekSectionsSplitAtDefaultLineup() async throws {
    let (vm, _, community) = try await Self.liveViewModelWithOpenSheet(memberCount: 30)
    let members = Self.sceneMemberDIDs(30)

    let unpicked = try #require(vm.peekMemberSections)
    #expect(unpicked.lineupCount == 6)
    #expect(unpicked.lineup.map { $0.did.didString() } == Array(members.prefix(6)))
    #expect(unpicked.more.map { $0.did.didString() } == Array(members.dropFirst(6)))
    #expect(vm.peekLineupHeading(count: unpicked.lineup.count) == "Joins your lineup if picked (6)")

    vm.toggleCommunity(community)
    let picked = try #require(vm.peekMemberSections)
    #expect(picked.lineup.count == 6)
    #expect(picked.more.count == 24)
    #expect(vm.peekLineupHeading(count: picked.lineup.count) == "In your lineup (6)")
  }

  @Test("Hearting the scene with the sheet open moves the split to the boosted lineup")
  @MainActor
  func peekSectionsFollowHeartBoost() async throws {
    let (vm, _, community) = try await Self.liveViewModelWithOpenSheet(memberCount: 30)
    let members = Self.sceneMemberDIDs(30)

    vm.toggleHeartBoost(for: community)
    #expect(vm.selectionWeight(for: Self.sceneCommunityId) == 2)
    let hearted = try #require(vm.peekMemberSections)
    #expect(hearted.lineupCount == 12)
    #expect(hearted.lineup.map { $0.did.didString() } == Array(members.prefix(12)))
    #expect(hearted.more.count == 18)
    #expect(vm.peekLineupHeading(count: hearted.lineup.count) == "In your lineup (12)")

    vm.toggleHeartBoost(for: community)
    #expect(vm.selectionWeight(for: Self.sceneCommunityId) == 1)
    #expect(vm.peekMemberSections?.lineup.count == 6)
  }

  @Test("Followed and blocked members leave both sections and the next member fills the lineup")
  @MainActor
  func peekSectionsSkipFollowedAndBlocked() async throws {
    let members = Self.sceneMemberDIDs(30)
    let (vm, _, _) = try await Self.liveViewModelWithOpenSheet(memberCount: 30) { mock in
      mock.followedDIDs = [members[1]]
      mock.blockedDIDs = [members[3]]
    }

    let sections = try #require(vm.peekMemberSections)
    let lineup = sections.lineup.map { $0.did.didString() }
    let more = sections.more.map { $0.did.didString() }
    #expect(lineup == [members[0], members[2], members[4], members[5], members[6], members[7]])
    #expect(more.count == 22)
    #expect(!more.contains(members[1]))
    #expect(!more.contains(members[3]))
  }

  @Test("A server that reports no lineup size puts every member in one list")
  func peekSectionsWithoutLineupCount() throws {
    let members = try Self.sceneMemberDIDs(4).map { did in
      BlueCatbirdIntelDefs.CommunityMemberRef(
        did: try DID(didString: did),
        role: "community_member",
        recommendedMode: "follow_all",
        whyPicked: "Posts often",
        rankScoreBps: 5000,
        repostShareBps: 1000,
        mediaShareBps: 2000,
        estimatedPostsPerWeek: 5
      )
    }
    let sections = SceneOnboardingViewModel.splitPeekMembers(members, lineupCount: nil, profilesByDID: [:])
    #expect(sections.lineup.isEmpty)
    #expect(sections.more.count == 4)
    #expect(sections.lineupCount == nil)

    let oversized = SceneOnboardingViewModel.splitPeekMembers(members, lineupCount: 12, profilesByDID: [:])
    #expect(oversized.lineup.count == 4)
    #expect(oversized.more.isEmpty)
  }

  // MARK: - Scene Card Faces

  @Test("Cards from a live server show the first six accounts a pick follows")
  @MainActor
  func cardFacesFromLiveServer() async throws {
    let samples = (0..<7).map { "did:plc:sampleface\($0)" }
    let (vm, mock, _) = try await Self.liveViewModelWithOpenSheet(memberCount: 6) { mock in
      mock.peekSampleAccountDids = samples
      mock.followedDIDs = [samples[2]]
    }
    let community = try #require(vm.activePeek?.community)
    #expect(community.alreadyFollowingCount == 2)

    let before = vm.sampleFaces(for: community)
    #expect(before.profiles.isEmpty)
    #expect(before.loadingCount == 6)
    #expect(!before.isEmpty)

    vm.requestSampleProfiles(for: community)
    await vm.sceneProfiles.flush()
    #expect(mock.hydrateCalls.last == Array(samples.prefix(6)))

    let after = vm.sampleFaces(for: community)
    #expect(after.loadingCount == 0)
    #expect(after.profiles.map(\.did) == [samples[0], samples[1], samples[3], samples[4], samples[5]])
    #expect(
      SceneCardFacesRow.accessibilitySummary(for: after)
        == "You'll follow Creator eface0, Creator eface1, Creator eface3, Creator eface4 and Creator eface5"
    )
  }

  @Test("Cards from an older server show no faces and look nothing up")
  @MainActor
  func cardFacesFromOlderServer() async throws {
    let mock = MockIntelligenceService()
    let vm = SceneOnboardingViewModel(service: mock)
    let community = try Self.makeCommunity(
      id: 497,
      title: "iOS & SwiftUI Builders",
      sampleAccountDids: ["did:plc:sampleface0", "did:plc:sampleface1"]
    )
    #expect(!vm.isLiveEngine)
    #expect(vm.sampleFaces(for: community) == .none)
    vm.requestSampleProfiles(for: community)
    await vm.sceneProfiles.flush()
    #expect(mock.hydrateCalls.isEmpty)
  }

  @Test("Card faces read as one sentence to VoiceOver")
  func cardFacesAccessibilitySummary() {
    func faces(_ names: [String]) -> SceneOnboardingViewModel.SceneCardFaces {
      SceneOnboardingViewModel.SceneCardFaces(
        profiles: names.map { HydratedRecommendedProfile(did: "did:plc:\($0)", handle: $0, displayName: $0, bio: "") },
        loadingCount: 0
      )
    }
    #expect(SceneCardFacesRow.accessibilitySummary(for: faces([])) == nil)
    #expect(SceneCardFacesRow.accessibilitySummary(for: faces(["Ada"])) == "You'll follow Ada")
    #expect(SceneCardFacesRow.accessibilitySummary(for: faces(["Ada", "Ben"])) == "You'll follow Ada and Ben")
    #expect(
      SceneCardFacesRow.accessibilitySummary(for: faces(["Ada", "Ben", "Cy"])) == "You'll follow Ada, Ben and Cy"
    )
  }

  // MARK: - Copy

  @Test("The already-following line appears only for a positive count")
  func alreadyFollowingLineCopy() {
    #expect(SceneOnboardingViewModel.alreadyFollowingLine(count: nil) == nil)
    #expect(SceneOnboardingViewModel.alreadyFollowingLine(count: 0) == nil)
    #expect(SceneOnboardingViewModel.alreadyFollowingLine(count: 3) == "You already follow 3 here")
  }

  @Test("Member tiers read in the lineup's own terms")
  func tierLabelCopy() {
    #expect(SceneOnboardingViewModel.tierLabel("headliner") == "Headliner")
    #expect(SceneOnboardingViewModel.tierLabel("core") == "Regular")
    #expect(SceneOnboardingViewModel.tierLabel("rising") == "Rising")
    #expect(SceneOnboardingViewModel.tierLabel("unknown") == nil)
    #expect(SceneOnboardingViewModel.tierLabel(nil) == nil)
  }

  @Test("Pace options state account counts for an older server and delivery for a live one")
  @MainActor
  func paceWordingFollowsEngine() async throws {
    let oldVM = SceneOnboardingViewModel(service: MockIntelligenceService())
    #expect(oldVM.paceSubtitle(for: .value_calm) == "~18 voices")
    #expect(oldVM.paceSubtitle(for: .value_balanced) == "~25 voices")
    #expect(oldVM.paceSubtitle(for: .value_lively) == "~34 voices")
    #expect(oldVM.paceFootnote == nil)

    let (liveVM, _, _) = try await Self.liveViewModelWithOpenSheet(memberCount: 1)
    #expect(liveVM.isLiveEngine)
    #expect(liveVM.paceSubtitle(for: .value_calm) == "Fewer reposts")
    #expect(liveVM.paceSubtitle(for: .value_balanced) == "Every post")
    #expect(liveVM.paceSubtitle(for: .value_lively) == "Every post")
    #expect(liveVM.paceFootnote == "Pace changes how much you see from heavy reposters, never who you follow.")

    liveVM.originalsOnlyForHeavyReposters = false
    #expect(liveVM.paceSubtitle(for: .value_calm) == "Every post")
    for option in [BlueCatbirdOnboardingDefs.BundleControlsPace.value_calm, .value_balanced, .value_lively] {
      #expect(!liveVM.paceSubtitle(for: option).contains("voices"))
    }
  }
}
