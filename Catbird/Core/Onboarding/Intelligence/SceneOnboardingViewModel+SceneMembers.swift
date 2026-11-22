import Foundation
import Petrel
import PetrelCatbird

// MARK: - Scene Members on Cards and in the Scene Sheet

extension SceneOnboardingViewModel {
  /// How many of a scene's accounts its card shows. A live server puts the accounts a pick follows
  /// first, so these faces are the start of what picking the scene adds to the lineup.
  public static let cardFaceCount = 6

  /// The scene sheet's member list split where the lineup stops: the accounts a pick follows, then
  /// the rest of the scene.
  public struct PeekMemberSections: Sendable {
    /// Accounts picking this scene follows. Empty when the server does not report a lineup size.
    public let lineup: [BlueCatbirdIntelDefs.CommunityMemberRef]
    /// The rest of the scene, or every member when the server does not report a lineup size.
    public let more: [BlueCatbirdIntelDefs.CommunityMemberRef]
    /// The lineup size the server reported, before any accounts the viewer follows or has blocked
    /// were left out; nil when the server does not report one.
    public let lineupCount: Int?
  }

  /// The faces on a scene card: the accounts picking the scene follows, as far as their profiles
  /// are in, and how many more are still loading.
  public struct SceneCardFaces: Sendable, Equatable {
    public let profiles: [HydratedRecommendedProfile]
    public let loadingCount: Int

    public static let none = SceneCardFaces(profiles: [], loadingCount: 0)

    public var isEmpty: Bool { profiles.isEmpty && loadingCount == 0 }
  }

  /// Asks for the profiles behind a card's faces. Cards that appear together are looked up together.
  public func requestSampleProfiles(for community: BlueCatbirdIntelDefs.CommunitySummary) {
    guard isLiveEngine else { return }
    sceneProfiles.request(Array(community.sampleAccountDids.prefix(Self.cardFaceCount)))
  }

  /// The faces a card shows, in the server's order. Accounts the viewer already follows, blocks or
  /// mutes are left out, as the lineup leaves them out. Only a live server orders a scene's accounts
  /// by what a pick follows, so other servers get no faces.
  public func sampleFaces(for community: BlueCatbirdIntelDefs.CommunitySummary) -> SceneCardFaces {
    guard isLiveEngine else { return .none }
    let dids = Array(community.sampleAccountDids.prefix(Self.cardFaceCount))
    return SceneCardFaces(
      profiles: sceneProfiles.profilesToFollow(for: dids),
      loadingCount: dids.filter { !sceneProfiles.isSettled($0) }.count
    )
  }

  /// Asks for the profiles of the open sheet's members in the batch that holds `did`, so rows
  /// further down the list load as they scroll into view.
  public func requestPeekProfiles(aroundMember did: String) {
    guard let members = activePeek?.members,
          let index = members.firstIndex(where: { $0.did.didString() == did }) else { return }
    let batchStart = (index / SceneProfileStore.batchSize) * SceneProfileStore.batchSize
    let batchEnd = min(batchStart + SceneProfileStore.batchSize, members.count)
    sceneProfiles.request(members[batchStart..<batchEnd].map(\.did))
  }

  /// The open sheet's members, split where picking the scene stops adding accounts. Hearting or
  /// un-hearting the scene while the sheet is open moves the split.
  public var peekMemberSections: PeekMemberSections? {
    guard let peek = activePeek else { return nil }
    let weight = selectionWeight(for: peek.community.communityId)
    let lineupCount = weight >= 2 ? peek.boostedLineupCount ?? peek.defaultLineupCount : peek.defaultLineupCount
    return Self.splitPeekMembers(
      peek.members,
      lineupCount: lineupCount,
      profilesByDID: sceneProfiles.profilesByDID,
      excludedDIDs: excludedDIDs
    )
  }

  /// Splits a scene's ordered members into the accounts a pick follows and the rest.
  ///
  /// The lineup takes members in order and passes over anyone the viewer already follows or blocks
  /// or mutes, the same accounts the starting lineup leaves out, so the first section matches what
  /// the lineup shows for this scene. Those accounts appear in neither section.
  nonisolated public static func splitPeekMembers(
    _ members: [BlueCatbirdIntelDefs.CommunityMemberRef],
    lineupCount: Int?,
    profilesByDID: [String: HydratedRecommendedProfile],
    excludedDIDs: Set<String> = []
  ) -> PeekMemberSections {
    let offered = members.filter { member in
      let did = member.did.didString()
      // An account the viewer swapped out of the lineup is not offered again.
      if excludedDIDs.contains(did) { return false }
      guard let profile = profilesByDID[did] else { return true }
      return !profile.alreadyFollowing && !profile.isBlockedOrMuted
    }
    guard let lineupCount else {
      return PeekMemberSections(lineup: [], more: offered, lineupCount: nil)
    }
    let split = min(max(lineupCount, 0), offered.count)
    return PeekMemberSections(
      lineup: Array(offered[..<split]),
      more: Array(offered[split...]),
      lineupCount: lineupCount
    )
  }

  /// The heading over the sheet's first section: "In your lineup" once the scene is picked, and
  /// what picking it would add before that.
  public func peekLineupHeading(count: Int) -> String {
    guard let communityId = activePeek?.community.communityId,
          selectionWeight(for: communityId) > 0 else {
      return "Joins your lineup if picked (\(count))"
    }
    return "In your lineup (\(count))"
  }

  // MARK: - Copy

  /// What a member's tier means to a viewer: how big an account it is within its scene, in the
  /// lineup's own terms.
  nonisolated public static func tierLabel(_ tier: String?) -> String? {
    switch tier {
    case "headliner": "Headliner"
    case "core": "Regular"
    case "rising": "Rising"
    default: nil
    }
  }

  /// "You already follow N here", or nil when the server reports none or does not report a count.
  nonisolated public static func alreadyFollowingLine(count: Int?) -> String? {
    guard let count, count > 0 else { return nil }
    return "You already follow \(count) here"
  }
}
