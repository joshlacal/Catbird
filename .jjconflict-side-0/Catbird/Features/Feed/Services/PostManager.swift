import Foundation
import OSLog
import Petrel
import SwiftUI

/// Manages all post-related operations and state
@Observable
final class PostManager {
  // MARK: - Properties

  private let logger = Logger(OSLog.postManager)

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
  
  /// Reference to app state for triggering invalidation events
  private weak var appState: AppState?

  // MARK: - Initialization

  init(client: ATProtoClient?, appState: AppState? = nil) {
    self.client = client
    self.appState = appState
    logger.debug("PostManager initialized")
  }

  /// Update client reference when it changes
  func updateClient(_ client: ATProtoClient?) {
    self.client = client
  }
  
  /// Update app state reference
  func updateAppState(_ appState: AppState?) {
    self.appState = appState
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
    threadgateAllowRules: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]? = nil,
    postgateEmbeddingRules: [AppBskyFeedPostgate.AppBskyFeedPostgateEmbeddingRulesUnion]? = nil
  ) async throws -> ATProtocolURI {
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
        let ref = Self.createReplyRef(for: parentPost)
        reply = ref
        logger.debug("Created reply reference: root=\(ref.root.uri), parent=\(ref.parent.uri)")
      } else {
        logger.debug("No parent post - creating root post")
      }

      // Create post labels only if selfLabels has content
      let postLabels: AppBskyFeedPost.AppBskyFeedPostLabelsUnion?
      if !selfLabels.values.isEmpty {
        postLabels = AppBskyFeedPost.AppBskyFeedPostLabelsUnion.comAtprotoLabelDefsSelfLabels(selfLabels)
      } else {
        postLabels = nil
      }

      // Create the post object
      let newPost = AppBskyFeedPost(
        text: postText,
        entities: nil,
        facets: facets.isEmpty ? nil : facets,
        reply: reply,
        embed: embed,
        langs: languages,
        labels: postLabels,
        tags: hashtags.isEmpty ? nil : hashtags,
        createdAt: currentATProtocolDate
      )
      
      logger.debug("Created post object - reply field: \(reply != nil ? "present" : "nil")")
      if let reply = reply {
        logger.debug("Reply details - root: \(reply.root.uri), parent: \(reply.parent.uri)")
      }

      // Prepare writes array for batched operation
      var writes: [ComAtprotoRepoApplyWrites.InputWritesUnion] = []

      // Encode post to CBOR to generate CID
      logger.debug("Encoding post to CBOR...")
      let postData = try newPost.encodedDAGCBOR()
      let cid = CID.fromDAGCBOR(postData)
      logger.debug("Post CID: \(cid)")
      logger.debug("Post CBOR length: \(postData.count) bytes")
      
      // Debug: check what fields are in the CBOR value
      let cborValue = try newPost.toCBORValue()
      if let orderedMap = cborValue as? OrderedCBORMap {
        logger.debug("CBOR fields in post:")
        for (key, _) in orderedMap.entries {
          logger.debug("  - \(key)")
        }
      }

      // Add post creation to writes
      let valueContainer = ATProtocolValueContainer.knownType(newPost)
      logger.debug("Wrapped post in ATProtocolValueContainer")
      
      // Debug: check if reply field survives the container wrapping
      let containerCBOR = try valueContainer.toCBORValue()
      if let orderedMap = containerCBOR as? OrderedCBORMap {
        logger.debug("ATProtocolValueContainer CBOR fields:")
        for (key, _) in orderedMap.entries {
          logger.debug("  - \(key)")
        }
        
        // Check specifically for reply field
        let hasReply = orderedMap.entries.contains { $0.key == "reply" }
        logger.debug("Reply field in container: \(hasReply)")
      }
      
      let createPost = ComAtprotoRepoApplyWrites.Create(
        collection: try NSID(nsidString: "app.bsky.feed.post"),
        rkey: try RecordKey(keyString: tid.description),
        value: valueContainer
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
      // Add postgate creation if applicable
      if let embeddingRules = postgateEmbeddingRules, !embeddingRules.isEmpty {
        let postgate = AppBskyFeedPostgate(
          createdAt: currentATProtocolDate,
          post: postURI,
          detachedEmbeddingUris: nil,
          embeddingRules: embeddingRules
        )
        let createPostgate = ComAtprotoRepoApplyWrites.Create(
          collection: try NSID(nsidString: "app.bsky.feed.postgate"),
          rkey: try RecordKey(keyString: tid.description),
          value: ATProtocolValueContainer.knownType(postgate)
        )
        writes.append(ComAtprotoRepoApplyWrites.InputWritesUnion(createPostgate))
        logger.debug("Added postgate creation to batch")
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
      
      // Create a temporary post for optimistic updates
      if let appState = appState {
        Task { @MainActor in
          // Create a temporary PostView for optimistic updates
          let tempPost = try createTemporaryPost(
            text: postText,
            did: did,
            uri: postURI,
            cid: cid,
            parentPost: parentPost,
            embed: embed,
            languages: languages,
            labels: selfLabels,
            createdAt: currentATProtocolDate
          )
          
          if let parentPost = parentPost {
            // This is a reply - send proper reply created event
            let parentUriString = parentPost.uri.uriString()
            appState.stateInvalidationBus.notify(.replyCreated(tempPost, parentUri: parentUriString))
            
            // Also notify thread update for the root post
            let rootUri = getRootUri(from: parentPost)
            appState.stateInvalidationBus.notify(.threadUpdated(rootUri: rootUri))
            
            // Show reply success toast with tap to view
            appState.toastManager.show(
              ToastItem(
                message: "Reply posted",
                icon: "bubble.left.and.bubble.right.fill",
                duration: 3.0,
//                action: .navigateToThread(postURI: postURI.uriString())
              )
            )
          } else {
            // This is a new post - send post created event
            appState.stateInvalidationBus.notify(.postCreated(tempPost))
            
            // Show post success toast with tap to view
            appState.toastManager.show(
              ToastItem(
                message: "Post published",
                icon: "paperplane.fill",
                duration: 3.0,
//                action: .navigateToPost(postURI: postURI.uriString(), authorHandle: "")
              )
            )
          }
          
          // Always notify profile update when a user creates a post
          // This ensures the user's profile refreshes when viewing their own profile
          appState.stateInvalidationBus.notify(.profileUpdated(did: did))
        }
      }

      // Reset to idle after brief delay
      Task {
        try? await Task.sleep(for: .seconds(2))
        status = .idle
      }

      return postURI

    } catch {
      // Update status on error
      status = .error(error.localizedDescription)
      logger.error("Failed to create post: \(error.localizedDescription)")
      throw error
    }
  }
  /// Creates a reply reference for a parent post
  static func createReplyRef(for parentPost: AppBskyFeedDefs.PostView)
    -> AppBskyFeedPost.ReplyRef {
    // Use the parentPost CID directly - this is the actual CID of the post as stored in the network
    let parentRef = ComAtprotoRepoStrongRef(uri: parentPost.uri, cid: parentPost.cid)

    // For the root, check if this is already a reply (in which case use its root)
    // or if it's the root itself
    let rootRef: ComAtprotoRepoStrongRef
    if case let .knownType(bskyPost) = parentPost.record,
      let postObj = bskyPost as? AppBskyFeedPost,
      let replyRoot = postObj.reply?.root {
      rootRef = replyRoot
    } else {
      // If not a reply, the parent is the root
      rootRef = parentRef
    }

    return AppBskyFeedPost.ReplyRef(root: rootRef, parent: parentRef)
  }

  /// Reset any error state
  func resetError() {
    if case .error = status {
      status = .idle
    }
  }
  
  // MARK: - Helper Methods
  
  /// Creates a temporary PostView for optimistic updates
  private func createTemporaryPost(
    text: String,
    did: String,
    uri: ATProtocolURI,
    cid: CID,
    parentPost: AppBskyFeedDefs.PostView?,
    embed: AppBskyFeedPost.AppBskyFeedPostEmbedUnion?,
    languages: [LanguageCodeContainer],
    labels: ComAtprotoLabelDefs.SelfLabels,
    createdAt: ATProtocolDate
  ) throws -> AppBskyFeedDefs.PostView {
    // Create author using current user's profile if available
    let author: AppBskyActorDefs.ProfileViewBasic
    
    if let currentProfile = appState?.currentUserProfile {
      // Use the actual user's profile data
      author = AppBskyActorDefs.ProfileViewBasic(
        did: try DID(didString: did),
        handle: currentProfile.handle,
        displayName: currentProfile.displayName,
        pronouns: currentProfile.pronouns, avatar: currentProfile.avatar,
        associated: currentProfile.associated,
        viewer: currentProfile.viewer,
        labels: currentProfile.labels,
        createdAt: currentProfile.createdAt,
        verification: currentProfile.verification,
        status: currentProfile.status,
        debug: nil
      )
    } else {
      // Fallback to minimal profile
      author = AppBskyActorDefs.ProfileViewBasic(
        did: try DID(didString: did),
        handle: try Handle(handleString: "temp.handle"), // This will be updated when the real post loads
        displayName: nil,
        pronouns: nil, avatar: nil,
        associated: nil,
        viewer: AppBskyActorDefs.ViewerState(
            muted: false,
            mutedOnlyReposts: nil,
            mutedOnlyQuoteposts: nil,
            mutedByList: nil,
            blockedBy: false,
            blocking: nil,
            blockingByList: nil,
            following: nil,
            followedBy: nil,
            knownFollowers: nil,
            activitySubscription: nil
        ),
        labels: [],
        createdAt: nil,
        verification: nil,
        status: nil,
        debug: nil
      )
    }
    
    // Create post labels only if labels has content
    let postLabels: AppBskyFeedPost.AppBskyFeedPostLabelsUnion?
    if !labels.values.isEmpty {
      postLabels = AppBskyFeedPost.AppBskyFeedPostLabelsUnion.comAtprotoLabelDefsSelfLabels(labels)
    } else {
      postLabels = nil
    }
    
    // Create the post record
    let postRecord = AppBskyFeedPost(
      text: text,
      entities: nil,
      facets: nil,
      reply: parentPost != nil ? Self.createReplyRef(for: parentPost!) : nil,
      embed: embed,
      langs: languages,
      labels: postLabels,
      tags: nil,
      createdAt: createdAt
    )
    
    // Convert the embed from PostEmbedUnion to PostViewEmbedUnion if available
    let postViewEmbed: AppBskyFeedDefs.PostViewEmbedUnion?
    if let embed = embed {
      switch embed {
      case .appBskyEmbedImages(let images):
        // Convert to view format
        let imageViews = try images.images.map { image in
          // Construct proper Bluesky CDN URLs
          let cidString = image.image.ref?.cid.string ?? ""
          let thumbUrlString = "https://cdn.bsky.app/img/feed_thumbnail/plain/\(did)/\(cidString)@jpeg"
          let fullsizeUrlString = "https://cdn.bsky.app/img/feed_fullsize/plain/\(did)/\(cidString)@jpeg"
          
          // If we can't create valid URIs, throw an error to prevent creating a temp post
          guard let thumbURI = try? URI(thumbUrlString),
                let fullsizeURI = try? URI(fullsizeUrlString) else {
            throw PostManagerError.invalidImageURI
          }
          
          return AppBskyEmbedImages.ViewImage(
            thumb: thumbURI,
            fullsize: fullsizeURI,
            alt: image.alt ?? "",
            aspectRatio: image.aspectRatio
          )
        }
        postViewEmbed = .appBskyEmbedImagesView(AppBskyEmbedImages.View(images: imageViews))
        
      case .appBskyEmbedExternal(let external):
        // Convert to view format
        let thumbUrl: URI?
        if let thumbCid = external.external.thumb?.ref?.cid.string {
          let thumbUrlString = "https://cdn.bsky.app/img/feed_thumbnail/plain/\(did)/\(thumbCid)@jpeg"
          thumbUrl = try? URI(thumbUrlString)
        } else {
          thumbUrl = nil
        }
        
        let externalView = AppBskyEmbedExternal.ViewExternal(
          uri: external.external.uri,
          title: external.external.title,
          description: external.external.description,
          thumb: thumbUrl,
          createdAt: nil,
          updatedAt: nil,
          readingTime: nil,
          labels: nil,
          source: nil,
          associatedRefs: nil,
          associatedProfiles: nil
        )
        postViewEmbed = .appBskyEmbedExternalView(AppBskyEmbedExternal.View(external: externalView))
        
      case .appBskyEmbedRecord(let record):
        // For record embeds (quotes), we need to fetch the actual record
        // For now, we'll leave it nil and let it load when the real post loads
        postViewEmbed = nil
        
      case .appBskyEmbedRecordWithMedia(let recordWithMedia):
        // Similar to record embed, complex to convert without fetching
        postViewEmbed = nil
        
      case .appBskyEmbedVideo(let video):
        // For video embeds, create a basic view
        // Note: Full video details would need to be fetched
        postViewEmbed = nil

      case .appBskyEmbedGallery(let gallery):
        // Convert to view format using the same CDN URL scheme as images
        let viewItems = try gallery.items.compactMap { item -> AppBskyEmbedGallery.ViewItemsUnion? in
          guard case .appBskyEmbedGalleryImage(let image) = item else { return nil }

          let cidString = image.image.ref?.cid.string ?? ""
          let thumbUrlString = "https://cdn.bsky.app/img/feed_thumbnail/plain/\(did)/\(cidString)@jpeg"
          let fullsizeUrlString = "https://cdn.bsky.app/img/feed_fullsize/plain/\(did)/\(cidString)@jpeg"

          guard let thumbnailURI = try? URI(thumbUrlString),
                let fullsizeURI = try? URI(fullsizeUrlString) else {
            throw PostManagerError.invalidImageURI
          }

          return .appBskyEmbedGalleryViewImage(
            AppBskyEmbedGallery.ViewImage(
              thumbnail: thumbnailURI,
              fullsize: fullsizeURI,
              alt: image.alt,
              aspectRatio: image.aspectRatio
            )
          )
        }
        postViewEmbed = .appBskyEmbedGalleryView(AppBskyEmbedGallery.View(items: viewItems))

      case .unexpected:
        postViewEmbed = nil
      }
    } else {
      postViewEmbed = nil
    }
    
    // Create the PostView
    return AppBskyFeedDefs.PostView(
      uri: uri,
      cid: cid,
      author: author,
      record: ATProtocolValueContainer.knownType(postRecord),
      embed: postViewEmbed,
      bookmarkCount: nil,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: 0,
      indexedAt: createdAt,
      viewer: AppBskyFeedDefs.ViewerState(
        repost: nil,
        like: nil,
        bookmarked: nil,
        threadMuted: false,
        replyDisabled: false,
        embeddingDisabled: false,
        pinned: false,
        knownLikers: nil
      ),
      labels: [],
      threadgate: nil,
      debug: nil
    )
  }
  
  /// Get the root URI from a post (handles nested replies)
  private func getRootUri(from post: AppBskyFeedDefs.PostView) -> String {
    // Check if this post is itself a reply
    if case let .knownType(bskyPost) = post.record,
       let postObj = bskyPost as? AppBskyFeedPost,
       let reply = postObj.reply {
      // Return the root URI from the reply
      return reply.root.uri.uriString()
    } else {
      // This post is the root
      return post.uri.uriString()
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
    parentPost: AppBskyFeedDefs.PostView? = nil,
    threadgateAllowRules: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]? = nil,
    postgateEmbeddingRules: [AppBskyFeedPostgate.AppBskyFeedPostgateEmbeddingRulesUnion]? = nil
  ) async throws {
    logger.info("Starting thread creation with \(posts.count) posts, isReply: \(parentPost != nil)")

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
      
      // If this thread is a reply, set up initial reply references from parentPost
      if let parentPost = parentPost {
        logger.debug("Thread is a reply - setting up reply references from parent post")
        parentRef = ComAtprotoRepoStrongRef(uri: parentPost.uri, cid: parentPost.cid)
        
        // Determine root: use parent's root if it's part of a thread, otherwise parent is the root
        if case .knownType(let record) = parentPost.record,
           let feedPost = record as? AppBskyFeedPost,
           let replyRef = feedPost.reply {
          rootRef = replyRef.root
          logger.debug("Parent is part of thread - using its root: \(replyRef.root.uri)")
        } else {
          rootRef = ComAtprotoRepoStrongRef(uri: parentPost.uri, cid: parentPost.cid)
          logger.debug("Parent is thread root - using parent as root: \(parentPost.uri)")
        }
      }

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

        // Set up reply references
        if let root = rootRef, let parent = parentRef {
          logger.debug("Creating reply reference for post #\(index+1)")
          reply = AppBskyFeedPost.ReplyRef(root: root, parent: parent)
          logger.debug("Reply reference - root: \(root.uri), parent: \(parent.uri)")
        }

        // Create post labels only if selfLabels has content
        let postLabels: AppBskyFeedPost.AppBskyFeedPostLabelsUnion?
        if !selfLabels.values.isEmpty {
          postLabels = AppBskyFeedPost.AppBskyFeedPostLabelsUnion.comAtprotoLabelDefsSelfLabels(selfLabels)
          logger.debug("Applied content labels to post #\(index+1)")
        } else {
          postLabels = nil
          logger.debug("No content labels for post #\(index+1)")
        }

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
          facets: postFacets?.isEmpty == true ? nil : postFacets,
          reply: reply,
          embed: postEmbed,
          langs: languages,
          labels: postLabels,
          tags: hashtags.isEmpty ? nil : hashtags,
          createdAt: postATProtocolDate
        )
        logger.debug("Post #\(index+1) object created")

        // Encode post to CBOR to generate CID
        logger.debug("Encoding post #\(index+1) to DAGCBOR")
        let postData = try post.encodedDAGCBOR()
        let cid = CID.fromDAGCBOR(postData)
        logger.debug("Post #\(index+1) CID: \(cid)")

        // If this is the first post and not a reply thread, set it as the root
        if index == 0 && rootRef == nil {
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
        // Add postgate for the first post if applicable
        if index == 0, let embeddingRules = postgateEmbeddingRules, !embeddingRules.isEmpty {
          let postgate = AppBskyFeedPostgate(
            createdAt: postATProtocolDate,
            post: postURI,
            detachedEmbeddingUris: nil,
            embeddingRules: embeddingRules
          )
          let createPostgate = ComAtprotoRepoApplyWrites.Create(
            collection: try NSID(nsidString: "app.bsky.feed.postgate"),
            rkey: try RecordKey(keyString: rkeys[index].description),
            value: ATProtocolValueContainer.knownType(postgate)
          )
          writes.append(ComAtprotoRepoApplyWrites.InputWritesUnion(createPostgate))
          logger.debug("Added postgate creation for first post")
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
      
      // Trigger state invalidation for thread creation
      if let appState = appState, let rootRef = rootRef {
        Task { @MainActor [weak self] in
          guard let self = self else { return }
          
          do {
            // Create a temporary post for the root of the thread
            let tempPost = try self.createTemporaryPost(
              text: posts[0],
              did: did,
              uri: rootRef.uri,
              cid: rootRef.cid,
              parentPost: nil,
              embed: embeds?.first ?? nil,
              languages: languages,
              labels: selfLabels,
              createdAt: ATProtocolDate(date: currentDate)
            )
          
            // Notify that a new post (thread root) was created
            appState.stateInvalidationBus.notify(.postCreated(tempPost))
            
            // Also notify thread update for the new thread
            appState.stateInvalidationBus.notify(.threadUpdated(rootUri: rootRef.uri.uriString()))
          } catch {
            self.logger.error("Failed to create temporary post for thread notification: \(error)")
          }
        }
      }

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
  /// Fetches the authenticated user's profile record and writes back a copy
  /// with the given pinned post applied.
  private func updatePinnedPost(
    _ pinnedPost: ComAtprotoRepoStrongRef?,
    fetchErrorMessage: String,
    writeErrorMessage: String
  ) async throws {
    guard let client = client else { throw AuthError.clientNotInitialized }
    let did = try await client.getDid()

    let getRecordParams = ComAtprotoRepoGetRecord.Parameters(
      repo: try ATIdentifier(string: did),
      collection: try NSID(nsidString: "app.bsky.actor.profile"),
      rkey: try RecordKey(keyString: "self")
    )
    let (getRecordCode, getRecordOutput) = try await client.com.atproto.repo.getRecord(input: getRecordParams)

    guard getRecordCode == 200, let existingRecord = getRecordOutput,
          case let .knownType(value) = existingRecord.value,
          let existingProfile = value as? AppBskyActorProfile else {
      throw NSError(
        domain: "ProfilePinning",
        code: getRecordCode,
        userInfo: [NSLocalizedDescriptionKey: fetchErrorMessage]
      )
    }

    let updatedProfile = AppBskyActorProfile(
      displayName: existingProfile.displayName,
      description: existingProfile.description,
      pronouns: existingProfile.pronouns,
      website: existingProfile.website,
      avatar: existingProfile.avatar,
      banner: existingProfile.banner,
      labels: existingProfile.labels,
      joinedViaStarterPack: existingProfile.joinedViaStarterPack,
      pinnedPost: pinnedPost,
      createdAt: existingProfile.createdAt
    )

    let putRecordInput = ComAtprotoRepoPutRecord.Input(
      repo: try ATIdentifier(string: did),
      collection: try NSID(nsidString: "app.bsky.actor.profile"),
      rkey: try RecordKey(keyString: "self"),
      record: ATProtocolValueContainer.knownType(updatedProfile),
      swapRecord: existingRecord.cid
    )

    let (putRecordCode, _) = try await client.com.atproto.repo.putRecord(input: putRecordInput)
    if putRecordCode != 200 {
      throw NSError(
        domain: "ProfilePinning",
        code: putRecordCode,
        userInfo: [NSLocalizedDescriptionKey: "\(writeErrorMessage) \(putRecordCode)"]
      )
    }
  }

  /// Pins a post to the authenticated user's profile.
  func pinPost(uri: ATProtocolURI, cid: String) async throws {
    let strongRef = ComAtprotoRepoStrongRef(uri: uri, cid: try CID.parse(cid))
    try await updatePinnedPost(
      strongRef,
      fetchErrorMessage: "Failed to fetch actor profile for pinning",
      writeErrorMessage: "Error updating pinned post: Unexpected response code"
    )
  }

  /// Unpins any currently pinned post from the authenticated user's profile.
  func unpinPost() async throws {
    try await updatePinnedPost(
      nil,
      fetchErrorMessage: "Failed to fetch actor profile for unpinning",
      writeErrorMessage: "Error unpinning post: Unexpected response code"
    )
  }

  // MARK: - Post Interaction Settings & Moderation

  private func isRecordNotFoundError(_ error: Error) -> Bool {
    if let protoError = error as? ATProtoError<ComAtprotoRepoGetRecord.Error>, protoError.error == .recordNotFound {
      return true
    }
    if let directError = error as? ComAtprotoRepoGetRecord.Error, directError == .recordNotFound {
      return true
    }
    if let xrpcError = error as? ATProtoXRPCError, xrpcError.error == "RecordNotFound" {
      return true
    }
    return false
  }

  /// Fetches an optional record from the repository, returning nil if the record does not exist.
  private func getOptionalRecord<T: ATProtocolValue>(
    repo: String,
    collection: String,
    rkey: RecordKey
  ) async throws -> (record: T?, cid: CID?) {
    guard let client = client else { throw AuthError.clientNotInitialized }
    let params = ComAtprotoRepoGetRecord.Parameters(
      repo: try ATIdentifier(string: repo),
      collection: try NSID(nsidString: collection),
      rkey: rkey
    )
    do {
      let (code, output) = try await client.com.atproto.repo.getRecord(input: params)
      if (200...299).contains(code) {
        if let record = output, case let .knownType(value) = record.value, let typedRecord = value as? T {
          return (typedRecord, record.cid)
        }
        return (nil, output?.cid)
      } else {
        throw AuthError.badResponse(code)
      }
    } catch {
      if isRecordNotFoundError(error) {
        return (nil, nil)
      }
      throw error
    }
  }

  /// Updates interaction settings for a post (postgate) and optionally its root post (threadgate).
  func updateInteractionSettings(
    postURI: ATProtocolURI,
    rootPostURI: ATProtocolURI,
    settings: PostInteractionSettingsState
  ) async throws {
    guard let client = client else { throw AuthError.clientNotInitialized }
    let did = try await client.getDid()
    let postRkey = try RecordKey(keyString: postURI.recordKey ?? "")
    let rootRkey = try RecordKey(keyString: rootPostURI.recordKey ?? "")

    var existingTg: AppBskyFeedThreadgate?
    var tgSwapCid: CID?
    let shouldCheckTg = rootPostURI.authority == did
    if shouldCheckTg {
      let (tgRecord, cid): (AppBskyFeedThreadgate?, CID?) = try await getOptionalRecord(
        repo: did,
        collection: "app.bsky.feed.threadgate",
        rkey: rootRkey
      )
      existingTg = tgRecord
      tgSwapCid = cid
    }

    var existingPg: AppBskyFeedPostgate?
    var pgSwapCid: CID?
    let shouldCheckPg = postURI.authority == did
    if shouldCheckPg {
      let (pgRecord, cid): (AppBskyFeedPostgate?, CID?) = try await getOptionalRecord(
        repo: did,
        collection: "app.bsky.feed.postgate",
        rkey: postRkey
      )
      existingPg = pgRecord
      pgSwapCid = cid
    }

    let updatedTg = PostInteractionSettingsState.mergeThreadgate(
      existing: existingTg,
      postURI: rootPostURI,
      settings: settings
    )
    let updatedPg = PostInteractionSettingsState.mergePostgate(
      existing: existingPg,
      postURI: postURI,
      settings: settings
    )

    let tgChanged: Bool
    if shouldCheckTg {
      if existingTg == nil {
        tgChanged = (updatedTg.allow != nil || updatedTg.hiddenReplies != nil)
      } else {
        tgChanged = (existingTg?.allow != updatedTg.allow)
      }
    } else {
      tgChanged = false
    }

    let pgChanged: Bool
    if shouldCheckPg {
      if existingPg == nil {
        pgChanged = (updatedPg.embeddingRules != nil || updatedPg.detachedEmbeddingUris != nil)
      } else {
        pgChanged = (existingPg?.embeddingRules != updatedPg.embeddingRules)
      }
    } else {
      pgChanged = false
    }

    var writes: [ComAtprotoRepoApplyWrites.InputWritesUnion] = []
    if tgChanged {
      if existingTg != nil {
        writes.append(.comAtprotoRepoApplyWritesUpdate(ComAtprotoRepoApplyWrites.Update(
          collection: try NSID(nsidString: "app.bsky.feed.threadgate"),
          rkey: rootRkey,
          value: ATProtocolValueContainer.knownType(updatedTg)
        )))
      } else {
        writes.append(.comAtprotoRepoApplyWritesCreate(ComAtprotoRepoApplyWrites.Create(
          collection: try NSID(nsidString: "app.bsky.feed.threadgate"),
          rkey: rootRkey,
          value: ATProtocolValueContainer.knownType(updatedTg)
        )))
      }
    }

    if pgChanged {
      if existingPg != nil {
        writes.append(.comAtprotoRepoApplyWritesUpdate(ComAtprotoRepoApplyWrites.Update(
          collection: try NSID(nsidString: "app.bsky.feed.postgate"),
          rkey: postRkey,
          value: ATProtocolValueContainer.knownType(updatedPg)
        )))
      } else {
        writes.append(.comAtprotoRepoApplyWritesCreate(ComAtprotoRepoApplyWrites.Create(
          collection: try NSID(nsidString: "app.bsky.feed.postgate"),
          rkey: postRkey,
          value: ATProtocolValueContainer.knownType(updatedPg)
        )))
      }
    }

    if writes.count > 1 {
      let applyInput = ComAtprotoRepoApplyWrites.Input(
        repo: try ATIdentifier(string: did),
        validate: true,
        writes: writes,
        swapCommit: nil
      )
      let (code, _) = try await client.com.atproto.repo.applyWrites(input: applyInput)
      guard (200...299).contains(code) else {
        throw AuthError.badResponse(code)
      }
    } else if tgChanged {
      let putTgInput = ComAtprotoRepoPutRecord.Input(
        repo: try ATIdentifier(string: did),
        collection: try NSID(nsidString: "app.bsky.feed.threadgate"),
        rkey: rootRkey,
        record: ATProtocolValueContainer.knownType(updatedTg),
        swapRecord: tgSwapCid
      )
      let (code, _) = try await client.com.atproto.repo.putRecord(input: putTgInput)
      guard (200...299).contains(code) else {
        throw AuthError.badResponse(code)
      }
    } else if pgChanged {
      let putPgInput = ComAtprotoRepoPutRecord.Input(
        repo: try ATIdentifier(string: did),
        collection: try NSID(nsidString: "app.bsky.feed.postgate"),
        rkey: postRkey,
        record: ATProtocolValueContainer.knownType(updatedPg),
        swapRecord: pgSwapCid
      )
      let (code, _) = try await client.com.atproto.repo.putRecord(input: putPgInput)
      guard (200...299).contains(code) else {
        throw AuthError.badResponse(code)
      }
    }
  }

  /// Maximum number of hidden replies allowed by the ATProto threadgate lexicon.
  public static let maxHiddenReplies = 300

  /// Hides or unhides a reply on a thread owned by the authenticated user.
  func setReplyHidden(rootPostURI: ATProtocolURI, replyURI: ATProtocolURI, hidden: Bool) async throws {
    guard let client = client else { throw AuthError.clientNotInitialized }
    let did = try await client.getDid()
    let rootRkey = try RecordKey(keyString: rootPostURI.recordKey ?? "")

    let (existingTg, swapCid): (AppBskyFeedThreadgate?, CID?) = try await getOptionalRecord(
      repo: did,
      collection: "app.bsky.feed.threadgate",
      rkey: rootRkey
    )

    var hiddenURIs = existingTg?.hiddenReplies ?? []
    if hidden {
      if !hiddenURIs.contains(replyURI) {
        if hiddenURIs.count >= Self.maxHiddenReplies {
          throw NSError(
            domain: "ThreadgateModeration",
            code: 400,
            userInfo: [NSLocalizedDescriptionKey: "Maximum of \(Self.maxHiddenReplies) hidden replies reached"]
          )
        }
        hiddenURIs.append(replyURI)
      }
    } else {
      hiddenURIs.removeAll { $0 == replyURI }
    }

    let allowRules = existingTg?.allow
    let createdAt = existingTg?.createdAt ?? ATProtocolDate(date: Date())
    let updatedTg = AppBskyFeedThreadgate(
      post: rootPostURI,
      allow: allowRules,
      createdAt: createdAt,
      hiddenReplies: hiddenURIs.isEmpty ? nil : hiddenURIs
    )

    let putTgInput = ComAtprotoRepoPutRecord.Input(
      repo: try ATIdentifier(string: did),
      collection: try NSID(nsidString: "app.bsky.feed.threadgate"),
      rkey: rootRkey,
      record: ATProtocolValueContainer.knownType(updatedTg),
      swapRecord: swapCid
    )
    let (code, _) = try await client.com.atproto.repo.putRecord(input: putTgInput)
    guard (200...299).contains(code) else {
      throw AuthError.badResponse(code)
    }
  }

  /// Detaches or re-attaches a quote embedding of the authenticated user's post.
  func setQuoteDetached(quotedPostURI: ATProtocolURI, quotePostURI: ATProtocolURI, detached: Bool) async throws {
    guard let client = client else { throw AuthError.clientNotInitialized }
    let did = try await client.getDid()
    let quotedRkey = try RecordKey(keyString: quotedPostURI.recordKey ?? "")

    let (existingPg, swapCid): (AppBskyFeedPostgate?, CID?) = try await getOptionalRecord(
      repo: did,
      collection: "app.bsky.feed.postgate",
      rkey: quotedRkey
    )

    var detachedURIs = existingPg?.detachedEmbeddingUris ?? []
    if detached {
      if !detachedURIs.contains(quotePostURI) {
        detachedURIs.append(quotePostURI)
      }
    } else {
      detachedURIs.removeAll { $0 == quotePostURI }
    }

    let embeddingRules = existingPg?.embeddingRules
    let createdAt = existingPg?.createdAt ?? ATProtocolDate(date: Date())
    let updatedPg = AppBskyFeedPostgate(
      createdAt: createdAt,
      post: quotedPostURI,
      detachedEmbeddingUris: detachedURIs.isEmpty ? nil : detachedURIs,
      embeddingRules: embeddingRules
    )

    let putPgInput = ComAtprotoRepoPutRecord.Input(
      repo: try ATIdentifier(string: did),
      collection: try NSID(nsidString: "app.bsky.feed.postgate"),
      rkey: quotedRkey,
      record: ATProtocolValueContainer.knownType(updatedPg),
      swapRecord: swapCid
    )
    let (code, _) = try await client.com.atproto.repo.putRecord(input: putPgInput)
    guard (200...299).contains(code) else {
      throw AuthError.badResponse(code)
    }
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
  
  enum PostManagerError: Error {
    case invalidImageURI
    
    var localizedDescription: String {
      switch self {
      case .invalidImageURI:
        return "Failed to create valid image URIs"
      }
    }
  }
}
