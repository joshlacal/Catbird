import Foundation
import Petrel

/// Complete muted-word rules, evaluated against each known post's own author.
enum MutedWordMatcher {
  static func matches(feedPost: AppBskyFeedDefs.FeedViewPost, words: [MutedWord], now: Date) -> Bool {
    if matches(post: feedPost.post, words: words, now: now) { return true }
    if case .appBskyFeedDefsPostView(let parent) = feedPost.reply?.parent {
      return matches(post: parent, words: words, now: now)
    }
    return false
  }

  static func matches(post: AppBskyFeedDefs.PostView, words: [MutedWord], now: Date) -> Bool {
    guard case .knownType(let value) = post.record, let record = value as? AppBskyFeedPost else { return false }
    let tags = (record.tags ?? []) + (record.facets ?? []).flatMap { facet in
      facet.features.compactMap { feature -> String? in
        if case .appBskyRichtextFacetTag(let tag) = feature { return tag.tag }
        return nil
      }
    }
    return matches(text: record.text, tags: tags, altText: altText(post),
                   authorIsFollowed: post.author.viewer?.following != nil, words: words, now: now)
  }

  static func matches(
    text: String, tags: [String], altText: String, authorIsFollowed: Bool,
    words: [MutedWord], now: Date
  ) -> Bool {
    words.contains { word in
      guard word.expiresAt.map({ $0 > now }) ?? true,
            !(word.actorTarget == "exclude-following" && authorIsFollowed) else { return false }
      let needle = word.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !needle.isEmpty else { return false }
      let tagNeedle = needle.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
      let tagMatches = !tagNeedle.isEmpty && tags.contains {
        $0.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
          .compare(tagNeedle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
      }
      let contentMatches = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        || altText.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
      return (word.targets.contains("content") && (contentMatches || tagMatches))
        || (word.targets.contains("tag") && tagMatches)
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
    case .appBskyEmbedRecordWithMediaView(let recordWithMedia):
      // Only this post's attached media; the quoted record is outside mute scope.
      switch recordWithMedia.media {
      case .appBskyEmbedImagesView(let images): return images.images.map(\.alt).joined(separator: " ")
      case .appBskyEmbedGalleryView(let gallery):
        return gallery.items.compactMap { item -> String? in
          if case .appBskyEmbedGalleryViewImage(let image) = item { return image.alt }
          return nil
        }.joined(separator: " ")
      case .appBskyEmbedVideoView(let video): return video.alt ?? ""
      default: return ""
      }
    default: return ""
    }
  }
}
