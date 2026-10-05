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
  private(set) var pinnedPost: AppBskyFeedDefs.FeedViewPost?

  // Non-observable properties to reduce metadata cache pressure
  private var _likes: [AppBskyFeedDefs.FeedViewPost] = []
  private var _otherUserLikes: [AppBskyFeedDefs.PostView] = []
  private var _lists: [AppBskyGraphDefs.ListView] = []
  private var _starterPacks: [AppBskyGraphDefs.StarterPackViewBasic] = []
  private var _feeds: [AppBskyFeedDefs.GeneratorView] = []
  private var _knownFollowers: [AppBskyActorDefs.ProfileView] = []
  private var _isLoadingMorePosts = false
  private var _isLoadingLikes = false
  private var _isLoadingSection = false
  private var _isLoadingKnownFollowers = false
  
  // Labeler-specific properties
  private(set) var labelerDetails: AppBskyLabelerDefs.LabelerViewDetailed?
  private(set) var isSubscribedToLabeler = false
  private(set) var isLabelerLiked = false
  private(set) var labelerLikeCount = 0
  private var labelerLikeURI: ATProtocolURI?
  
  // Computed properties for non-observable data
  var likes: [AppBskyFeedDefs.FeedViewPost] { _likes }
  var otherUserLikes: [AppBskyFeedDefs.PostView] { _otherUserLikes }
  var lists: [AppBskyGraphDefs.ListView] { _lists }
  var starterPacks: [AppBskyGraphDefs.StarterPackViewBasic] { _starterPacks }
  var feeds: [AppBskyFeedDefs.GeneratorView] { _feeds }
  var knownFollowers: [AppBskyActorDefs.ProfileView] { _knownFollowers }
  var isLoadingMorePosts: Bool { _isLoadingMorePosts }
  var isLoadingLikes: Bool { _isLoadingLikes }
  /// True while lists, starter packs or feeds are loading.
  var isLoadingSection: Bool { _isLoadingSection }
  var isLoadingKnownFollowers: Bool { _isLoadingKnownFollowers }
  
  /// Check if this profile is a labeler
  var isLabeler: Bool {
    // A profile is a labeler if it has loaded labeler details OR
    // if the associated labeler field is set to true
    if labelerDetails != nil {
      return true
    }
    // Check if associated.labeler is explicitly true (not just present)
    if let labeler = profile?.associated?.labeler, labeler == true {
      return true
    }
    return false
  }

  // Pagination tracking. Each flag turns false once the server stops returning a cursor.
  private(set) var hasMoreStarterPacks = false
  private(set) var hasMorePosts = true
  private(set) var hasMoreReplies = true
  private(set) var hasMoreMedia = true
  private(set) var hasMoreLikes = true
  private(set) var hasMoreLists = true
  private(set) var hasMoreFeeds = true

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
  let currentUserDID: String?  // This is the logged-in user's DID
  private let logger = Logger(subsystem: "blue.catbird", category: "ProfileViewModel")
  private weak var stateInvalidationBus: StateInvalidationBus?
  
  // Content filtering service
  private let contentFilterService = ContentFilterService()
  
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

  // MARK: - Content Filtering
  
  /// Apply content filtering to profile posts based on user preferences
  func applyContentFiltering(filterSettings: FeedTunerSettings) async {
    // Filter posts
    let filteredPosts = await contentFilterService.filterFeedViewPosts(posts, settings: filterSettings)
    
    // Filter replies
    let filteredReplies = await contentFilterService.filterFeedViewPosts(replies, settings: filterSettings)
    
    // Filter media posts
    let filteredMediaPosts = await contentFilterService.filterFeedViewPosts(postsWithMedia, settings: filterSettings)
    
    await MainActor.run {
      self.posts = filteredPosts
      self.replies = filteredReplies
      self.postsWithMedia = filteredMediaPosts
    }
    
      logger.debug("Applied content filtering to profile posts: \(self.posts.count) posts, \(self.replies.count) replies, \(self.postsWithMedia.count) media posts")
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

      if responseCode == 200, let profile = profileData {
        await SpotlightEntityDonator.shared.donate(profiles: [profile])
      }

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
          
          // Set default tab based on profile type
          if self.isLabeler && self.selectedProfileTab == .posts {
            self.selectedProfileTab = .labelerInfo
          }
        } else {
          // Petrel drops the XRPC error body, so map by status: getProfile answers 400 for
          // deactivated, suspended and unknown accounts.
          let profileError: ProfileError = (responseCode == 400 || responseCode == 404)
            ? .unavailable
            : .httpError(responseCode)
          self.error = profileError
          logger.error("ProfileViewModel[\(self.instanceId)]: Failed to load profile - HTTP \(responseCode)")
        }
        self.isLoading = false
      }
      
      // Load labeler details if this is a labeler profile
      if isLabeler {
        await loadLabelerDetails()
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

  /// Loads the first page of the user's posts, replacing anything already loaded.
  func loadPosts() async {
    await loadFeed(type: .posts, resetCursor: true)
    // Persist to SwiftData for profile posts feed
    await cacheCurrentTabPosts(for: .posts)
  }

  /// Appends the next page of posts, if there is one.
  func loadMorePosts() async {
    guard hasMorePosts, postsCursor != nil else { return }
    await loadFeed(type: .posts, resetCursor: false)
    await cacheCurrentTabPosts(for: .posts)
  }

  /// Loads the first page of the user's replies, replacing anything already loaded.
  func loadReplies() async {
    await loadFeed(type: .replies, resetCursor: true)
    await cacheCurrentTabPosts(for: .replies)
  }

  /// Appends the next page of replies, if there is one.
  func loadMoreReplies() async {
    guard hasMoreReplies, repliesCursor != nil else { return }
    await loadFeed(type: .replies, resetCursor: false)
    await cacheCurrentTabPosts(for: .replies)
  }

  /// Loads the first page of the user's media posts, replacing anything already loaded.
  func loadMediaPosts() async {
    await loadFeed(type: .media, resetCursor: true)
    await cacheCurrentTabPosts(for: .media)
  }

  /// Appends the next page of media posts, if there is one.
  func loadMoreMediaPosts() async {
    guard hasMoreMedia, mediaPostsCursor != nil else { return }
    await loadFeed(type: .media, resetCursor: false)
    await cacheCurrentTabPosts(for: .media)
  }

  /// Loads the first page of liked posts, replacing anything already loaded.
  func refreshLikes() async throws {
    try await fetchLikes(reset: true)
  }

  /// Appends the next page of liked posts, if there is one.
  func loadMoreLikes() async {
    guard hasMoreLikes, likesCursor != nil else { return }
    do {
      try await fetchLikes(reset: false)
    } catch {
      logger.error("Error loading more likes: \(error.localizedDescription)")
    }
  }

  private func fetchLikes(reset: Bool) async throws {
    guard let client = client, let profile = profile, !_isLoadingLikes else { return }
    _isLoadingLikes = true
    defer { _isLoadingLikes = false }
    let cursor = reset ? nil : likesCursor

    if isCurrentUser {
      let params = AppBskyFeedGetActorLikes.Parameters(
        actor: try ATIdentifier(string: profile.did.didString()),
        limit: 20,
        cursor: cursor
      )

      let (responseCode, output) = try await client.app.bsky.feed.getActorLikes(input: params)

      guard responseCode == 200, let feed = output?.feed else {
        logger.warning("getActorLikes returned HTTP \(responseCode)")
        throw ProfileError.httpError(responseCode)
      }
      await MainActor.run {
        if reset {
          self._likes = feed
        } else {
          self._likes.append(contentsOf: feed)
        }
        self.likesCursor = output?.cursor
        self.hasMoreLikes = output?.cursor != nil
      }
    } else {
      let result = try await ActorLikesRecordFetcher.fetchLikedPosts(
        client: client,
        actorDID: profile.did.didString(),
        cursor: cursor,
        limit: 25
      )

      await MainActor.run {
        if reset {
          self._otherUserLikes = result.posts
        } else {
          self._otherUserLikes.append(contentsOf: result.posts)
        }
        self.likesCursor = result.cursor
        self.hasMoreLikes = result.cursor != nil
      }
    }
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

  /// Loads the first page of starter packs, replacing anything already loaded.
  func refreshStarterPacks() async throws {
    try await fetchStarterPacks(reset: true)
  }

  /// Appends the next page of starter packs, if there is one.
  func loadStarterPacks() async {
    guard hasMoreStarterPacks, starterPacksCursor != nil else { return }
    do {
      try await fetchStarterPacks(reset: false)
    } catch {
      logger.error("Error loading more starter packs: \(error.localizedDescription)")
    }
  }

  private func fetchStarterPacks(reset: Bool) async throws {
    guard let client = client, let profile = profile, !_isLoadingSection else { return }
    _isLoadingSection = true
    defer { _isLoadingSection = false }

    let params = AppBskyGraphGetActorStarterPacks.Parameters(
      actor: try ATIdentifier(string: profile.did.didString()),
      limit: 20,
      cursor: reset ? nil : starterPacksCursor
    )

    let (responseCode, output) = try await client.app.bsky.graph.getActorStarterPacks(
      input: params)

    guard responseCode == 200, let packs = output?.starterPacks else {
      logger.warning("Failed to load starter packs: HTTP \(responseCode)")
      throw ProfileError.httpError(responseCode)
    }
    await MainActor.run {
      if reset {
        self._starterPacks = packs
      } else {
        self._starterPacks.append(contentsOf: packs)
      }
      self.starterPacksCursor = output?.cursor
      self.hasMoreStarterPacks = output?.cursor != nil
    }
  }

  /// Loads the first page of lists, replacing anything already loaded.
  func refreshLists() async throws {
    try await fetchLists(reset: true)
  }

  /// Appends the next page of lists, if there is one.
  func loadMoreLists() async {
    guard hasMoreLists, listsCursor != nil else { return }
    do {
      try await fetchLists(reset: false)
    } catch {
      logger.error("Error loading more lists: \(error.localizedDescription)")
    }
  }

  private func fetchLists(reset: Bool) async throws {
    guard let client = client, let profile = profile, !_isLoadingSection else { return }
    _isLoadingSection = true
    defer { _isLoadingSection = false }

    let params = AppBskyGraphGetLists.Parameters(
      actor: try ATIdentifier(string: profile.did.didString()),
      limit: 20,
      cursor: reset ? nil : listsCursor
    )

    let (responseCode, output) = try await client.app.bsky.graph.getLists(input: params)

    guard responseCode == 200, let lists = output?.lists else {
      logger.warning("Failed to load lists: HTTP \(responseCode)")
      throw ProfileError.httpError(responseCode)
    }
    await MainActor.run {
      if reset {
        self._lists = lists
      } else {
        self._lists.append(contentsOf: lists)
      }
      self.listsCursor = output?.cursor
      self.hasMoreLists = output?.cursor != nil
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
          // Extract pinned post if present (will have reason = .appBskyFeedDefsReasonPin)
          let pinned = feed.first { post in
            if case .appBskyFeedDefsReasonPin = post.reason {
              return true
            }
            return post.post.viewer?.pinned == true
          }
          
          // Remove pinned post from regular feed to avoid duplication
          let regularPosts = feed.filter { post in
            if case .appBskyFeedDefsReasonPin = post.reason {
              return false
            }
            return post.post.viewer?.pinned != true
          }
          
          if let pinned = pinned {
            logger.debug("ProfileViewModel[\(self.instanceId)]: Found pinned post: \(pinned.post.uri.uriString())")
          }
          
          await MainActor.run {
            if resetCursor {
              self.pinnedPost = pinned
              self.posts = regularPosts
            } else {
              // When paginating, don't update pinned post
              self.posts.append(contentsOf: regularPosts)
            }
            self.postsCursor = output?.cursor
            self.hasMorePosts = output?.cursor != nil
          }
        }

      case .replies:
        // Most of an author feed is often top-level posts, so keep paging (within a small
        // budget) until enough replies to other people turn up to fill the screen.
        var cursor = resetCursor ? nil : repliesCursor
        var repliesToOthers: [AppBskyFeedDefs.FeedViewPost] = []
        var requestCount = 0
        var didReceivePage = false

        repeat {
          let params = AppBskyFeedGetAuthorFeed.Parameters(
            actor: try ATIdentifier(string: profile.did.didString()),
            limit: 30,
            cursor: cursor,
            filter: "posts_with_replies"
          )

          let (responseCode, output) = try await client.app.bsky.feed.getAuthorFeed(input: params)
          requestCount += 1

          guard responseCode == 200, let feed = output?.feed else { break }
          didReceivePage = true
          cursor = output?.cursor

          // Filter to only include replies to other people
          repliesToOthers.append(contentsOf: feed.filter { post in
            guard post.reason == nil, let reply = post.reply else { return false }
            switch reply.parent {
            case .appBskyFeedDefsPostView(let parentPost):
              return parentPost.author.did != profile.did
            case .appBskyFeedDefsNotFoundPost, .appBskyFeedDefsBlockedPost, .unexpected:
              return true
            }
          })
        } while repliesToOthers.count < 10 && cursor != nil && requestCount < 5

        if didReceivePage {
          let nextCursor = cursor
          let pageReplies = repliesToOthers
          await MainActor.run {
            if resetCursor {
              self.replies = pageReplies
            } else {
              self.replies.append(contentsOf: pageReplies)
            }
            self.repliesCursor = nextCursor
            self.hasMoreReplies = nextCursor != nil
          }
        }

      case .media:
        let params = AppBskyFeedGetAuthorFeed.Parameters(
          actor: try ATIdentifier(string: profile.did.didString()),
          limit: 30,
          cursor: resetCursor ? nil : mediaPostsCursor,
          filter: "posts_with_media"
        )

        let (responseCode, output) = try await client.app.bsky.feed.getAuthorFeed(input: params)

        if responseCode == 200, let feed = output?.feed {
          // Filter to only include posts with media
          let postsWithMedia = feed.filter { post in
            if let embed = post.post.embed {
              switch embed {
              case .appBskyEmbedImagesView, .appBskyEmbedGalleryView, .appBskyEmbedVideoView:
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
            self.hasMoreMedia = output?.cursor != nil
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
    case posts, replies, media
  }

  // MARK: - SwiftData Caching for Profile Tabs

  /// Computes a unique feed key for this profile tab for SwiftData persistence
  func profileFeedKey(for tab: ProfileTab) -> String {
    let base = "author:\(userDID)"
    let baseKey: String
    switch tab {
    case .posts: baseKey = base + ":posts"
    case .replies: baseKey = base + ":replies"
    case .media: baseKey = base + ":media"
    case .likes: baseKey = base + ":likes"
    default: baseKey = base + ":other"
    }
    let account = currentUserDID ?? "unknown-account"
    return "\(account)-\(baseKey)"
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
    }

    let key = profileFeedKey(for: tab)

    // Map to CachedFeedViewPost with this tab-specific feed key, preserving feed order
    let cached = source.enumerated().compactMap { (index, post) in
      CachedFeedViewPost(from: post, feedType: key, feedOrder: index)
    }

    // Persist using the ModelActor
    await PersistentFeedStateManager.shared.saveFeedData(cached, for: key)
  }

  /// Loads the first page of feeds, replacing anything already loaded.
  func refreshFeeds() async throws {
    try await fetchFeeds(reset: true)
  }

  /// Appends the next page of feeds, if there is one.
  func loadMoreFeeds() async {
    guard hasMoreFeeds, feedsCursor != nil else { return }
    do {
      try await fetchFeeds(reset: false)
    } catch {
      logger.error("Error loading more feeds: \(error.localizedDescription)")
    }
  }

  private func fetchFeeds(reset: Bool) async throws {
    guard let client = client, let profile = profile, !_isLoadingSection else { return }
    _isLoadingSection = true
    defer { _isLoadingSection = false }

    let params = AppBskyFeedGetActorFeeds.Parameters(
      actor: try ATIdentifier(string: profile.did.didString()),
      limit: 20,
      cursor: reset ? nil : feedsCursor
    )

    let (responseCode, output) = try await client.app.bsky.feed.getActorFeeds(input: params)

    guard responseCode == 200, let fetchedFeeds = output?.feeds else {
      logger.warning("Failed to load feeds: HTTP \(responseCode)")
      throw ProfileError.httpError(responseCode)
    }
    await MainActor.run {
      if reset {
        self._feeds = fetchedFeeds
      } else {
        self._feeds.append(contentsOf: fetchedFeeds)
      }
      self.feedsCursor = output?.cursor
      self.hasMoreFeeds = output?.cursor != nil
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

    let mimeType = ImageMetadataStripper.detectMIMEType(from: imageData)

    let (responseCode, blobOutput) = try await client.com.atproto.repo.uploadBlob(
      data: imageData,
      mimeType: mimeType,
      stripMetadata: true
    )

    guard responseCode == 200, let blob = blobOutput?.blob else {
      throw NSError(
        domain: "ProfileImageUpload", code: responseCode,
        userInfo: [NSLocalizedDescriptionKey: "Failed to upload image: HTTP \(responseCode)"])
    }

    return blob
  }

  // MARK: Update Profile

  /// Updates the signed-in user's profile record.
  ///
  /// For the text fields, `nil` keeps the existing value and an empty (or whitespace-only)
  /// string clears it. `avatar` and `banner` keep the existing images when `nil`.
  func updateProfile(displayName: String? = nil, description: String? = nil, pronouns: String? = nil, website: String? = nil, avatar: Blob? = nil, banner: Blob? = nil) async throws {
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

      let websiteURI: URI? = if let website {
        Self.nilIfBlank(website).flatMap { try? URI(uriString: $0) }
      } else {
        existingProfile.website
      }

      updatedProfile = AppBskyActorProfile(
        displayName: displayName.map(Self.nilIfBlank) ?? existingProfile.displayName,
        description: description.map(Self.nilIfBlank) ?? existingProfile.description,
        pronouns: pronouns.map(Self.nilIfBlank) ?? existingProfile.pronouns,
        website: websiteURI,
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
      let newWebsiteURI: URI? = website.flatMap(Self.nilIfBlank).flatMap { try? URI(uriString: $0) }

      updatedProfile = AppBskyActorProfile(
        displayName: displayName.flatMap(Self.nilIfBlank),
        description: description.flatMap(Self.nilIfBlank),
        pronouns: pronouns.flatMap(Self.nilIfBlank),
        website: newWebsiteURI,
        avatar: avatar,
        banner: banner,
        labels: nil,
        joinedViaStarterPack: nil,
        pinnedPost: nil,
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
  
  private static func nilIfBlank(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
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
  
  // MARK: - Labeler Methods
  
  /// Load detailed labeler information if this profile is a labeler
  func loadLabelerDetails() async {
    guard isLabeler, let client = client, let profile = profile else { return }
    
    do {
      let did = profile.did
      let params = AppBskyLabelerGetServices.Parameters(dids: [did], detailed: true)
      let (_, response) = try await client.app.bsky.labeler.getServices(input: params)
      
      if let views = response?.views, let firstView = views.first {
        if case let .appBskyLabelerDefsLabelerViewDetailed(detailed) = firstView {
          await MainActor.run {
            self.labelerDetails = detailed
            self.isLabelerLiked = detailed.viewer?.like != nil
            self.labelerLikeURI = detailed.viewer?.like
            self.labelerLikeCount = detailed.likeCount ?? 0
          }
        }
      }
      
      // Check if subscribed
      await checkLabelerSubscription()
    } catch {
      logger.error("Failed to load labeler details: \(error.localizedDescription)")
    }
  }
  
  /// Check if user is subscribed to this labeler
  private func checkLabelerSubscription() async {
    guard let client = client, let profile = profile else { return }
    
    do {
      let (_, response) = try await client.app.bsky.actor.getPreferences(
        input: AppBskyActorGetPreferences.Parameters()
      )
      
      if let prefs = response?.preferences.items {
        for pref in prefs {
          if case let .labelersPref(labelerPref) = pref {
            let isSubscribed = labelerPref.labelers.contains { labeler in
              labeler.did == profile.did
            }
            await MainActor.run {
              self.isSubscribedToLabeler = isSubscribed
            }
            return
          }
        }
      }
      
      await MainActor.run {
        self.isSubscribedToLabeler = false
      }
    } catch {
      logger.error("Failed to check labeler subscription: \(error.localizedDescription)")
    }
  }
  
  /// Subscribe to this labeler
  func subscribeToLabeler() async throws {
    guard let client = client, let profile = profile else { return }
    
    // Get current preferences
    let (_, currentPrefs) = try await client.app.bsky.actor.getPreferences(
      input: AppBskyActorGetPreferences.Parameters()
    )
    
    guard let preferences = currentPrefs?.preferences.items else { return }
    
    var updatedPreferences = preferences
    var foundLabelersPref = false
    
    // Find and update labelers pref
    for (index, pref) in updatedPreferences.enumerated() {
      if case let .labelersPref(labelerPref) = pref {
        foundLabelersPref = true
        var labelers = labelerPref.labelers
        
        // Add this labeler if not already present
        if !labelers.contains(where: { $0.did == profile.did }) {
          labelers.append(AppBskyActorDefs.LabelerPrefItem(did: profile.did))
          updatedPreferences[index] = .labelersPref(
            AppBskyActorDefs.LabelersPref(labelers: labelers)
          )
        }
        break
      }
    }
    
    // If no labelers pref exists, create one
    if !foundLabelersPref {
      updatedPreferences.append(
        .labelersPref(
          AppBskyActorDefs.LabelersPref(labelers: [
            AppBskyActorDefs.LabelerPrefItem(did: profile.did)
          ])
        )
      )
    }
    
    // Save preferences
    let apiPreferences = AppBskyActorDefs.Preferences(items: updatedPreferences)
    _ = try await client.app.bsky.actor.putPreferences(
      input: AppBskyActorPutPreferences.Input(preferences: apiPreferences)
    )
    
    await MainActor.run {
      self.isSubscribedToLabeler = true
    }
  }
  
  /// Unsubscribe from this labeler
  func unsubscribeFromLabeler() async throws {
    guard let client = client, let profile = profile else { return }
    
    // Get current preferences
    let (_, currentPrefs) = try await client.app.bsky.actor.getPreferences(
      input: AppBskyActorGetPreferences.Parameters()
    )
    
    guard let preferences = currentPrefs?.preferences.items else { return }
    
    var updatedPreferences = preferences
    
    // Find and update labelers pref
    for (index, pref) in updatedPreferences.enumerated() {
      if case let .labelersPref(labelerPref) = pref {
        let labelers = labelerPref.labelers.filter { $0.did != profile.did }
        updatedPreferences[index] = .labelersPref(
          AppBskyActorDefs.LabelersPref(labelers: labelers)
        )
        break
      }
    }
    
    // Save preferences
    let apiPreferences = AppBskyActorDefs.Preferences(items: updatedPreferences)
    _ = try await client.app.bsky.actor.putPreferences(
      input: AppBskyActorPutPreferences.Input(preferences: apiPreferences)
    )
    
    await MainActor.run {
      self.isSubscribedToLabeler = false
    }
  }
  
  /// Like this labeler
  func likeLabeler() async throws {
    guard let client = client, let labelerDetails = labelerDetails else { return }
    guard let currentUserDID = currentUserDID else { return }
    
    let postRef = ComAtprotoRepoStrongRef(
      uri: labelerDetails.uri,
      cid: labelerDetails.cid
    )
    
    let like = AppBskyFeedLike(
      subject: postRef,
      createdAt: ATProtocolDate(date: Date()),
      via: nil
    )
    
    let (_, response) = try await client.com.atproto.repo.createRecord(
      input: ComAtprotoRepoCreateRecord.Input(
        repo: try ATIdentifier(string: currentUserDID),
        collection: NSID(nsidString: "app.bsky.feed.like"),
        record: .knownType(like)
      )
    )
    
    if let likeURI = response?.uri {
      await MainActor.run {
        self.labelerLikeURI = likeURI
        self.isLabelerLiked = true
        self.labelerLikeCount += 1
      }
    }
  }
  
  /// Unlike this labeler
  func unlikeLabeler() async throws {
    guard let client = client, labelerDetails != nil else { return }
    guard let currentUserDID = currentUserDID else { return }
    guard let likeUri = labelerLikeURI else { return }
    
    // Extract rkey from the like URI
    guard let rkey = likeUri.recordKey else { return }
    
    _ = try await client.com.atproto.repo.deleteRecord(
      input: ComAtprotoRepoDeleteRecord.Input(
        repo: try ATIdentifier(string: currentUserDID),
        collection: NSID(nsidString: "app.bsky.feed.like"),
        rkey: RecordKey(keyString: rkey)
      )
    )
    
    await MainActor.run {
      self.labelerLikeURI = nil
      self.isLabelerLiked = false
      self.labelerLikeCount = max(0, self.labelerLikeCount - 1)
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
  /// The account is deactivated, suspended, deleted or otherwise not viewable.
  case unavailable
  
  var errorDescription: String? {
    switch self {
    case .clientNotAvailable:
      return "You’re signed out. Sign in and try again."
    case .invalidUserDID:
      return "This profile link isn’t valid."
    case .httpError:
      return "Couldn’t load this profile. Try again."
    case .unavailable:
      return "This account may have been deactivated, suspended or deleted."
    }
  }
}
