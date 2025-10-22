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
  func shouldShowFeedViewPost(_ post: AppBskyFeedDefs.FeedViewPost, settings: FeedTunerSettings) -> Bool {
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
    
    // Check reply filtering
    let isReply = post.reply != nil
    if settings.hideReplies && isReply {
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
    // Check language filtering
    if settings.hideNonPreferredLanguages && !settings.preferredLanguages.isEmpty {
      if case .knownType(let record) = post.post.record,
         let feedPost = record as? AppBskyFeedPost {
        
        var hasPreferredLanguage = false
        
        if let postLanguages = feedPost.langs, !postLanguages.isEmpty {
          hasPreferredLanguage = postLanguages.contains { postLangContainer in
            settings.preferredLanguages.contains { prefLang in
              let postLangCode = postLangContainer.lang.languageCode?.identifier ?? postLangContainer.lang.minimalIdentifier
              return postLangCode == prefLang
            }
          }
        } else {
          // No language metadata - use detection
          let postText = feedPost.text
          if !postText.isEmpty {
            let detectedLanguage = LanguageDetector.shared.detectLanguage(for: postText)
            if let detectedLang = detectedLanguage {
              hasPreferredLanguage = settings.preferredLanguages.contains(detectedLang)
            } else {
              hasPreferredLanguage = true  // Allow if can't detect
            }
          } else {
            hasPreferredLanguage = true  // Allow if no text
          }
        }
        
        if !hasPreferredLanguage {
          logger.debug("Filtered: non-preferred language")
          return false
        }
      }
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
    
    // Check replies by not followed users
    // Interpretation: Hide replies TO posts/threads from unfollowed users
    // Key: Must follow someone in the ORIGINAL THREAD (parent or root), EXCLUDING the reply author
    // This prevents seeing followed bots/users spamming replies to unfollowed users
    if settings.hideRepliesByUnfollowed && isReply {
      let replyAuthor = post.post.author.handle
      let replyAuthorDid = post.post.author.did.didString()
      
      // Exception 1: Always show user's own replies
      if let currentUserDid = settings.currentUserDid, replyAuthorDid == currentUserDid {
        logger.debug("✅ Showing reply by @\(replyAuthor): user's own reply")
        return true
      }
      
      // Check if we follow anyone in the ORIGINAL THREAD (parent or root)
      // CRITICAL: We exclude the reply author from this check
      var followedInThread: [String] = []
      
      if let reply = post.reply {
        // Check parent author (if not the reply author)
        if case .appBskyFeedDefsPostView(let parentView) = reply.parent {
          let parentHandle = parentView.author.handle
          let parentDid = parentView.author.did.didString()
          
          // Skip if parent is the same as reply author (self-reply)
          if parentDid != replyAuthorDid {
            if parentView.author.viewer?.following != nil {
              followedInThread.append("@\(parentHandle) (parent)")
            }
          }
        }
        
        // Check root author (if not the reply author)
        if case .appBskyFeedDefsPostView(let rootView) = reply.root {
          let rootHandle = rootView.author.handle
          let rootDid = rootView.author.did.didString()
          
          // Skip if root is the same as reply author (self-reply)
          if rootDid != replyAuthorDid {
            if rootView.author.viewer?.following != nil {
              followedInThread.append("@\(rootHandle) (root)")
            }
          }
        }
      }
      
      // Show only if we follow someone in the thread OTHER THAN the reply author
      if !followedInThread.isEmpty {
        logger.debug("✅ Showing reply by @\(replyAuthor): follows \(followedInThread.joined(separator: ", "))")
        return true
      }
      
      // Hide: replying to a thread with no OTHER followed users
      logger.debug("🚫 FILTERING: Reply by @\(replyAuthor) to unfollowed thread")
      return false
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
  func shouldShowPostView(_ post: AppBskyFeedDefs.PostView, settings: FeedTunerSettings) -> Bool {
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
    
    // Check language filtering
    if settings.hideNonPreferredLanguages && !settings.preferredLanguages.isEmpty {
      if case .knownType(let record) = post.record,
         let feedPost = record as? AppBskyFeedPost {
        
        var hasPreferredLanguage = false
        
        if let postLanguages = feedPost.langs, !postLanguages.isEmpty {
          hasPreferredLanguage = postLanguages.contains { postLangContainer in
            settings.preferredLanguages.contains { prefLang in
              let postLangCode = postLangContainer.lang.languageCode?.identifier ?? postLangContainer.lang.minimalIdentifier
              return postLangCode == prefLang
            }
          }
        } else {
          // No language metadata - use detection
          let postText = feedPost.text
          if !postText.isEmpty {
            let detectedLanguage = LanguageDetector.shared.detectLanguage(for: postText)
            if let detectedLang = detectedLanguage {
              hasPreferredLanguage = settings.preferredLanguages.contains(detectedLang)
            } else {
              hasPreferredLanguage = true
            }
          } else {
            hasPreferredLanguage = true
          }
        }
        
        if !hasPreferredLanguage {
          logger.debug("Filtered: non-preferred language")
          return false
        }
      }
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
}
