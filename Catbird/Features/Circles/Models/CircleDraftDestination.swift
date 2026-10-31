import Foundation
import Petrel
import PetrelCatbird

/// The Circle a saved composer draft was written for, stored beside its content.
///
/// A draft without one is Public, which is how every draft saved before this
/// existed restores. Identifiers are kept as text so the saved JSON does not
/// depend on generated lexicon types.
struct CircleDraftDestination: Codable, Hashable, Sendable {
  /// The thread a Circle reply belongs to.
  struct Reply: Codable, Hashable, Sendable {
    let rootURI: String
    let rootCID: String
    let parentURI: String
    let parentCID: String

    init(_ ref: AppBskyFeedPost.ReplyRef) {
      rootURI = ref.root.uri.uriString()
      rootCID = ref.root.cid.string
      parentURI = ref.parent.uri.uriString()
      parentCID = ref.parent.cid.string
    }

    /// The references as a post record carries them, or nil when one no longer parses.
    var ref: AppBskyFeedPost.ReplyRef? {
      guard let rootURI = try? ATProtocolURI(uriString: self.rootURI),
            let rootCID = try? CID.parse(self.rootCID),
            let parentURI = try? ATProtocolURI(uriString: self.parentURI),
            let parentCID = try? CID.parse(self.parentCID) else { return nil }
      return AppBskyFeedPost.ReplyRef(
        root: ComAtprotoRepoStrongRef(uri: rootURI, cid: rootCID),
        parent: ComAtprotoRepoStrongRef(uri: parentURI, cid: parentCID)
      )
    }
  }

  /// The account the Circle belongs to. The destination never restores under another account.
  let accountDID: String
  let spaceURI: String
  let circleID: String
  let name: String
  let ownerDID: String
  var reply: Reply?

  init(circle: CircleSummary, accountDID: String, reply: Reply?) {
    self.accountDID = accountDID
    self.spaceURI = circle.uri.uriString()
    self.circleID = circle.circleId.toString()
    self.name = circle.name
    self.ownerDID = circle.owner.didString()
    self.reply = reply
  }

  /// The Circle as the composer posts to it, or nil when a stored identifier no longer parses.
  var circle: CircleSummary? {
    guard let space = try? SpaceRef(uriString: spaceURI),
          let circleID = try? TID(tidString: self.circleID),
          let owner = try? DID(didString: ownerDID) else { return nil }
    return CircleSummary(uri: space, circleId: circleID, name: name, owner: owner)
  }
}

/// Why a restored Circle draft cannot post until its author picks an audience again.
/// The draft is kept and stays private; it never falls back to Public on its own.
enum CircleDraftAudienceIssue: Equatable, Sendable {
  /// The draft was written for a Circle of another account.
  case otherAccount
  /// The Circle was deleted, or this account can no longer post to it.
  case circleUnavailable(name: String)

  var message: String {
    switch self {
    case .otherAccount:
      return "This draft was written for a Circle on another account. Choose an audience before posting."
    case .circleUnavailable(let name):
      return "The Circle “\(name)” is no longer available. Choose an audience before posting."
    }
  }
}

/// A restored Circle destination the composer could not use. The saved value is
/// written back unchanged, so the draft keeps blocking posting across restores.
struct UnresolvedCircleAudience: Equatable {
  let saved: CircleDraftDestination
  let issue: CircleDraftAudienceIssue
}

extension CircleService {
  /// The listing of `space` among this account's Circles, or nil when a complete
  /// listing does not include it. An incomplete listing throws instead.
  func listedCircle(_ space: SpaceRef, maxPages: Int = 50) async throws -> CircleSummary? {
    var cursor: String?
    var seenCursors: Set<String> = []
    for _ in 0..<maxPages {
      let page = try await listCircles(cursor: cursor)
      if let circle = page.circles.first(where: { $0.uri == space }) { return circle }
      guard let next = page.cursor else { return nil }
      guard seenCursors.insert(next).inserted else { throw CircleError.invalidResponse }
      cursor = next
    }
    throw CircleError.invalidResponse
  }
}
