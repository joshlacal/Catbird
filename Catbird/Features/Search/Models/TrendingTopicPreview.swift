import Foundation
import Petrel

struct TrendingTopicPreview: Equatable {
  struct Media: Identifiable, Equatable {
    let id: String
    let url: URL
  }
  struct Participant: Identifiable, Equatable {
    let id: String
    let avatar: URL
  }
  var media: [Media] = []
  var participants: [Participant] = []
  var contributorProfiles: [AppBskyActorDefs.ProfileViewBasic] = []
}

/// Preview art never reveals a warning. Unknown label semantics also require text fallback.
/// This gate runs before constructing either image or avatar requests, including cache hits.
enum TrendingTopicPreviewPolicy {
  struct Context {
    var mutedUsers: Set<String> = []
    var blockedUsers: Set<String> = []
    var hiddenPosts: Set<String> = []
    var mutedWords: [MutedWord] = []
    var feedPreference: FeedViewPreference?
    var currentUserDID: String = ""
    var allowsPost: (AppBskyFeedDefs.FeedViewPost) -> Bool = { _ in true }
  }

  static func select(_ posts: [AppBskyFeedDefs.FeedViewPost], context: Context) -> TrendingTopicPreview {
    var result = TrendingTopicPreview()
    var postIDs = Set<String>()
    var authorIDs = Set<String>()
    for post in posts.prefix(30) where permits(post, context: context) {
      let id = post.post.uri.uriString()
      guard postIDs.insert(id).inserted else { continue }
      if result.media.count < 3, let url = thumbnail(post.post) {
        result.media.append(.init(id: id, url: url))
      }
      let author = post.post.author
      let did = author.did.didString()
      if result.participants.count < 3, let avatar = author.finalAvatarURL(),
         let url = imageURL(avatar.absoluteString), authorIDs.insert(did).inserted {
        result.participants.append(.init(id: did, avatar: url))
        result.contributorProfiles.append(author)
      }
      if result.media.count == 3 && result.participants.count == 3 { break }
    }
    // Stable shuffle: a cached topic does not rearrange when scrolling or returning from a feed.
    result.media.sort { stableRank($0.id) < stableRank($1.id) }
    return result
  }

  static func permitsLabelerScope(local: [String], applied: [String]?) -> Bool {
    guard let applied else { return false }
    let required = Set(local + ["did:plc:ar7c4by46qjdydhdevvrndac"])
    return Set(applied) == required
  }

  static func feedURI(for link: String) -> ATProtocolURI? {
    guard let url = URL(string: link, relativeTo: URL(string: "https://bsky.app"))?.absoluteURL,
          url.scheme == "https", url.host == "bsky.app", url.query == nil, url.fragment == nil else { return nil }
    let parts = url.path.split(separator: "/").map(String.init)
    guard parts.count == 4, parts[0] == "profile", parts[2] == "feed",
          parts[1].hasPrefix("did:"), !parts[3].isEmpty else { return nil }
    return try? ATProtocolURI(uriString: "at://\(parts[1])/app.bsky.feed.generator/\(parts[3])")
  }

  static func permits(_ item: AppBskyFeedDefs.FeedViewPost, context: Context) -> Bool {
    let post = item.post
    guard !context.hiddenPosts.contains(post.uri.uriString()),
          post.viewer?.threadMuted != true,
          permitsAuthor(post.author, context: context),
          safeLabels(post.labels),
          case .knownType(let record) = post.record, let value = record as? AppBskyFeedPost,
          context.allowsPost(item) else { return false }
    if let labels = value.labels {
      guard case .comAtprotoLabelDefsSelfLabels(let labels) = labels, labels.values.isEmpty else { return false }
    }
    guard value.reply == nil || item.reply != nil else { return false }
    // Quoted records can carry independent warnings, blocks, or unavailable records.
    // Until that context is fully evaluated, neither their media nor author is previewed.
    switch post.embed {
    case .appBskyEmbedRecordView, .appBskyEmbedRecordWithMediaView: return false
    default: break
    }
    if case .appBskyFeedDefsReasonRepost(let reason) = item.reason,
       !permitsAuthor(reason.by, context: context) { return false }
    if context.feedPreference?.hideReposts == true && item.reason != nil { return false }
    if let reply = item.reply {
      if context.feedPreference?.hideReplies == true { return false }
      if let minimum = context.feedPreference?.hideRepliesByLikeCount, (post.likeCount ?? 0) < minimum { return false }
      guard case .appBskyFeedDefsPostView(let parent) = reply.parent,
            case .appBskyFeedDefsPostView(let root) = reply.root,
            safeContextPost(parent, context: context), safeContextPost(root, context: context) else { return false }
      if context.feedPreference?.hideRepliesByUnfollowed == true,
         post.author.did.didString() != context.currentUserDID,
         parent.author.viewer?.following == nil, root.author.viewer?.following == nil,
         parent.author.did.didString() != context.currentUserDID, root.author.did.didString() != context.currentUserDID { return false }
    }
    return !matchesMutedWord(value, author: post.author, altText: altText(post), context: context)
  }

  private static func safeContextPost(_ post: AppBskyFeedDefs.PostView, context: Context) -> Bool {
    guard !context.hiddenPosts.contains(post.uri.uriString()), post.viewer?.threadMuted != true, permitsAuthor(post.author, context: context),
          safeLabels(post.labels), case .knownType(let record) = post.record,
          let value = record as? AppBskyFeedPost else { return false }
    if let labels = value.labels {
      guard case .comAtprotoLabelDefsSelfLabels(let labels) = labels, labels.values.isEmpty else { return false }
    }
    switch post.embed {
    case .appBskyEmbedRecordView, .appBskyEmbedRecordWithMediaView: return false
    default: break
    }
    return !matchesMutedWord(value, author: post.author, altText: altText(post), context: context)
  }

  static func permitsAuthor(_ author: AppBskyActorDefs.ProfileViewBasic, context: Context) -> Bool {
    let viewer = author.viewer
    return !context.mutedUsers.contains(author.did.didString())
      && !context.blockedUsers.contains(author.did.didString())
      && viewer?.muted != true && viewer?.mutedByList == nil
      && viewer?.blocking == nil && viewer?.blockingByList == nil && viewer?.blockedBy != true
      && safeLabels(author.labels)
  }

  private static func safeLabels(_ labels: [ComAtprotoLabelDefs.Label]?) -> Bool {
    // Covers canonical warnings, reserved hide/warn/redaction labels and custom labelers.
    !(labels ?? []).contains { ReportingService.isLabelActive($0) }
  }

  private static func matchesMutedWord(_ post: AppBskyFeedPost, author: AppBskyActorDefs.ProfileViewBasic, altText: String, context: Context) -> Bool {
    let tags = (post.tags ?? []) + (post.facets ?? []).flatMap { facet in
      facet.features.compactMap { feature -> String? in
        if case .appBskyRichtextFacetTag(let tag) = feature { return tag.tag }
        return nil
      }
    }
    // Include alt text: a text-only post can still describe muted content in its attached image.
    let text = post.text + " " + altText
    return context.mutedWords.contains { word in
      guard word.expiresAt.map({ $0 > Date() }) ?? true,
            !(word.actorTarget == "exclude-following" && author.viewer?.following != nil),
            !word.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
      let needle = word.value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
      let matchesTag = tags.contains { $0.compare(needle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
      return (word.targets.contains("content") && (text.range(of: word.value, options: [.caseInsensitive, .diacriticInsensitive]) != nil || matchesTag))
        || (word.targets.contains("tag") && matchesTag)
    }
  }

  private static func altText(_ post: AppBskyFeedDefs.PostView) -> String {
    switch post.embed {
    case .appBskyEmbedImagesView(let images): return images.images.map(\.alt).joined(separator: " ")
    case .appBskyEmbedGalleryView(let gallery):
      return gallery.items.compactMap { item -> String? in
        if case .appBskyEmbedGalleryViewImage(let image) = item { return image.alt }
        return nil
      }.joined(separator: " ")
    case .appBskyEmbedVideoView(let video): return video.alt ?? ""
    default: return ""
    }
  }

  private static func thumbnail(_ post: AppBskyFeedDefs.PostView) -> URL? {
    switch post.embed {
    case .appBskyEmbedImagesView(let images): return images.images.first.flatMap { imageURL($0.thumb.uriString()) }
    case .appBskyEmbedVideoView(let video): return video.thumbnail.flatMap { imageURL($0.uriString()) }
    case .appBskyEmbedGalleryView(let gallery):
      for item in gallery.items {
        if case .appBskyEmbedGalleryViewImage(let image) = item, let url = imageURL(image.thumbnail.uriString()) { return url }
      }
      return nil
    default: return nil
    }
  }

  private static func imageURL(_ value: String) -> URL? {
    guard let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
    return url
  }

  private static func stableRank(_ value: String) -> UInt64 {
    value.utf8.reduce(14695981039346656037) { ($0 ^ UInt64($1)) &* 1099511628211 }
  }
}
