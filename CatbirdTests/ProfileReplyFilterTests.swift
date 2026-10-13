import Foundation
import Petrel
import Testing

@testable import Catbird

/// The Replies tab keeps replies to other people. The rule compares a reply's parent with the
/// reply's own author, never with the screen's route, which can be a handle while the profile is
/// still loading. Because `isReplyToOthers` takes no route at all, that independence is
/// structural; these cases pin the rule itself.
@Suite("Profile replies filter")
struct ProfileReplyFilterTests {
  private static let profileDID = "did:plc:profile"
  private static let otherDID = "did:plc:someone-else"

  @Test("A reply continuing the profile's own thread is left out")
  func selfThreadReplyIsExcluded() throws {
    let item = try Self.reply(parent: .appBskyFeedDefsPostView(Self.post("parent", by: Self.profileDID)))
    #expect(!ProfileViewModel.isReplyToOthers(item))
  }

  @Test("A reply to another account is kept")
  func replyToOtherIsKept() throws {
    let item = try Self.reply(parent: .appBskyFeedDefsPostView(Self.post("parent", by: Self.otherDID)))
    #expect(ProfileViewModel.isReplyToOthers(item))
  }

  @Test("A reply whose parent is missing or blocked is kept")
  func unavailableParentIsKept() throws {
    let parentURI = try ATProtocolURI(uriString: "at://\(Self.otherDID)/app.bsky.feed.post/parent")
    let missing = try Self.reply(parent: .appBskyFeedDefsNotFoundPost(.init(uri: parentURI, notFound: true)))
    let blocked = try Self.reply(parent: .appBskyFeedDefsBlockedPost(.init(
      uri: parentURI, blocked: true, author: .init(did: try DID(didString: Self.otherDID))
    )))

    #expect(ProfileViewModel.isReplyToOthers(missing))
    #expect(ProfileViewModel.isReplyToOthers(blocked))
  }

  /// Another account's reply to the profile, reposted by the profile: its parent is by
  /// someone other than its author, so only the repost check leaves it out.
  @Test("A repost of a reply is left out")
  func repostIsExcluded() throws {
    let reason = AppBskyFeedDefs.FeedViewPostReasonUnion.appBskyFeedDefsReasonRepost(
      AppBskyFeedDefs.ReasonRepost(
        by: try ProfilePostIdentityTests.makeProfile(did: Self.profileDID),
        uri: nil, cid: nil, indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_750_000_000))
      )
    )
    let item = try Self.reply(
      parent: .appBskyFeedDefsPostView(Self.post("parent", by: Self.profileDID)), reason: reason, author: Self.otherDID
    )
    #expect(!ProfileViewModel.isReplyToOthers(item))
  }

  @Test("A top-level post is left out")
  func topLevelPostIsExcluded() throws {
    let item = AppBskyFeedDefs.FeedViewPost(
      post: try Self.post("top", by: Self.profileDID), reply: nil, reason: nil, feedContext: nil, reqId: nil
    )
    #expect(!ProfileViewModel.isReplyToOthers(item))
  }

  // MARK: - Fixtures

  private static func post(_ rkey: String, by did: String) throws -> AppBskyFeedDefs.PostView {
    PublicPostTestFixtures.makePostView(
      uri: try ATProtocolURI(uriString: "at://\(did)/app.bsky.feed.post/\(rkey)"),
      authorDID: try DID(didString: did)
    )
  }

  private static func reply(
    parent: AppBskyFeedDefs.ReplyRefParentUnion,
    reason: AppBskyFeedDefs.FeedViewPostReasonUnion? = nil,
    author: String = profileDID
  ) throws -> AppBskyFeedDefs.FeedViewPost {
    let root = AppBskyFeedDefs.ReplyRefRootUnion.appBskyFeedDefsPostView(try post("root", by: otherDID))
    return AppBskyFeedDefs.FeedViewPost(
      post: try post("reply", by: author),
      reply: AppBskyFeedDefs.ReplyRef(root: root, parent: parent),
      reason: reason,
      feedContext: nil,
      reqId: nil
    )
  }
}
