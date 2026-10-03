import Foundation
import Petrel
import Testing
@testable import Catbird
#if canImport(UIKit)
import UIKit
#endif

@Suite("Trending topic preview safeguards", .serialized)
@MainActor
struct TrendingTopicPreviewPolicyTests {
  @Test("Hydrated JSON fixtures decode a typed post and select at most three distinct posts")
  func distinctPostsAndStableSelection() throws {
    let first = try fixture("one", author: 1, embed: images("one", count: 3))
    guard case .knownType(let value) = first.post.record else {
      Issue.record("The feed fixture must use Petrel's typed record decoder")
      return
    }
    #expect(value is AppBskyFeedPost)
    let posts = try [first, first] + (2...5).map { try fixture("post-\($0)", author: $0) }
    let preview = TrendingTopicPreviewPolicy.select(posts, context: .init())

    #expect(preview.media.count == 3)
    #expect(Set(preview.media.map(\.id)).count == 3)
    #expect(Set(preview.media.map(\.id)) == Set([first.post.uri.uriString(), uri("post-2", author: 2), uri("post-3", author: 3)]))
    #expect(preview.media.filter { $0.id == first.post.uri.uriString() }.count == 1)
    #expect(preview == TrendingTopicPreviewPolicy.select(posts, context: .init()))
  }

  @Test("Participant avatars are deduplicated by author and capped at three")
  func participantDeduplication() throws {
    let posts = try [fixture("one", author: 1), fixture("two", author: 1), fixture("three", author: 2), fixture("four", author: 3), fixture("five", author: 4)]
    let preview = TrendingTopicPreviewPolicy.select(posts, context: .init())

    #expect(preview.participants.map(\.id) == [did(1), did(2), did(3)])
    #expect(Set(preview.participants.map(\.avatar)).count == 3)
  }

  @Test("Contributor profiles match selected participants and omit unsafe or hidden feed authors")
  func contributorProfilesMatchEligibleParticipants() throws {
    let safe = try fixture("safe-participant", author: 1)
    let duplicate = try fixture("same-author", author: 1)
    let warned = try fixture("warned-participant", author: 2, postLabels: [label("porn")])
    let hidden = try fixture("hidden-participant", author: 3)
    let blocked = try fixture("blocked-participant", author: 4)
    let safeSecond = try fixture("safe-second-participant", author: 5)
    let preview = TrendingTopicPreviewPolicy.select([safe, duplicate, warned, hidden, blocked, safeSecond], context: .init(
      blockedUsers: [did(4)], hiddenPosts: [hidden.post.uri.uriString()]))

    #expect(preview.contributorProfiles.map { $0.did.didString() } == preview.participants.map(\.id))
    #expect(preview.contributorProfiles.map { $0.did.didString() } == [did(1), did(5)])
    #expect(preview.contributorProfiles == [safe.post.author, safeSecond.post.author])
  }

  @Test("Participant avatars use the CDN thumbnail size before making image requests")
  func participantAvatarThumbnail() throws {
    let post = try fixture("avatar-thumbnail", avatar: "https://cdn.bsky.app/img/avatar/plain/did:plc:previewauthor1/avatar@jpeg")
    let preview = TrendingTopicPreviewPolicy.select([post], context: .init())

    #expect(preview.participants.map(\.avatar.absoluteString) == ["https://cdn.bsky.app/img/avatar_thumbnail/plain/did:plc:previewauthor1/avatar@jpeg"])
  }

  @Test("Preview scope requires exactly the applied default and every selected labeler")
  func appliedLabelerScope() {
    let defaultLabeler = "did:plc:ar7c4by46qjdydhdevvrndac"
    let custom = "did:plc:custompreviewlabeler"
    let extra = "did:plc:extrapreviewlabeler"

    #expect(!TrendingTopicPreviewPolicy.permitsLabelerScope(local: [], applied: nil))
    #expect(!TrendingTopicPreviewPolicy.permitsLabelerScope(local: [], applied: []))
    #expect(TrendingTopicPreviewPolicy.permitsLabelerScope(local: [], applied: [defaultLabeler]))
    #expect(!TrendingTopicPreviewPolicy.permitsLabelerScope(local: [custom], applied: [custom]))
    #expect(!TrendingTopicPreviewPolicy.permitsLabelerScope(local: [custom], applied: [defaultLabeler]))
    #expect(!TrendingTopicPreviewPolicy.permitsLabelerScope(local: [custom], applied: [defaultLabeler, custom, extra]))
    #expect(!TrendingTopicPreviewPolicy.permitsLabelerScope(local: [], applied: [defaultLabeler, custom]))
    #expect(TrendingTopicPreviewPolicy.permitsLabelerScope(local: [custom, defaultLabeler, custom], applied: [custom, defaultLabeler, defaultLabeler]))
  }

  @Test("Truncating a large labeler header cannot approve previews for the omitted subscriptions")
  func truncatedLabelerScope() {
    let defaultLabeler = "did:plc:ar7c4by46qjdydhdevvrndac"
    let selected = (0..<20).map { "did:plc:previewlabeler\($0)" }

    #expect(TrendingTopicPreviewPolicy.permitsLabelerScope(local: Array(selected.prefix(19)), applied: [defaultLabeler] + Array(selected.prefix(19))))
    #expect(!TrendingTopicPreviewPolicy.permitsLabelerScope(local: selected, applied: [defaultLabeler] + Array(selected.prefix(19))))
  }

  @Test("Existing topic contributors obey author labels and local graph decisions")
  func contributorAuthorModeration() throws {
    let ordinary = try fixture("ordinary-contributor").post.author
    #expect(TrendingTopicPreviewPolicy.permitsAuthor(ordinary, context: .init()))
    #expect(!TrendingTopicPreviewPolicy.permitsAuthor(ordinary, context: .init(mutedUsers: [did(1)])))
    #expect(!TrendingTopicPreviewPolicy.permitsAuthor(ordinary, context: .init(blockedUsers: [did(1)])))
    for value in ["porn", "!warn", "!hide", "custom-warning"] {
      let author = try fixture("labeled-contributor", authorLabels: [label(value, subject: did(1))]).post.author
      #expect(!TrendingTopicPreviewPolicy.permitsAuthor(author, context: .init()))
    }
    let inactiveAuthor = try fixture("inactive-contributor", authorLabels: [label("porn", negated: true), label("custom-warning", expiresAt: "2000-01-01T00:00:00Z")]).post.author
    #expect(TrendingTopicPreviewPolicy.permitsAuthor(inactiveAuthor, context: .init()))
  }

  @Test("Selection examines only a bounded page, even if later posts would be eligible")
  func boundedCandidatePage() throws {
    let rejected = try (0..<30).map { try fixture("warn-\($0)", postLabels: [label("porn")]) }
    let eligible = try fixture("outside-page")

    #expect(TrendingTopicPreviewPolicy.select(rejected + [eligible], context: .init()) == .init())
  }

  @Test("Image and video previews use supplied thumbnails rather than original media")
  func imageAndVideoThumbnailURLs() throws {
    let posts = try [fixture("image", embed: images("image")), fixture("video", author: 2, embed: video("video"))]
    let urls = Set(TrendingTopicPreviewPolicy.select(posts, context: .init()).media.map(\.url.absoluteString))

    #expect(urls == ["https://cdn.example.test/image-thumb-0.jpg", "https://cdn.example.test/video-still.jpg"])
    #expect(!urls.contains("https://cdn.example.test/image-original-0.jpg"))
    #expect(!urls.contains("https://video.example.test/video/playlist.m3u8"))
  }

  @Test("Missing image/video thumbnails retain a usable text and participant fallback")
  func noMediaFallback() throws {
    let posts = try [fixture("text", embed: nil), fixture("empty-images", author: 2, embed: images("empty", count: 0)), fixture("video-no-still", author: 3, embed: video("no-still", hasThumbnail: false))]
    let preview = TrendingTopicPreviewPolicy.select(posts, context: .init())

    #expect(preview.media.isEmpty)
    #expect(preview.participants.count == 3)
  }

  @Test("External link art and independently moderated quoted media are never selected")
  func externalAndQuotedMedia() throws {
    let external = try fixture("external", embed: [
      "$type": "app.bsky.embed.external#view",
      "external": ["uri": "https://external.example.test/article", "title": "Article", "description": "Description", "thumb": "https://external.example.test/art.jpg"]
    ])
    let quoted = try fixture("quoted", embed: quotedRecord())
    let quoteWithOwnMedia = try fixture("quote-with-media", embed: [
      "$type": "app.bsky.embed.recordWithMedia#view", "record": quotedRecord(), "media": images("quoted-own-media")
    ])

    #expect(TrendingTopicPreviewPolicy.select([external], context: .init()).media.isEmpty)
    #expect(TrendingTopicPreviewPolicy.select([quoted, quoteWithOwnMedia], context: .init()) == .init())
  }

  @Test("Non-HTTPS thumbnails and avatars cannot become image requests")
  func invalidImageSchemes() throws {
    let post = try fixture("insecure", embed: images("insecure", scheme: "http"), avatar: "http://cdn.example.test/avatar.jpg")

    #expect(TrendingTopicPreviewPolicy.select([post], context: .init()) == .init())
  }

  @Test("Active warning, adult, reserved and unknown custom labels suppress all preview URLs", arguments: [
    "porn", "nsfw", "sexual", "nudity", "suggestive", "gore", "violence", "graphic", "graphic-media", "corpse", "self-harm", "!hide", "!warn", "!no-promote", "custom-sensitive-media"
  ])
  func canonicalLabelsBeforeSelection(_ value: String) throws {
    let post = try fixture("labeled", postLabels: [label(value)])

    #expect(!TrendingTopicPreviewPolicy.permits(post, context: .init()))
    #expect(TrendingTopicPreviewPolicy.select([post], context: .init()) == .init())
  }

  @Test("Self-applied and account labels also suppress media and author avatars")
  func selfAndAccountLabels() throws {
    let selfLabeled = try fixture("self-labeled", selfLabels: ["porn"])
    let accountLabeled = try fixture("account-labeled", authorLabels: [label("!warn", subject: did(1))])
    let unknownSelfLabel = try fixture("custom-self-label", selfLabels: ["custom-warning"])

    for post in [selfLabeled, accountLabeled, unknownSelfLabel] {
      #expect(TrendingTopicPreviewPolicy.select([post], context: .init()) == .init())
    }
    #expect(TrendingTopicPreviewPolicy.select([try fixture("empty-self-labels", selfLabels: [])], context: .init()).media.count == 1)
  }

  @Test("Negated and expired labels do not suppress safe content, but any active label still does")
  func labelActivity() throws {
    let inactive = [label("porn", negated: true), label("custom-warning", expiresAt: "2000-01-01T00:00:00Z")]
    let safe = try fixture("inactive-labels", postLabels: inactive, authorLabels: inactive)
    let active = try fixture("mixed-labels", postLabels: inactive + [label("porn", expiresAt: "2999-01-01T00:00:00Z")])

    #expect(TrendingTopicPreviewPolicy.select([safe], context: .init()).media.count == 1)
    #expect(TrendingTopicPreviewPolicy.select([safe], context: .init()).participants.count == 1)
    #expect(TrendingTopicPreviewPolicy.select([active], context: .init()) == .init())
  }

  @Test("Hidden posts and local mute/block decisions suppress thumbnails and avatars")
  func localModerationBeforeSelection() throws {
    let post = try fixture("local-decision")
    let contexts = [
      TrendingTopicPreviewPolicy.Context(mutedUsers: [did(1)]),
      TrendingTopicPreviewPolicy.Context(blockedUsers: [did(1)]),
      TrendingTopicPreviewPolicy.Context(hiddenPosts: [post.post.uri.uriString()]),
      TrendingTopicPreviewPolicy.Context(allowsPost: { _ in false })
    ]
    for context in contexts {
      #expect(TrendingTopicPreviewPolicy.select([post], context: context) == .init())
    }
  }

  @Test("Server viewer relationships supplement incomplete local graph caches", arguments: ["muted", "mutedByList", "blocking", "blockingByList", "blockedBy"])
  func serverViewerModeration(_ relationship: String) throws {
    var viewer: [String: Any] = [:]
    switch relationship {
    case "muted", "blockedBy": viewer[relationship] = true
    case "blocking": viewer[relationship] = "at://did:plc:viewer/app.bsky.graph.block/one"
    default: viewer[relationship] = moderationList()
    }
    let post = try fixture("viewer-decision", authorViewer: viewer)

    #expect(!TrendingTopicPreviewPolicy.permitsAuthor(post.post.author, context: .init()))
    #expect(TrendingTopicPreviewPolicy.select([post], context: .init()) == .init())
  }

  @Test("A muted thread and unknown post record never expose preview URLs")
  func mutedThreadAndUnknownRecord() throws {
    let muted = try fixture("muted-thread", postViewer: ["threadMuted": true])
    let unknown = try fixture("unknown-record", recordType: "test.catbird.unregisteredRecord")

    #expect(TrendingTopicPreviewPolicy.select([muted, unknown], context: .init()) == .init())
  }

  @Test("Reply previews honor root/parent moderation and hidden context")
  func replyContextModeration() throws {
    let ordinary = try fixture("reply", replyParent: fixture("parent", author: 2), replyRoot: fixture("root", author: 3))
    #expect(TrendingTopicPreviewPolicy.select([ordinary], context: .init()).media.count == 1)
    #expect(TrendingTopicPreviewPolicy.select([ordinary], context: .init(mutedUsers: [did(2)])) == .init())
    #expect(TrendingTopicPreviewPolicy.select([ordinary], context: .init(blockedUsers: [did(3)])) == .init())
    #expect(TrendingTopicPreviewPolicy.select([ordinary], context: .init(hiddenPosts: [uri("parent", author: 2)])) == .init())

    let warnedRoot = try fixture("reply-warning", replyParent: fixture("parent", author: 2), replyRoot: fixture("warned-root", author: 3, postLabels: [label("porn")]))
    #expect(TrendingTopicPreviewPolicy.select([warnedRoot], context: .init()) == .init())
    let mutedContext = TrendingTopicPreviewPolicy.Context(mutedWords: [mutedWord("context-token")])
    let mutedParent = try fixture("reply-muted-word", replyParent: fixture("parent", author: 2, text: "A context-token"), replyRoot: fixture("root", author: 3))
    #expect(TrendingTopicPreviewPolicy.select([mutedParent], context: mutedContext) == .init())
    let mutedRootThread = try fixture("reply-muted-root-thread", replyParent: fixture("parent", author: 2), replyRoot: fixture("root", author: 3, postViewer: ["threadMuted": true]))
    #expect(TrendingTopicPreviewPolicy.select([mutedRootThread], context: .init()) == .init())
    let selfLabeledParent = try fixture("reply-self-labeled-parent", replyParent: fixture("parent", author: 2, selfLabels: ["nudity"]), replyRoot: fixture("root", author: 3))
    #expect(TrendingTopicPreviewPolicy.select([selfLabeledParent], context: .init()) == .init())
    let quotedParent = try fixture("reply-quoted-parent", replyParent: fixture("parent", author: 2, embed: quotedRecord()), replyRoot: fixture("root", author: 3))
    #expect(TrendingTopicPreviewPolicy.select([quotedParent], context: .init()) == .init())
  }

  @Test("A reply without hydrated parent/root context fails closed")
  func missingReplyHydration() throws {
    let post = try fixture("unhydrated-reply", unhydratedReply: true)

    #expect(TrendingTopicPreviewPolicy.select([post], context: .init()) == .init())
    #expect(TrendingTopicPreviewPolicy.select([post], context: .init(feedPreference: feedPreference(hideReplies: true))) == .init())
  }

  @Test("Feed reply and repost preferences are applied before preview art")
  func replyAndRepostPreferences() throws {
    let reply = try fixture("reply", replyParent: fixture("parent", author: 2), replyRoot: fixture("root", author: 3))
    let repost = try fixture("repost", reposter: 4)
    let hideReplies = TrendingTopicPreviewPolicy.Context(feedPreference: feedPreference(hideReplies: true))
    let lowLikes = TrendingTopicPreviewPolicy.Context(feedPreference: feedPreference(minimumLikes: 10))
    let unfollowedContext = TrendingTopicPreviewPolicy.Context(feedPreference: feedPreference(hideUnfollowedReplies: true), currentUserDID: did(9))
    let hideReposts = TrendingTopicPreviewPolicy.Context(feedPreference: feedPreference(hideReposts: true))

    #expect(TrendingTopicPreviewPolicy.select([reply], context: hideReplies) == .init())
    #expect(TrendingTopicPreviewPolicy.select([reply], context: lowLikes) == .init())
    #expect(TrendingTopicPreviewPolicy.select([reply], context: unfollowedContext) == .init())
    #expect(TrendingTopicPreviewPolicy.select([repost], context: hideReposts) == .init())
    #expect(TrendingTopicPreviewPolicy.select([repost], context: .init(mutedUsers: [did(4)])) == .init())

    let followedParent = try fixture("reply-followed-context", replyParent: fixture("parent-followed", author: 2, authorViewer: followingViewer()), replyRoot: fixture("root", author: 3))
    #expect(TrendingTopicPreviewPolicy.select([followedParent], context: unfollowedContext).media.count == 1)
  }

  @Test("Muted words respect content/tag targets, following scope and expiry")
  func mutedWordScopes() throws {
    let text = try fixture("text-mute", text: "A CAFÉ discussion", embed: images("text"))
    let tagged = try fixture("tag-mute", tags: ["Café"])
    let faceted = try fixture("facet-mute", facetTag: "Café")
    let content = TrendingTopicPreviewPolicy.Context(mutedWords: [mutedWord("cafe")])
    let tagOnly = TrendingTopicPreviewPolicy.Context(mutedWords: [mutedWord("#cafe", targets: ["tag"])])

    #expect(TrendingTopicPreviewPolicy.select([text], context: content) == .init())
    #expect(TrendingTopicPreviewPolicy.select([tagged, faceted], context: content) == .init())
    #expect(TrendingTopicPreviewPolicy.select([tagged, faceted], context: tagOnly) == .init())
    #expect(TrendingTopicPreviewPolicy.select([text], context: tagOnly).media.count == 1)

    let expired = TrendingTopicPreviewPolicy.Context(mutedWords: [mutedWord("cafe", expiresAt: .distantPast)])
    #expect(TrendingTopicPreviewPolicy.select([text], context: expired).media.count == 1)
    let followed = try fixture("followed", text: "A café discussion", authorViewer: followingViewer())
    let excludeFollowing = TrendingTopicPreviewPolicy.Context(mutedWords: [mutedWord("cafe", actorTarget: "exclude-following")])
    #expect(TrendingTopicPreviewPolicy.select([followed], context: excludeFollowing).media.count == 1)
    #expect(TrendingTopicPreviewPolicy.select([text], context: excludeFollowing) == .init())
    #expect(TrendingTopicPreviewPolicy.select([text], context: .init(mutedWords: [mutedWord("  ")])).media.count == 1)
  }

  @Test("Muted content described only in attached image alt text suppresses its thumbnail")
  func mutedImageAltText() throws {
    let post = try fixture("alt-text", embed: images("alt", alt: "A sensitive-token scene"))

    #expect(TrendingTopicPreviewPolicy.select([post], context: .init(mutedWords: [mutedWord("sensitive-token")])) == .init())
  }

  @Test("Only supported Bluesky feed links can initiate preview requests")
  func feedRouteValidation() {
    let path = "/profile/did:plc:trendauthor/app.bsky.feed.generator/topic"
    #expect(TrendingTopicPreviewPolicy.feedURI(for: path) == nil)
    let valid = "/profile/did:plc:trendauthor/feed/topic"
    #expect(TrendingTopicPreviewPolicy.feedURI(for: valid)?.uriString() == "at://did:plc:trendauthor/app.bsky.feed.generator/topic")
    #expect(TrendingTopicPreviewPolicy.feedURI(for: "https://bsky.app" + valid)?.uriString() == "at://did:plc:trendauthor/app.bsky.feed.generator/topic")
    for link in ["https://other.example.test" + valid, "http://bsky.app" + valid, valid + "?cursor=one", valid + "#fragment", "/topic/topic", "/profile/actor.test/feed/topic"] {
      #expect(TrendingTopicPreviewPolicy.feedURI(for: link) == nil)
    }
  }

  @Test("Cached raw posts are re-evaluated when local moderation changes without fetching again")
  func cacheReevaluatesModeration() async throws {
    let store = TrendingTopicMediaStore()
    let post = try fixture("cached")
    var fetches = 0
    await store.load(key: "topic") { fetches += 1; return [post] }
    let original = store.preview(key: "topic", context: .init())
    #expect(original.media.count == 1)
    #expect(store.preview(key: "topic", context: .init(hiddenPosts: [post.post.uri.uriString()])) == .init())
    #expect(store.preview(key: "topic", context: .init(mutedUsers: [did(1)])) == .init())
    #expect(store.preview(key: "topic", context: .init(allowsPost: { _ in false })) == .init())
    #expect(store.preview(key: "topic", context: .init()) == original)
    await store.load(key: "topic") { fetches += 1; return [] }
    #expect(fetches == 1)
  }

  @Test("Concurrent requests for the same feed coalesce into one cached fetch")
  func coalescedLoads() async throws {
    let store = TrendingTopicMediaStore()
    let source = PreviewControlledSource()
    let post = try fixture("coalesced")
    let first = Task { await store.load(key: "topic") { try await source.fetch("topic") } }
    await source.waitForRequests(1)
    let second = Task { await store.load(key: "topic") { try await source.fetch("topic") } }
    await settle()
    #expect(source.keys == ["topic"])
    source.succeed(0, posts: [post])
    await first.value
    await second.value
    #expect(source.keys == ["topic"])
    #expect(store.preview(key: "topic", context: .init()).media.count == 1)
  }

  @Test("Preview fetching admits at most two feeds and releases capacity as each completes")
  func boundedRequestFanout() async throws {
    let store = TrendingTopicMediaStore()
    let source = PreviewControlledSource()
    let post = try fixture("bounded-fetch")
    let tasks = ["one", "two", "three", "four"].map { key in
      Task { await store.load(key: key) { try await source.fetch(key) } }
    }
    await source.waitForRequests(2)
    await settle()
    #expect(source.keys.count == 2)
    source.succeed(0, posts: [post])
    await source.waitForRequests(3)
    #expect(source.keys.count == 3)
    source.succeed(1, posts: [post])
    await source.waitForRequests(4)
    source.succeed(2, posts: [post])
    source.succeed(3, posts: [post])
    for task in tasks { await task.value }
    #expect(source.maximumActiveRequests == 2)
  }

  @Test("Canceling a queued preview makes no fetch and leaves later visible requests usable")
  func queuedCancellation() async throws {
    let store = TrendingTopicMediaStore()
    let source = PreviewControlledSource()
    let post = try fixture("after-queue-cancel")
    let first = Task { await store.load(key: "one") { try await source.fetch("one") } }
    let second = Task { await store.load(key: "two") { try await source.fetch("two") } }
    await source.waitForRequests(2)
    let canceled = Task { await store.load(key: "canceled") { try await source.fetch("canceled") } }
    await settle()
    canceled.cancel()
    await canceled.value
    #expect(!source.keys.contains("canceled"))
    source.succeed(0, posts: [])
    source.succeed(1, posts: [])
    await first.value
    await second.value
    await store.load(key: "canceled") { [post] }
    #expect(store.preview(key: "canceled", context: .init()).media.count == 1)
  }

  @Test("Canceling an active request rejects its delayed result without poisoning the cache")
  func activeCancellation() async throws {
    let store = TrendingTopicMediaStore()
    let source = PreviewControlledSource()
    let post = try fixture("canceled-result")
    let canceled = Task { await store.load(key: "topic") { try await source.fetch("topic") } }
    await source.waitForRequests(1)
    canceled.cancel()
    source.succeed(0, posts: [post])
    await canceled.value
    #expect(store.preview(key: "topic", context: .init()) == .init())
    var retryFetches = 0
    await store.load(key: "topic") { retryFetches += 1; return [post] }
    #expect(retryFetches == 1)
    #expect(store.preview(key: "topic", context: .init()).media.count == 1)
  }

  @Test("A canceled request reporting a transport error cannot install a negative cache")
  func canceledFailureDoesNotPoisonCache() async throws {
    let store = TrendingTopicMediaStore()
    let source = PreviewControlledSource()
    let post = try fixture("after-canceled-error")
    let canceled = Task { await store.load(key: "topic") { try await source.fetch("topic") } }
    await source.waitForRequests(1)
    canceled.cancel()
    source.fail(0)
    await canceled.value
    var fetches = 0
    await store.load(key: "topic") { fetches += 1; return [post] }

    #expect(fetches == 1)
    #expect(store.preview(key: "topic", context: .init()).media.count == 1)
  }

  @Test("Changing accepted labelers clears art and rejects stale successful requests")
  func labelerInvalidation() async throws {
    let store = TrendingTopicMediaStore()
    let source = PreviewControlledSource()
    let post = try fixture("old-labeler-response")
    store.invalidate(labelers: "default")
    let revision = store.revision
    store.invalidate(labelers: "default")
    #expect(store.revision == revision)
    await store.load(key: "cached") { [post] }
    let pending = Task { await store.load(key: "pending") { try await source.fetch("pending") } }
    await source.waitForRequests(1)
    store.invalidate(labelers: "default,custom")
    #expect(store.revision == revision + 1)
    #expect(store.preview(key: "cached", context: .init()) == .init())
    source.succeed(0, posts: [post])
    await pending.value
    #expect(store.preview(key: "pending", context: .init()) == .init())
    var fetches = 0
    await store.load(key: "pending") { fetches += 1; return [post] }
    #expect(fetches == 1)
  }

  @Test("An obsolete failed request cannot install a negative cache in the new revision")
  func invalidationRejectsStaleFailure() async throws {
    let store = TrendingTopicMediaStore()
    let source = PreviewControlledSource()
    let post = try fixture("new-revision")
    let pending = Task { await store.load(key: "topic") { try await source.fetch("topic") } }
    await source.waitForRequests(1)
    store.invalidate(labelers: "new-labelers")
    source.fail(0)
    await pending.value
    var fetches = 0
    await store.load(key: "topic") { fetches += 1; return [post] }

    #expect(fetches == 1)
    #expect(store.preview(key: "topic", context: .init()).media.count == 1)
  }

  @Test("Graph changes clear every entry and permanently bypass the old prefetched feed")
  func graphInvalidationClearsCachedViewerState() async throws {
    let store = TrendingTopicMediaStore()
    let post = try fixture("old-viewer-state")
    await store.load(key: "one") { [post] }
    await store.load(key: "two") { [post] }
    let revision = store.revision
    #expect(store.canReusePrefetchedFeed)
    #expect(store.preview(key: "one", context: .init()).media.count == 1)
    #expect(store.preview(key: "two", context: .init()).media.count == 1)

    store.invalidateForGraphChange()

    #expect(store.revision == revision + 1)
    #expect(!store.canReusePrefetchedFeed)
    #expect(store.preview(key: "one", context: .init()) == .init())
    #expect(store.preview(key: "two", context: .init()) == .init())
    var fetches = 0
    await store.load(key: "one") { fetches += 1; return [post] }
    #expect(fetches == 1)
    #expect(store.preview(key: "one", context: .init()).media.count == 1)
    store.invalidate(labelers: "new-labelers")
    #expect(!store.canReusePrefetchedFeed)
  }

  @Test("A prefetched topic feed is consumed once per link across cache invalidation")
  func prefetchedFeedReuseOnce() {
    let store = TrendingTopicMediaStore()
    #expect(store.consumePrefetchedFeedReuse(for: "one"))
    #expect(!store.consumePrefetchedFeedReuse(for: "one"))
    #expect(store.consumePrefetchedFeedReuse(for: "two"))
    store.invalidate(labelers: "new-labelers")
    #expect(!store.consumePrefetchedFeedReuse(for: "one"))
    #expect(store.consumePrefetchedFeedReuse(for: "three"))
    store.invalidateForGraphChange()
    #expect(!store.consumePrefetchedFeedReuse(for: "four"))
  }

  @Test("Prefetched feed reuse history admits at most twenty distinct links")
  func boundedPrefetchedFeedHistory() {
    let store = TrendingTopicMediaStore()
    for index in 0..<20 { #expect(store.consumePrefetchedFeedReuse(for: "topic-\(index)")) }
    #expect(!store.consumePrefetchedFeedReuse(for: "topic-20"))
    #expect(!store.consumePrefetchedFeedReuse(for: "topic-0"))
  }

  #if canImport(UIKit)
  @Test("Returning to the foreground removes stale viewer state and rejects pending art")
  func foregroundInvalidation() async throws {
    let store = TrendingTopicMediaStore()
    let source = PreviewControlledSource()
    let post = try fixture("foreground-viewer-state")
    await store.load(key: "cached") { [post] }
    #expect(store.consumePrefetchedFeedReuse(for: "cached"))
    let pending = Task { await store.load(key: "pending") { try await source.fetch("pending") } }
    await source.waitForRequests(1)
    let revision = store.revision

    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

    #expect(store.revision == revision + 1)
    #expect(store.preview(key: "cached", context: .init()) == .init())
    #expect(!store.canReusePrefetchedFeed)
    #expect(!store.consumePrefetchedFeedReuse(for: "new-topic"))
    source.succeed(0, posts: [post])
    await pending.value
    #expect(store.preview(key: "pending", context: .init()) == .init())
    var fetches = 0
    await store.load(key: "pending") { fetches += 1; return [post] }
    #expect(fetches == 1)
    #expect(store.preview(key: "pending", context: .init()).media.count == 1)
  }
  #endif

  @Test("Graph changes reject obsolete success and error completions without blocking a fresh fetch", arguments: [false, true])
  func graphInvalidationRejectsObsoleteCompletion(fails: Bool) async throws {
    let store = TrendingTopicMediaStore()
    let source = PreviewControlledSource()
    let post = try fixture("old-graph-response")
    let pending = Task { await store.load(key: "topic") { try await source.fetch("topic") } }
    await source.waitForRequests(1)

    store.invalidateForGraphChange()
    if fails { source.fail(0) } else { source.succeed(0, posts: [post]) }
    await pending.value

    #expect(store.preview(key: "topic", context: .init()) == .init())
    #expect(!store.canReusePrefetchedFeed)
    var fetches = 0
    await store.load(key: "topic") { fetches += 1; return [post] }
    #expect(fetches == 1)
    #expect(store.preview(key: "topic", context: .init()).media.count == 1)
  }

  @Test("Each graph notification invalidates the store once before cached art can be read")
  func graphNotificationInvalidatesOnce() async throws {
    let store = TrendingTopicMediaStore()
    let post = try fixture("notification-viewer-state")
    await store.load(key: "topic") { [post] }
    let revision = store.revision

    NotificationCenter.default.post(name: NSNotification.Name("UserGraphChanged"), object: nil)

    #expect(store.revision == revision + 1)
    #expect(!store.canReusePrefetchedFeed)
    #expect(store.preview(key: "topic", context: .init()) == .init())
    await settle()
    #expect(store.revision == revision + 1)
    NotificationCenter.default.post(name: NSNotification.Name("UserGraphChanged"), object: nil)
    #expect(store.revision == revision + 2)
    await Task.detached {
      NotificationCenter.default.post(name: NSNotification.Name("UserGraphChanged"), object: nil)
    }.value
    #expect(store.revision == revision + 3)
  }

  @Test("Successful and failed preview entries share the same bounded cache")
  func failuresShareCacheCapacity() async throws {
    let store = TrendingTopicMediaStore()
    let post = try fixture("retained-success")
    await store.load(key: "safe") { [post] }
    for index in 0..<20 {
      await store.load(key: "failure-\(index)") { throw PreviewFixtureError.fetchFailed }
    }
    var fetches = 0
    await store.load(key: "failure-0") { fetches += 1; return [post] }

    #expect(fetches == 1)
    #expect(store.preview(key: "failure-0", context: .init()).media.count == 1)
    #expect(store.preview(key: "safe", context: .init()).media.count == 1)
  }

  @Test("A current fetch failure is cached as a text fallback to avoid repeated row retries")
  func currentFailureBackoff() async {
    let store = TrendingTopicMediaStore()
    var fetches = 0
    await store.load(key: "topic") { fetches += 1; throw PreviewFixtureError.fetchFailed }
    await store.load(key: "topic") { fetches += 1; return [] }

    #expect(fetches == 1)
    #expect(store.preview(key: "topic", context: .init()) == .init())
  }

  // MARK: - Hydrated protocol fixtures

  private let fixtureCID = "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"
  private let timestamp = "2026-01-01T00:00:00Z"

  private func did(_ index: Int) -> String { "did:plc:previewauthor\(index)" }
  private func uri(_ key: String, author: Int = 1) -> String { "at://\(did(author))/app.bsky.feed.post/\(key)" }

  private func fixture(
    _ key: String,
    author: Int = 1,
    text: String = "An ordinary topic post",
    embed: [String: Any]? = [
      "$type": "app.bsky.embed.images#view",
      "images": [["thumb": "https://cdn.example.test/default-thumb.jpg", "fullsize": "https://cdn.example.test/default-original.jpg", "alt": "An ordinary scene"]]
    ],
    avatar: String? = nil,
    postLabels: [[String: Any]] = [],
    selfLabels: [String]? = nil,
    authorLabels: [[String: Any]] = [],
    authorViewer: [String: Any]? = nil,
    postViewer: [String: Any]? = nil,
    tags: [String]? = nil,
    facetTag: String? = nil,
    recordType: String = "app.bsky.feed.post",
    unhydratedReply: Bool = false,
    replyParent: AppBskyFeedDefs.FeedViewPost? = nil,
    replyRoot: AppBskyFeedDefs.FeedViewPost? = nil,
    reposter: Int? = nil
  ) throws -> AppBskyFeedDefs.FeedViewPost {
    var record: [String: Any] = ["$type": recordType, "text": text, "createdAt": timestamp]
    if let selfLabels { record["labels"] = ["$type": "com.atproto.label.defs#selfLabels", "values": selfLabels.map { ["val": $0] }] }
    if let tags { record["tags"] = tags }
    if let facetTag {
      record["facets"] = [["index": ["byteStart": 0, "byteEnd": 1], "features": [["$type": "app.bsky.richtext.facet#tag", "tag": facetTag]]]]
    }
    if unhydratedReply {
      record["reply"] = ["parent": ["uri": uri("parent", author: 2), "cid": fixtureCID], "root": ["uri": uri("root", author: 3), "cid": fixtureCID]]
    }
    var profile: [String: Any] = ["did": did(author), "handle": "author\(author).test", "avatar": avatar ?? "https://cdn.example.test/avatar-\(author).jpg", "labels": authorLabels]
    if let authorViewer { profile["viewer"] = authorViewer }
    var post: [String: Any] = ["$type": "app.bsky.feed.defs#postView", "uri": uri(key, author: author), "cid": fixtureCID, "author": profile, "record": record, "indexedAt": timestamp, "likeCount": 2, "labels": postLabels]
    if let embed { post["embed"] = embed }
    if let postViewer { post["viewer"] = postViewer }
    var envelope: [String: Any] = ["post": post]
    if let replyParent, let replyRoot {
      var parent = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(replyParent.post)) as? [String: Any])
      var root = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(replyRoot.post)) as? [String: Any])
      parent["$type"] = "app.bsky.feed.defs#postView"
      root["$type"] = "app.bsky.feed.defs#postView"
      record["reply"] = ["parent": ["uri": replyParent.post.uri.uriString(), "cid": fixtureCID], "root": ["uri": replyRoot.post.uri.uriString(), "cid": fixtureCID]]
      post["record"] = record
      envelope["post"] = post
      envelope["reply"] = ["parent": parent, "root": root]
    }
    if let reposter {
      envelope["reason"] = ["$type": "app.bsky.feed.defs#reasonRepost", "by": ["did": did(reposter), "handle": "author\(reposter).test"], "indexedAt": timestamp]
    }
    return try JSONDecoder().decode(AppBskyFeedDefs.FeedViewPost.self, from: JSONSerialization.data(withJSONObject: envelope))
  }

  private func images(_ key: String, count: Int = 1, scheme: String = "https", alt: String = "An ordinary scene") -> [String: Any] {
    ["$type": "app.bsky.embed.images#view", "images": (0..<count).map { index in
      ["thumb": "\(scheme)://cdn.example.test/\(key)-thumb-\(index).jpg", "fullsize": "https://cdn.example.test/\(key)-original-\(index).jpg", "alt": alt]
    }]
  }

  private func video(_ key: String, hasThumbnail: Bool = true) -> [String: Any] {
    var result: [String: Any] = ["$type": "app.bsky.embed.video#view", "cid": fixtureCID, "playlist": "https://video.example.test/\(key)/playlist.m3u8"]
    if hasThumbnail { result["thumbnail"] = "https://cdn.example.test/\(key)-still.jpg" }
    return result
  }

  private func quotedRecord() -> [String: Any] {
    ["$type": "app.bsky.embed.record#view", "record": [
      "$type": "app.bsky.embed.record#viewRecord", "uri": uri("quoted", author: 7), "cid": fixtureCID,
      "author": ["did": did(7), "handle": "quoted.test"], "indexedAt": timestamp,
      "value": ["$type": "app.bsky.feed.post", "text": "Quoted topic", "createdAt": timestamp], "embeds": [images("quoted")]
    ]]
  }

  private func label(_ value: String, subject: String? = nil, negated: Bool = false, expiresAt: String? = nil) -> [String: Any] {
    var result: [String: Any] = ["src": "did:plc:previewlabeler", "uri": subject ?? uri("labeled"), "val": value, "cts": timestamp, "neg": negated]
    if let expiresAt { result["exp"] = expiresAt }
    return result
  }

  private func moderationList() -> [String: Any] {
    ["uri": "at://did:plc:previewlistowner/app.bsky.graph.list/one", "cid": fixtureCID, "name": "Muted list", "purpose": "app.bsky.graph.defs#modlist"]
  }

  private func followingViewer() -> [String: Any] { ["following": "at://did:plc:viewer/app.bsky.graph.follow/one"] }

  private func mutedWord(_ value: String, targets: [String] = ["content"], actorTarget: String? = nil, expiresAt: Date? = nil) -> MutedWord {
    MutedWord(id: "fixture-\(value)", value: value, targets: targets, actorTarget: actorTarget, expiresAt: expiresAt)
  }

  private func feedPreference(hideReplies: Bool = false, hideUnfollowedReplies: Bool = false, minimumLikes: Int? = nil, hideReposts: Bool = false) -> FeedViewPreference {
    FeedViewPreference(hideReplies: hideReplies, hideRepliesByUnfollowed: hideUnfollowedReplies, hideRepliesByLikeCount: minimumLikes, hideReposts: hideReposts, hideQuotePosts: false)
  }

  private func settle() async { for _ in 0..<40 { await Task.yield() } }
}

private enum PreviewFixtureError: Error { case fetchFailed }

@MainActor
private final class PreviewControlledSource {
  private(set) var keys: [String] = []
  private(set) var maximumActiveRequests = 0
  private var requests: [Int: CheckedContinuation<[AppBskyFeedDefs.FeedViewPost], any Error>] = [:]

  func fetch(_ key: String) async throws -> [AppBskyFeedDefs.FeedViewPost] {
    let index = keys.count
    keys.append(key)
    // Deliberately ignores cancellation so the store must reject obsolete results.
    return try await withCheckedThrowingContinuation { continuation in
      requests[index] = continuation
      maximumActiveRequests = max(maximumActiveRequests, requests.count)
    }
  }

  func waitForRequests(_ count: Int) async {
    for _ in 0..<1000 {
      if keys.count >= count { return }
      await Task.yield()
    }
    Issue.record("Expected \(count) preview requests, received \(keys.count)")
  }

  func succeed(_ index: Int, posts: [AppBskyFeedDefs.FeedViewPost]) {
    requests.removeValue(forKey: index)?.resume(returning: posts)
  }

  func fail(_ index: Int) {
    requests.removeValue(forKey: index)?.resume(throwing: PreviewFixtureError.fetchFailed)
  }
}
