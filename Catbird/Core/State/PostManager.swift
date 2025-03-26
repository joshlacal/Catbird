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
        embed: AppBskyFeedPost.AppBskyFeedPostEmbedUnion? = nil
    ) async throws {
        logger.info("Creating \(parentPost == nil ? "post" : "reply") with text length: \(postText.count)")
        
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

            // Prepare the API request
            let createRecordInput = ComAtprotoRepoCreateRecord.Input(
                repo: did,
                collection: "app.bsky.feed.post",
                record: ATProtocolValueContainer.knownType((newPost))
            )

            // Make the API call
            let (responseCode, _) = try await client.com.atproto.repo.createRecord(
                input: createRecordInput)

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
        let rootPostReference: ComAtprotoRepoStrongRef
        if case let .knownType(bskyPost) = parentPost.record,
          let postObj = bskyPost as? AppBskyFeedPost
        {
            rootPostReference =
            postObj.reply?.root ?? ComAtprotoRepoStrongRef(uri: parentPost.uri, cid: parentPost.cid)
        } else {
            rootPostReference = ComAtprotoRepoStrongRef(uri: parentPost.uri, cid: parentPost.cid)
        }

        let parentPostReference = ComAtprotoRepoStrongRef(uri: parentPost.uri, cid: parentPost.cid)
        return AppBskyFeedPost.ReplyRef(root: rootPostReference, parent: parentPostReference)
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
        func createThread(
            posts: [String],
            languages: [LanguageCodeContainer],
            selfLabels: ComAtprotoLabelDefs.SelfLabels,
            hashtags: [String] = []
        ) async throws {
            guard !posts.isEmpty else { return }
            guard let client = client else {
                throw AuthError.clientNotInitialized
            }
            
            // Update status
            status = .posting
            
            do {
                // Get user DID
                let did = try await client.getDid()
                let currentDate = Date()
                let currentATProtocolDate = ATProtocolDate(date: currentDate)
                
                // Generate TIDs for all posts
                let rkeys = try await generateRKeys(count: posts.count)
                
                // Create an array to hold all write operations
                var writes: [ComAtprotoRepoApplyWrites.InputWritesUnion] = []
                
                // Keep track of root and parent references
                var rootRef: ComAtprotoRepoStrongRef?
                var parentRef: ComAtprotoRepoStrongRef?
                
                // Process each post
                for (index, postText) in posts.enumerated() {
                    // Create post object
                    var reply: AppBskyFeedPost.ReplyRef?
                    
                    // For posts after the first one, set up reply references
                    if index > 0, let root = rootRef, let parent = parentRef {
                        reply = AppBskyFeedPost.ReplyRef(root: root, parent: parent)
                    }
                    
                    // Create post labels
                    let postLabels = AppBskyFeedPost.AppBskyFeedPostLabelsUnion.comAtprotoLabelDefsSelfLabels(selfLabels)
                    
                    // Create the post object
                    let post = AppBskyFeedPost(
                        text: postText,
                        entities: nil,
                        facets: nil,
                        reply: reply,
                        embed: nil,
                        langs: languages,
                        labels: postLabels,
                        tags: hashtags,
                        createdAt: currentATProtocolDate
                    )
                    
                    // Encode post to CBOR to generate CID
                    let postData = try post.toCBORValue() as! Data
                    let cid = CID.fromDAGCBOR(postData).string
                    
                    // Record URI for this post
                    let postURI = try ATProtocolURI(uriString: "at://\(did)/app.bsky.feed.post/\(rkeys[index])")
                    
                    // If this is the first post, set it as the root for the thread
                    if index == 0 {
                        rootRef = ComAtprotoRepoStrongRef(uri: postURI, cid: cid)
                    }
                    
                    // Set this post as the parent for the next post
                    parentRef = ComAtprotoRepoStrongRef(uri: postURI, cid: cid)
                    
                    // Create write operation for this post
                    let create = ComAtprotoRepoApplyWrites.Create(
                        collection: "app.bsky.feed.post",
                        rkey: rkeys[index],
                        value: ATProtocolValueContainer.knownType(post)
                    )
                    
                    writes.append(ComAtprotoRepoApplyWrites.InputWritesUnion(create))
                }
                
                // Create the input for applyWrites
                let input = ComAtprotoRepoApplyWrites.Input(
                    repo: did,
                    validate: true,
                    writes: writes
                )
                
                // Execute the batch operation
                let (responseCode, _) = try await client.com.atproto.repo.applyWrites(input: input)
                
                // Handle the response
                if responseCode != 200 {
                    let error = AuthError.badResponse(responseCode)
                    status = .error(error.localizedDescription)
                    throw error
                }
                
                // Update status on success
                status = .success
                logger.info("Thread with \(posts.count) posts created successfully")
                
                // Reset to idle after brief delay
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    status = .idle
                }
                
            } catch {
                // Update status on error
                status = .error(error.localizedDescription)
                logger.error("Failed to create thread: \(error.localizedDescription)")
                throw error
            }
        }
        
        /// Generates an array of TIDs to use as record keys
        private func generateRKeys(count: Int) async throws -> [String] {
            var rkeys: [String] = []
            for _ in 0..<count {
                let tid = await TID.next()
                rkeys.append(tid)
            }
            return rkeys
        }
    }
