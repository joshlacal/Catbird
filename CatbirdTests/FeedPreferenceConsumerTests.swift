import Foundation
import Petrel
import Testing
@testable import Catbird

@MainActor
struct FeedPreferenceConsumerTests {
  @Test("Complete muted-word metadata reaches both feed and post predicates")
  func metadataReachesPredicates() throws {
    let service = ContentFilterService()
    let post = try fixturePost(text: "A needle in this post")
    var settings = FeedTunerSettings.default
    settings.mutedWords = [MutedWord(id: "one", value: "needle", targets: ["tag"], actorTarget: nil, expiresAt: nil)]
    #expect(service.shouldShowFeedViewPost(post, settings: settings))
    settings.mutedWords = [MutedWord(id: "one", value: "needle", targets: ["content"], actorTarget: nil, expiresAt: nil)]
    #expect(!service.shouldShowFeedViewPost(post, settings: settings))
    #expect(!service.shouldShowPostView(post.post, settings: settings))
    settings.mutedWords = [MutedWord(id: "one", value: "needle", targets: ["content"], actorTarget: nil, expiresAt: Date(timeIntervalSince1970: 0))]
    #expect(service.shouldShowFeedViewPost(post, settings: settings))
    settings.mutedWords = []
    #expect(service.shouldShowFeedViewPost(post, settings: settings))
  }

  @Test("The retained text/media conflict is effective in the ordinary feed predicate")
  func contentConflict() throws {
    let post = try fixturePost(text: "Text")
    let settings = settings(textOnly: true, mediaOnly: true)
    #expect(!ContentFilterService().shouldShowFeedViewPost(post, settings: settings))
  }

  @Test("Hide replies retains the current user's own reply exception")
  func ownReplyException() throws {
    let own = try fixturePost(text: "Reply")
    let parent = try fixturePost(text: "Parent").post
    let reply = AppBskyFeedDefs.FeedViewPost(post: own.post,
      reply: .init(root: .appBskyFeedDefsPostView(parent), parent: .appBskyFeedDefsPostView(parent), grandparentAuthor: nil),
      reason: nil, feedContext: nil, reqId: nil)
    #expect(ContentFilterService().shouldShowFeedViewPost(reply, settings: settings(hideReplies: true)))
  }

  @Test("Confirmed snapshots copy collection values instead of following a pending mutable model")
  func confirmedSnapshotIsIndependent() {
    let prefs = Preferences(accountDID: "fixture")
    prefs.adultContentEnabled = true
    prefs.mutedWords = [MutedWord(id: "word", value: "retained", targets: ["tag"], actorTarget: "exclude-following", expiresAt: nil)]
    let snapshot = FeedPreferenceSnapshot(prefs)
    prefs.mutedWords = []
    prefs.adultContentEnabled = false
    #expect(snapshot.mutedWords.count == 1)
    #expect(snapshot.mutedWords[0].targets == ["tag"])
    #expect(snapshot.mutedWords[0].actorTarget == "exclude-following")
    #expect(snapshot.adultContentEnabled)
  }

  private func settings(textOnly: Bool = false, mediaOnly: Bool = false, hideReplies: Bool = false) -> FeedTunerSettings {
    FeedTunerSettings(hideReplies: hideReplies, hideRepliesByUnfollowed: false, hideRepliesByLikeCount: nil,
      hideReposts: false, hideQuotePosts: false, hideNonPreferredLanguages: false, preferredLanguages: [],
      mutedUsers: [], blockedUsers: [], hideLinks: false, onlyTextPosts: textOnly, onlyMediaPosts: mediaOnly,
      contentLabelPreferences: [], hideAdultContent: false, hiddenPosts: [], currentUserDid: "did:plc:fixture")
  }

  private func fixturePost(text: String) throws -> AppBskyFeedDefs.FeedViewPost {
    let record = AppBskyFeedPost(text: text, entities: nil, facets: nil, reply: nil, embed: nil,
      langs: nil, labels: nil, tags: nil, createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)))
    let author = AppBskyActorDefs.ProfileViewBasic(did: try DID(didString: "did:plc:fixture"),
      handle: try Handle(handleString: "author.test"), displayName: "Fixture", pronouns: nil, avatar: nil,
      associated: nil, viewer: nil, labels: nil, createdAt: nil, verification: nil, status: nil, debug: nil)
    let post = AppBskyFeedDefs.PostView(uri: try ATProtocolURI(uriString: "at://did:plc:fixture/app.bsky.feed.post/one"),
      cid: CID.fromDAGCBOR(Data("cid-fixture".utf8)), author: author, record: .knownType(record), embed: nil,
      bookmarkCount: nil, replyCount: 0, repostCount: 0, likeCount: 0, quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)), viewer: nil, labels: nil, threadgate: nil, debug: nil)
    return .init(post: post, reply: nil, reason: nil, feedContext: nil, reqId: nil)
  }
}
