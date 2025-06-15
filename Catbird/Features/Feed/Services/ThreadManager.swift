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
  var threadViewPost: AppBskyFeedGetPostThread.OutputThreadUnion?

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
  private var client: ATProtoClient {
    guard let client = appState.atProtoClient else {
//      #if DEBUG
        fatalError("ATProtoClient not available in ThreadManager. This should never happen.")
//      #else
//        // Handle in production with error state
//        isLoading = false
//        error = NSError(
//          domain: "ThreadManager",
//          code: -1,
//          userInfo: [
//            NSLocalizedDescriptionKey: "Network client unavailable. Please restart the app."
//          ]
//        )
//        return ATProtoClient(configuration: .init(host: ""))
//      #endif
    }
    return client
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
      let params = AppBskyFeedGetPostThread.Parameters(
        uri: uri,
        depth: 10,  // Let API decide depth for replies
        parentHeight: 10
      )
      let (responseCode, output) = try await client.app.bsky.feed.getPostThread(input: params)

      if responseCode == 200, let output = output {
        // Log the number of parent posts in the initial response
        if case .appBskyFeedDefsThreadViewPost(let threadView) = output.thread {
          var parentCount = 0
          var currentParent: AppBskyFeedDefs.ThreadViewPostParentUnion? = threadView.parent

          while currentParent != nil {
            parentCount += 1
            if case .appBskyFeedDefsThreadViewPost(let parentView) = currentParent! {
              currentParent = parentView.parent
            } else {
              currentParent = nil
            }
          }

          logger.debug(
            "Initial thread load: Found \(parentCount) parent posts for thread: \(uri.uriString())")
        }

        // Merge shadows for the fetched thread
        self.threadViewPost = await mergeShadowsInThread(output.thread)
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
    
    // Find the oldest parent post's URI to use for loading more parents
    var oldestParentURI = uri
    
    if let currentThread = self.threadViewPost, 
       case .appBskyFeedDefsThreadViewPost(let threadViewPost) = currentThread {
      // Traverse the parent chain to find the oldest ancestor
      var currentParent: AppBskyFeedDefs.ThreadViewPostParentUnion? = threadViewPost.parent
      var oldestValidParent: AppBskyFeedDefs.ThreadViewPost?
      
      while currentParent != nil {
        if case .appBskyFeedDefsThreadViewPost(let parentPost) = currentParent! {
          oldestValidParent = parentPost
          currentParent = parentPost.parent
        } else {
          break
        }
      }
      
      // Use the oldest parent's URI instead of the original URI
      if let oldestParent = oldestValidParent {
        oldestParentURI = oldestParent.post.uri
        logger.debug("loadMoreParents: Using oldest parent post URI: \(oldestParentURI.uriString())")
      }
    }
    
    logger.debug("Loading more parents for post: \(oldestParentURI.uriString())")

    do {
      // Request a thread with focus on parent posts
      let params = AppBskyFeedGetPostThread.Parameters(
        uri: oldestParentURI,
        depth: 0,  // Minimal depth since we care about parents
        parentHeight: 10
      )

      let (responseCode, output) = try await client.app.bsky.feed.getPostThread(input: params)

      if responseCode == 200, let output = output {
        // Log the parent posts in the response
        if case .appBskyFeedDefsThreadViewPost(let threadView) = output.thread {
          var parentCount = 0
          var parents: [String] = []
          var currentParent: AppBskyFeedDefs.ThreadViewPostParentUnion? = threadView.parent

          while currentParent != nil {
            parentCount += 1
            if case .appBskyFeedDefsThreadViewPost(let parentView) = currentParent! {
              let uri = parentView.post.uri.uriString()
              parents.append(uri)
              currentParent = parentView.parent
            } else {
              currentParent = nil
            }
          }

          logger.debug("Response for loadMoreParents: Found \(parentCount) parent posts")
          if !parents.isEmpty {
            logger.debug("Parent URIs: \(parents.joined(separator: ", "))")
          }
        }

        if let currentThreadViewPost = self.threadViewPost {
          // Count the current number of parents before integration
          var currentParentCount = 0
          if case .appBskyFeedDefsThreadViewPost(let threadView) = currentThreadViewPost {
            var currentParent: AppBskyFeedDefs.ThreadViewPostParentUnion? = threadView.parent
            while currentParent != nil {
              currentParentCount += 1
              if case .appBskyFeedDefsThreadViewPost(let parentView) = currentParent! {
                currentParent = parentView.parent
              } else {
                currentParent = nil
              }
            }
          }
          logger.debug("Before integration: Thread has \(currentParentCount) parents")

          // Integrate the newly fetched parent posts into our existing thread structure
          self.threadViewPost = await integrateParentPosts(
            existingThread: currentThreadViewPost,
            parentThread: output.thread
          )

          // Count the new number of parents after integration
          var newParentCount = 0
          if case .appBskyFeedDefsThreadViewPost(let threadView) = self.threadViewPost! {
            var currentParent: AppBskyFeedDefs.ThreadViewPostParentUnion? = threadView.parent
            while currentParent != nil {
              newParentCount += 1
              if case .appBskyFeedDefsThreadViewPost(let parentView) = currentParent! {
                currentParent = parentView.parent
              } else {
                currentParent = nil
              }
            }
          }
          logger.debug("After integration: Thread now has \(newParentCount) parents")
          
          // Check if we actually added more parents
          let addedParents = newParentCount > currentParentCount
          
          // First, check if the parent count is different
          if addedParents {
            logger.debug("loadMoreParents: Successfully added \(newParentCount - currentParentCount) more parents")
            isLoadingMoreParents = false
            return true  // Success - we added more parents
          }
          
          // Even if parent count didn't change, check if we've now reached the root post
          var reachedRoot = false
          
          // Traverse to the oldest parent to check if it's the root
          if case .appBskyFeedDefsThreadViewPost(let threadView) = self.threadViewPost! {
            var currentNode: AppBskyFeedDefs.ThreadViewPostParentUnion? = threadView.parent
            var oldestParent: AppBskyFeedDefs.ThreadViewPost?
            
            // Traverse to find the oldest parent
            while currentNode != nil {
              if case .appBskyFeedDefsThreadViewPost(let parentPost) = currentNode! {
                oldestParent = parentPost
                currentNode = parentPost.parent
              } else {
                break
              }
            }
            
            // Check if the oldest parent we found is the root post
            if let oldest = oldestParent {
              reachedRoot = oldest.parent == nil
              
              // Additional check for the root post - is it the one with text "1"?
              if reachedRoot {
                logger.debug("loadMoreParents: Found root post with URI: \(oldest.post.uri.uriString())")
                  if let text = try oldest.post.record.toJSON() as? [String: Any] {
                      let text = text["text"] as? String ?? ""
                    
                  logger.debug("loadMoreParents: Root post text: \"\(text)\"")
                }
              }
            }
          }
          
          // Log what happened
          if reachedRoot {
            logger.debug("loadMoreParents: Successfully reached the root post of the thread")
          } else {
            logger.warning("loadMoreParents: No new parents were added despite successful API call")
          }
          
          // Consider it a success if we either added parents or reached the root
          let success = addedParents || reachedRoot 
          
          isLoadingMoreParents = false
          return success  // Return true if we added more parents OR reached the root post
        }
      } else {
        logger.error("Failed to load more parents: HTTP \(responseCode)")
      }
    } catch {
      self.error = error
      logger.error("Error loading more parents: \(error.localizedDescription)")
    }

    isLoadingMoreParents = false
    return false
  }

  // MARK: - Shadow Merging

  /// Merges post shadow state with thread data for optimistic UI updates using an iterative approach
  /// - Parameter threadUnion: The thread data to process
  /// - Returns: Updated thread data with shadows applied
  private func mergeShadowsInThread(_ threadUnion: AppBskyFeedGetPostThread.OutputThreadUnion) async
    -> AppBskyFeedGetPostThread.OutputThreadUnion {
    // Keep track of original reply relationships
    var originalRepliesMap: [String: [AppBskyFeedDefs.ThreadViewPostRepliesUnion]] = [:]
    var processedThreads: [String: AppBskyFeedDefs.ThreadViewPost] = [:]

    func processNode(_ post: AppBskyFeedDefs.ThreadViewPost) async -> AppBskyFeedDefs.ThreadViewPost {
      let postURI = post.post.uri.uriString()

      // Save original replies structure
      if let replies = post.replies, !replies.isEmpty {
        originalRepliesMap[postURI] = replies
      }

      // Merge shadows for this post
      let mergedPost = await appState.postShadowManager.mergeShadow(post: post.post)

      // Process parent if it exists
      let mergedParent: AppBskyFeedDefs.ThreadViewPostParentUnion?
      if let parent = post.parent {
        switch parent {
        case .appBskyFeedDefsThreadViewPost(let parentThread):
          let processedParent = await processNode(parentThread)
          processedThreads[processedParent.post.uri.uriString()] = processedParent
          mergedParent = .appBskyFeedDefsThreadViewPost(processedParent)
        default:
          mergedParent = parent
        }
      } else {
        mergedParent = nil
      }

      // Process replies if they exist
      var mergedReplies: [AppBskyFeedDefs.ThreadViewPostRepliesUnion]?
      if let replies = post.replies {
        var processed: [AppBskyFeedDefs.ThreadViewPostRepliesUnion] = []
        for reply in replies {
          switch reply {
          case .appBskyFeedDefsThreadViewPost(let replyThread):
            let processedReply = await processNode(replyThread)
            processedThreads[processedReply.post.uri.uriString()] = processedReply
            processed.append(.appBskyFeedDefsThreadViewPost(processedReply))
          default:
            processed.append(reply)
          }
        }
        mergedReplies = processed
      }

      let result = AppBskyFeedDefs.ThreadViewPost(
        post: mergedPost,
        parent: mergedParent,
        replies: mergedReplies,
        threadContext: post.threadContext
      )

      processedThreads[postURI] = result
      return result
    }

    func findRepliesForPost(uri: String, processedThreads: [String: AppBskyFeedDefs.ThreadViewPost])
      -> [AppBskyFeedDefs.ThreadViewPostRepliesUnion]? {
      // First try to use the original structure
      if let originalReplies = originalRepliesMap[uri] {
        // Convert original replies to use processed posts
        var processedReplies: [AppBskyFeedDefs.ThreadViewPostRepliesUnion] = []

        for originalReply in originalReplies {
          if case .appBskyFeedDefsThreadViewPost(let originalReplyPost) = originalReply {
            let replyURI = originalReplyPost.post.uri.uriString()
            if let processedReplyPost = processedThreads[replyURI] {
              processedReplies.append(.appBskyFeedDefsThreadViewPost(processedReplyPost))
            } else {
              processedReplies.append(originalReply)  // Fallback to original
            }
          } else {
            processedReplies.append(originalReply)  // Non-standard reply types
          }
        }

        return processedReplies.isEmpty ? nil : processedReplies
      }

      // Fallback to reconstructing from parent relationships if no original structure found
      var replies: [AppBskyFeedDefs.ThreadViewPostRepliesUnion] = []

      for (_, replyThread) in processedThreads {
        if let parent = replyThread.parent,
          case .appBskyFeedDefsThreadViewPost(let parentThread) = parent,
          parentThread.post.uri.uriString() == uri {
          replies.append(.appBskyFeedDefsThreadViewPost(replyThread))
        }
      }

      return replies.isEmpty ? nil : replies
    }

    // Start processing from the root of the thread
    switch threadUnion {
    case .appBskyFeedDefsThreadViewPost(let threadViewPost):
      let processedRoot = await processNode(threadViewPost)
      return .appBskyFeedDefsThreadViewPost(processedRoot)
    case .appBskyFeedDefsNotFoundPost, .appBskyFeedDefsBlockedPost, .unexpected, .pending:
      return threadUnion        
    }
  }

  /// Integrates newly fetched parent posts into the existing thread structure using an iterative approach
  /// - Parameters:
  ///   - existingThread: The current thread structure
  ///   - parentThread: The newly fetched parent thread structure
  /// - Returns: Updated thread with extended parent chain
  @MainActor
  func integrateParentPosts(
    existingThread: AppBskyFeedGetPostThread.OutputThreadUnion,
    parentThread: AppBskyFeedGetPostThread.OutputThreadUnion
  ) async -> AppBskyFeedGetPostThread.OutputThreadUnion {
    // Check if existing thread is a valid thread post
    guard case .appBskyFeedDefsThreadViewPost(let existingRootPost) = existingThread else {
      logger.debug("integrateParentPosts: Existing thread is not a valid thread post")
      return existingThread
    }
    
    // SPECIAL CASE: Check if parentThread is the root post (no parent)
    if case .appBskyFeedDefsThreadViewPost(let parentThreadPost) = parentThread, 
       parentThreadPost.parent == nil {
      logger.debug("integrateParentPosts: Parent thread appears to be the root post (no parent)")
        
//        logger.debug("integrateParentPosts: Root post URI: \(parentThreadPost.post.uri.uriString()), text: \"\(parentThreadPost.post.record ?? "")\"")
      
      // Check the full existing chain to see if we already have this root post somewhere
      var hasRootAlready = false
      if let existingParent = existingRootPost.parent {
        var currentNode = existingParent
        while !hasRootAlready, case .appBskyFeedDefsThreadViewPost(let post) = currentNode {
          // Check if this post matches the root post
          if post.post.uri.uriString() == parentThreadPost.post.uri.uriString() {
            hasRootAlready = true
            logger.debug("integrateParentPosts: Root post is already in our chain")
            break
          }
          
          // Move to next parent if available
          if let nextParent = post.parent {
            currentNode = nextParent
          } else {
            break
          }
        }
      }
      
      // If we already have this root post in our chain, no need to integrate again
      if hasRootAlready {
        logger.debug("integrateParentPosts: Found matching root post already in our chain, no need to integrate")
        return existingThread
      }
      
      // If our existing post has only one parent and that parent has no parent,
      // and the parentThread also has no parent, this might be the same post
      if let existingParent = existingRootPost.parent,
         case .appBskyFeedDefsThreadViewPost(let existingParentPost) = existingParent,
         existingParentPost.parent == nil {
        // Check if URIs match
        if existingParentPost.post.uri.uriString() == parentThreadPost.post.uri.uriString() {
          logger.debug("integrateParentPosts: Found matching root posts, no need to integrate")
          return existingThread
        } else {
          logger.debug("integrateParentPosts: Found a new root post that's different from our existing parent")
          // Create a new parent chain by attaching the root post as the parent of our existing parent
          let newTopParent = AppBskyFeedDefs.ThreadViewPost(
            post: existingParentPost.post,
            parent: nil, // The existing parent now has no parent
            replies: existingParentPost.replies,
            threadContext: existingParentPost.threadContext
          )
          
          // Create the chain that attaches to the root post
          let result = AppBskyFeedDefs.ThreadViewPost(
            post: existingRootPost.post,
            parent: .appBskyFeedDefsThreadViewPost(newTopParent),
            replies: existingRootPost.replies,
            threadContext: existingRootPost.threadContext
          )
          return .appBskyFeedDefsThreadViewPost(result)
        }
      }
      
      // This is a fresh root post - attach it as the parent of our oldest ancestor
      logger.debug("integrateParentPosts: Integrating root post as the top parent")
      
      // STEP 1: Collect all posts in the existing parent chain into an array
      var existingParentChain: [AppBskyFeedDefs.ThreadViewPost] = []
      var currentPost: AppBskyFeedDefs.ThreadViewPostParentUnion? = existingRootPost.parent
      
      // Build the chain from immediate parent to oldest ancestor
      while let parent = currentPost {
        if case .appBskyFeedDefsThreadViewPost(let threadViewPost) = parent {
          existingParentChain.append(threadViewPost)
          currentPost = threadViewPost.parent
        } else {
          // Non-standard parent type (blocked/notfound), stop here
          break
        }
      }
      
      if existingParentChain.isEmpty {
        logger.debug("integrateParentPosts: No existing parents to attach root to")
        
        // Create a new thread with the root post as the direct parent
        let result = AppBskyFeedDefs.ThreadViewPost(
          post: existingRootPost.post,
          parent: .appBskyFeedDefsThreadViewPost(parentThreadPost),
          replies: existingRootPost.replies,
          threadContext: existingRootPost.threadContext
        )
        return .appBskyFeedDefsThreadViewPost(result)
      }
      
      // Get the oldest ancestor in our chain
      let oldestExistingAncestor = existingParentChain.last!
      
      // Create the extended chain with the root post as the parent of our oldest ancestor
      let extendedOldestAncestor = AppBskyFeedDefs.ThreadViewPost(
        post: oldestExistingAncestor.post,
        parent: .appBskyFeedDefsThreadViewPost(parentThreadPost),
        replies: oldestExistingAncestor.replies,
        threadContext: oldestExistingAncestor.threadContext
      )
      
      // Rebuild the chain from oldest to newest
      var rebuiltChain: AppBskyFeedDefs.ThreadViewPostParentUnion =
        .appBskyFeedDefsThreadViewPost(extendedOldestAncestor)
      
      // Skip the last element (oldest ancestor) as we already processed it
      for i in (0..<existingParentChain.count - 1).reversed() {
        let currentAncestor = existingParentChain[i]
        let rebuiltPost = AppBskyFeedDefs.ThreadViewPost(
          post: currentAncestor.post,
          parent: rebuiltChain,
          replies: currentAncestor.replies,
          threadContext: currentAncestor.threadContext
        )
        rebuiltChain = .appBskyFeedDefsThreadViewPost(rebuiltPost)
      }
      
      // Connect the root post to our rebuilt parent chain
      let result = AppBskyFeedDefs.ThreadViewPost(
        post: existingRootPost.post,
        parent: rebuiltChain,
        replies: existingRootPost.replies,
        threadContext: existingRootPost.threadContext
      )
      
      let finalResult = await mergeShadowsInThread(.appBskyFeedDefsThreadViewPost(result))
      logger.debug("integrateParentPosts: Successfully integrated root post at the top")
      return finalResult
    }

    // If no parent chain exists, handle simple case
    guard existingRootPost.parent != nil else {
      if case .appBskyFeedDefsThreadViewPost = parentThread,
        let connectionPoint = findConnectionPoint(
          existingPostURI: existingRootPost.post.uri.uriString(),
          parentThread: parentThread
        ) {
        logger.debug(
          "integrateParentPosts: No existing parent chain, found direct connection point")
        // Create new thread with connected parent
        let result = AppBskyFeedDefs.ThreadViewPost(
          post: existingRootPost.post,
          parent: connectionPoint.parent,
          replies: existingRootPost.replies,
          threadContext: existingRootPost.threadContext
        )
        return .appBskyFeedDefsThreadViewPost(result)
      }
      logger.debug("integrateParentPosts: No existing parent chain and no connection point found")
      return existingThread
    }

    // STEP 1: Collect all posts in the existing parent chain into an array
    var existingParentChain: [AppBskyFeedDefs.ThreadViewPost] = []
    var currentPost: AppBskyFeedDefs.ThreadViewPostParentUnion? = existingRootPost.parent

    // Build the chain from immediate parent to oldest ancestor
    while let parent = currentPost {
      if case .appBskyFeedDefsThreadViewPost(let threadViewPost) = parent {
        existingParentChain.append(threadViewPost)
        currentPost = threadViewPost.parent
      } else {
        // Non-standard parent type (blocked/notfound), stop here
        break
      }
    }

    logger.debug(
      "integrateParentPosts: Existing parent chain has \(existingParentChain.count) posts")

    // If chain is empty, return original
    if existingParentChain.isEmpty {
      logger.debug("integrateParentPosts: Existing parent chain is empty after processing")
      return existingThread
    }

    // STEP 2: Find the oldest ancestor in our existing chain
    let oldestExistingAncestor = existingParentChain.last!
    logger.debug(
      "integrateParentPosts: Oldest ancestor URI: \(oldestExistingAncestor.post.uri.uriString())")

    // Log if this might be a root post
    if oldestExistingAncestor.parent == nil {
      logger.debug("integrateParentPosts: Oldest ancestor appears to be the root post (no parent)")
    }

    // STEP 3: Find connection point in the new parent thread for this oldest ancestor
    guard
      let connectionPoint = findConnectionPoint(
        existingPostURI: oldestExistingAncestor.post.uri.uriString(),
        parentThread: parentThread
      )
    else {
      logger.debug("integrateParentPosts: No connection point found for oldest ancestor")
      
      // If we're at the root already and can't find a connection point, we're done
      if oldestExistingAncestor.parent == nil {
        logger.debug("integrateParentPosts: Already at root post with no further parents")
        return existingThread
      }
      
      // Special case: if parentThread is the root post and doesn't match our ancestors
      if case .appBskyFeedDefsThreadViewPost(let parentThreadPost) = parentThread, 
          parentThreadPost.parent == nil {
        logger.debug("integrateParentPosts: Found potential root post that doesn't match our ancestors")
        
        // Attempt to attach it to our oldest ancestor directly
        let extendedOldestAncestor = AppBskyFeedDefs.ThreadViewPost(
          post: oldestExistingAncestor.post,
          parent: .appBskyFeedDefsThreadViewPost(parentThreadPost),
          replies: oldestExistingAncestor.replies,
          threadContext: oldestExistingAncestor.threadContext
        )
        
        // Start rebuilding the chain
        var rebuiltChain: AppBskyFeedDefs.ThreadViewPostParentUnion =
          .appBskyFeedDefsThreadViewPost(extendedOldestAncestor)
        
        // Skip the last element (oldest ancestor) as we already processed it
        for i in (0..<existingParentChain.count - 1).reversed() {
          let currentAncestor = existingParentChain[i]
          let rebuiltPost = AppBskyFeedDefs.ThreadViewPost(
            post: currentAncestor.post,
            parent: rebuiltChain,
            replies: currentAncestor.replies,
            threadContext: currentAncestor.threadContext
          )
          rebuiltChain = .appBskyFeedDefsThreadViewPost(rebuiltPost)
        }
        
        // Connect the root post to our rebuilt parent chain
        let result = AppBskyFeedDefs.ThreadViewPost(
          post: existingRootPost.post,
          parent: rebuiltChain,
          replies: existingRootPost.replies,
          threadContext: existingRootPost.threadContext
        )
        
        let finalResult = await mergeShadowsInThread(.appBskyFeedDefsThreadViewPost(result))
        logger.debug("integrateParentPosts: Attached root post directly to oldest ancestor")
        return finalResult
      }
      
      return existingThread
    }

    // Log the connection point's parent URI if available
    if let connectionParent = connectionPoint.parent {
      if case .appBskyFeedDefsThreadViewPost(let parentPost) = connectionParent {
        logger.debug(
          "integrateParentPosts: Connection point parent URI: \(parentPost.post.uri.uriString())")
      } else {
        logger.debug("integrateParentPosts: Connection point has non-standard parent")
      }
    } else {
      logger.debug("integrateParentPosts: Connection point has no parent")
    }

    // STEP 4: Create a new parent chain by connecting our oldest ancestor to new parents
    let extendedOldestAncestor = AppBskyFeedDefs.ThreadViewPost(
      post: oldestExistingAncestor.post,
      parent: connectionPoint.parent,
      replies: oldestExistingAncestor.replies,
      threadContext: oldestExistingAncestor.threadContext
    )

    // STEP 5: Rebuild the chain from oldest to newest by working backward
    var rebuiltChain: AppBskyFeedDefs.ThreadViewPostParentUnion =
      .appBskyFeedDefsThreadViewPost(extendedOldestAncestor)

    // Skip the last element (oldest ancestor) as we already processed it
    for i in (0..<existingParentChain.count - 1).reversed() {
      let currentAncestor = existingParentChain[i]
      let rebuiltPost = AppBskyFeedDefs.ThreadViewPost(
        post: currentAncestor.post,
        parent: rebuiltChain,
        replies: currentAncestor.replies,
        threadContext: currentAncestor.threadContext
      )
      rebuiltChain = .appBskyFeedDefsThreadViewPost(rebuiltPost)
    }

    logger.debug("integrateParentPosts: Rebuilt parent chain successfully")

    // STEP 6: Finally, connect the root post to our rebuilt parent chain
    let result = AppBskyFeedDefs.ThreadViewPost(
      post: existingRootPost.post,
      parent: rebuiltChain,
      replies: existingRootPost.replies,
      threadContext: existingRootPost.threadContext
    )

    // Apply shadow merging to the integrated results
    let finalResult = await mergeShadowsInThread(.appBskyFeedDefsThreadViewPost(result))

    // Verify the final parent chain length
    if case .appBskyFeedDefsThreadViewPost(let finalThreadView) = finalResult {
      var finalParentCount = 0
      var finalParent: AppBskyFeedDefs.ThreadViewPostParentUnion? = finalThreadView.parent

      while finalParent != nil {
        finalParentCount += 1
        if case .appBskyFeedDefsThreadViewPost(let parentView) = finalParent! {
          finalParent = parentView.parent
        } else {
          finalParent = nil
        }
      }

      logger.debug("integrateParentPosts: Final parent chain has \(finalParentCount) posts")
    }

    return finalResult
  }

  /// Finds the connection point in the parent thread that links to our existing post - iterative approach
  /// - Parameters:
  ///   - existingPostURI: URI of the existing post we're trying to connect to
  ///   - parentThread: The parent thread to search in
  /// - Returns: The thread view post that should be the parent of our existing post
  private func findConnectionPoint(
    existingPostURI: String,
    parentThread: AppBskyFeedGetPostThread.OutputThreadUnion
  ) -> AppBskyFeedDefs.ThreadViewPost? {
    logger.debug("findConnectionPoint: Searching for connection point for URI: \(existingPostURI)")

    // Use a queue for breadth-first search (BFS)
    var queue: [(node: AppBskyFeedGetPostThread.OutputThreadUnion, depth: Int)] = []
    queue.append((parentThread, 0))

    // Track visited nodes to avoid cycles
    var visitedURIs = Set<String>()

    while !queue.isEmpty {
      let (currentNode, depth) = queue.removeFirst()

      switch currentNode {
      case .appBskyFeedDefsThreadViewPost(let threadViewPost):
        let currentPostURI = threadViewPost.post.uri.uriString()

        // Skip if already visited
        if visitedURIs.contains(currentPostURI) {
          continue
        }
        visitedURIs.insert(currentPostURI)

        logger.debug("findConnectionPoint: Checking post at depth \(depth): \(currentPostURI)")

        // Check if this post itself is what we're looking for
        if currentPostURI == existingPostURI {
          logger.debug("findConnectionPoint: Found exact match in current post: \(currentPostURI)")
          return threadViewPost
        }

        // Check if any replies in this post point to our existing post
        if let replies = threadViewPost.replies {
          logger.debug(
            "findConnectionPoint: Checking \(replies.count) replies of post \(currentPostURI)")

          for reply in replies {
            switch reply {
            case .appBskyFeedDefsThreadViewPost(let replyPost):
              let replyURI = replyPost.post.uri.uriString()

              // If the reply is our target, the current post is the connection point
              if replyURI == existingPostURI {
                logger.debug("findConnectionPoint: Found match in reply: \(replyURI)")
                return threadViewPost
              }

              // Add this reply to the queue to be processed
              queue.append(
                (
                  .appBskyFeedDefsThreadViewPost(replyPost),
                  depth + 1
                ))

            default:
              break
            }
          }
        }

        // Add the parent to the queue to be processed
        if let parent = threadViewPost.parent {
          switch parent {
          case .appBskyFeedDefsThreadViewPost(let parentThreadPost):
            queue.append(
              (
                .appBskyFeedDefsThreadViewPost(parentThreadPost),
                depth + 1
              ))
          default:
            break
          }
        }
        default:
        logger.debug("findConnectionPoint: Skipping non-standard post type")
      }
    }

    logger.debug("findConnectionPoint: No connection point found after checking all posts")
    return nil
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
    threadViewPost = nil
    currentThreadURI = nil
    error = nil
    isLoading = false
    isLoadingMoreParents = false
  }
}

// Helper extension to convert OutputThreadUnion to ThreadViewPostParentUnion
extension AppBskyFeedGetPostThread.OutputThreadUnion {
  func asThreadViewPostParentUnion() -> AppBskyFeedDefs.ThreadViewPostParentUnion? {
    switch self {
    case .appBskyFeedDefsThreadViewPost(let threadViewPost):
      return .appBskyFeedDefsThreadViewPost(threadViewPost)
    case .appBskyFeedDefsNotFoundPost(let notFoundPost):
      return .appBskyFeedDefsNotFoundPost(notFoundPost)
    case .appBskyFeedDefsBlockedPost(let blockedPost):
      return .appBskyFeedDefsBlockedPost(blockedPost)
    case .unexpected:
      return nil
    case .pending:
        return nil
    }
  }
}

/// Parent post representation, copied from ThreadView so it can be used across classes
public struct ParentPost: Identifiable, Equatable, Hashable, Sendable {
  public let id: String
  public let post: AppBskyFeedDefs.ThreadViewPostParentUnion
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
    let reply: AppBskyFeedDefs.ThreadViewPostRepliesUnion
    let depth: Int
    let isFromOP: Bool
    let hasReplies: Bool
      
    static func == (lhs: ReplyWrapper, rhs: ReplyWrapper) -> Bool {
      return lhs.id == rhs.id
      // Optionally include the scalar properties if needed
      // && lhs.isFromOP == rhs.isFromOP && lhs.hasReplies == rhs.hasReplies
    }
    
    // Ensure hash value is based only on id to match equality implementation
    func hash(into hasher: inout Hasher) {
      hasher.combine(id)
    }
  }
