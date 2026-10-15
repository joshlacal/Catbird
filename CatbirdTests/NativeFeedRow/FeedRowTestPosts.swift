#if os(iOS)
import Foundation
import Petrel
import Testing
@testable import Catbird

// MARK: - Feed Row Test Posts

/// Fixture posts for native feed row tests, built like `FeedSnapshotUpdateTests.makePost`.
/// Extend `cachedPost` with more defaulted parameters rather than adding new builders.
@MainActor
enum FeedRowTestPosts {
  /// A timeline entry for one text post. The optional parameters switch on the
  /// features the native-row classifier looks at; every default is a plain post.
  /// `postKey` is the record key of the post's URI, so tests can tell two fixture posts apart.
  static func cachedPost(
    text: String = "Feed fixture", likeCount: Int = 0, displayName: String = "Fixture",
    langs: [String]? = nil, withImageEmbed: Bool = false, asReply: Bool = false,
    asRepost: Bool = false, asPin: Bool = false, tags: [String]? = nil, pronouns: String? = nil,
    selfDeclaredBot: Bool = false, pinned: Bool = false, authorBlockedViewer: Bool = false,
    authorIsLive: Bool = false, facets: [AppBskyRichtextFacet]? = nil, postKey: String = "one",
    authorDID: String = "did:plc:fixture"
  ) throws -> CachedFeedViewPost {
    let did = try DID(didString: authorDID)
    let viewer = authorBlockedViewer ? AppBskyActorDefs.ViewerState(blockedBy: true) : nil
    let labels = selfDeclaredBot
      ? [ComAtprotoLabelDefs.Label(
        src: did, uri: URI(uriString: did.didString()), val: "bot", cts: ATProtocolDate(date: Date(timeIntervalSince1970: 0)))]
      : nil
    let status = authorIsLive
      ? AppBskyActorDefs.StatusView(
        status: "app.bsky.actor.status#live", record: .null, isActive: true)
      : nil
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: did, handle: try Handle(handleString: "author.test"), displayName: displayName,
      pronouns: pronouns, avatar: nil, associated: nil, viewer: viewer, labels: labels,
      createdAt: nil, verification: nil, status: status, debug: nil)
    let post = try postView(
      uri: "at://did:plc:fixture/app.bsky.feed.post/\(postKey)", text: text, likeCount: likeCount,
      author: author, langs: langs, tags: tags, facets: facets,
      embed: withImageEmbed ? imageEmbed : nil,
      viewerState: pinned ? AppBskyFeedDefs.ViewerState(pinned: true) : nil)

    var reply: AppBskyFeedDefs.ReplyRef?
    if asReply {
      let parent = try postView(
        uri: "at://did:plc:fixture/app.bsky.feed.post/parent", text: "Parent", likeCount: 0,
        author: author, langs: nil, tags: nil, facets: nil, embed: nil, viewerState: nil)
      reply = AppBskyFeedDefs.ReplyRef(root: .appBskyFeedDefsPostView(parent), parent: .appBskyFeedDefsPostView(parent))
    }
    var reason: AppBskyFeedDefs.FeedViewPostReasonUnion?
    if asRepost {
      reason = .appBskyFeedDefsReasonRepost(
        AppBskyFeedDefs.ReasonRepost(by: author, indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0))))
    } else if asPin {
      reason = .appBskyFeedDefsReasonPin(AppBskyFeedDefs.ReasonPin())
    }
    let decoded = AppBskyFeedDefs.FeedViewPost(
      post: post, reply: reply, reason: reason, feedContext: nil, reqId: nil)
    return try #require(CachedFeedViewPost(from: decoded, feedType: "timeline"))
  }

  /// A timeline entry whose post record is not an `app.bsky.feed.post`.
  static func cachedPostWithForeignRecord() throws -> CachedFeedViewPost {
    let source = try cachedPost()
    let item = try source.feedViewPost
    let post = item.post
    let foreign = AppBskyFeedDefs.PostView(
      uri: post.uri, cid: post.cid, author: post.author, record: .string("not a post record"),
      embed: nil, bookmarkCount: nil, replyCount: 0, repostCount: 0, likeCount: 0, quoteCount: nil,
      indexedAt: post.indexedAt, viewer: nil, labels: nil, threadgate: nil, debug: nil)
    let decoded = AppBskyFeedDefs.FeedViewPost(
      post: foreign, reply: nil, reason: nil, feedContext: nil, reqId: nil)
    return try #require(CachedFeedViewPost(from: decoded, feedType: "timeline"))
  }

  // MARK: - Builders

  private static let imageEmbed: AppBskyFeedDefs.PostViewEmbedUnion = .appBskyEmbedImagesView(
    AppBskyEmbedImages.View(images: [
      AppBskyEmbedImages.ViewImage(
        thumb: URI(uriString: "https://cdn.example.test/thumb.jpg"),
        fullsize: URI(uriString: "https://cdn.example.test/full.jpg"),
        alt: "An image", aspectRatio: AppBskyEmbedDefs.AspectRatio(width: 4, height: 3))
    ]))

  private static func postView(
    uri: String, text: String, likeCount: Int, author: AppBskyActorDefs.ProfileViewBasic,
    langs: [String]?, tags: [String]?, facets: [AppBskyRichtextFacet]?, embed: AppBskyFeedDefs.PostViewEmbedUnion?,
    viewerState: AppBskyFeedDefs.ViewerState?
  ) throws -> AppBskyFeedDefs.PostView {
    let record = AppBskyFeedPost(
      text: text, entities: nil, facets: facets, reply: nil, embed: nil,
      langs: langs?.map { LanguageCodeContainer(languageCode: $0) }, labels: nil, tags: tags,
      createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)))
    return AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(uriString: uri),
      cid: CID.fromDAGCBOR(Data(uri.utf8)), author: author,
      record: .knownType(record), embed: embed, bookmarkCount: nil,
      replyCount: 0, repostCount: 0, likeCount: likeCount, quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)),
      viewer: viewerState, labels: nil, threadgate: nil, debug: nil)
  }

  /// Content signature of the fixed fixture post.
  static func signature() throws -> FeedPostContentSignature {
    FeedPostContentSignature(try cachedPost())
  }
}
#endif
