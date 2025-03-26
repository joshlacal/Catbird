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
final class ThreadManager {
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
  private let logger = Logger(subsystem: "com.joshlacalamito.Catbird", category: "ThreadManager")

  // MARK: - Private Properties

  /// Reference to the app state
  private let appState: AppState

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
  }

  // MARK: - Thread Loading

  /// Load a thread by its URI
  /// - Parameter uri: The post URI to load
  @MainActor
  func loadThread(uri: ATProtocolURI) async {
    isLoading = true
    error = nil

    logger.debug("Loading thread: \(uri.uriString())")

    do {
      let params = AppBskyFeedGetPostThread.Parameters(
        uri: uri,
        depth: nil,  // Let API decide depth for replies
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
    logger.debug("Loading more parents for post: \(uri.uriString())")

    do {
      // Request a thread with focus on parent posts
      let params = AppBskyFeedGetPostThread.Parameters(
        uri: uri,
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

          isLoadingMoreParents = false
          return newParentCount > currentParentCount  // Return true only if we actually added more parents
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
    -> AppBskyFeedGetPostThread.OutputThreadUnion
  {
    // Keep track of original reply relationships
    var originalRepliesMap: [String: [AppBskyFeedDefs.ThreadViewPostRepliesUnion]] = [:]
    var processedThreads: [String: AppBskyFeedDefs.ThreadViewPost] = [:]

    func processNode(_ post: AppBskyFeedDefs.ThreadViewPost) async -> AppBskyFeedDefs.ThreadViewPost
    {
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
      var mergedReplies: [AppBskyFeedDefs.ThreadViewPostRepliesUnion]? = nil
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
      -> [AppBskyFeedDefs.ThreadViewPostRepliesUnion]?
    {
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
          parentThread.post.uri.uriString() == uri
        {
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

    // If no parent chain exists, handle simple case
    guard existingRootPost.parent != nil else {
      if case .appBskyFeedDefsThreadViewPost = parentThread,
        let connectionPoint = findConnectionPoint(
          existingPostURI: existingRootPost.post.uri.uriString(),
          parentThread: parentThread
        )
      {
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

    // STEP 3: Find connection point in the new parent thread for this oldest ancestor
    guard
      let connectionPoint = findConnectionPoint(
        existingPostURI: oldestExistingAncestor.post.uri.uriString(),
        parentThread: parentThread
      )
    else {
      logger.debug("integrateParentPosts: No connection point found for oldest ancestor")
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
        break
      }
    }

    logger.debug("findConnectionPoint: No connection point found after checking all posts")
    return nil
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
    case .pending(_):
        return nil
    }
  }
}

/// Parent post representation, copied from ThreadView so it can be used across classes
public struct ParentPost: Identifiable, Equatable {
  public let id: String
  public let post: AppBskyFeedDefs.ThreadViewPostParentUnion
  public let grandparentAuthor: AppBskyActorDefs.ProfileViewBasic?

  public static func == (lhs: ParentPost, rhs: ParentPost) -> Bool {
    return lhs.id == rhs.id
  }
}

  struct ReplyWrapper: Identifiable, Equatable {
    let id: String
    let reply: AppBskyFeedDefs.ThreadViewPostRepliesUnion
    let isFromOP: Bool
    let hasReplies: Bool
      static func == (lhs: ReplyWrapper, rhs: ReplyWrapper) -> Bool {
        return lhs.id == rhs.id
        // Optionally include the scalar properties if needed
        // && lhs.isFromOP == rhs.isFromOP && lhs.hasReplies == rhs.hasReplies
      }

  }
