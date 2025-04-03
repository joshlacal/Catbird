import Foundation
import OSLog
import Petrel
import SwiftUI

/// Manages all post-related operations and state
@Observable
final class PostManager {
  // MARK: - Properties

  private let logger = Logger(subsystem: "blue.catbird", category: "PostManager")

  /// Posting status states
  enum PostingStatus {
    case idle
    case posting
    case success
    case error(String)
  }

  /// Current posting status
  private(set) var status: PostingStatus = .idle

  /// Reference to the ATProto client for making API calls
  private weak var client: ATProtoClient?

  // MARK: - Initialization

  init(client: ATProtoClient?) {
    self.client = client
    logger.debug("PostManager initialized")
  }

  /// Update client reference when it changes
  func updateClient(_ client: ATProtoClient?) {
    self.client = client
  }

  // MARK: - Post Creation

  /// Creates a new post or reply on the Bluesky network
  func createPost(
    _ postText: String,
    languages: [LanguageCodeContainer],
    metadata: [String: String] = [:],
    hashtags: [String] = [],
    facets: [AppBskyRichtextFacet] = [],
    parentPost: AppBskyFeedDefs.PostView? = nil,
    selfLabels: ComAtprotoLabelDefs.SelfLabels,
    embed: AppBskyFeedPost.AppBskyFeedPostEmbedUnion? = nil,
    threadgateAllowRules: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]? = nil
  ) async throws {
    logger.info(
      "Creating \(parentPost == nil ? "post" : "reply") with text length: \(postText.count)")

    // Update status
    status = .posting

    do {
      // Ensure client exists
      guard let client = client else {
        let error = AuthError.clientNotInitialized
        status = .error(error.localizedDescription)
        throw error
      }

      let currentDate = Date()
      let currentATProtocolDate = ATProtocolDate(date: currentDate)

      // Get user DID
      let did = try await client.getDid()

      // Generate TID for the post
      let tid = await TIDGenerator.nextTID()

      // Create the post URI
      let postURI = try ATProtocolURI(uriString: "at://\(did)/app.bsky.feed.post/\(tid)")
      logger.debug("Generated post URI: \(postURI)")

      // Prepare reply reference if this is a reply
      var reply: AppBskyFeedPost.ReplyRef?
      if let parentPost = parentPost {
        reply = try createReplyRef(for: parentPost)
      }

      // Create post labels
      let postLabels = AppBskyFeedPost.AppBskyFeedPostLabelsUnion.comAtprotoLabelDefsSelfLabels(
        selfLabels)

      // Create the post object
      let newPost = AppBskyFeedPost(
        text: postText,
        entities: nil,
        facets: facets,
        reply: reply,
        embed: embed,
        langs: languages,
        labels: postLabels,
        tags: hashtags,
        createdAt: currentATProtocolDate
      )

      // Prepare writes array for batched operation
      var writes: [ComAtprotoRepoApplyWrites.InputWritesUnion] = []

      // Encode post to CBOR to generate CID
      let postData = try newPost.encodedDAGCBOR()
      let cid = CID.fromDAGCBOR(postData)
      logger.debug("Post CID: \(cid)")

      // Add post creation to writes
      let createPost = ComAtprotoRepoApplyWrites.Create(
        collection: try NSID(nsidString: "app.bsky.feed.post"),
        rkey: try RecordKey(keyString: tid.description),
        value: ATProtocolValueContainer.knownType(newPost)
      )
      writes.append(ComAtprotoRepoApplyWrites.InputWritesUnion(createPost))

      // Add threadgate creation if applicable
      if let allowRules = threadgateAllowRules {
        // Create threadgate
        let threadgate = AppBskyFeedThreadgate(
          post: postURI,
          allow: allowRules,
          createdAt: currentATProtocolDate,
          hiddenReplies: nil
        )

        // Create threadgate with standard "gate" record key
        let createThreadgate = ComAtprotoRepoApplyWrites.Create(
          collection: try NSID(nsidString: "app.bsky.feed.threadgate"),
          rkey: try RecordKey(keyString: tid.description),
          value: ATProtocolValueContainer.knownType(threadgate)
        )
        writes.append(ComAtprotoRepoApplyWrites.InputWritesUnion(createThreadgate))
        logger.debug("Added threadgate creation to batch")
      }

      // Execute batch write operation
      let input = ComAtprotoRepoApplyWrites.Input(
        repo: try ATIdentifier(string: did),
        validate: true,
        writes: writes
      )

      // Execute the batch operation
      logger.info("Executing batch write operation with \(writes.count) operations")
      let (responseCode, _) = try await client.com.atproto.repo.applyWrites(input: input)

      // Handle the response
      if responseCode != 200 {
        let error = AuthError.badResponse(responseCode)
        status = .error(error.localizedDescription)
        throw error
      }

      // Update status on success
      status = .success
      logger.info("\(parentPost == nil ? "New post" : "Reply") created successfully")

      // Reset to idle after brief delay
      Task {
        try? await Task.sleep(for: .seconds(2))
        status = .idle
      }

    } catch {
      // Update status on error
      status = .error(error.localizedDescription)
      logger.error("Failed to create post: \(error.localizedDescription)")
      throw error
    }
  }
  /// Creates a reply reference for a parent post
  private func createReplyRef(for parentPost: AppBskyFeedDefs.PostView) throws
    -> AppBskyFeedPost.ReplyRef
  {
    logger.debug("Creating reply reference for post: \(parentPost.uri)")

    // Use the parentPost CID directly - this is the actual CID of the post as stored in the network
    let parentRef = ComAtprotoRepoStrongRef(uri: parentPost.uri, cid: parentPost.cid)
    logger.debug("Parent reference created: uri=\(parentPost.uri), cid=\(parentPost.cid)")

    // For the root, check if this is already a reply (in which case use its root)
    // or if it's the root itself
    let rootRef: ComAtprotoRepoStrongRef
    if case let .knownType(bskyPost) = parentPost.record,
      let postObj = bskyPost as? AppBskyFeedPost,
      let replyRoot = postObj.reply?.root
    {
      rootRef = replyRoot
      logger.debug(
        "Using existing root reference from parent: uri=\(replyRoot.uri), cid=\(replyRoot.cid)")
    } else {
      // If not a reply, the parent is the root
      rootRef = parentRef
      logger.debug("Parent post is the root of thread: uri=\(parentRef.uri)")
    }

    logger.info("Reply reference created - root: \(rootRef.uri), parent: \(parentRef.uri)")
    return AppBskyFeedPost.ReplyRef(root: rootRef, parent: parentRef)
  }

  /// Reset any error state
  func resetError() {
    if case .error = status {
      status = .idle
    }
  }

  /// Creates a thread of multiple posts in a single batch operation
  /// - Parameters:
  ///   - posts: Array of post texts to create as a thread
  ///   - languages: Language codes for the posts
  ///   - selfLabels: Content labels for the posts
  ///   - hashtags: Optional hashtags to include
  ///   - facets: Optional array of facets arrays for each post
  ///   - embeds: Optional array of embeds for each post
  ///   - threadgateAllowRules: Optional array of threadgate rules for the first post
  func createThread(
    posts: [String],
    languages: [LanguageCodeContainer],
    selfLabels: ComAtprotoLabelDefs.SelfLabels,
    hashtags: [String] = [],
    facets: [[AppBskyRichtextFacet]?]? = nil,
    embeds: [AppBskyFeedPost.AppBskyFeedPostEmbedUnion?]? = nil,
    threadgateAllowRules: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]? = nil
  ) async throws {
    logger.info("Starting thread creation with \(posts.count) posts")

    guard !posts.isEmpty else {
      logger.warning("Attempted to create empty thread, aborting")
      return
    }

    guard let client = client else {
      logger.error("Client not initialized, unable to create thread")
      throw AuthError.clientNotInitialized
    }

    // Update status
    status = .posting
    logger.debug("Thread posting status set to .posting")

    do {
      // Get user DID
      logger.debug("Fetching user DID")
      let did = try await client.getDid()
      logger.info("Using DID: \(did)")

      let currentDate = Date()

      // Generate TIDs for all posts
      logger.debug("Generating record keys (TIDs) for \(posts.count) posts")
      let rkeys = try await generateRKeys(count: posts.count)
      logger.debug("Generated keys: \(rkeys)")

      // Create an array to hold all write operations
      var writes: [ComAtprotoRepoApplyWrites.InputWritesUnion] = []
      logger.debug("Preparing write operations for batch processing")

      // Keep track of root and parent references
      var rootRef: ComAtprotoRepoStrongRef?
      var parentRef: ComAtprotoRepoStrongRef?

      // Process each post
      for (index, postText) in posts.enumerated() {
        // Create a slightly incremented timestamp for each post
        let postDate = currentDate.addingTimeInterval(Double(index) / 1000.0)  // Add index milliseconds
        let postATProtocolDate = ATProtocolDate(date: postDate)

        logger.debug("Processing post #\(index+1) with \(postText.count) characters")

        // Create post URI
        let postURI = try ATProtocolURI(uriString: "at://\(did)/app.bsky.feed.post/\(rkeys[index])")
        logger.debug("Post #\(index+1) URI: \(postURI)")

        // Create post object
        var reply: AppBskyFeedPost.ReplyRef?

        // For posts after the first one, set up reply references
        if index > 0, let root = rootRef, let parent = parentRef {
          logger.debug("Creating reply reference for post #\(index+1)")
          reply = AppBskyFeedPost.ReplyRef(root: root, parent: parent)
          logger.debug("Reply reference - root: \(root.uri), parent: \(parent.uri)")
        }

        // Create post labels
        let postLabels = AppBskyFeedPost.AppBskyFeedPostLabelsUnion.comAtprotoLabelDefsSelfLabels(
          selfLabels)
        logger.debug("Applied content labels to post #\(index+1)")

        // Get facets for this post if available
        let postFacets = facets != nil && index < facets!.count ? facets![index] : nil
        logger.debug("Post #\(index+1) has \(postFacets?.count ?? 0) facets")

        // Get embed for this post if available
        let postEmbed = embeds != nil && index < embeds!.count ? embeds![index] : nil
        if postEmbed != nil {
          logger.debug("Post #\(index+1) includes an embed")
        }

        // Create the post object
        let post = AppBskyFeedPost(
          text: postText,
          entities: nil,
          facets: postFacets,
          reply: reply,
          embed: postEmbed,
          langs: languages,
          labels: postLabels,
          tags: hashtags,
          createdAt: postATProtocolDate
        )
        logger.debug("Post #\(index+1) object created")

        // Encode post to CBOR to generate CID
        logger.debug("Encoding post #\(index+1) to DAGCBOR")
        let postData = try post.encodedDAGCBOR()
        let cid = CID.fromDAGCBOR(postData)
        logger.debug("Post #\(index+1) CID: \(cid)")

        // If this is the first post, set it as the root for the thread
        if index == 0 {
          rootRef = ComAtprotoRepoStrongRef(uri: postURI, cid: cid)
          logger.debug("First post set as thread root: \(postURI)")
        }

        // Set this post as the parent for the next post
        parentRef = ComAtprotoRepoStrongRef(uri: postURI, cid: cid)
        logger.debug("Set parent reference for next post: \(postURI)")

        // Create write operation for this post
        let create = ComAtprotoRepoApplyWrites.Create(
          collection: try NSID(nsidString: "app.bsky.feed.post"),
          rkey: try RecordKey(keyString: rkeys[index].description),
          value: ATProtocolValueContainer.knownType(post)
        )
        logger.debug("Created write operation for post #\(index+1)")

        writes.append(ComAtprotoRepoApplyWrites.InputWritesUnion(create))
        logger.debug("Added post #\(index+1) to batch write queue")

        // Add threadgate for the first post if applicable
        if index == 0 && threadgateAllowRules != nil {
          let threadgate = AppBskyFeedThreadgate(
            post: postURI,
            allow: threadgateAllowRules!,
            createdAt: postATProtocolDate,
            hiddenReplies: nil
          )

          // Create threadgate with standard "gate" record key
          let createThreadgate = ComAtprotoRepoApplyWrites.Create(
            collection: try NSID(nsidString: "app.bsky.feed.threadgate"),
            rkey: try RecordKey(keyString: rkeys[index].description),
            value: ATProtocolValueContainer.knownType(threadgate)
          )
          writes.append(ComAtprotoRepoApplyWrites.InputWritesUnion(createThreadgate))
          logger.debug("Added threadgate creation for first post")
        }
      }

      // Create the input for applyWrites
      logger.info("Preparing batch applyWrites operation with \(writes.count) operations")
      let input = ComAtprotoRepoApplyWrites.Input(
        repo: try ATIdentifier(string: did),
        validate: true,
        writes: writes
      )

      // Execute the batch operation
      logger.info("Executing batch write operation")
      let (responseCode, _) = try await client.com.atproto.repo.applyWrites(input: input)
      logger.debug("Batch write response code: \(responseCode)")

      // Handle the response
      if responseCode != 200 {
        logger.error("Error response from server: \(responseCode)")
        let error = AuthError.badResponse(responseCode)
        status = .error(error.localizedDescription)
        throw error
      }

      // Update status on success
      status = .success
      logger.info("Thread with \(posts.count) posts created successfully")

      // Reset to idle after brief delay
      logger.debug("Scheduling status reset after delay")
      Task {
        try? await Task.sleep(for: .seconds(2))
        status = .idle
        logger.debug("Status reset to idle")
      }

    } catch {
      // Update status on error
      status = .error(error.localizedDescription)
      logger.error("Failed to create thread: \(error.localizedDescription)")
      throw error
    }
  }

  /// Generates an array of TIDs to use as record keys
  private func generateRKeys(count: Int) async throws -> [TID] {
    var rkeys: [TID] = []
    for _ in 0..<count {
      let tid = await TIDGenerator.nextTID()
      rkeys.append(tid)
    }
    return rkeys
  }

  // Post Manager Errors
  enum AuthError: Error {
    case clientNotInitialized
    case badResponse(Int)

    var localizedDescription: String {
      switch self {
      case .clientNotInitialized:
        return "Client not initialized"
      case .badResponse(let code):
        return "Bad response: \(code)"
      }
    }
  }
}
