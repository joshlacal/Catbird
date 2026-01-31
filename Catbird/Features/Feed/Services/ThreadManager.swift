//
//  ThreadManager.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/25/25.
//

import Foundation
import Observation
import Petrel
import SwiftData
import os

/// Manages loading and caching of thread data
@Observable
final class ThreadManager: StateInvalidationSubscriber {
  // MARK: - Published Properties

  /// The thread data once loaded
  var threadData: AppBskyUnspeccedGetPostThreadV2.Output?

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

  /// The URI of the currently loaded thread (for state invalidation)
  private var currentThreadURI: ATProtocolURI?

  /// Model context for SwiftData cache operations
  @ObservationIgnored private var modelContext: ModelContext?

  /// The ATPROTO client for API calls
  private var client: ATProtoClient? {
    return appState.atProtoClient
  }

  // MARK: - Initialization

  init(appState: AppState) {
    self.appState = appState
    // Subscribe to state invalidation events
    appState.stateInvalidationBus.subscribe(self)
  }

  deinit {
    // Unsubscribe from state invalidation events
    appState.stateInvalidationBus.unsubscribe(self)
  }

  /// Configure with model context for SwiftData cache operations
  func setModelContext(_ context: ModelContext) {
    self.modelContext = context
    logger.debug("ThreadManager configured with ModelContext for caching")
  }

  // MARK: - Thread Loading

  /// Check if cached thread data exists
  /// - Parameter uri: The post URI to look up in cache
  /// - Returns: True if cache exists for this thread
  @MainActor
  private func hasCachedThread(uri: ATProtocolURI) async -> Bool {
    guard let modelContext = modelContext else {
      return false
    }

    let descriptor = FetchDescriptor<CachedFeedViewPost>(
      predicate: #Predicate<CachedFeedViewPost> { post in
          post.uri == uri && post.feedType == "thread-cache"
      }
    )

    do {
      let cachedPosts = try modelContext.fetch(descriptor)
      let hasCached = !cachedPosts.isEmpty
      if hasCached {
        logger.info("✅ Found cached posts for thread: \(uri.uriString())")
      }
      return hasCached
    } catch {
      logger.error("Failed to check cached thread: \(error.localizedDescription)")
      return false
    }
  }

  /// Load a thread by its URI
  /// - Parameter uri: The post URI to load
  @MainActor
  func loadThread(uri: ATProtocolURI) async {
    isLoading = true
    error = nil
    currentThreadURI = uri

    logger.debug("Loading thread: \(uri.uriString())")

    // Check if we have cached data (just for logging/optimization hints)
    let hasCached = await hasCachedThread(uri: uri)
    if hasCached {
      logger.info("📦 Cache exists for this thread - will refresh with fresh data")
    }

    do {
      guard let client = client else {
        self.error = NSError(
          domain: "ThreadManager", code: -1,
          userInfo: [NSLocalizedDescriptionKey: "Network client unavailable. Please check your connection."]
        )
        isLoading = false
        return
      }
      
      let params = AppBskyUnspeccedGetPostThreadV2.Parameters(
        anchor: uri,
        above: true,  // Load parent posts
        below: 10  // Load reply depth
      )
      let (responseCode, output) = try await client.app.bsky.unspecced.getPostThreadV2(input: params)

      if responseCode == 200, let output = output {
        // Log the number of items in the thread response
        let parentCount = output.thread.filter { $0.depth < 0 }.count
        logger.debug(
          "Initial thread load: Found \(parentCount) parent posts and \(output.thread.count) total items for thread: \(uri.uriString())")

        // Store the thread data directly (no shadow merging needed with v2)
        self.threadData = output

        // Save thread posts to cache for instant display on future visits
        await cacheThreadPosts(output.thread)
      } else {
        // Handle specific errors
        if responseCode == 404 {
          self.error = NSError(
            domain: "ThreadManager", code: 404,
            userInfo: [NSLocalizedDescriptionKey: "Post not found"])
        } else if responseCode == 403 {
          self.error = NSError(
            domain: "ThreadManager", code: 403,
            userInfo: [NSLocalizedDescriptionKey: "Post is blocked"])
        } else {
          self.error = NSError(
            domain: "ThreadManager", code: responseCode,
            userInfo: [
              NSLocalizedDescriptionKey: "Failed to fetch thread, response code: \(responseCode)"
            ])
        }
      }
    } catch {
      self.error = error
      logger.error("Error loading thread: \(error.localizedDescription)")
    }

    isLoading = false
  }

  /// Load hidden replies for a thread using getPostThreadOtherV2
  /// This fetches replies that are hidden by threadgate settings
  /// - Parameter uri: The anchor post URI to load hidden replies for
  @MainActor
  func loadHiddenReplies(uri: ATProtocolURI) async {
    guard !isLoadingHiddenReplies else {
      logger.debug("Already loading hidden replies, skipping request.")
      return
    }

    isLoadingHiddenReplies = true
    defer { isLoadingHiddenReplies = false }

    logger.debug("Loading hidden replies for thread: \(uri.uriString())")

    do {
      guard let client = client else {
        logger.error("Network client unavailable for loading hidden replies")
        return
      }

      let params = AppBskyUnspeccedGetPostThreadOtherV2.Parameters(
        anchor: uri
      )

      let (responseCode, output) = try await client.app.bsky.unspecced.getPostThreadOtherV2(input: params)

      if responseCode == 200, let output = output {
        logger.debug("Loaded \(output.thread.count) hidden replies for thread: \(uri.uriString())")
        self.hiddenReplies = output.thread
      } else {
        logger.warning("Failed to load hidden replies, response code: \(responseCode)")
        self.hiddenReplies = []
      }
    } catch {
      logger.error("Error loading hidden replies: \(error.localizedDescription)")
      self.hiddenReplies = []
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
        below: 0  // Don't load replies
      )
      
      let (responseCode, output) = try await client.app.bsky.unspecced.getPostThreadV2(input: params)

      if responseCode == 200, let output = output {
        let newParentCount = output.thread.filter { $0.depth < 0 }.count
        logger.debug("Loaded \(newParentCount) parent posts")

        // Merge the new parent posts with existing thread data
        var mergedThread = currentData.thread
        
        // Add new parents that aren't already in the thread
        for newItem in output.thread.filter({ $0.depth < 0 }) {
          if !mergedThread.contains(where: { $0.uri == newItem.uri }) {
            mergedThread.append(newItem)
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

        return newParentCount > parentItems.count
      } else {
        logger.error("Failed to load more parents, response code: \(responseCode)")
        return false
      }
    } catch {
      logger.error("Error loading more parents: \(error.localizedDescription)")
      return false
    }
  }

  // MARK: - Cache Management

  /// Save thread posts to SwiftData cache for instant display on future visits
  private func cacheThreadPosts(_ threadItems: [AppBskyUnspeccedGetPostThreadV2.ThreadItem]) async {
    guard let modelContext = modelContext else {
      logger.debug("Cannot cache thread posts - modelContext unavailable")
      return
    }

    var savedCount = 0

    for threadItem in threadItems {
      // Only cache actual posts (not blocked/notfound items)
      guard case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost) = threadItem.value else {
        continue
      }

      // Convert to FeedViewPost for caching
      let feedViewPost = AppBskyFeedDefs.FeedViewPost(
        post: threadItemPost.post,
        reply: nil,
        reason: nil,
        feedContext: nil,
        reqId: nil
      )

      // Create cached post with special feedType for thread cache
      guard let cachedPost = CachedFeedViewPost(
        from: feedViewPost,
        cursor: nil,
        feedType: "thread-cache",
        feedOrder: nil
      ) else {
        continue
      }

      await MainActor.run {
        // Upsert: update existing post or insert new one to avoid constraint violations
        let postId = cachedPost.id
        let descriptor = FetchDescriptor<CachedFeedViewPost>(
          predicate: #Predicate<CachedFeedViewPost> { post in
            post.id == postId
          }
        )

        do {
          let existing = try modelContext.fetch(descriptor)
          _ = modelContext.upsert(
            cachedPost,
            existingModel: existing.first,
            update: { existingPost, newPost in existingPost.update(from: newPost) }
          )
          savedCount += 1
        } catch {
          logger.error("Failed to check/save thread post to cache: \(error.localizedDescription)")
        }
      }
    }

    // Save all changes at once
    await MainActor.run {
      do {
        if savedCount > 0 {
          try modelContext.save()
          logger.info("✅ Saved \(savedCount) thread posts to cache")
        }
      } catch {
        logger.error("Failed to save thread posts to cache: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - State Invalidation Handling
  
  /// Check if this manager is interested in a specific event
  func isInterestedIn(_ event: StateInvalidationEvent) -> Bool {
    switch event {
    case .threadUpdated(let rootUri):
      // Only interested if it's our current thread
      if let currentURI = currentThreadURI {
        return currentURI.uriString() == rootUri || isRelatedToCurrentThread(rootUri)
      }
      return false
      
    case .replyCreated(_, let parentUri):
      // Only interested if the reply is in our current thread
      if let currentURI = currentThreadURI {
        return currentURI.uriString() == parentUri || isRelatedToCurrentThread(parentUri)
      }
      return false
      
    case .accountSwitched:
      // Always interested in account switches
      return true
      
    default:
      // Not interested in other events
      return false
    }
  }
  
  /// Handle state invalidation events from the central event bus
  func handleStateInvalidation(_ event: StateInvalidationEvent) async {
    logger.debug("Handling state invalidation event: \(String(describing: event))")
    
    switch event {
    case .threadUpdated(let rootUri):
      // Refresh thread if this is the current thread or if the URI matches
      if let currentURI = currentThreadURI, 
         currentURI.uriString() == rootUri || isRelatedToCurrentThread(rootUri) {
        await refreshCurrentThread()
      }
      
    case .replyCreated(_, let parentUri):
      // Refresh thread if a reply was created in the current thread
      if let currentURI = currentThreadURI,
         currentURI.uriString() == parentUri || isRelatedToCurrentThread(parentUri) {
        await refreshCurrentThread()
      }
      
    case .accountSwitched:
      // Clear thread data when account is switched
      await clearThreadData()
      
    default:
      // Other events don't affect thread views
      break
    }
  }
  
  /// Check if a URI is related to the current thread
  private func isRelatedToCurrentThread(_ uri: String) -> Bool {
    guard let currentURI = currentThreadURI else { return false }
    
    // Simple check: if the URIs match exactly
    if currentURI.uriString() == uri {
      return true
    }
    
    // Could add more sophisticated checking here if needed
    // (e.g., checking if the URI is a reply in the current thread)
    return false
  }
  
  /// Refresh the current thread
  @MainActor
  private func refreshCurrentThread() async {
    guard let currentURI = currentThreadURI, !isLoading else { return }
    
    logger.debug("Refreshing current thread: \(currentURI.uriString())")
    await loadThread(uri: currentURI)
  }
  
  /// Clear thread data
  @MainActor
  private func clearThreadData() async {
    threadData = nil
    hiddenReplies = []
    currentThreadURI = nil
    error = nil
    isLoading = false
    isLoadingMoreParents = false
    isLoadingHiddenReplies = false
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

struct ReplyWrapper: Identifiable, Equatable, Hashable {
  let id: String
  let threadItem: AppBskyUnspeccedGetPostThreadV2.ThreadItem
  let depth: Int
  let isFromOP: Bool
  let isOpThread: Bool  // Whether this post is part of OP's contiguous thread
  let hasReplies: Bool
      
  static func == (lhs: ReplyWrapper, rhs: ReplyWrapper) -> Bool {
    return lhs.id == rhs.id
  }
  
  // Ensure hash value is based only on id to match equality implementation
  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
