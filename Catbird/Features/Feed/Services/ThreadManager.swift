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

/// Manages loading and caching of thread data
@Observable
final class ThreadManager: StateInvalidationSubscriber {
  // MARK: - Published Properties

  /// The thread data once loaded
  var threadData: AppBskyUnspeccedGetPostThreadV2.Output?

  /// Loading state indicator
  var isLoading: Bool = false

  /// Loading state for additional parent posts
  var isLoadingMoreParents: Bool = false

  /// Any error that occurred during loading
  var error: Error?

  // Logger for debugging thread loading issues
  private let logger = Logger(subsystem: "blue.catbird", category: "ThreadManager")

  // MARK: - Private Properties

  /// Reference to the app state
  private let appState: AppState
  
  /// The URI of the currently loaded thread (for state invalidation)
  private var currentThreadURI: ATProtocolURI?

  /// The ATPROTO client for API calls
  private var client: ATProtoClient? {
    // Safe handling to prevent fatalError during FaultOrdering
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

  // MARK: - Thread Loading

  /// Load a thread by its URI
  /// - Parameter uri: The post URI to load
  @MainActor
  func loadThread(uri: ATProtocolURI) async {
    isLoading = true
    error = nil
    currentThreadURI = uri

    logger.debug("Loading thread: \(uri.uriString())")

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


  // MARK: - State Invalidation Handling
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
    currentThreadURI = nil
    error = nil
    isLoading = false
    isLoadingMoreParents = false
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
