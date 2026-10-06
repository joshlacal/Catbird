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
    var quotedPosts: [String: AppBskyFeedDefs.PostView] = [:]
    var allowsExternal: (URL) -> Bool = { _ in true }
    var allowsPost: (AppBskyFeedDefs.FeedViewPost) -> Bool = { _ in true }
  }

  static func select(_ posts: [AppBskyFeedDefs.FeedViewPost], context: Context) -> TrendingTopicPreview {
    var result = TrendingTopicPreview()
    var postIDs = Set<String>()
    var authorIDs = Set<String>()
    var mediaSourceIDs = Set<String>()
    var mediaURLs = Set<URL>()
    for post in posts.prefix(30) where permits(post, context: context) {
      let id = post.post.uri.uriString()
      guard postIDs.insert(id).inserted else { continue }
      if result.media.count < 3, let thumbnail = thumbnail(post.post.embed, sourceID: id),
         !mediaSourceIDs.contains(thumbnail.sourceID), !mediaURLs.contains(thumbnail.url) {
        mediaSourceIDs.insert(thumbnail.sourceID)
        mediaURLs.insert(thumbnail.url)
        result.media.append(.init(id: id, url: thumbnail.url))
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

  /// getPosts accepts at most 25 URIs per request.
  static let maxHydratedQuotes = 25

  /// One bounded getPosts batch hydrates viewer state omitted by quote ViewRecord.
  /// The bound covers every quote in a preview response, so quote posts are not
  /// dropped (with their own media) merely because an earlier post used up the batch.
  static func quotedPostURIs(in posts: [AppBskyFeedDefs.FeedViewPost]) -> [ATProtocolURI] {
    var result: [ATProtocolURI] = []
    var seen = Set<String>()
    func visit(_ embed: AppBskyFeedDefs.PostViewEmbedUnion?, depth: Int) {
      guard depth < 3, result.count < maxHydratedQuotes else { return }
      let quote: AppBskyEmbedRecord.View
      switch embed {
      case .appBskyEmbedRecordView(let record): quote = record
      case .appBskyEmbedRecordWithMediaView(let record): quote = record.record
      default: return
      }
      guard case .appBskyEmbedRecordViewRecord(let record) = quote.record,
            seen.insert(record.uri.uriString()).inserted else { return }
      result.append(record.uri)
      for child in (record.embeds ?? []).prefix(4) {
        visit(postEmbed(child), depth: depth + 1)
      }
    }
    for post in posts.prefix(30) { visit(post.post.embed, depth: 0) }
    return result
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
    guard safeEmbed(post.embed, context: context, depth: 0) else { return false }
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
    return !matchesMutedWord(value, author: post.author, altText: altText(post.embed), context: context)
  }

  private static func safeContextPost(_ post: AppBskyFeedDefs.PostView, context: Context) -> Bool {
    guard !context.hiddenPosts.contains(post.uri.uriString()), post.viewer?.threadMuted != true, permitsAuthor(post.author, context: context),
          safeLabels(post.labels), case .knownType(let record) = post.record,
          let value = record as? AppBskyFeedPost else { return false }
    if let labels = value.labels {
      guard case .comAtprotoLabelDefsSelfLabels(let labels) = labels, labels.values.isEmpty else { return false }
    }
    guard safeEmbed(post.embed, context: context, depth: 0) else { return false }
    return !matchesMutedWord(value, author: post.author, altText: altText(post.embed), context: context)
  }

  static func permitsAuthor(_ author: AppBskyActorDefs.ProfileViewBasic, context: Context) -> Bool {
    let viewer = author.viewer
    return !context.mutedUsers.contains(author.did.didString())
      && !context.blockedUsers.contains(author.did.didString())
      && viewer?.muted != true && viewer?.mutedByList == nil
      && viewer?.blocking == nil && viewer?.blockingByList == nil && viewer?.blockedBy != true
      && safeLabels(author.labels)
  }

  /// Labels that only change logged-out visibility. Trending previews require a session,
  /// so these never imply a warning for the viewer.
  private static let signedInNeutralLabels: Set<String> = ["!no-unauthenticated"]

  private static func safeLabels(_ labels: [ComAtprotoLabelDefs.Label]?) -> Bool {
    // Covers canonical warnings, reserved hide/warn/redaction labels and custom labelers.
    !(labels ?? []).contains { !signedInNeutralLabels.contains($0.val) && ReportingService.isLabelActive($0) }
  }

  /// "Who is chatting" avatars: the trend's own actors first, then preview post authors.
  /// Every actor passes the same author gate as preview posts before an avatar is used.
  static func participants(
    actors: [AppBskyActorDefs.ProfileViewBasic],
    fallback: [TrendingTopicPreview.Participant],
    context: Context,
    limit: Int = 3
  ) -> [TrendingTopicPreview.Participant] {
    var result: [TrendingTopicPreview.Participant] = []
    var seen = Set<String>()
    for actor in actors where result.count < limit && permitsAuthor(actor, context: context) {
      let did = actor.did.didString()
      guard let avatar = actor.finalAvatarURL(), let url = imageURL(avatar.absoluteString),
            seen.insert(did).inserted else { continue }
      result.append(.init(id: did, avatar: url))
    }
    for participant in fallback where result.count < limit && seen.insert(participant.id).inserted {
      result.append(participant)
    }
    return result
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

  private static func safeEmbed(_ embed: AppBskyFeedDefs.PostViewEmbedUnion?, context: Context, depth: Int) -> Bool {
    switch embed {
    case .appBskyEmbedRecordView(let quote):
      return context.feedPreference?.hideQuotePosts != true && safeQuote(quote, context: context, depth: depth + 1)
    case .appBskyEmbedRecordWithMediaView(let quote):
      return context.feedPreference?.hideQuotePosts != true
        && safeEmbed(postEmbed(quote.media), context: context, depth: depth)
        && safeQuote(quote.record, context: context, depth: depth + 1)
    case .appBskyEmbedGalleryView(let gallery):
      return gallery.items.allSatisfy { item in
        if case .appBskyEmbedGalleryViewImage = item { return true }
        return false
      }
    case .appBskyEmbedExternalView(let external):
      guard let destination = URL(string: external.external.uri.uriString()) else { return false }
      return context.allowsExternal(destination)
    case .unexpected: return false
    default: return true
    }
  }

  private static func safeQuote(_ quote: AppBskyEmbedRecord.View, context: Context, depth: Int) -> Bool {
    guard depth <= 3, case .appBskyEmbedRecordViewRecord(let record) = quote.record,
          let post = context.quotedPosts[record.uri.uriString()],
          post.uri == record.uri, post.cid == record.cid, post.author.did == record.author.did,
          !context.hiddenPosts.contains(record.uri.uriString()), post.viewer?.threadMuted != true,
          permitsAuthor(record.author, context: context), permitsAuthor(post.author, context: context),
          safeLabels(record.labels), safeLabels(post.labels),
          case .knownType(let value) = record.value, let provided = value as? AppBskyFeedPost,
          case .knownType(let hydratedValue) = post.record, let hydrated = hydratedValue as? AppBskyFeedPost,
          provided == hydrated, provided.reply == nil, context.allowsPost(.init(post: post)) else { return false }
    if let labels = provided.labels {
      guard case .comAtprotoLabelDefsSelfLabels(let labels) = labels, labels.values.isEmpty else { return false }
    }
    // Every supplied nested embed must be understood and independently hydrated.
    // A quote reply has no hydrated parent/root in getPosts, so it remains text-only.
    let embeds = record.embeds ?? []
    guard embeds.count <= 4,
          safeEmbed(post.embed, context: context, depth: depth),
          !matchesMutedWord(hydrated, author: post.author, altText: altText(post.embed), context: context) else { return false }
    for embed in embeds {
      let embed = postEmbed(embed)
      guard safeEmbed(embed, context: context, depth: depth),
            !matchesMutedWord(provided, author: record.author, altText: altText(embed), context: context) else { return false }
    }
    return !matchesMutedWord(provided, author: record.author, altText: "", context: context)
  }

  private static func altText(_ embed: AppBskyFeedDefs.PostViewEmbedUnion?) -> String {
    switch embed {
    case .appBskyEmbedImagesView(let images): return images.images.map(\.alt).joined(separator: " ")
    case .appBskyEmbedGalleryView(let gallery):
      return gallery.items.compactMap { item -> String? in
        if case .appBskyEmbedGalleryViewImage(let image) = item { return image.alt }
        return nil
      }.joined(separator: " ")
    case .appBskyEmbedVideoView(let video): return video.alt ?? ""
    case .appBskyEmbedExternalView(let external): return external.external.title + " " + external.external.description
    case .appBskyEmbedRecordWithMediaView(let quote): return altText(postEmbed(quote.media))
    default: return ""
    }
  }

  private struct Thumbnail {
    let sourceID: String
    let url: URL
  }

  private static func thumbnail(_ embed: AppBskyFeedDefs.PostViewEmbedUnion?, sourceID: String, depth: Int = 0) -> Thumbnail? {
    guard depth <= 3 else { return nil }
    let url: URL?
    switch embed {
    case .appBskyEmbedImagesView(let images):
      url = images.images.lazy.compactMap { imageURL($0.thumb.uriString()) }.first
    case .appBskyEmbedVideoView(let video): url = video.thumbnail.flatMap { imageURL($0.uriString()) }
    case .appBskyEmbedGalleryView(let gallery):
      url = gallery.items.lazy.compactMap { item -> URL? in
        if case .appBskyEmbedGalleryViewImage(let image) = item { return imageURL(image.thumbnail.uriString()) }
        return nil
      }.first
    case .appBskyEmbedExternalView(let external): url = external.external.thumb.flatMap { imageURL($0.uriString()) }
    case .appBskyEmbedRecordView(let quote): return quoteThumbnail(quote, depth: depth + 1)
    case .appBskyEmbedRecordWithMediaView(let quote):
      return thumbnail(postEmbed(quote.media), sourceID: sourceID, depth: depth)
        ?? quoteThumbnail(quote.record, depth: depth + 1)
    default: return nil
    }
    return url.map { Thumbnail(sourceID: sourceID, url: $0) }
  }

  private static func quoteThumbnail(_ quote: AppBskyEmbedRecord.View, depth: Int) -> Thumbnail? {
    guard depth <= 3, case .appBskyEmbedRecordViewRecord(let record) = quote.record else { return nil }
    for embed in (record.embeds ?? []).prefix(4) {
      if let result = thumbnail(postEmbed(embed), sourceID: record.uri.uriString(), depth: depth) { return result }
    }
    return nil
  }

  private static func postEmbed(_ embed: AppBskyEmbedRecord.ViewRecordEmbedsUnion) -> AppBskyFeedDefs.PostViewEmbedUnion {
    switch embed {
    case .appBskyEmbedImagesView(let value): return .appBskyEmbedImagesView(value)
    case .appBskyEmbedVideoView(let value): return .appBskyEmbedVideoView(value)
    case .appBskyEmbedGalleryView(let value): return .appBskyEmbedGalleryView(value)
    case .appBskyEmbedExternalView(let value): return .appBskyEmbedExternalView(value)
    case .appBskyEmbedRecordView(let value): return .appBskyEmbedRecordView(value)
    case .appBskyEmbedRecordWithMediaView(let value): return .appBskyEmbedRecordWithMediaView(value)
    case .unexpected(let value): return .unexpected(value)
    }
  }

  private static func postEmbed(_ embed: AppBskyEmbedRecordWithMedia.ViewMediaUnion) -> AppBskyFeedDefs.PostViewEmbedUnion {
    switch embed {
    case .appBskyEmbedImagesView(let value): return .appBskyEmbedImagesView(value)
    case .appBskyEmbedVideoView(let value): return .appBskyEmbedVideoView(value)
    case .appBskyEmbedGalleryView(let value): return .appBskyEmbedGalleryView(value)
    case .appBskyEmbedExternalView(let value): return .appBskyEmbedExternalView(value)
    case .unexpected(let value): return .unexpected(value)
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

/// Matches the existing external-card provider gate, including links without a playable ID.
enum TrendingTopicExternalMediaPolicy {
  static func provider(for url: URL) -> ExternalMediaProvider? {
    if let type = ExternalMediaType.detect(from: url) { return type.provider }
    let host = url.host?.lowercased() ?? ""
    if host.contains("youtube.com") || host.contains("youtu.be") {
      return host.contains("shorts") ? .youtubeShorts : .youtube
    }
    let hosts: [(String, ExternalMediaProvider)] = [
      ("tenor.com", .tenor), ("giphy.com", .giphy), ("klipy.com", .klipy),
      ("vimeo.com", .vimeo), ("twitch.tv", .twitch), ("spotify.com", .spotify),
      ("music.apple.com", .appleMusic), ("soundcloud.com", .soundcloud),
      ("flickr.com", .flickr), ("flic.kr", .flickr), ("bandcamp.com", .bandcamp)
    ]
    return hosts.first { host.contains($0.0) }?.1
  }
}
