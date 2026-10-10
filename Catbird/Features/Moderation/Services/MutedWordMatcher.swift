import Foundation
import Petrel

/// Complete muted-word rules, evaluated against each known post's own author.
enum MutedWordMatcher {
  private static let hashCharacterSet = CharacterSet(charactersIn: "#")

  /// Precompiled muted-word matcher built once per settings snapshot.
  /// Pre-trims needles, pre-folds text for case/diacritic insensitivity,
  /// indexes tag needles in a Set for O(1) matching, and pre-filters expired rules.
  struct Compiled: Sendable, Equatable {
    let tagNeedlesAll: Set<String>
    let tagNeedlesUnfollowedOnly: Set<String>
    let contentNeedlesAll: [String]
    let contentNeedlesUnfollowedOnly: [String]

    static let empty = Compiled(words: [])

    var isEmpty: Bool {
      tagNeedlesAll.isEmpty && tagNeedlesUnfollowedOnly.isEmpty
        && contentNeedlesAll.isEmpty && contentNeedlesUnfollowedOnly.isEmpty
    }

    init(words: [MutedWord], now: Date = Date()) {
      var tagAll = Set<String>()
      var tagUnfollowed = Set<String>()
      var contentAll: [String] = []
      var contentUnfollowed: [String] = []

      for word in words {
        if let expiresAt = word.expiresAt, expiresAt <= now {
          continue
        }
        let needle = word.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { continue }

        let targetsContent = word.targets.contains("content")
        let targetsTag = word.targets.contains("tag")
        guard targetsContent || targetsTag else { continue }

        let excludeFollowing = (word.actorTarget == "exclude-following")

        let tagNeedle = needle.trimmingCharacters(in: MutedWordMatcher.hashCharacterSet)
        if !tagNeedle.isEmpty {
          let normalizedTag = tagNeedle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
          if !normalizedTag.isEmpty {
            if excludeFollowing {
              tagUnfollowed.insert(normalizedTag)
            } else {
              tagAll.insert(normalizedTag)
            }
          }
        }

        if targetsContent {
          let foldedNeedle = needle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
          if !foldedNeedle.isEmpty {
            if excludeFollowing {
              contentUnfollowed.append(foldedNeedle)
            } else {
              contentAll.append(foldedNeedle)
            }
          }
        }
      }

      self.tagNeedlesAll = tagAll
      self.tagNeedlesUnfollowedOnly = tagUnfollowed
      self.contentNeedlesAll = contentAll
      self.contentNeedlesUnfollowedOnly = contentUnfollowed
    }

    func matches(feedPost: AppBskyFeedDefs.FeedViewPost) -> Bool {
      guard !isEmpty else { return false }
      if matches(post: feedPost.post) { return true }
      if case .appBskyFeedDefsPostView(let parent) = feedPost.reply?.parent {
        return matches(post: parent)
      }
      return false
    }

    func matches(post: AppBskyFeedDefs.PostView) -> Bool {
      guard !isEmpty else { return false }
      guard case .knownType(let value) = post.record, let record = value as? AppBskyFeedPost else { return false }
      let authorIsFollowed = post.author.viewer?.following != nil

      let rawTags = (record.tags ?? []) + (record.facets ?? []).flatMap { facet in
        facet.features.compactMap { feature -> String? in
          if case .appBskyRichtextFacetTag(let tag) = feature { return tag.tag }
          return nil
        }
      }
      if !rawTags.isEmpty && matches(tags: rawTags, authorIsFollowed: authorIsFollowed) {
        return true
      }

      if hasContentRules(authorIsFollowed: authorIsFollowed) {
        if !record.text.isEmpty {
          let foldedText = record.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
          if matches(foldedHaystack: foldedText, authorIsFollowed: authorIsFollowed) {
            return true
          }
        }
        let alt = MutedWordMatcher.altText(post)
        if !alt.isEmpty {
          let foldedAlt = alt.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
          if matches(foldedHaystack: foldedAlt, authorIsFollowed: authorIsFollowed) {
            return true
          }
        }
      }

      return false
    }

    func matches(text: String, tags: [String], altText: String, authorIsFollowed: Bool) -> Bool {
      guard !isEmpty else { return false }
      if !tags.isEmpty && matches(tags: tags, authorIsFollowed: authorIsFollowed) {
        return true
      }
      if hasContentRules(authorIsFollowed: authorIsFollowed) {
        if !text.isEmpty {
          let foldedText = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
          if matches(foldedHaystack: foldedText, authorIsFollowed: authorIsFollowed) {
            return true
          }
        }
        if !altText.isEmpty {
          let foldedAlt = altText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
          if matches(foldedHaystack: foldedAlt, authorIsFollowed: authorIsFollowed) {
            return true
          }
        }
      }
      return false
    }

    private func hasContentRules(authorIsFollowed: Bool) -> Bool {
      !contentNeedlesAll.isEmpty || (!authorIsFollowed && !contentNeedlesUnfollowedOnly.isEmpty)
    }

    private func matches(tags: [String], authorIsFollowed: Bool) -> Bool {
      var postTagSet = Set<String>()
      for tag in tags {
        let trimmed = tag.trimmingCharacters(in: MutedWordMatcher.hashCharacterSet)
        guard !trimmed.isEmpty else { continue }
        let normalized = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if !normalized.isEmpty {
          postTagSet.insert(normalized)
        }
      }
      guard !postTagSet.isEmpty else { return false }
      if !postTagSet.isDisjoint(with: tagNeedlesAll) { return true }
      if !authorIsFollowed && !postTagSet.isDisjoint(with: tagNeedlesUnfollowedOnly) { return true }
      return false
    }

    private func matches(foldedHaystack: String, authorIsFollowed: Bool) -> Bool {
      for needle in contentNeedlesAll {
        if foldedHaystack.contains(needle) { return true }
      }
      if !authorIsFollowed {
        for needle in contentNeedlesUnfollowedOnly {
          if foldedHaystack.contains(needle) { return true }
        }
      }
      return false
    }
  }

  static func matches(feedPost: AppBskyFeedDefs.FeedViewPost, words: [MutedWord], now: Date = Date()) -> Bool {
    guard !words.isEmpty else { return false }
    let compiled = Compiled(words: words, now: now)
    return compiled.matches(feedPost: feedPost)
  }

  static func matches(post: AppBskyFeedDefs.PostView, words: [MutedWord], now: Date = Date()) -> Bool {
    guard !words.isEmpty else { return false }
    let compiled = Compiled(words: words, now: now)
    return compiled.matches(post: post)
  }

  static func matches(
    text: String, tags: [String], altText: String, authorIsFollowed: Bool,
    words: [MutedWord], now: Date = Date()
  ) -> Bool {
    guard !words.isEmpty else { return false }
    let compiled = Compiled(words: words, now: now)
    return compiled.matches(text: text, tags: tags, altText: altText, authorIsFollowed: authorIsFollowed)
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
