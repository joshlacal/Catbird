import Foundation
import Petrel
import OSLog

/// Centralized service for applying content filtering across all views
/// Ensures consistent filtering in feeds, threads, profiles, and search results
actor ContentFilterService {
  private let logger = Logger(subsystem: "blue.catbird.app", category: "ContentFilterService")
  
  // MARK: - Public API
  
  /// Filter an array of FeedViewPost based on user preferences
  func filterFeedViewPosts(_ posts: [AppBskyFeedDefs.FeedViewPost], settings: FeedTunerSettings) -> [AppBskyFeedDefs.FeedViewPost] {
    var filtered: [AppBskyFeedDefs.FeedViewPost] = []
    
    for post in posts {
      if shouldShowFeedViewPost(post, settings: settings) {
        filtered.append(post)
      }
    }
    
    logger.debug("Filtered \(posts.count) FeedViewPosts to \(filtered.count)")
    return filtered
  }
  
  /// Filter an array of PostView based on user preferences
  func filterPostViews(_ posts: [AppBskyFeedDefs.PostView], settings: FeedTunerSettings) -> [AppBskyFeedDefs.PostView] {
    var filtered: [AppBskyFeedDefs.PostView] = []
    
    for post in posts {
      if shouldShowPostView(post, settings: settings) {
        filtered.append(post)
      }
    }
    
    logger.debug("Filtered \(posts.count) PostViews to \(filtered.count)")
    return filtered
  }
  
  // MARK: - Individual Post Filtering
  
  /// Check if a FeedViewPost should be shown based on filtering rules
  nonisolated func shouldShowFeedViewPost(_ post: AppBskyFeedDefs.FeedViewPost, settings: FeedTunerSettings) -> Bool {
    // Check if post is hidden (strongest filter after blocking)
    let postURI = post.post.uri.uriString()
    if settings.hiddenPosts.contains(postURI) {
      logger.debug("Filtered: hidden post \(postURI)")
      return false
    }
    
    // Check if post author is blocked (strongest filter)
    let authorDID = post.post.author.did.didString()
    if settings.blockedUsers.contains(authorDID) {
      logger.debug("Filtered: blocked user \(post.post.author.handle)")
      return false
    }
    
    // Check if post author is muted
    if settings.mutedUsers.contains(authorDID) {
      logger.debug("Filtered: muted user \(post.post.author.handle)")
      return false
    }
    
    // Check if root post author is blocked/muted (for replies)
    if let reply = post.reply,
       case .appBskyFeedDefsPostView(let rootPost) = reply.root {
      let rootAuthorDID = rootPost.author.did.didString()
      if settings.blockedUsers.contains(rootAuthorDID) {
        logger.debug("Filtered: reply to blocked user \(rootPost.author.handle)")
        return false
      }
      if settings.mutedUsers.contains(rootAuthorDID) {
        logger.debug("Filtered: reply to muted user \(rootPost.author.handle)")
        return false
      }
    }
    
    // Check if parent post author is blocked/muted
    if let reply = post.reply,
       case .appBskyFeedDefsPostView(let parentPost) = reply.parent {
      let parentAuthorDID = parentPost.author.did.didString()
      if settings.blockedUsers.contains(parentAuthorDID) {
        logger.debug("Filtered: reply to blocked parent \(parentPost.author.handle)")
        return false
      }
      if settings.mutedUsers.contains(parentAuthorDID) {
        logger.debug("Filtered: reply to muted parent \(parentPost.author.handle)")
        return false
      }
    }
    
    if MutedWordMatcher.matches(feedPost: post, words: settings.mutedWords, now: Date()) { return false }
    if !passesLocalPostType(post.post, settings: settings) { return false }

    // Check reply filtering
    let isReply = post.reply != nil
    if settings.hideReplies && isReply && authorDID != settings.currentUserDid {
      logger.debug("Filtered: reply post (hideReplies enabled)")
      return false
    }
    
    // Check reply like count filtering (if reply doesn't have enough likes, hide it)
    if let minLikeCount = settings.hideRepliesByLikeCount, isReply {
      let likeCount = post.post.likeCount ?? 0
      if likeCount < minLikeCount {
        logger.debug("Filtered: reply with \(likeCount) likes (minimum: \(minLikeCount))")
        return false
      }
    }
    
    // Check repost filtering
    let isRepost = post.reason != nil
    if isRepost {
      // Check if reposter is blocked/muted
      if case .appBskyFeedDefsReasonRepost(let repostReason) = post.reason {
        let reposterDID = repostReason.by.did.didString()
        if settings.blockedUsers.contains(reposterDID) {
          logger.debug("Filtered: repost by blocked user \(repostReason.by.handle)")
          return false
        }
        if settings.mutedUsers.contains(reposterDID) {
          logger.debug("Filtered: repost by muted user \(repostReason.by.handle)")
          return false
        }
      }
      
      if settings.hideReposts {
        logger.debug("Filtered: repost (hideReposts enabled)")
        return false
      }
    }
    // Declared and detected languages use the same account-local reading rules.
    if settings.hideNonPreferredLanguages,
       case .knownType(let record) = post.post.record,
       let feedPost = record as? AppBskyFeedPost,
       !ReadingLanguagePolicy.allows(declaredLanguages: feedPost.langs?.map { $0.lang.minimalIdentifier } ?? [],
         preferredLanguages: settings.preferredLanguages, text: feedPost.text) {
      return false
    }

    // Check quote post filtering
    let isQuotePost: Bool = {
      guard case .knownType(let record) = post.post.record,
            let feedPost = record as? AppBskyFeedPost else {
        return false
      }
      
      if let embed = feedPost.embed {
        switch embed {
        case .appBskyEmbedRecord, .appBskyEmbedRecordWithMedia:
          return true
        default:
          break
        }
      }
      return false
    }()
    
    if settings.hideQuotePosts && isQuotePost {
      logger.debug("Filtered: quote post (hideQuotePosts enabled)")
      return false
    }
    
    // Evaluate the authors of the original context, including a followed
    // author's self-thread. Following only an unrelated reply author is not enough.
    if settings.hideRepliesByUnfollowed && isReply {
      let isOwnReply = post.post.author.did.didString() == settings.currentUserDid
      var followsContext = false
      if let reply = post.reply {
        if case .appBskyFeedDefsPostView(let parent) = reply.parent {
          followsContext = parent.author.viewer?.following != nil
            || parent.author.did.didString() == settings.currentUserDid
        }
        if case .appBskyFeedDefsPostView(let root) = reply.root {
          followsContext = followsContext || root.author.viewer?.following != nil
            || root.author.did.didString() == settings.currentUserDid
        }
      }
      if !isOwnReply && !followsContext {
        logger.debug("Filtered: reply to unfollowed thread")
        return false
      }
    }

    // Check content label filtering
    if !settings.contentLabelPreferences.isEmpty || settings.hideAdultContent {
      if let labels = post.post.labels, !labels.isEmpty {
        for label in labels {
          let labelValue = label.val.lowercased()
          
          // Check adult content filter
          if settings.hideAdultContent && ["nsfw", "porn", "sexual"].contains(labelValue) {
            logger.debug("Filtered: adult content")
            return false
          }
          
          // Check user's label preferences
          let visibility = ContentFilterManager.getVisibilityForLabel(
            label: labelValue,
            labelerDid: label.src,
            preferences: settings.contentLabelPreferences
          )
          
          if visibility == .hide {
            logger.debug("Filtered: hidden label '\(labelValue)'")
            return false
          }
        }
      }
    }
    
    return true
  }
  
  /// Check if a PostView should be shown based on filtering rules
  nonisolated func shouldShowPostView(_ post: AppBskyFeedDefs.PostView, settings: FeedTunerSettings) -> Bool {
    // Check if post author is blocked (strongest filter)
    let authorDID = post.author.did.didString()
    if settings.blockedUsers.contains(authorDID) {
      logger.debug("Filtered: blocked user \(post.author.handle)")
      return false
    }
    
    // Check if post author is muted
    if settings.mutedUsers.contains(authorDID) {
      logger.debug("Filtered: muted user \(post.author.handle)")
      return false
    }
    
    if MutedWordMatcher.matches(post: post, words: settings.mutedWords, now: Date()) { return false }

    // Declared and detected languages use the same account-local reading rules.
    if settings.hideNonPreferredLanguages,
       case .knownType(let record) = post.record,
       let feedPost = record as? AppBskyFeedPost,
       !ReadingLanguagePolicy.allows(declaredLanguages: feedPost.langs?.map { $0.lang.minimalIdentifier } ?? [],
         preferredLanguages: settings.preferredLanguages, text: feedPost.text) {
      return false
    }

    // Check content label filtering
    if !settings.contentLabelPreferences.isEmpty || settings.hideAdultContent {
      if let labels = post.labels, !labels.isEmpty {
        for label in labels {
          let labelValue = label.val.lowercased()
          
          // Check adult content filter
          if settings.hideAdultContent && ["nsfw", "porn", "sexual"].contains(labelValue) {
            logger.debug("Filtered: adult content")
            return false
          }
          
          // Check user's label preferences
          let visibility = ContentFilterManager.getVisibilityForLabel(
            label: labelValue,
            labelerDid: label.src,
            preferences: settings.contentLabelPreferences
          )
          
          if visibility == .hide {
            logger.debug("Filtered: hidden label '\(labelValue)'")
            return false
          }
        }
      }
    }
    
    return true
  }
  private nonisolated func passesLocalPostType(_ post: AppBskyFeedDefs.PostView, settings: FeedTunerSettings) -> Bool {
    if settings.onlyTextPosts && post.embed != nil { return false }
    if settings.onlyMediaPosts {
      let hasMedia: Bool
      guard let embed = post.embed else { return false }
      switch embed {
      case .appBskyEmbedImagesView, .appBskyEmbedGalleryView, .appBskyEmbedVideoView: hasMedia = true
      case .appBskyEmbedRecordWithMediaView(let value):
        switch value.media {
        case .appBskyEmbedImagesView, .appBskyEmbedGalleryView, .appBskyEmbedVideoView: hasMedia = true
        default: hasMedia = false
        }
      default: hasMedia = false
      }
      if !hasMedia { return false }
    }
    if settings.hideLinks {
      if let embed = post.embed {
        switch embed {
        case .appBskyEmbedExternalView: return false
        case .appBskyEmbedRecordWithMediaView(let value):
          if case .appBskyEmbedExternalView = value.media { return false }
        default: break
        }
      }
      if case .knownType(let record) = post.record, let value = record as? AppBskyFeedPost {
        for facet in value.facets ?? [] {
          if facet.features.contains(where: { if case .appBskyRichtextFacetLink = $0 { return true }; return false }) { return false }
        }
      }
    }
    return true
  }

}
