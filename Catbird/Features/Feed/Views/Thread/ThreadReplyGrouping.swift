#if os(iOS)
import Foundation
import Petrel

// MARK: - ParentPost Extensions
extension ParentPost {
  /// Safely extracts URI from parent post thread item
  var uri: ATProtocolURI? {
    return threadItem.uri
  }

  var post: AppBskyFeedDefs.PostView? {
    guard case .appBskyUnspeccedDefsThreadItemPost(let item) = threadItem.value else {
      return nil
    }
    return item.post
  }
}

// MARK: - Reply grouping

/// Groups depth-ordered V2 reply `items` into top-level chains and their nested
/// descendants, preserving API order.
///
/// - `depth == 1` starts a new chain (top-level reply to the main post).
/// - `depth > 1` appends to the current chain root's nested list.
///
/// Blocked / not-found / no-auth items become neutral tombstone wrappers rather
/// than being dropped, so a subtree under a blocked reply stays reachable and
/// the chain root can itself be a tombstone. Pure and side-effect free for tests.
func buildReplyWrappers(
  items: [AppBskyUnspeccedGetPostThreadV2.ThreadItem],
  mainPost: AppBskyFeedDefs.PostView?
) -> (topLevel: [ReplyWrapper], nested: [String: [ReplyWrapper]]) {
  var topLevelReplies: [ReplyWrapper] = []
  var nestedMap: [String: [ReplyWrapper]] = [:]
  var currentChainTopLevelURI: String?

  for item in items {
    let id = item.uri.uriString()
    let wrapper: ReplyWrapper
    if case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost) = item.value {
      // Optional-safe: with a blocked anchor there is no OP to compare against,
      // so `mainPost == nil` yields `isFromOP == false`.
      let isFromOP = mainPost?.author.did.didString() == threadItemPost.post.author.did.didString()
      wrapper = ReplyWrapper(
        id: id,
        threadItem: item,
        depth: item.depth,
        isFromOP: isFromOP,
        isOpThread: threadItemPost.opThread,
        hasReplies: threadItemPost.moreReplies > 0
      )
    } else {
      // Tombstone wrapper for blocked / not-found / no-auth replies.
      wrapper = ReplyWrapper(
        id: id,
        threadItem: item,
        depth: item.depth,
        isFromOP: false,
        isOpThread: false,
        hasReplies: false
      )
    }

    if item.depth == 1 {
      // Top-level reply to main post - starts a new chain.
      topLevelReplies.append(wrapper)
      currentChainTopLevelURI = id
      nestedMap[id] = []
    } else if item.depth > 1, let chainRoot = currentChainTopLevelURI {
      // Nested reply (depth 2+) - belongs to the current chain.
      nestedMap[chainRoot]?.append(wrapper)
    }
  }

  return (topLevelReplies, nestedMap)
}

// MARK: - ReplyWrapper Extensions
extension ReplyWrapper {
  /// Computed property to access the post from the thread item
  /// Returns nil for non-accessible post types (not found, blocked, etc.)
  var post: AppBskyFeedDefs.PostView? {
    switch threadItem.value {
    case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost):
      return threadItemPost.post
    case .appBskyUnspeccedDefsThreadItemNotFound, .appBskyUnspeccedDefsThreadItemBlocked,
         .appBskyUnspeccedDefsThreadItemNoUnauthenticated, .unexpected:
      return nil
    }
  }

  /// The URI this post directly replies to, when its record is available.
  var parentURI: String? {
    guard let post,
      case .knownType(let record) = post.record,
      let feedPost = record as? AppBskyFeedPost
    else {
      return nil
    }

    return feedPost.reply?.parent.uri.uriString()
  }

  /// URI accessor that works for all thread item types
  var uri: ATProtocolURI {
    return threadItem.uri
  }
}
#endif
