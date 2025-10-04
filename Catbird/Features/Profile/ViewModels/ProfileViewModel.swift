import Foundation
import OSLog
import Observation
import Petrel
import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@Observable final class ProfileViewModel: StateInvalidationSubscriber, Hashable, Equatable {
  // MARK: - Properties

  // CRITICAL: Reduced observable properties to prevent Swift metadata cache corruption
  // Only the most essential properties are observable
  private(set) var profile: AppBskyActorDefs.ProfileViewDetailed?
  private(set) var posts: [AppBskyFeedDefs.FeedViewPost] = []
  private(set) var replies: [AppBskyFeedDefs.FeedViewPost] = []
  private(set) var postsWithMedia: [AppBskyFeedDefs.FeedViewPost] = []
  private(set) var isLoading = false
  private(set) var error: Error?
  var selectedProfileTab: ProfileTab = .posts

  // Non-observable properties to reduce metadata cache pressure
  private var _likes: [AppBskyFeedDefs.FeedViewPost] = []
  private var _otherUserLikes: [AppBskyFeedDefs.PostView] = []
  private var _lists: [AppBskyGraphDefs.ListView] = []
  private var _starterPacks: [AppBskyGraphDefs.StarterPackViewBasic] = []
  private var _feeds: [AppBskyFeedDefs.GeneratorView] = []
  private var _knownFollowers: [AppBskyActorDefs.ProfileView] = []
  private var _isLoadingMorePosts = false
  private var _isLoadingKnownFollowers = false
  
  // Computed properties for non-observable data
  var likes: [AppBskyFeedDefs.FeedViewPost] { _likes }
  var otherUserLikes: [AppBskyFeedDefs.PostView] { _otherUserLikes }
  var lists: [AppBskyGraphDefs.ListView] { _lists }
  var starterPacks: [AppBskyGraphDefs.StarterPackViewBasic] { _starterPacks }
  var feeds: [AppBskyFeedDefs.GeneratorView] { _feeds }
  var knownFollowers: [AppBskyActorDefs.ProfileView] { _knownFollowers }
  var isLoadingMorePosts: Bool { _isLoadingMorePosts }
  var isLoadingKnownFollowers: Bool { _isLoadingKnownFollowers }

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
  let userDID: String  // This is the DID of the profile we're viewing (made public for stable view ID)
  private let currentUserDID: String?  // This is the logged-in user's DID
  private let logger = Logger(subsystem: "blue.catbird", category: "ProfileViewModel")
  private weak var stateInvalidationBus: StateInvalidationBus?
  
  // Task management to prevent crashes
  private var activeLoadTasks: Set<Task<Void, Never>> = []
  
  // Unique instance identifier to prevent metadata cache conflicts
  private let instanceId = UUID().uuidString
  
  // Serial queue for synchronized property access to prevent metadata cache corruption
  private let propertyQueue = DispatchQueue(label: "ProfileViewModel.properties", qos: .userInitiated)

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
    
      logger.debug("ProfileViewModel[\(self.instanceId)]: Initializing for userDID: \(userDID)")
    
    // Subscribe to state invalidation events if bus is provided with safety check
    // Use a completely deferred subscription to avoid any metadata cache conflicts during init
    if let bus = stateInvalidationBus {
      Task.detached { [weak self, weak bus] in
        // Wait longer to ensure object is fully initialized
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
        
        await MainActor.run {
          guard let self = self, let bus = bus else { return }
          bus.subscribe(self)
          self.logger.debug("ProfileViewModel[\(self.instanceId)]: Deferred subscription completed")
        }
      }
    }
  }
  
  deinit {
      logger.debug("ProfileViewModel[\(self.instanceId)]: Deinitializing")
    
    // Cancel all active tasks to prevent crashes
    for task in activeLoadTasks {
      task.cancel()
    }
    activeLoadTasks.removeAll()
    
    // Unsubscribe from state invalidation events
    stateInvalidationBus?.unsubscribe(self)
  }

  // MARK: - Public Methods

  /// Loads the user profile with enhanced crash protection
  func loadProfile() async {
    guard let client = client else {
      await MainActor.run {
        self.error = ProfileError.clientNotAvailable
        self.isLoading = false
      }
      return
    }
    
    // Validate userDID to prevent AT Protocol errors
    guard !userDID.isEmpty && userDID != "fallback" && userDID != "unknown" else {
      await MainActor.run {
        self.error = ProfileError.invalidUserDID
        self.isLoading = false
      }
      return
    }

    await MainActor.run {
      self.isLoading = true
      self.error = nil
    }

    do {
      let (responseCode, profileData) = try await client.app.bsky.actor.getProfile(
        input: .init(actor: try ATIdentifier(string: userDID))
      )

      await MainActor.run {
        // Double-check that we're still valid and not cancelled
        guard !Task.isCancelled else { 
          logger.debug("ProfileViewModel[\(self.instanceId)]: Task cancelled during profile load")
          return 
        }
        
        if responseCode == 200, let profile = profileData {
          self.profile = profile
          self.error = nil
          logger.debug("ProfileViewModel[\(self.instanceId)]: Successfully loaded profile for \(profile.handle)")
        } else {
          let profileError = ProfileError.httpError(responseCode)
          self.error = profileError
          logger.error("ProfileViewModel[\(self.instanceId)]: Failed to load profile - HTTP \(responseCode)")
        }
        self.isLoading = false
      }
    } catch {
      await MainActor.run {
        // Check if object is still valid to prevent crash during deallocation
        guard !Task.isCancelled else { 
          logger.debug("ProfileViewModel[\(self.instanceId)]: Task cancelled during error handling")
          return 
        }
        
        self.error = error
        self.isLoading = false
        logger.error("ProfileViewModel[\(self.instanceId)]: Error loading profile: \(error.localizedDescription)")
      }
    }
  }

  /// Loads user's posts
  func loadPosts() async {
    await loadFeed(type: .posts, resetCursor: postsCursor == nil)
    // Persist to SwiftData for profile posts feed
    await cacheCurrentTabPosts(for: .posts)
  }

  /// Loads user's replies
  func loadReplies() async {
    await loadFeed(type: .replies, resetCursor: repliesCursor == nil)
    await cacheCurrentTabPosts(for: .replies)
  }

  /// Loads user's posts with media
  func loadMediaPosts() async {
    await loadFeed(type: .media, resetCursor: mediaPostsCursor == nil)
    await cacheCurrentTabPosts(for: .media)
  }

  /// Loads user's liked posts
  func loadLikes() async {
    await loadFeed(type: .likes, resetCursor: likesCursor == nil)
  }

  /// Loads known followers - people who follow this profile and are also followed by the current user
  func loadKnownFollowers() async {
    guard let client = client, let profile = profile, !self.isCurrentUser, !isLoadingKnownFollowers else { return }

    _isLoadingKnownFollowers = true

    do {
      let params = AppBskyGraphGetKnownFollowers.Parameters(
        actor: try ATIdentifier(string: profile.did.didString()),
        limit: 20,
        cursor: knownFollowersCursor
      )

      let (responseCode, output) = try await client.app.bsky.graph.getKnownFollowers(input: params)

      if responseCode == 200, let followers = output?.followers {
        await MainActor.run {
          // Check if object is still valid to prevent crash during deallocation
          guard !Task.isCancelled else { return }
          
          if self.knownFollowersCursor == nil {
            self._knownFollowers = followers
          } else {
            self._knownFollowers.append(contentsOf: followers)
          }
          self.knownFollowersCursor = output?.cursor
          self._isLoadingKnownFollowers = false
        }
      } else {
        logger.warning("Failed to load known followers: HTTP \(responseCode)")
        await MainActor.run { 
          guard !Task.isCancelled else { return }
          self._isLoadingKnownFollowers = false 
        }
      }
    } catch {
      logger.error("Error loading known followers: \(error.localizedDescription)")
      await MainActor.run { 
        guard !Task.isCancelled else { return }
        self._isLoadingKnownFollowers = false 
      }
    }
  }

  /// Loads user's starter packs
  func loadStarterPacks() async {
    guard let client = client, let profile = profile, !isLoadingMorePosts else { return }

    _isLoadingMorePosts = true

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
            self._starterPacks = packs
          } else {
            self._starterPacks.append(contentsOf: packs)
          }
          self.starterPacksCursor = output?.cursor
          self.hasMoreStarterPacks = output?.cursor != nil
          self._isLoadingMorePosts = false
        }
      } else {
        logger.warning("Failed to load starter packs: HTTP \(responseCode)")
        await MainActor.run {
          self._isLoadingMorePosts = false
          self.hasMoreStarterPacks = false
        }
      }
    } catch {
      logger.error("Error loading starter packs: \(error.localizedDescription)")
      await MainActor.run {
        self._isLoadingMorePosts = false
        self.hasMoreStarterPacks = false
      }
    }
  }

  /// Loads user's lists
  func loadLists() async {
    guard let client = client, let profile = profile, !isLoadingMorePosts else { return }

    _isLoadingMorePosts = true

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
            self._lists = lists
          } else {
            self._lists.append(contentsOf: lists)
          }
          self.listsCursor = output?.cursor
          self._isLoadingMorePosts = false
        }
      } else {
        logger.warning("Failed to load lists: HTTP \(responseCode)")
        await MainActor.run { self._isLoadingMorePosts = false }
      }
    } catch {
      logger.error("Error loading lists: \(error.localizedDescription)")
      await MainActor.run { self._isLoadingMorePosts = false }
    }
  }

  // MARK: - Private Methods

  /// Load different types of feeds
  private func loadFeed(type: FeedType, resetCursor: Bool) async {
    guard let client = client, let profile = profile, !isLoadingMorePosts else { return }

    _isLoadingMorePosts = true

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
              case .pending(_):
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
                          self._likes = feed
                      } else {
                          self._likes.append(contentsOf: feed)
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
                          self._otherUserLikes = likedPosts
                      } else {
                          self._otherUserLikes.append(contentsOf: likedPosts)
                      }
                      
                      // Store cursor for next pagination
                      self.likesCursor = decodedData.cursor
                  }
              }
          }
      }

      await MainActor.run {
        self._isLoadingMorePosts = false
      }

    } catch {
      logger.error(
        "Error loading feed (\(String(describing: type))): \(error.localizedDescription)")
      await MainActor.run {
        self._isLoadingMorePosts = false
      }
    }
  }

  // MARK: - Helper Types

  private enum FeedType {
    case posts, replies, media, likes
  }

  // MARK: - SwiftData Caching for Profile Tabs

  /// Computes a unique feed key for this profile tab for SwiftData persistence
  func profileFeedKey(for tab: ProfileTab) -> String {
    let base = "author:\(userDID)"
    switch tab {
    case .posts: return base + ":posts"
    case .replies: return base + ":replies"
    case .media: return base + ":media"
    case .likes: return base + ":likes"
    default: return base + ":other"
    }
  }

  /// Creates CachedFeedViewPost entries for the current tab and saves them via PersistentFeedStateManager
  @MainActor
  private func cacheCurrentTabPosts(for type: FeedType) async {
    let tab: ProfileTab
    let source: [AppBskyFeedDefs.FeedViewPost]
    switch type {
    case .posts:
      tab = .posts
      source = posts
    case .replies:
      tab = .replies
      source = replies
    case .media:
      tab = .media
      source = postsWithMedia
    case .likes:
      tab = .likes
      source = _likes
    }

    let key = profileFeedKey(for: tab)

    // Map to CachedFeedViewPost with this tab-specific feed key
    let cached = source.compactMap { post in
      CachedFeedViewPost(from: post, feedType: key)
    }

    // Persist using the ModelActor
    await PersistentFeedStateManager.shared.saveFeedData(cached, for: key)
  }

  /// Loads user's feeds (feed generators)
  func loadFeeds() async {
    guard let client = client, let profile = profile, !isLoadingMorePosts else { return }

    _isLoadingMorePosts = true

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
            self._feeds = fetchedFeeds
          } else {
            self._feeds.append(contentsOf: fetchedFeeds)
          }
          self.feedsCursor = output?.cursor
          self._isLoadingMorePosts = false
        }
      } else {
        logger.warning("Failed to load feeds: HTTP \(responseCode)")
        await MainActor.run {
          self._isLoadingMorePosts = false
        }
      }
    } catch {
      logger.error("Error loading feeds: \(error.localizedDescription)")
      await MainActor.run {
        self._isLoadingMorePosts = false
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
    if let image = PlatformImage(data: processedData),
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
    #if os(iOS)
    guard let image = UIImage(data: data) else { return nil }
    #elseif os(macOS)
    guard let image = NSImage(data: data) else { return nil }
    #else
    return nil // Unsupported platform
    #endif
    return image.jpegData(compressionQuality: 0.8)
  }
  
  /// Compresses image to target size
  private func compressImage(_ image: PlatformImage, maxSizeInBytes: Int) -> Data? {
    #if os(iOS)
    var compression: CGFloat = 0.8
    var imageData = image.jpegData(compressionQuality: compression)
    
    while let data = imageData, data.count > maxSizeInBytes && compression > 0.1 {
      compression -= 0.1
      imageData = image.jpegData(compressionQuality: compression)
    }
    
    return imageData
    #else
    // macOS compression is more complex, returning as-is for now
    let imageRep = NSBitmapImageRep(data: image.tiffRepresentation!)
    return imageRep?.representation(using: .jpeg, properties: [:])
    #endif
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
      _likes = []
      _otherUserLikes = []
      _lists = []
      _starterPacks = []
      _feeds = []
      _knownFollowers = []
      error = nil
      
    default:
      break
    }
  }
  
  // MARK: - Hashable & Equatable conformance to prevent Swift metadata cache conflicts
  
  func hash(into hasher: inout Hasher) {
    hasher.combine(instanceId)
    hasher.combine(userDID)
  }
  
  static func == (lhs: ProfileViewModel, rhs: ProfileViewModel) -> Bool {
    return lhs.instanceId == rhs.instanceId && lhs.userDID == rhs.userDID
  }

}

// MARK: - Profile Error Types
enum ProfileError: LocalizedError {
  case clientNotAvailable
  case invalidUserDID
  case httpError(Int)
  
  var errorDescription: String? {
    switch self {
    case .clientNotAvailable:
      return "Network client not available"
    case .invalidUserDID:
      return "Invalid user identifier"
    case .httpError(let code):
      return "HTTP error: \(code)"
    }
  }
}
