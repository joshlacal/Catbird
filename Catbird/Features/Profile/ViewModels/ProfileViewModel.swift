import Foundation
import OSLog
import Observation
import Petrel
import SwiftUI
import UIKit

@Observable final class ProfileViewModel: StateInvalidationSubscriber {
  // MARK: - Properties

  // Profile data
  private(set) var profile: AppBskyActorDefs.ProfileViewDetailed?
    private(set) var posts: [AppBskyFeedDefs.FeedViewPost] = []
  private(set) var replies: [AppBskyFeedDefs.FeedViewPost] = []
  private(set) var postsWithMedia: [AppBskyFeedDefs.FeedViewPost] = []
    private(set) var likes: [AppBskyFeedDefs.FeedViewPost] = []
    private(set) var otherUserLikes: [AppBskyFeedDefs.PostView] = []
  private(set) var lists: [AppBskyGraphDefs.ListView] = []
  private(set) var starterPacks: [AppBskyGraphDefs.StarterPackViewBasic] = []
  private(set) var feeds: [AppBskyFeedDefs.GeneratorView] = []
  private(set) var knownFollowers: [AppBskyActorDefs.ProfileView] = []

  // UI state
  private(set) var isLoading = false
  private(set) var isLoadingMorePosts = false
  private(set) var isLoadingKnownFollowers = false
  private(set) var error: Error?
  var selectedProfileTab: ProfileTab = .posts

  // Pagination tracking
  private(set) var hasMoreStarterPacks = false

  // Pagination cursors
  private var postsCursor: String?
  private var repliesCursor: String?
  private var mediaPostsCursor: String?
  private var likesCursor: String?
  private var listsCursor: String?
  private var starterPacksCursor: String?
  private var feedsCursor: String?
  private var knownFollowersCursor: String?

  // Dependencies
  private let client: ATProtoClient?
  private let userDID: String  // This is the DID of the profile we're viewing
  private let currentUserDID: String?  // This is the logged-in user's DID
  private let logger = Logger(subsystem: "blue.catbird", category: "ProfileViewModel")
  private weak var stateInvalidationBus: StateInvalidationBus?

  // Check if this is the current user's profile - comparing correctly
  var isCurrentUser: Bool {
    guard let profile = profile else { return false }
    return profile.did.didString() == currentUserDID
  }

  // MARK: - Initialization

  init(client: ATProtoClient?, userDID: String, currentUserDID: String?, stateInvalidationBus: StateInvalidationBus? = nil) {
    self.client = client
    self.userDID = userDID
    self.currentUserDID = currentUserDID
    self.stateInvalidationBus = stateInvalidationBus
    
    // Subscribe to state invalidation events if bus is provided
    stateInvalidationBus?.subscribe(self)
  }
  
  deinit {
    // Unsubscribe from state invalidation events
    stateInvalidationBus?.unsubscribe(self)
  }

  // MARK: - Public Methods

  /// Loads the user profile
  func loadProfile() async {
    guard let client = client else {
      self.error = NSError(
        domain: "ProfileViewModel", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Client not available"])
      return
    }

    isLoading = true
    error = nil

    do {
      let (responseCode, profileData) = try await client.app.bsky.actor.getProfile(
        input: .init(actor: try ATIdentifier(string: userDID))
      )

      await MainActor.run {
        if responseCode == 200, let profile = profileData {
          self.profile = profile
        } else {
          self.error = NSError(
            domain: "ProfileViewModel",
            code: responseCode,
            userInfo: [NSLocalizedDescriptionKey: "Failed to load profile: HTTP \(responseCode)"]
          )
        }
        self.isLoading = false
      }
    } catch {
      await MainActor.run {
        self.error = error
        self.isLoading = false
      }
    }
  }

  /// Loads user's posts
  func loadPosts() async {
    await loadFeed(type: .posts, resetCursor: postsCursor == nil)
  }

  /// Loads user's replies
  func loadReplies() async {
    await loadFeed(type: .replies, resetCursor: repliesCursor == nil)
  }

  /// Loads user's posts with media
  func loadMediaPosts() async {
    await loadFeed(type: .media, resetCursor: mediaPostsCursor == nil)
  }

  /// Loads user's liked posts
  func loadLikes() async {
    await loadFeed(type: .likes, resetCursor: likesCursor == nil)
  }

  /// Loads known followers - people who follow this profile and are also followed by the current user
  func loadKnownFollowers() async {
    guard let client = client, let profile = profile, !self.isCurrentUser, !isLoadingKnownFollowers else { return }

    isLoadingKnownFollowers = true

    do {
      let params = AppBskyGraphGetKnownFollowers.Parameters(
        actor: try ATIdentifier(string: profile.did.didString()),
        limit: 20,
        cursor: knownFollowersCursor
      )

      let (responseCode, output) = try await client.app.bsky.graph.getKnownFollowers(input: params)

      if responseCode == 200, let followers = output?.followers {
        await MainActor.run {
          if self.knownFollowersCursor == nil {
            self.knownFollowers = followers
          } else {
            self.knownFollowers.append(contentsOf: followers)
          }
          self.knownFollowersCursor = output?.cursor
          self.isLoadingKnownFollowers = false
        }
      } else {
        logger.warning("Failed to load known followers: HTTP \(responseCode)")
        await MainActor.run { 
          self.isLoadingKnownFollowers = false 
        }
      }
    } catch {
      logger.error("Error loading known followers: \(error.localizedDescription)")
      await MainActor.run { 
        self.isLoadingKnownFollowers = false 
      }
    }
  }

  /// Loads user's starter packs
  func loadStarterPacks() async {
    guard let client = client, let profile = profile, !isLoadingMorePosts else { return }

    isLoadingMorePosts = true

    do {
      let params = AppBskyGraphGetActorStarterPacks.Parameters(
        actor: try ATIdentifier(string: profile.did.didString()),
        limit: 20,
        cursor: starterPacksCursor
      )

      let (responseCode, output) = try await client.app.bsky.graph.getActorStarterPacks(
        input: params)

      if responseCode == 200, let packs = output?.starterPacks {
        await MainActor.run {
          if self.starterPacksCursor == nil {
            self.starterPacks = packs
          } else {
            self.starterPacks.append(contentsOf: packs)
          }
          self.starterPacksCursor = output?.cursor
          self.hasMoreStarterPacks = output?.cursor != nil
          self.isLoadingMorePosts = false
        }
      } else {
        logger.warning("Failed to load starter packs: HTTP \(responseCode)")
        await MainActor.run {
          self.isLoadingMorePosts = false
          self.hasMoreStarterPacks = false
        }
      }
    } catch {
      logger.error("Error loading starter packs: \(error.localizedDescription)")
      await MainActor.run {
        self.isLoadingMorePosts = false
        self.hasMoreStarterPacks = false
      }
    }
  }

  /// Loads user's lists
  func loadLists() async {
    guard let client = client, let profile = profile, !isLoadingMorePosts else { return }

    isLoadingMorePosts = true

    do {
      let params = AppBskyGraphGetLists.Parameters(
        actor: try ATIdentifier(string: profile.did.didString()),
        limit: 20,
        cursor: listsCursor
      )

      let (responseCode, output) = try await client.app.bsky.graph.getLists(input: params)

      if responseCode == 200, let lists = output?.lists {
        await MainActor.run {
          if self.listsCursor == nil {
            self.lists = lists
          } else {
            self.lists.append(contentsOf: lists)
          }
          self.listsCursor = output?.cursor
          self.isLoadingMorePosts = false
        }
      } else {
        logger.warning("Failed to load lists: HTTP \(responseCode)")
        await MainActor.run { self.isLoadingMorePosts = false }
      }
    } catch {
      logger.error("Error loading lists: \(error.localizedDescription)")
      await MainActor.run { self.isLoadingMorePosts = false }
    }
  }

  // MARK: - Private Methods

  /// Load different types of feeds
  private func loadFeed(type: FeedType, resetCursor: Bool) async {
    guard let client = client, let profile = profile, !isLoadingMorePosts else { return }

    isLoadingMorePosts = true

    do {
      switch type {
      case .posts:
        let params = AppBskyFeedGetAuthorFeed.Parameters(
          actor: try ATIdentifier(string: profile.did.didString()),
          limit: 50,
          cursor: resetCursor ? nil : postsCursor,
          filter: "posts_and_author_threads",
          includePins: true
        )

        let (responseCode, output) = try await client.app.bsky.feed.getAuthorFeed(input: params)

        if responseCode == 200, let feed = output?.feed {
          await MainActor.run {
            if resetCursor {
              self.posts = feed
            } else {
              self.posts.append(contentsOf: feed)
            }
            self.postsCursor = output?.cursor
          }
        }

      case .replies:
        let params = AppBskyFeedGetAuthorFeed.Parameters(
          actor: try ATIdentifier(string: profile.did.didString()),
          limit: 20,
          cursor: resetCursor ? nil : repliesCursor,
          filter: "posts_with_replies"
        )

        let (responseCode, output) = try await client.app.bsky.feed.getAuthorFeed(input: params)

        if responseCode == 200, let feed = output?.feed {
          // Filter to only include replies
          let repliesToOthers = feed.filter { post in
            // Check if post has a reply
            if let reply = post.reply {
              // Handle the parent union type without optional binding
              switch reply.parent {
              case .appBskyFeedDefsPostView(let parentPost):
                // If it's a reply to someone else's post
                return parentPost.author.did != profile.did
              case .appBskyFeedDefsNotFoundPost, .appBskyFeedDefsBlockedPost, .unexpected:
                // For other parent types, include them in the result
                return true
              }
            }
            return false
          }

          await MainActor.run {
            if resetCursor {
              self.replies = repliesToOthers
            } else {
              self.replies.append(contentsOf: repliesToOthers)
            }
            self.repliesCursor = output?.cursor
          }
        }

      case .media:
        let params = AppBskyFeedGetAuthorFeed.Parameters(
          actor: try ATIdentifier(string: profile.did.didString()),
          limit: 20,
          cursor: resetCursor ? nil : mediaPostsCursor
        )

        let (responseCode, output) = try await client.app.bsky.feed.getAuthorFeed(input: params)

        if responseCode == 200, let feed = output?.feed {
          // Filter to only include posts with media
          let postsWithMedia = feed.filter { post in
            if let embed = post.post.embed {
              switch embed {
              case .appBskyEmbedImagesView, .appBskyEmbedVideoView, .appBskyEmbedExternalView:
                return true
              case .appBskyEmbedRecordWithMediaView:
                return true
              default:
                return false
              }
            }
            return false
          }

          await MainActor.run {
            if resetCursor {
              self.postsWithMedia = postsWithMedia
            } else {
              self.postsWithMedia.append(contentsOf: postsWithMedia)
            }
            self.mediaPostsCursor = output?.cursor
          }
        }

      case .likes:
          if userDID == currentUserDID {
              // Current implementation for the user's own likes
              let params = AppBskyFeedGetActorLikes.Parameters(
                  actor: try ATIdentifier(string: profile.did.didString()),
                  limit: 20,
                  cursor: resetCursor ? nil : likesCursor
              )
              
              let (responseCode, output) = try await client.app.bsky.feed.getActorLikes(input: params)
              
              if responseCode == 200, let feed = output?.feed {
                  await MainActor.run {
                      if resetCursor {
                          self.likes = feed
                      } else {
                          self.likes.append(contentsOf: feed)
                      }
                      self.likesCursor = output?.cursor
                  }
              }
              
          } else {
              // Fetch other user's likes directly from their PDS
              let pdsURL = try await client.resolveDIDToPDSURL(did: profile.did.didString())
              let endpoint = "com.atproto.repo.listRecords"
              var url = pdsURL.appendingPathComponent("xrpc").appendingPathComponent(endpoint)
              
              // Create parameters including cursor for pagination
              var queryItems = [
                  URLQueryItem(name: "repo", value: userDID),
                  URLQueryItem(name: "collection", value: "app.bsky.feed.like"),
                  URLQueryItem(name: "limit", value: "25")
              ]
              
              // Add cursor if we're paginating
              if !resetCursor, let cursor = likesCursor {
                  queryItems.append(URLQueryItem(name: "cursor", value: cursor))
              }
              
              // Add query parameters to URL
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
              components?.queryItems = queryItems
              url = components?.url ?? url
              
              // Create and send request
              var urlRequest = URLRequest(url: url)
              urlRequest.httpMethod = "GET"
              urlRequest.allHTTPHeaderFields = ["Accept": "application/json"]
              
              let (data, response) = try await URLSession.shared.data(for: urlRequest)
              
              // Decode response
              let decoder = JSONDecoder()
              guard let decodedData = try? decoder.decode(ComAtprotoRepoListRecords.Output.self, from: data),
                    let httpResponse = response as? HTTPURLResponse,
                    httpResponse.statusCode == 200 else {
                  throw NetworkError.connectionFailed
              }
              
              // Extract post URIs from like records
              var postURIs: [ATProtocolURI] = []
              for record in decodedData.records {
                  if case let .knownType(likeRecord) = record.value,
                     let like = likeRecord as? AppBskyFeedLike {
                      postURIs.append(like.subject.uri)
                  }
              }
              
              if !postURIs.isEmpty {
                  let maxURIsPerRequest = 25
                  let chunks = stride(from: 0, to: postURIs.count, by: maxURIsPerRequest).map {
                      Array(postURIs[$0..<min($0 + maxURIsPerRequest, postURIs.count)])
                  }
                  
                  var fetchedPosts: [AppBskyFeedDefs.PostView] = []
                  
                  // Process each chunk
                  for chunk in chunks {
                      let (_, postsOutput) = try await client.app.bsky.feed.getPosts(
                          input: AppBskyFeedGetPosts.Parameters(uris: chunk)
                      )
                      
                      if let posts = postsOutput?.posts {
                          fetchedPosts.append(contentsOf: posts)
                      }
                  }
                  
                  // Update UI on main thread
                  let likedPosts = fetchedPosts
                  await MainActor.run {
                      if resetCursor {
                          self.otherUserLikes = likedPosts
                      } else {
                          self.otherUserLikes.append(contentsOf: likedPosts)
                      }
                      
                      // Store cursor for next pagination
                      self.likesCursor = decodedData.cursor
                  }
              }
          }
      }

      await MainActor.run {
        self.isLoadingMorePosts = false
      }

    } catch {
      logger.error(
        "Error loading feed (\(String(describing: type))): \(error.localizedDescription)")
      await MainActor.run {
        self.isLoadingMorePosts = false
      }
    }
  }

  // MARK: - Helper Types

  private enum FeedType {
    case posts, replies, media, likes
  }

  /// Loads user's feeds (feed generators)
  func loadFeeds() async {
    guard let client = client, let profile = profile, !isLoadingMorePosts else { return }

    isLoadingMorePosts = true

    do {
      let params = AppBskyFeedGetActorFeeds.Parameters(
        actor: try ATIdentifier(string: profile.did.didString()),
        limit: 20,
        cursor: feedsCursor
      )

      let (responseCode, output) = try await client.app.bsky.feed.getActorFeeds(input: params)

      if responseCode == 200, let fetchedFeeds = output?.feeds {
        await MainActor.run {
          if self.feedsCursor == nil {
            self.feeds = fetchedFeeds
          } else {
            self.feeds.append(contentsOf: fetchedFeeds)
          }
          self.feedsCursor = output?.cursor
          self.isLoadingMorePosts = false
        }
      } else {
        logger.warning("Failed to load feeds: HTTP \(responseCode)")
        await MainActor.run {
          self.isLoadingMorePosts = false
        }
      }
    } catch {
      logger.error("Error loading feeds: \(error.localizedDescription)")
      await MainActor.run {
        self.isLoadingMorePosts = false
      }
    }
  }

  // MARK: - Image Upload Methods
  
  /// Uploads an image and returns a Blob for use in profile
  func uploadImageBlob(_ imageData: Data) async throws -> Blob {
    guard let client = client else {
      throw NSError(
        domain: "ProfileImageUpload", code: 0,
        userInfo: [NSLocalizedDescriptionKey: "Client not available"])
    }
    
    let processedData = try await processImageForUpload(imageData)
    
    let (responseCode, blobOutput) = try await client.com.atproto.repo.uploadBlob(
      data: processedData,
      mimeType: "image/jpeg",
      stripMetadata: true
    )
    
    guard responseCode == 200, let blob = blobOutput?.blob else {
      throw NSError(
        domain: "ProfileImageUpload", code: responseCode,
        userInfo: [NSLocalizedDescriptionKey: "Failed to upload image: HTTP \(responseCode)"])
    }
    
    return blob
  }
  
  /// Processes image data for upload with compression and format conversion
  private func processImageForUpload(_ data: Data) async throws -> Data {
    var processedData = data
    
    // Convert HEIC to JPEG if needed
    if checkImageFormat(data) == "HEIC" {
      if let converted = convertHEICToJPEG(data) {
        processedData = converted
      }
    }
    
    // Compress image to meet AT Protocol limits (target 900KB, max 1MB)
    if let image = UIImage(data: processedData),
       let compressed = compressImage(image, maxSizeInBytes: 900_000) {
      processedData = compressed
    }
    
    return processedData
  }
  
  /// Checks the image format based on data header
  private func checkImageFormat(_ data: Data) -> String {
    guard data.count >= 4 else { return "Unknown" }
    
    let bytes = data.prefix(4)
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
      return "JPEG"
    } else if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
      return "PNG"
    } else if data.count >= 12 {
      let heicHeader = data.subdata(in: 4..<12)
      if String(data: heicHeader, encoding: .ascii)?.contains("ftyp") == true {
        let heicTypes = ["heic", "heix", "hevc", "hevx"]
        if let typeString = String(data: data.subdata(in: 8..<12), encoding: .ascii),
           heicTypes.contains(where: typeString.lowercased().contains) {
          return "HEIC"
        }
      }
    }
    return "Unknown"
  }
  
  /// Converts HEIC data to JPEG
  private func convertHEICToJPEG(_ data: Data) -> Data? {
    guard let image = UIImage(data: data) else { return nil }
    return image.jpegData(compressionQuality: 0.8)
  }
  
  /// Compresses image to target size
  private func compressImage(_ image: UIImage, maxSizeInBytes: Int) -> Data? {
    var compression: CGFloat = 0.8
    var imageData = image.jpegData(compressionQuality: compression)
    
    while let data = imageData, data.count > maxSizeInBytes && compression > 0.1 {
      compression -= 0.1
      imageData = image.jpegData(compressionQuality: compression)
    }
    
    return imageData
  }

  // MARK: Update Profile
  func updateProfile(displayName: String, description: String, avatar: Blob? = nil, banner: Blob? = nil) async throws {
    guard let client = client else {
      throw NSError(
        domain: "ProfileCreation", code: 0,
        userInfo: [NSLocalizedDescriptionKey: "Client not available"])
    }

    guard let currentUserDID = currentUserDID else {
      throw NSError(
        domain: "ProfileCreation", code: 0,
        userInfo: [NSLocalizedDescriptionKey: "Current user DID not available"])
    }

    // Get the profile record
    let getRecordParams = ComAtprotoRepoGetRecord.Parameters(
      repo: try ATIdentifier(string: currentUserDID),
      collection: try NSID(nsidString: "app.bsky.actor.profile"),
      rkey: try RecordKey(keyString: "self")
    )
    let (getRecordCode, getRecordOutput) = try await client.com.atproto.repo.getRecord(
      input: getRecordParams)

    var updatedProfile: AppBskyActorProfile

    if getRecordCode == 200, let existingRecord = getRecordOutput {
      // Prepare the updated profile
      guard case let .knownType(value) = existingRecord.value,
        let existingProfile = value as? AppBskyActorProfile
      else {
        throw NSError(
          domain: "ProfileDecoding", code: 0,
          userInfo: [
            NSLocalizedDescriptionKey: "Expected AppBskyActorProfile but found different type"
          ])
      }

      updatedProfile = AppBskyActorProfile(
        displayName: displayName,
        description: description,
        avatar: avatar ?? existingProfile.avatar,
        banner: banner ?? existingProfile.banner,
        labels: existingProfile.labels,
        joinedViaStarterPack: existingProfile.joinedViaStarterPack,
        pinnedPost: existingProfile.pinnedPost,
        createdAt: existingProfile.createdAt
      )

      // Put the updated record
      let putRecordInput = ComAtprotoRepoPutRecord.Input(
        repo: try ATIdentifier(string: currentUserDID),
        collection: try NSID(nsidString: "app.bsky.actor.profile"),
        rkey: try RecordKey(keyString: "self"),
        record: ATProtocolValueContainer.knownType(updatedProfile),
        swapRecord: existingRecord.cid
      )

      let (putRecordCode, _) = try await client.com.atproto.repo.putRecord(input: putRecordInput)
      if putRecordCode == 200 {
        await loadProfile()  // Refresh the profile
      } else {
        throw NSError(
          domain: "ProfileUpdate", code: putRecordCode,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Error updating profile: Unexpected response code \(putRecordCode)"
          ])
      }
    } else if getRecordCode == 400 {
      // Create a new profile record
      updatedProfile = AppBskyActorProfile(
        displayName: displayName,
        description: description,
        avatar: avatar,
        banner: banner,
        labels: nil,
        joinedViaStarterPack: nil, pinnedPost: nil,
        createdAt: ATProtocolDate(date: Date())
      )

      let createRecordInput = ComAtprotoRepoCreateRecord.Input(
        repo: try ATIdentifier(string: currentUserDID),
        collection: try NSID(nsidString: "app.bsky.actor.profile"),
        rkey: try RecordKey(keyString: "self"),
        record: ATProtocolValueContainer.knownType(updatedProfile)
      )

      let (createRecordCode, _) = try await client.com.atproto.repo.createRecord(
        input: createRecordInput)
      if createRecordCode == 200 {
        await loadProfile()  // Refresh the profile
      } else {
        throw NSError(
          domain: "ProfileCreation", code: createRecordCode,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Error creating profile: Unexpected response code \(createRecordCode)"
          ])
      }
    } else {
      throw NSError(
        domain: "ProfileUpdate", code: getRecordCode,
        userInfo: [NSLocalizedDescriptionKey: "Failed to get existing profile record"])
    }
  }
  
  // MARK: - StateInvalidationSubscriber
  
  /// Check if this subscriber is interested in a specific event
  func isInterestedIn(_ event: StateInvalidationEvent) -> Bool {
    switch event {
    case .postCreated(let post):
      // Only interested if:
      // 1. We're viewing our own profile (userDID matches currentUserDID)
      // 2. The post was created by us (matches currentUserDID)
      // Note: Don't rely on isCurrentUser since profile might not be loaded yet
      guard let currentUserDID = currentUserDID else { return false }
      return userDID == currentUserDID && post.author.did.didString() == currentUserDID
      
    case .profileUpdated(let did):
      // Interested if it's the profile we're viewing
      return did == userDID
      
    case .accountSwitched:
      // Always interested in account switches
      return true
      
    default:
      // Not interested in other events
      return false
    }
  }
  
  /// Handle state invalidation events
  @MainActor
  func handleStateInvalidation(_ event: StateInvalidationEvent) async {
    logger.debug("ProfileViewModel: Handling state invalidation event: \(String(describing: event))")
    
    switch event {
    case .postCreated(let post):
      // If a new post was created by this profile, refresh the profile and posts
      if post.author.did.didString() == userDID {
        logger.debug("ProfileViewModel: New post created by profile, refreshing...")
        await loadProfile()
        
        // Refresh the currently selected tab
        switch selectedProfileTab {
        case .posts:
          await loadPosts()
        case .replies:
          await loadReplies()
        case .media:
          await loadMediaPosts()
        default:
          break
        }
      }
      
    case .profileUpdated(let did):
      // If this profile was updated, refresh it
      if did == userDID {
        logger.debug("ProfileViewModel: Profile updated, refreshing...")
        await loadProfile()
      }
      
    case .accountSwitched:
      // Clear all data when account is switched
      logger.debug("ProfileViewModel: Account switched, clearing profile data...")
      profile = nil
      posts = []
      replies = []
      postsWithMedia = []
      likes = []
      otherUserLikes = []
      lists = []
      starterPacks = []
      feeds = []
      knownFollowers = []
      error = nil
      
    default:
      break
    }
  }

}
