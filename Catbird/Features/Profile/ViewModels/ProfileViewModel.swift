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

@MainActor
@Observable final class ProfileViewModel: StateInvalidationSubscriber, Hashable, Equatable {
  // MARK: - Properties

  // CRITICAL: Reduced observable properties to prevent Swift metadata cache corruption
  // Only the most essential properties are observable
  private(set) var profile: AppBskyActorDefs.ProfileViewDetailed?
  // The post tabs render straight from these rows, each boxed once when its page arrives and
  // kept only here. A row id appears at most once per tab (see `appendingUnique`).
  private(set) var boxedPosts: [EquatableBox<AppBskyFeedDefs.FeedViewPost>] = []
  private(set) var boxedReplies: [EquatableBox<AppBskyFeedDefs.FeedViewPost>] = []
  private(set) var boxedPostsWithMedia: [EquatableBox<AppBskyFeedDefs.FeedViewPost>] = []
  private(set) var isLoading = false
  private(set) var error: Error?
  var selectedProfileTab: ProfileTab = .posts
  /// Boxed once per first page, so the list compares the pinned row by pointer.
  private(set) var pinnedPost: EquatableBox<AppBskyFeedDefs.FeedViewPost>?

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
    if userDID == ModerationPrefs.blueskyModerationDID {
      return true
    }
    // Check if associated.labeler is explicitly true (not just present)
    if let labeler = profile?.associated?.labeler, labeler == true {
      return true
    }
    return false
  }

  /// The Follow button's write state, kept here because the header's own state resets when
  /// its list cell is reused. See ProfileFollowWrites.
  let followWrites = ProfileFollowWrites()

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

  // Dependencies
  private let client: ATProtoClient?
  let userDID: String  // This is the DID of the profile we're viewing (made public for stable view ID)
  let currentUserDID: String?  // This is the logged-in user's DID
  private let logger = Logger(subsystem: "blue.catbird", category: "ProfileViewModel")
  private weak var stateInvalidationBus: StateInvalidationBus?
  
  // Task management to prevent crashes
  private var activeLoadTasks: Set<Task<Void, Never>> = []
  
  // Unique instance identifier to prevent metadata cache conflicts
  private let instanceId = UUID().uuidString
  
  // Serial queue for synchronized property access to prevent metadata cache corruption
  private let propertyQueue = DispatchQueue(label: "ProfileViewModel.properties", qos: .userInitiated)

  /// The ProfileOpen interval, open from the first load until the first post row appears or
  /// the screen shows that none will. Only the first load of a view model is measured.
  @ObservationIgnored private var openSignpost: OSSignpostID?
  @ObservationIgnored private var hasBegunOpenSignpost = false
  @ObservationIgnored private var hasMarkedOpenHeaderReady = false

  // Check if this is the current user's profile - comparing correctly
  var isCurrentUser: Bool {
    if let profile = profile {
      return profile.did.didString() == currentUserDID
    }
    if let currentUserDID = currentUserDID, !currentUserDID.isEmpty {
      return userDID == currentUserDID
    }
    return false
  }

  // MARK: - Initialization

  init(client: ATProtoClient?, userDID: String, currentUserDID: String?, stateInvalidationBus: StateInvalidationBus? = nil) {
    self.client = client
    self.userDID = userDID
    self.currentUserDID = currentUserDID
    self.stateInvalidationBus = stateInvalidationBus
    if userDID == ModerationPrefs.blueskyModerationDID {
      self.selectedProfileTab = .labelerInfo
    }
    
      logger.debug("ProfileViewModel[\(self.instanceId)]: Initializing for userDID: \(userDID)")
    
    // Subscribe to state invalidation events if bus is provided with safety check
    // Use a completely deferred subscription to avoid any metadata cache conflicts during init
    if let bus = stateInvalidationBus {
      Task { @MainActor [weak self] in
        // Wait longer to ensure object is fully initialized
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
        guard let self else { return }
        bus.subscribe(self)
        self.logger.debug("ProfileViewModel[\(self.instanceId)]: Deferred subscription completed")
      }
    }
  }
  
  isolated deinit {
    logger.debug("ProfileViewModel[\(self.instanceId)]: Deinitializing")
    endOpenSignpost(.left)
    
    // Cancel all active tasks to prevent crashes
    for task in activeLoadTasks {
      task.cancel()
    }
    activeLoadTasks.removeAll()
    
    // Unsubscribe from state invalidation events
    stateInvalidationBus?.unsubscribe(self)
  }

  // MARK: - Open Signpost

  /// Starts the ProfileOpen interval. Only the first load of this view model is measured.
  func beginOpenSignpost() {
    guard !hasBegunOpenSignpost else { return }
    hasBegunOpenSignpost = true
    openSignpost = PerformanceSignposts.beginProfileOpen()
  }

  /// Whether a ProfileOpen interval is still open.
  var isOpenSignpostActive: Bool { openSignpost != nil }

  /// Ends ProfileOpen when the first post row, or the pinned post, appears. Every row calls
  /// this as it appears; only the first call does anything.
  func markFirstPostVisible() {
    endOpenSignpost(.firstRow)
  }

  /// Called when the first load finishes. Ends ProfileOpen if the screen will show no post row;
  /// a tab with rows waits for its first row to appear (it may be below a long header).
  func endOpenSignpostIfNothingToShow() {
    guard openSignpost != nil else { return }
    let outcome = Self.openOutcomeWithoutRows(
      hasProfile: profile != nil, tab: selectedProfileTab, tabIsEmpty: selectedTabIsEmpty
    )
    if let outcome { endOpenSignpost(outcome) }
  }

  /// Ends ProfileOpen when the user leaves before any row appeared.
  func abandonOpenSignpost() {
    endOpenSignpost(.left)
  }

  /// How ProfileOpen ends when its first load finishes, or nil while a row is still to appear.
  nonisolated static func openOutcomeWithoutRows(
    hasProfile: Bool, tab: ProfileTab, tabIsEmpty: Bool
  ) -> ProfileOpenOutcome? {
    // The error screen replaces the tabs, even when the first page did load.
    guard hasProfile else { return .failed }
    switch tab {
    case .posts, .replies, .media:
      return tabIsEmpty ? .noRows : nil
    default:
      return .nonPostTab
    }
  }

  private var selectedTabIsEmpty: Bool {
    switch selectedProfileTab {
    case .posts: boxedPosts.isEmpty && pinnedPost == nil
    case .replies: boxedReplies.isEmpty
    case .media: boxedPostsWithMedia.isEmpty
    default: true
    }
  }

  private func endOpenSignpost(_ outcome: ProfileOpenOutcome) {
    guard let openSignpost else { return }
    self.openSignpost = nil
    PerformanceSignposts.endProfileOpen(id: openSignpost, outcome: outcome)
  }

  // MARK: - Rows

  /// `existing` followed by the rows of `page` whose id it does not already hold, in API order.
  /// An author feed can return a post again on a later page, and the same post twice in one page.
  /// A repost has its own id (Petrel `FeedViewPost.id`), so it stays next to its original. The
  /// pinned post is not part of `existing`: on another account's profile the AppView also returns
  /// it in time order, and that copy is kept.
  nonisolated static func appendingUnique(
    _ page: [EquatableBox<AppBskyFeedDefs.FeedViewPost>],
    to existing: [EquatableBox<AppBskyFeedDefs.FeedViewPost>]
  ) -> [EquatableBox<AppBskyFeedDefs.FeedViewPost>] {
    var seen = Set(existing.map { $0.value.id })
    var combined = existing
    combined.reserveCapacity(existing.count + page.count)
    for box in page where seen.insert(box.value.id).inserted {
      combined.append(box)
    }
    return combined
  }

  /// Whether an author-feed item belongs on the Replies tab: a reply, not a repost, whose
  /// parent is by someone else (or can't be shown). Without reposts every item is by the
  /// profile, so the item's own author stands in for the profile's DID. That holds even when
  /// the screen was opened by handle and the profile has not loaded yet.
  nonisolated static func isReplyToOthers(_ post: AppBskyFeedDefs.FeedViewPost) -> Bool {
    guard post.reason == nil, let reply = post.reply else { return false }
    switch reply.parent {
    case .appBskyFeedDefsPostView(let parentPost):
      return parentPost.author.did != post.post.author.did
    case .appBskyFeedDefsNotFoundPost, .appBskyFeedDefsBlockedPost, .unexpected:
      return true
    }
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
        // A cancelled load keeps the profile already shown, but must not leave the screen
        // loading: empty tabs would show a spinner until some later load finished.
        guard !Task.isCancelled else {
          self.isLoading = false
          logger.debug("ProfileViewModel[\(self.instanceId)]: Task cancelled during profile load")
          return
        }
        
        if responseCode == 200, let profile = profileData {
          self.profile = profile
          self.error = nil
          if !self.hasMarkedOpenHeaderReady, let openSignpost = self.openSignpost {
            self.hasMarkedOpenHeaderReady = true
            PerformanceSignposts.profileOpenHeaderReady(id: openSignpost)
          }
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

      // Donate after the header has its data, never ahead of it. Not awaited.
      if responseCode == 200, let profile = profileData {
        Task(priority: .utility) {
          await SpotlightEntityDonator.shared.donate(profiles: [profile])
        }
      }

      // Load labeler details if this is a labeler profile
      if isLabeler {
        await loadLabelerDetails()
      }
    } catch {
      await MainActor.run {
        guard !Task.isCancelled else {
          self.isLoading = false
          logger.debug("ProfileViewModel[\(self.instanceId)]: Task cancelled during error handling")
          return
        }
        
        self.error = error
        self.isLoading = false
        logger.error("ProfileViewModel[\(self.instanceId)]: Error loading profile: \(error.localizedDescription)")
      }
    }
  }

  /// Reloads the header once the AppView has had a moment to index a follow or unfollow, so
  /// the counts and `viewer.following` catch up. A newer write replaces a reload still waiting.
  func refreshHeaderAfterFollowWrite() {
    followWrites.scheduleRefresh { [weak self] in
      await self?.loadProfile()
    }
  }

  /// Loads the first page of the user's posts, replacing anything already loaded.
  func loadPosts() async {
    await loadFeed(type: .posts, resetCursor: true)
  }

  /// Appends the next page of posts, if there is one.
  func loadMorePosts() async {
    guard hasMorePosts, postsCursor != nil else { return }
    await loadFeed(type: .posts, resetCursor: false)
  }

  /// Loads the first page of the user's replies, replacing anything already loaded.
  func loadReplies() async {
    await loadFeed(type: .replies, resetCursor: true)
  }

  /// Appends the next page of replies, if there is one.
  func loadMoreReplies() async {
    guard hasMoreReplies, repliesCursor != nil else { return }
    await loadFeed(type: .replies, resetCursor: false)
  }

  /// Loads the first page of the user's media posts, replacing anything already loaded.
  func loadMediaPosts() async {
    await loadFeed(type: .media, resetCursor: true)
  }

  /// Appends the next page of media posts, if there is one.
  func loadMoreMediaPosts() async {
    guard hasMoreMedia, mediaPostsCursor != nil else { return }
    await loadFeed(type: .media, resetCursor: false)
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

  /// Loads known followers: people who follow this profile and whom the current user follows.
  /// The header shows only the first page, so a load replaces it. Without `reset`, a profile
  /// that already has them keeps them.
  func loadKnownFollowers(reset: Bool = false) async {
    let actor = profile?.did.didString() ?? userDID
    guard let client = client, !actor.isEmpty, actor != "fallback", actor != "unknown", actor != currentUserDID, !self.isCurrentUser, !isLoadingKnownFollowers else { return }

    if !reset && !_knownFollowers.isEmpty {
      return
    }

    // Cleared on every exit, cancellation included: a flag left set would refuse every later
    // load of this screen, pull to refresh too.
    _isLoadingKnownFollowers = true
    defer { _isLoadingKnownFollowers = false }

    do {
      let params = AppBskyGraphGetKnownFollowers.Parameters(
        actor: try ATIdentifier(string: actor),
        limit: 20
      )

      let (responseCode, output) = try await client.app.bsky.graph.getKnownFollowers(input: params)

      guard responseCode == 200, let followers = output?.followers else {
        logger.warning("Failed to load known followers: HTTP \(responseCode)")
        return
      }
      guard !Task.isCancelled else { return }
      _knownFollowers = followers
    } catch {
      logger.error("Error loading known followers: \(error.localizedDescription)")
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
    let actor = profile?.did.didString() ?? userDID
    guard let client = client, !actor.isEmpty, actor != "fallback", actor != "unknown", !isLoadingMorePosts else { return }

    _isLoadingMorePosts = true

    // ProfilePage measures one "load more" request until its rows are applied, and only a
    // request that really starts (past the shared in-flight guard above).
    let pageSignpost = resetCursor ? nil : PerformanceSignposts.beginProfilePage()
    let rowsBefore = rowCount(for: type)
    var pageApplied = false
    defer {
      if let pageSignpost {
        PerformanceSignposts.endProfilePage(
          id: pageSignpost, tab: type.rawValue, added: rowCount(for: type) - rowsBefore,
          success: pageApplied
        )
      }
    }

    do {
      let actorIdentifier = try ATIdentifier(string: actor)
      switch type {
      case .posts:
        let params = AppBskyFeedGetAuthorFeed.Parameters(
          actor: actorIdentifier,
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
          
          let boxedPage = regularPosts.map { EquatableBox($0) }
          let boxedPinned = pinned.map { EquatableBox($0) }
          await MainActor.run {
            if resetCursor {
              self.pinnedPost = boxedPinned
              self.boxedPosts = Self.appendingUnique(boxedPage, to: [])
            } else {
              // When paginating, don't update pinned post
              self.boxedPosts = Self.appendingUnique(boxedPage, to: self.boxedPosts)
            }
            self.postsCursor = output?.cursor
            self.hasMorePosts = output?.cursor != nil
          }
          pageApplied = true
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
            actor: actorIdentifier,
            limit: 30,
            cursor: cursor,
            filter: "posts_with_replies"
          )

          let (responseCode, output) = try await client.app.bsky.feed.getAuthorFeed(input: params)
          requestCount += 1

          guard responseCode == 200, let feed = output?.feed else { break }
          didReceivePage = true
          cursor = output?.cursor

          repliesToOthers.append(contentsOf: feed.filter(Self.isReplyToOthers))
        } while repliesToOthers.count < 10 && cursor != nil && requestCount < 5

        if didReceivePage {
          let nextCursor = cursor
          let boxedPage = repliesToOthers.map { EquatableBox($0) }
          await MainActor.run {
            if resetCursor {
              self.boxedReplies = Self.appendingUnique(boxedPage, to: [])
            } else {
              self.boxedReplies = Self.appendingUnique(boxedPage, to: self.boxedReplies)
            }
            self.repliesCursor = nextCursor
            self.hasMoreReplies = nextCursor != nil
          }
          pageApplied = true
        }
      case .media:
        let params = AppBskyFeedGetAuthorFeed.Parameters(
          actor: actorIdentifier,
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

          let boxedPage = postsWithMedia.map { EquatableBox($0) }
          await MainActor.run {
            if resetCursor {
              self.boxedPostsWithMedia = Self.appendingUnique(boxedPage, to: [])
            } else {
              self.boxedPostsWithMedia = Self.appendingUnique(boxedPage, to: self.boxedPostsWithMedia)
            }
            self.mediaPostsCursor = output?.cursor
            self.hasMoreMedia = output?.cursor != nil
          }
          pageApplied = true
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

  /// The raw value names the tab in ProfilePage signposts.
  private enum FeedType: String {
    case posts, replies, media
  }

  private func rowCount(for type: FeedType) -> Int {
    switch type {
    case .posts: boxedPosts.count
    case .replies: boxedReplies.count
    case .media: boxedPostsWithMedia.count
    }
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
  
  nonisolated private static func nilIfBlank(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  // MARK: - StateInvalidationSubscriber
  
  /// Check if this subscriber is interested in a specific event
  nonisolated func isInterestedIn(_ event: StateInvalidationEvent) -> Bool {
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
      boxedPosts = []
      boxedReplies = []
      boxedPostsWithMedia = []
      pinnedPost = nil
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
  
  nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(instanceId)
    hasher.combine(userDID)
  }
  
  nonisolated static func == (lhs: ProfileViewModel, rhs: ProfileViewModel) -> Bool {
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
