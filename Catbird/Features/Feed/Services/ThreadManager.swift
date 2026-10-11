//
//  ThreadManager.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/25/25.
//

import Foundation
import Observation
import Petrel
import os

enum ThreadSortAPIMapper {
  static func apiValue(for setting: String) -> String {
    switch setting {
    case "newest": return "newest"
    case "oldest": return "oldest"
    // "hot", "top", and the official app's "hotness"/"most-likes"/"random"
    // all map to the AppView's engagement ordering.
    default: return "top"
    }
  }
}

/// Manages loading and caching of thread data
@Observable
final class ThreadManager {
  // MARK: - Thread Anchor Prefill Cache (P080)

  private struct PrefillKey: Hashable {
    let userDID: String
    let uri: String
  }

  private struct PrefillEntry {
    let post: AppBskyFeedDefs.PostView
    let timestamp: Date
  }

  private static let prefillLock = NSLock()
  private static var prefillEntries: [PrefillKey: PrefillEntry] = [:]
  private static let prefillTTL: TimeInterval = 10.0

  public static func storePrefillPost(_ post: AppBskyFeedDefs.PostView, userDID: String?) {
    guard let userDID, !userDID.isEmpty else { return }
    let key = PrefillKey(userDID: userDID, uri: post.uri.uriString())
    prefillLock.withLock {
      let now = Date()
      prefillEntries = prefillEntries.filter { now.timeIntervalSince($0.value.timestamp) < prefillTTL }
      prefillEntries[key] = PrefillEntry(post: post, timestamp: now)
    }
  }

  public static func prefillPost(for uri: ATProtocolURI, userDID: String?) -> AppBskyFeedDefs.PostView? {
    guard let userDID, !userDID.isEmpty else { return nil }
    let key = PrefillKey(userDID: userDID, uri: uri.uriString())
    return prefillLock.withLock {
      guard let entry = prefillEntries.removeValue(forKey: key) else { return nil }
      if Date().timeIntervalSince(entry.timestamp) < prefillTTL {
        return entry.post
      }
      return nil
    }
  }

  public static func clearPrefillCache() {
    prefillLock.withLock {
      prefillEntries.removeAll()
    }
  }
  // MARK: - Published Properties

  /// The thread data once loaded
  var threadData: AppBskyUnspeccedGetPostThreadV2.Output?

  /// The blocked anchor payload when the thread's depth-0 item is a blocked
  /// post. A 200 response with a `threadItemBlocked` at depth 0 is a valid
  /// (not error) state: the anchor is hidden but parents/replies still render.
  var blockedAnchor: AppBskyUnspeccedDefs.ThreadItemBlocked?

  /// Hidden/other replies loaded via getPostThreadOtherV2
  var hiddenReplies: [AppBskyUnspeccedGetPostThreadOtherV2.ThreadItem] = []

  /// Loading state indicator
  var isLoading: Bool = false

  /// Loading state for additional parent posts
  var isLoadingMoreParents: Bool = false

  /// Loading state for hidden replies
  var isLoadingHiddenReplies: Bool = false

  /// Any error that occurred during loading
  var error: Error?

  // Logger for debugging thread loading issues
  private let logger = Logger(subsystem: "blue.catbird", category: "ThreadManager")

  // MARK: - Private Properties

  /// Reference to the app state
  private let appState: AppState


  /// The ATPROTO client for API calls
  private var client: ATProtoClient? {
    return appState.atProtoClient
  }

  // MARK: - Initialization

  init(appState: AppState) {
    self.appState = appState
  }

  // MARK: - Thread Loading


  /// Load a thread by its URI
  func loadThread(
    uri: ATProtocolURI,
    visibilityContext: PostVisibilityContext = .public
  ) async {
    guard !Task.isCancelled else { return }
    isLoading = true
    error = nil
    logger.debug("Loading thread: \(uri.uriString()) (context: \(visibilityContext))")

    do {
      guard let client = client else {
        self.error = NSError(
          domain: "ThreadManager", code: -1,
          userInfo: [NSLocalizedDescriptionKey: "Couldn’t load this thread. Check your connection and try again."]
        )
        isLoading = false
        return
      }
      
      // Linear threads fetch one deep chain per reply; tree threads fetch a
      // shallower but fully branching tree.
      let layoutMode = ThreadLayoutMode(threadedReplies: appState.appSettings.threadedReplies)
      let params = AppBskyUnspeccedGetPostThreadV2.Parameters(
        anchor: uri,
        above: true,  // Load parent posts
        below: layoutMode.fetchDepth,
        branchingFactor: layoutMode.fetchBranchingFactor,
        sort: ThreadSortAPIMapper.apiValue(for: appState.appSettings.threadSortOrder)
      )
      let (responseCode, output) = try await client.app.bsky.unspecced.getPostThreadV2(input: params)
      try Task.checkCancellation()

      if responseCode == 200, let output = output {
        // Log the number of items in the thread response
        let parentCount = output.thread.filter { $0.depth < 0 }.count
        logger.debug(
          "Initial thread load: Found \(parentCount) parent posts and \(output.thread.count) total items for thread: \(uri.uriString())")

        // Store the thread data directly (no shadow merging needed with v2)
        self.threadData = output

        // Detect a blocked anchor (200 with a blocked depth-0 item). This is a
        // valid state, not an error — the views render the anchor tombstone card
        // alongside whatever parents/replies the AppView returned.
        self.blockedAnchor = Self.detectBlockedAnchor(in: output.thread)

        // Opening a thread is deliberate engagement: make its anchor post
        // findable in Spotlight. Non-public contexts stay out of the index.
        if visibilityContext == .public,
           let anchor = output.thread.first(where: { $0.depth == 0 }),
           case .appBskyUnspeccedDefsThreadItemPost(let anchorItem) = anchor.value {
          let anchorPost = anchorItem.post
          Task(priority: .utility) {
            await SpotlightEntityDonator.shared.donate(posts: [anchorPost])
          }
        }
      } else {
        // Handle specific errors
        if responseCode == 404 {
          self.error = NSError(
            domain: "ThreadManager", code: 404,
            userInfo: [NSLocalizedDescriptionKey: "This post may have been deleted."])
        } else if responseCode == 403 {
          // Genuine forbidden fetch (no body). A blocked *anchor* is NOT this
          // case — it arrives as a 200 with a `threadItemBlocked` at depth 0 and
          // is surfaced via `blockedAnchor`, not as an error.
          self.error = NSError(
            domain: "ThreadManager", code: 403,
            userInfo: [NSLocalizedDescriptionKey: "This post isn’t available."])
        } else {
          logger.error("Thread fetch failed with response code \(responseCode)")
          self.error = NSError(
            domain: "ThreadManager", code: responseCode,
            userInfo: [
              NSLocalizedDescriptionKey: "Couldn’t load this thread. Please try again."
            ])
        }
      }
    } catch {
      if !Task.isCancelled, !error.isCancellation {
        self.error = error
        logger.error("Error loading thread: \(error.localizedDescription)")
      }
    }

    isLoading = false
  }

  /// Detect a blocked anchor in a V2 thread: the depth-0 item is a
  /// `threadItemBlocked`. Pure and side-effect free for unit testing.
  /// - Returns: the blocked payload when the anchor is blocked, else `nil`.
  static func detectBlockedAnchor(
    in threadItems: [AppBskyUnspeccedGetPostThreadV2.ThreadItem]
  ) -> AppBskyUnspeccedDefs.ThreadItemBlocked? {
    guard let anchorItem = threadItems.first(where: { $0.depth == 0 }),
      case .appBskyUnspeccedDefsThreadItemBlocked(let blocked) = anchorItem.value
    else {
      return nil
    }
    return blocked
  }

  /// Load hidden replies for a thread using getPostThreadOtherV2
  /// This fetches replies that are hidden by threadgate settings
  /// - Parameter uri: The anchor post URI to load hidden replies for
  /// - Returns: `true` when the hidden replies were fetched successfully
  @MainActor
  @discardableResult
  func loadHiddenReplies(uri: ATProtocolURI) async -> Bool {
    guard !isLoadingHiddenReplies else {
      logger.debug("Already loading hidden replies, skipping request.")
      return false
    }

    isLoadingHiddenReplies = true
    defer { isLoadingHiddenReplies = false }

    logger.debug("Loading hidden replies for thread: \(uri.uriString())")

    do {
      guard let client = client else {
        logger.error("Network client unavailable for loading hidden replies")
        return false
      }

      let params = AppBskyUnspeccedGetPostThreadOtherV2.Parameters(
        anchor: uri
      )

      let (responseCode, output) = try await client.app.bsky.unspecced.getPostThreadOtherV2(input: params)

      if responseCode == 200, let output = output {
        logger.debug("Loaded \(output.thread.count) hidden replies for thread: \(uri.uriString())")
        self.hiddenReplies = output.thread
        return true
      } else {
        logger.warning("Failed to load hidden replies, response code: \(responseCode)")
        self.hiddenReplies = []
        return false
      }
    } catch {
      logger.error("Error loading hidden replies: \(error.localizedDescription)")
      self.hiddenReplies = []
      return false
    }
  }

  /// Load more parent posts for a thread and integrate them into the existing thread structure
  /// - Parameter uri: The post URI to use as a reference point for loading more parents
  /// - Returns: Success flag indicating if more parents were successfully loaded
  @MainActor
  func loadMoreParents(uri: ATProtocolURI) async -> Bool {
    guard !isLoadingMoreParents else {
      logger.debug("Already loading more parents, skipping request.")
      return false
    }

    isLoadingMoreParents = true
    defer { isLoadingMoreParents = false }

    logger.debug("Loading more parents for thread: \(uri.uriString())")

    guard let currentData = threadData else {
      logger.warning("No thread data to load more parents for")
      return false
    }

    // Find the topmost parent in current data
    let parentItems = currentData.thread.filter { $0.depth < 0 }.sorted { $0.depth < $1.depth }
    
    guard let topmostParent = parentItems.first else {
      logger.debug("No parent posts found in current thread")
      return false
    }
    
    // Check if we can load more parents
    guard case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost) = topmostParent.value,
          threadItemPost.moreParents else {
      logger.debug("No more parents available to load")
      return false
    }

    do {
      guard let client = client else {
        logger.error("Network client unavailable")
        return false
      }

      // Load more parents by requesting the topmost parent's URI
      let params = AppBskyUnspeccedGetPostThreadV2.Parameters(
        anchor: topmostParent.uri,
        above: true,  // Load more parent posts
        below: 0,  // Don't load replies
        sort: ThreadSortAPIMapper.apiValue(for: appState.appSettings.threadSortOrder)
      )
      
      let (responseCode, output) = try await client.app.bsky.unspecced.getPostThreadV2(input: params)

      if responseCode == 200, let output = output {
        let newParentCount = output.thread.filter { $0.depth < 0 }.count
        logger.debug("Loaded \(newParentCount) parent posts")

        // Merge the new parent posts with existing thread data
        var mergedThread = currentData.thread
        var addedCount = 0

        // The new parents' depths are relative to the topmost parent we used as
        // the anchor, so rebase them onto the current thread's depth scale.
        let depthOffset = topmostParent.depth
        for newItem in output.thread.filter({ $0.depth < 0 }) {
          if !mergedThread.contains(where: { $0.uri == newItem.uri }) {
            mergedThread.append(
              AppBskyUnspeccedGetPostThreadV2.ThreadItem(
                uri: newItem.uri,
                depth: newItem.depth + depthOffset,
                value: newItem.value
              )
            )
            addedCount += 1
          }
        }
        
        // Sort by depth to maintain order
        mergedThread.sort { $0.depth < $1.depth }
        
        // Update thread data
        self.threadData = AppBskyUnspeccedGetPostThreadV2.Output(
          thread: mergedThread,
          threadgate: currentData.threadgate,
          hasOtherReplies: currentData.hasOtherReplies
        )

        return addedCount > 0
      } else {
        logger.error("Failed to load more parents, response code: \(responseCode)")
        return false
      }
    } catch {
      logger.error("Error loading more parents: \(error.localizedDescription)")
      return false
    }
  }

  /// Flattens a hierarchical `AppBskyFeedDefs.ThreadViewPost` into a V2-style `[ThreadItem]`
  /// with explicit depth values (negative for parents, 0 for anchor, positive for replies).
  public static func flattenThreadViewPost(_ root: AppBskyFeedDefs.ThreadViewPost) -> [AppBskyUnspeccedGetPostThreadV2.ThreadItem] {
    var items: [AppBskyUnspeccedGetPostThreadV2.ThreadItem] = []

    // Parents (traverse parent chain upwards)
    var parents: [AppBskyFeedDefs.PostView] = []
    var currentParent = root.parent
    while let p = currentParent {
      switch p {
      case .appBskyFeedDefsThreadViewPost(let parentThreadPost):
        parents.append(parentThreadPost.post)
        currentParent = parentThreadPost.parent
      default:
        currentParent = nil
      }
    }

    // Parents are closest-first in loop, so reverse them so most distant ancestor is first (depth -N)
    for (index, parentPost) in parents.reversed().enumerated() {
      let depth = -(parents.count - index)
      let threadItemPost = AppBskyUnspeccedDefs.ThreadItemPost(
        post: parentPost,
        moreParents: false,
        moreReplies: 0,
        opThread: false,
        opThreadPostIndex: nil,
        opThreadPostCount: nil,
        hiddenByThreadgate: false,
        mutedByViewer: false
      )
      items.append(
        AppBskyUnspeccedGetPostThreadV2.ThreadItem(
          uri: parentPost.uri,
          depth: depth,
          value: .appBskyUnspeccedDefsThreadItemPost(threadItemPost)
        )
      )
    }

    // Anchor post (depth 0)
    let anchorItemPost = AppBskyUnspeccedDefs.ThreadItemPost(
      post: root.post,
      moreParents: false,
      moreReplies: root.replies?.count ?? 0,
      opThread: true,
      opThreadPostIndex: nil,
      opThreadPostCount: nil,
      hiddenByThreadgate: false,
      mutedByViewer: false
    )
    items.append(
      AppBskyUnspeccedGetPostThreadV2.ThreadItem(
        uri: root.post.uri,
        depth: 0,
        value: .appBskyUnspeccedDefsThreadItemPost(anchorItemPost)
      )
    )

    // Replies (recursively traverse replies)
    func addReplies(from replies: [AppBskyFeedDefs.ThreadViewPostRepliesUnion]?, currentDepth: Int) {
      guard let replies else { return }
      for replyUnion in replies {
        switch replyUnion {
        case .appBskyFeedDefsThreadViewPost(let replyPost):
          let replyItemPost = AppBskyUnspeccedDefs.ThreadItemPost(
            post: replyPost.post,
            moreParents: false,
            moreReplies: replyPost.replies?.count ?? 0,
            opThread: false,
            opThreadPostIndex: nil,
            opThreadPostCount: nil,
            hiddenByThreadgate: false,
            mutedByViewer: false
          )
          items.append(
            AppBskyUnspeccedGetPostThreadV2.ThreadItem(
              uri: replyPost.post.uri,
              depth: currentDepth,
              value: .appBskyUnspeccedDefsThreadItemPost(replyItemPost)
            )
          )
          addReplies(from: replyPost.replies, currentDepth: currentDepth + 1)
        default:
          break
        }
      }
    }
    addReplies(from: root.replies, currentDepth: 1)

    return items
  }
  
}

/// Parent post representation for the v2 thread API
public struct ParentPost: Identifiable, Equatable, Hashable, Sendable {
  public let id: String
  public let threadItem: AppBskyUnspeccedGetPostThreadV2.ThreadItem
  public let grandparentAuthor: AppBskyActorDefs.ProfileViewBasic?

  public static func == (lhs: ParentPost, rhs: ParentPost) -> Bool {
    return lhs.id == rhs.id
  }
  
  // Ensure hash value is based only on id to match equality implementation
  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
