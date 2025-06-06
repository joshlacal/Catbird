import Foundation
import OSLog
import Petrel
import SwiftUI

enum GraphError: Error, LocalizedError {
  case clientNotInitialized
  case invalidResponse
  case networkError(Error)
  case unknown(Error)

  var errorDescription: String? {
    switch self {
    case .clientNotInitialized:
      return "ATProto client not initialized"
    case .invalidResponse:
      return "Invalid response from server"
    case .networkError(let error):
      return "Network error: \(error.localizedDescription)"
    case .unknown(let error):
      return "Unknown error: \(error.localizedDescription)"
    }
  }
}

/// Manages social graph interactions like following, muting, and blocking users
@Observable
final class GraphManager {
  private let logger = Logger(subsystem: "blue.catbird", category: "GraphManager")
  private var atProtoClient: ATProtoClient?

  // Cache of operations in progress to prevent duplicate requests
  private var inProgressFollowOperations: Set<String> = []
  private var inProgressBlockOperations: Set<String> = []
  private var inProgressMuteOperations: Set<String> = []

  // Cache of user relationships
  @MainActor private(set) var followingCache: [String: ATProtocolURI] = [:]
  @MainActor private(set) var muteCache: Set<String> = []
  @MainActor private(set) var blockCache: Set<String> = []

  // Last update timestamps for caches
  @MainActor private var lastFollowingUpdate: Date?
  @MainActor private var lastMutesUpdate: Date?
  @MainActor private var lastBlocksUpdate: Date?

  // Cache expiration time (30 minutes)
  private let cacheExpirationTime: TimeInterval = 1800
  
  // Cache invalidation strategies
  enum CacheInvalidationReason {
    case userInitiated      // User manually refreshed
    case dataStale         // Data is older than expiration time
    case errorOccurred     // Network or API error
    case relationshipChanged // Follow/block/mute state changed
    case accountSwitched   // Different account logged in
  }

  init(atProtoClient: ATProtoClient?) {
    self.atProtoClient = atProtoClient
  }

  // MARK: - Cache Invalidation
  
  /// Comprehensive cache invalidation with reason tracking
  @MainActor
  func invalidateCache(for reason: CacheInvalidationReason, cacheTypes: CacheType...) {
    logger.info("Invalidating cache for reason: \(String(describing: reason))")
    
    let typesToInvalidate = cacheTypes.isEmpty ? CacheType.allCases : cacheTypes
    
    for cacheType in typesToInvalidate {
      switch cacheType {
      case .following:
        followingCache.removeAll()
        lastFollowingUpdate = nil
        
      case .mutes:
        muteCache.removeAll()
        lastMutesUpdate = nil
        
      case .blocks:
        blockCache.removeAll()
        lastBlocksUpdate = nil
        
      case .all:
        followingCache.removeAll()
        muteCache.removeAll()
        blockCache.removeAll()
        lastFollowingUpdate = nil
        lastMutesUpdate = nil
        lastBlocksUpdate = nil
      }
    }
    
    // Log cache state for debugging
    logger.debug("Cache invalidated. Remaining items - Following: \(self.followingCache.count), Mutes: \(self.muteCache.count), Blocks: \(self.blockCache.count)")
  }
  
  /// Smart cache invalidation that considers staleness and errors
  @MainActor
  private func shouldInvalidateCache(for cacheType: CacheType) -> Bool {
    let lastUpdate: Date?
    
    switch cacheType {
    case .following:
      lastUpdate = lastFollowingUpdate
    case .mutes:
      lastUpdate = lastMutesUpdate
    case .blocks:
      lastUpdate = lastBlocksUpdate
    case .all:
      return true // Always invalidate when requesting all
    }
    
    guard let lastUpdate = lastUpdate else {
      return true // No data cached, need to fetch
    }
    
    let timeSinceUpdate = Date().timeIntervalSince(lastUpdate)
    return timeSinceUpdate > cacheExpirationTime
  }
  
  /// Enum for specifying which caches to invalidate
  enum CacheType: CaseIterable {
    case following
    case mutes
    case blocks
    case all
  }
  
  /// Force refresh all caches (user-initiated)
  func refreshAllCaches() async throws {
    await MainActor.run {
      invalidateCache(for: .userInitiated, cacheTypes: .all)
    }
    
    // Fetch fresh data
    async let following = refreshFollowingCache()
    async let mutes = refreshMuteCache()
    async let blocks = refreshBlockCache()
    
    // Wait for all to complete
    _ = try await (following, mutes, blocks)
  }

  /// Updates the ATProtoClient reference
  func updateClient(_ client: ATProtoClient?) {
    self.atProtoClient = client

    // Clear caches when client changes
    Task { @MainActor in
      followingCache.removeAll()
      muteCache.removeAll()
      blockCache.removeAll()
      lastFollowingUpdate = nil
      lastMutesUpdate = nil
      lastBlocksUpdate = nil
    }
  }

  // MARK: - Following Methods

  /// Follows a user by their DID
  /// - Parameter did: The decentralized identifier of the user to follow
  /// - Returns: A boolean indicating success or failure
  @discardableResult
  func follow(did: String) async throws -> Bool {
    // Avoid duplicate follow operations for the same DID
    guard !inProgressFollowOperations.contains(did) else {
      logger.debug("Follow operation already in progress for \(did)")
      return false
    }

    // Ensure client exists
    guard let client = atProtoClient else {
      logger.error("ATProtoClient is nil, cannot follow user")
      throw GraphError.clientNotInitialized
    }

    inProgressFollowOperations.insert(did)
    defer { inProgressFollowOperations.remove(did) }

    logger.debug("Following user: \(did)")

    do {
      // Create the follow record
      let userDID = try await client.getDid()

      // Convert string to DID type
      let subjectDID = try DID(didString: did)

      let follow = AppBskyGraphFollow(
        subject: subjectDID,
        createdAt: ATProtocolDate(date: Date())
      )

      // Wrap the follow in a value container
      let record = ATProtocolValueContainer.knownType(follow)

      // Create the record
      let input = ComAtprotoRepoCreateRecord.Input(
        repo: try ATIdentifier(string: userDID),
        collection: try NSID(nsidString: "app.bsky.graph.follow"),
        record: record
      )

      let (responseCode, response) = try await client.com.atproto.repo.createRecord(input: input)

      guard responseCode >= 200 && responseCode < 300, let response = response else {
        logger.error("Failed to follow user: \(did) with response code \(responseCode)")
        return false
      }

      // Update cache with new relationship
      await updateFollowingCache(did: did, uri: response.uri)
      
      // Invalidate related caches since relationships changed
      await MainActor.run {
        invalidateCache(for: .relationshipChanged, cacheTypes: .following)
      }

      logger.debug("Successfully followed user: \(did)")
      return true
    } catch {
      logger.error("Error following user: \(error.localizedDescription)")
      // Invalidate cache on error to ensure fresh data on next attempt
      await MainActor.run {
        invalidateCache(for: .errorOccurred, cacheTypes: .following)
      }
      throw error
    }
  }

  /// Unfollows a user by their viewer.following record URI
  /// - Parameter followingUri: The URI of the follow record to delete
  /// - Returns: A boolean indicating success or failure
  @discardableResult
  func unfollowByUri(followingUri: ATProtocolURI) async throws -> Bool {
    // Ensure client exists
    guard let client = atProtoClient else {
      logger.error("ATProtoClient is nil, cannot unfollow user")
      throw GraphError.clientNotInitialized
    }

    // Parse the URI to get required components
    // URI format: at://did:plc:abc123/app.bsky.graph.follow/rkey

    let repoString = followingUri.authority
    guard let rkey = followingUri.recordKey else {
      throw GraphManagerError.invalidFollowUri
    }

    do {
      let input = ComAtprotoRepoDeleteRecord.Input(
        repo: try ATIdentifier(string: repoString),
        collection: try NSID(nsidString: "app.bsky.graph.follow"),
        rkey: try RecordKey(keyString: rkey)
      )

      let (responseCode, _) = try await client.com.atproto.repo.deleteRecord(input: input)

      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Failed to unfollow user with response code \(responseCode)")
        return false
      }

      // Remove from cache
      await removeFromFollowingCache(uri: followingUri)
      
      // Invalidate related caches since relationships changed
      await MainActor.run {
        invalidateCache(for: .relationshipChanged, cacheTypes: .following)
      }

      logger.debug("Successfully unfollowed user using URI")
      return true
    } catch {
      logger.error("Error unfollowing user: \(error.localizedDescription)")
      // Invalidate cache on error to ensure fresh data on next attempt
      await MainActor.run {
        invalidateCache(for: .errorOccurred, cacheTypes: .following)
      }
      throw error
    }
  }

  /// Unfollows a user by their DID - requires looking up the follow record first
  /// - Parameter did: The decentralized identifier of the user to unfollow
  /// - Returns: A boolean indicating success or failure
  @discardableResult
  func unfollow(did: String) async throws -> Bool {
    // Avoid duplicate unfollow operations for the same DID
    guard !inProgressFollowOperations.contains(did) else {
      logger.debug("Unfollow operation already in progress for \(did)")
      return false
    }

    // Ensure client exists
    guard let client = atProtoClient else {
      logger.error("ATProtoClient is nil, cannot unfollow user")
      throw GraphError.clientNotInitialized
    }

    inProgressFollowOperations.insert(did)
    defer { inProgressFollowOperations.remove(did) }

    logger.debug("Unfollowing user: \(did)")

    // Check cache first
    if let followingUri = await followingCache[did] {
      return try await unfollowByUri(followingUri: followingUri)
    }

    do {
      // First, get the user's profile to get the follow record URI
        let params = AppBskyActorGetProfile.Parameters(actor: try ATIdentifier(string: did))
      let (profileCode, profile) = try await client.app.bsky.actor.getProfile(input: params)

      guard profileCode == 200,
        let profile = profile,
        let viewer = profile.viewer,
        let followingUri = viewer.following
      else {
        logger.error("Failed to get profile or follow record for \(did)")
        return false
      }

      // Now unfollow using the record URI
      return try await unfollowByUri(followingUri: followingUri)
    } catch {
      logger.error("Error unfollowing user: \(error.localizedDescription)")
      throw error
    }
  }

  /// Checks if the current user is following a specific user
  /// - Parameter did: The DID of the user to check
  /// - Returns: True if following, false otherwise
  func isFollowing(did: String) async -> Bool {
    guard !did.isEmpty else { return false }

    // Check cache first if it's not expired
    if await isCacheValid(lastUpdate: lastFollowingUpdate) {
      return await followingCache.keys.contains(did)
    }

    // Ensure client exists
    guard let client = atProtoClient else {
      logger.error("ATProtoClient is nil, cannot check following status")
      return false
    }

    do {
      // We can check a single profile to see if we're following them
      let params = AppBskyActorGetProfile.Parameters(actor: try ATIdentifier(string: did))
      let (_, response) = try await client.app.bsky.actor.getProfile(input: params)

      // Update cache for this user if we're following them
      if let following = response?.viewer?.following {
        await updateFollowingCache(did: did, uri: following)
        return true
      }

      return false
    } catch {
      logger.error("Error checking follow status: \(error.localizedDescription)")
      return false
    }
  }

  /// Gets a count of followers for a specific user
  /// - Parameter did: The DID of the user
  /// - Returns: The number of followers or nil if unable to retrieve
  func getFollowersCount(did: String) async -> Int? {
    guard !did.isEmpty else { return nil }

    // Ensure client exists
    guard let client = atProtoClient else {
      logger.error("ATProtoClient is nil, cannot get followers count")
      return nil
    }

    do {
      // Get the profile details which includes follower count
      let params = AppBskyActorGetProfile.Parameters(actor: try ATIdentifier(string: did))
      let (_, response) = try await client.app.bsky.actor.getProfile(input: params)

      // The detailed profile has the follower count
      return response?.followersCount
    } catch {
      logger.error("Error getting followers count: \(error.localizedDescription)")
      return nil
    }
  }

  // MARK: - Block Methods

  /// Blocks a user by their DID
  /// - Parameter did: The decentralized identifier of the user to block
  /// - Returns: A boolean indicating success or failure
  @discardableResult
  func block(did: String) async throws -> Bool {
    // Avoid duplicate block operations for the same DID
    guard !inProgressBlockOperations.contains(did) else {
      logger.debug("Block operation already in progress for \(did)")
      return false
    }

    // Ensure client exists
    guard let client = atProtoClient else {
      logger.error("ATProtoClient is nil, cannot block user")
      throw GraphError.clientNotInitialized
    }

    inProgressBlockOperations.insert(did)
    defer { inProgressBlockOperations.remove(did) }

    logger.debug("Blocking user: \(did)")

    do {
      // Create the block record
      let userDID = try await client.getDid()
      let block = AppBskyGraphBlock(
        subject: try DID(didString: did),
        createdAt: ATProtocolDate(date: Date())
      )

      // Wrap the block in a value container
      let record = ATProtocolValueContainer.knownType(block)

      // Create the record
      let input = ComAtprotoRepoCreateRecord.Input(
        repo: try ATIdentifier(string: userDID),
        collection: try NSID(nsidString: "app.bsky.graph.block"),
        record: record
      )

      let (responseCode, _) = try await client.com.atproto.repo.createRecord(input: input)

      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Failed to block user: \(did) with response code \(responseCode)")
        return false
      }

      // Update the block cache
      await addToBlockCache(did: did)
      
      // Notify that graph has changed
      NotificationCenter.default.post(name: NSNotification.Name("UserGraphChanged"), object: nil)

      logger.debug("Successfully blocked user: \(did)")
      return true
    } catch {
      logger.error("Error blocking user: \(error.localizedDescription)")
      throw error
    }
  }

  /// Unblocks a user by their block record URI
  /// - Parameter blockUri: The URI of the block record to delete
  /// - Returns: A boolean indicating success or failure
  @discardableResult
  private func unblockByUri(blockUri: ATProtocolURI) async throws -> Bool {
    // Ensure client exists
    guard let client = atProtoClient else {
      logger.error("ATProtoClient is nil, cannot unblock user")
      throw GraphError.clientNotInitialized
    }

    // Parse the URI to get required components
    // URI format: at://did:plc:abc123/app.bsky.graph.block/rkey
    let repoString = blockUri.authority
    guard let rkey = blockUri.recordKey else {
      throw GraphManagerError.invalidBlockUri
    }

    do {
      let input = ComAtprotoRepoDeleteRecord.Input(
        repo: try ATIdentifier(string: repoString),
        collection: try NSID(nsidString: "app.bsky.graph.block"),
        rkey: try RecordKey(keyString: rkey)
      )

      let (responseCode, _) = try await client.com.atproto.repo.deleteRecord(input: input)

      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Failed to unblock user with response code \(responseCode)")
        return false
      }

      logger.debug("Successfully unblocked user using URI")
      return true
    } catch {
      logger.error("Error unblocking user: \(error.localizedDescription)")
      throw error
    }
  }

  /// Unblocks a user by their DID - requires finding the block record first
  /// - Parameter did: The decentralized identifier of the user to unblock
  /// - Returns: A boolean indicating success or failure
  @discardableResult
  func unblock(did: String) async throws -> Bool {
    // Avoid duplicate unblock operations for the same DID
    guard !inProgressBlockOperations.contains(did) else {
      logger.debug("Unblock operation already in progress for \(did)")
      return false
    }

    // Ensure client exists
    guard let client = atProtoClient else {
      logger.error("ATProtoClient is nil, cannot unblock user")
      throw GraphError.clientNotInitialized
    }

    inProgressBlockOperations.insert(did)
    defer { inProgressBlockOperations.remove(did) }

    logger.debug("Unblocking user: \(did)")

    do {
      // Get the profile to get the block URI
      let params = AppBskyActorGetProfile.Parameters(actor: try ATIdentifier(string: did))
      let (profileCode, profile) = try await client.app.bsky.actor.getProfile(input: params)

      guard profileCode == 200,
        let profile = profile,
        let viewer = profile.viewer,
        let blockUri = viewer.blocking
      else {
        logger.error("Failed to get profile or block record for \(did)")
        return false
      }

      let success = try await unblockByUri(blockUri: blockUri)

      if success {
        // Remove from block cache
        await removeFromBlockCache(did: did)
        
        // Notify that graph has changed
        NotificationCenter.default.post(name: NSNotification.Name("UserGraphChanged"), object: nil)
      }

      return success
    } catch {
      logger.error("Error unblocking user: \(error.localizedDescription)")
      throw error
    }
  }

  /// Checks if the current user has blocked a specific user
  /// - Parameter did: The DID of the user to check
  /// - Returns: True if blocked, false otherwise
  func isBlocking(did: String) async -> Bool {
    guard !did.isEmpty else { return false }

    // Check cache first if it's not expired
    if await isCacheValid(lastUpdate: lastBlocksUpdate) {
      return await blockCache.contains(did)
    }

    // Ensure client exists
    guard let client = atProtoClient else {
      logger.error("ATProtoClient is nil, cannot check block status")
      return false
    }

    do {
      // Check the profile to see if we're blocking them
      let params = AppBskyActorGetProfile.Parameters(actor: try ATIdentifier(string: did))
      let (_, response) = try await client.app.bsky.actor.getProfile(input: params)

      // Update cache for this user if we're blocking them
      let isBlocked = response?.viewer?.blocking != nil
      if isBlocked {
        await addToBlockCache(did: did)
      }

      return isBlocked
    } catch {
      logger.error("Error checking block status: \(error.localizedDescription)")
      return false
    }
  }

  /// Refreshes the cached list of blocked users
  /// - Returns: The list of blocked profile DIDs
  @discardableResult
  func refreshBlockCache() async throws -> Set<String> {  // Added throws
    // Ensure client exists
    guard let client = atProtoClient else {
      logger.error("ATProtoClient is nil, cannot get blocks")
      throw GraphError.clientNotInitialized
    }

    var collectedBlocks = Set<String>()  // Local set for accumulation
    var cursor: String?

    do {  // Wrap network calls in do-catch
      repeat {
        let params = AppBskyGraphGetBlocks.Parameters(limit: 100, cursor: cursor)
        // Network call inside the loop
        let (responseCode, response) = try await client.app.bsky.graph.getBlocks(input: params)

        guard responseCode == 200, let response = response else {
          logger.error("Failed to get blocks with response code \(responseCode)")
          throw GraphManagerError.failedToFetchBlocks
        }

        // Modify local variable *after* await
        for profile in response.blocks {
            collectedBlocks.insert(profile.did.didString())
        }

        cursor = response.cursor
      } while cursor != nil
        
        let collectedBlocks = collectedBlocks
      // Update MainActor property once at the end
      await MainActor.run {
        blockCache = collectedBlocks
        lastBlocksUpdate = Date()
      }
      return collectedBlocks  // Return the result
    } catch {
      logger.error("Error fetching blocks: \(error.localizedDescription)")
      // Use comprehensive cache invalidation strategy for errors
      await MainActor.run {
        invalidateCache(for: .errorOccurred, cacheTypes: .blocks)
      }
      throw error  // Re-throw the error
    }
  }

  // MARK: - Mute Methods

  /// Mutes a user by their DID
  /// - Parameter did: The decentralized identifier of the user to mute
  /// - Returns: A boolean indicating success or failure
  @discardableResult
  func mute(did: String) async throws -> Bool {
    // Avoid duplicate mute operations for the same DID
    guard !inProgressMuteOperations.contains(did) else {
      logger.debug("Mute operation already in progress for \(did)")
      return false
    }

    // Ensure client exists
    guard let client = atProtoClient else {
      logger.error("ATProtoClient is nil, cannot mute user")
      throw GraphError.clientNotInitialized
    }

    inProgressMuteOperations.insert(did)
    defer { inProgressMuteOperations.remove(did) }

    logger.debug("Muting user: \(did)")

    do {
      let input = AppBskyGraphMuteActor.Input(actor: try ATIdentifier(string: did))

      let responseCode = try await client.app.bsky.graph.muteActor(input: input)

      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Failed to mute user: \(did) with response code \(responseCode)")
        return false
      }

      // Update mute cache
      await addToMuteCache(did: did)
      
      // Notify that graph has changed
      NotificationCenter.default.post(name: NSNotification.Name("UserGraphChanged"), object: nil)

      logger.debug("Successfully muted user: \(did)")
      return true
    } catch {
      logger.error("Error muting user: \(error.localizedDescription)")
      throw error
    }
  }

  /// Unmutes a user by their DID
  /// - Parameter did: The decentralized identifier of the user to unmute
  /// - Returns: A boolean indicating success or failure
  @discardableResult
  func unmute(did: String) async throws -> Bool {
    // Avoid duplicate unmute operations for the same DID
    guard !inProgressMuteOperations.contains(did) else {
      logger.debug("Unmute operation already in progress for \(did)")
      return false
    }

    // Ensure client exists
    guard let client = atProtoClient else {
      logger.error("ATProtoClient is nil, cannot unmute user")
      throw GraphError.clientNotInitialized
    }

    inProgressMuteOperations.insert(did)
    defer { inProgressMuteOperations.remove(did) }

    logger.debug("Unmuting user: \(did)")

    do {
      let input = AppBskyGraphUnmuteActor.Input(actor: try ATIdentifier(string: did))

      let responseCode = try await client.app.bsky.graph.unmuteActor(input: input)

      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Failed to unmute user: \(did) with response code \(responseCode)")
        return false
      }

      // Update mute cache
      await removeFromMuteCache(did: did)
      
      // Notify that graph has changed
      NotificationCenter.default.post(name: NSNotification.Name("UserGraphChanged"), object: nil)

      logger.debug("Successfully unmuted user: \(did)")
      return true
    } catch {
      logger.error("Error unmuting user: \(error.localizedDescription)")
      throw error
    }
  }

  /// Checks if the current user has muted a specific user
  /// - Parameter did: The DID of the user to check
  /// - Returns: True if muted, false otherwise
  func isMuting(did: String) async -> Bool {
    guard !did.isEmpty else { return false }

    // Check cache first if it's not expired
    if await isCacheValid(lastUpdate: lastMutesUpdate) {
      return await muteCache.contains(did)
    }

    // Ensure client exists
    guard let client = atProtoClient else {
      logger.error("ATProtoClient is nil, cannot check mute status")
      return false
    }

    // Try to refresh the cache first
    do {
      try await refreshMuteCache()  // Added try
      return await muteCache.contains(did)
    } catch {
      logger.error("Error refreshing mute cache: \(error.localizedDescription)")

      // Fall back to checking the profile
      do {
        let params = AppBskyActorGetProfile.Parameters(actor: try ATIdentifier(string: did))
        let (_, response) = try await client.app.bsky.actor.getProfile(input: params)

        let isMuted = response?.viewer?.muted ?? false
        if isMuted {
          await addToMuteCache(did: did)
        }

        return isMuted
      } catch {
        logger.error("Error checking mute status: \(error.localizedDescription)")
        return false
      }
    }
  }

  /// Refreshes the cached list of muted users
  /// - Returns: The list of muted profile DIDs
  @discardableResult
  func refreshMuteCache() async throws -> Set<String> {  // Added throws
    // Ensure client exists
    guard let client = atProtoClient else {
      logger.error("ATProtoClient is nil, cannot get mutes")
      throw GraphError.clientNotInitialized  // Throw error if client is nil
    }

    var collectedMutes = Set<String>()  // Local set for accumulation
    var cursor: String?

    do {  // Wrap network calls in do-catch
      repeat {
        let params = AppBskyGraphGetMutes.Parameters(limit: 100, cursor: cursor)
        // Network call inside the loop
        let (responseCode, response) = try await client.app.bsky.graph.getMutes(input: params)

        guard responseCode == 200, let response = response else {
          logger.error("Failed to get mutes with response code \(responseCode)")
          throw GraphManagerError.failedToFetchMutes
        }

        // Modify local variable *after* await
        for profile in response.mutes {
            collectedMutes.insert(profile.did.didString())
        }

        cursor = response.cursor
      } while cursor != nil

        let collectedMutes = collectedMutes
      // Update MainActor property once at the end
      await MainActor.run {
        muteCache = collectedMutes
        lastMutesUpdate = Date()
      }
      return collectedMutes  // Return the result
    } catch {
      logger.error("Error fetching mutes: \(error.localizedDescription)")
      // Use comprehensive cache invalidation strategy for errors
      await MainActor.run {
        invalidateCache(for: .errorOccurred, cacheTypes: .mutes)
      }
      throw error  // Re-throw the error
    }
  }

  // MARK: - Thread Muting

  /// Mutes a thread to prevent notifications
  /// - Parameter threadRootUri: The URI of the thread's root post
  /// - Returns: A boolean indicating success or failure
  @discardableResult
  func muteThread(threadRootUri: ATProtocolURI) async throws -> Bool {
    // Ensure client exists
    guard let client = atProtoClient else {
      logger.error("ATProtoClient is nil, cannot mute thread")
      throw GraphError.clientNotInitialized
    }

    logger.debug("Muting thread: \(threadRootUri)")

    do {
      let input = AppBskyGraphMuteThread.Input(root: threadRootUri)

      let responseCode = try await client.app.bsky.graph.muteThread(input: input)

      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Failed to mute thread with response code \(responseCode)")
        return false
      }

      logger.debug("Successfully muted thread")
      return true
    } catch {
      logger.error("Error muting thread: \(error.localizedDescription)")
      throw error
    }
  }

  /// Unmutes a thread to re-enable notifications
  /// - Parameter threadRootUri: The URI of the thread's root post
  /// - Returns: A boolean indicating success or failure
  @discardableResult
  func unmuteThread(threadRootUri: ATProtocolURI) async throws -> Bool {
    // Ensure client exists
    guard let client = atProtoClient else {
      logger.error("ATProtoClient is nil, cannot unmute thread")
      throw GraphError.clientNotInitialized
    }

    logger.debug("Unmuting thread: \(threadRootUri)")

    do {
      let input = AppBskyGraphUnmuteThread.Input(root: threadRootUri)

      let responseCode = try await client.app.bsky.graph.unmuteThread(input: input)

      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Failed to unmute thread with response code \(responseCode)")
        return false
      }

      logger.debug("Successfully unmuted thread")
      return true
    } catch {
      logger.error("Error unmuting thread: \(error.localizedDescription)")
      throw error
    }
  }

  // MARK: - Following Cache Management

  /// Refreshes the list of users the current user is following
  /// - Returns: A dictionary mapping DIDs to their follow record URIs
  @discardableResult
  func refreshFollowingCache() async throws -> [String: ATProtocolURI] {
    // Ensure client exists
    guard let client = atProtoClient else {
      logger.error("ATProtoClient is nil, cannot get following")
      throw GraphError.clientNotInitialized
    }

    var allFollowing: [String: ATProtocolURI] = [:]
    var cursor: String?

    do {
      let userDID = try await client.getDid()
      repeat {
        let params = AppBskyGraphGetFollows.Parameters(actor: try ATIdentifier(string: userDID), limit: 100, cursor: cursor)
        let (responseCode, response) = try await client.app.bsky.graph.getFollows(input: params)

        guard responseCode == 200, let response = response else {
          logger.error("Failed to get following with response code \(responseCode)")
          throw GraphManagerError.failedToFetchFollowing
        }

        // Extract DIDs and URIs from the response
        for profile in response.follows {
          //                    if let did = profile.did, let viewerState = profile.viewer, let following = viewerState.following {
            allFollowing[profile.did.didString()] = profile.viewer?.following
          //                    }
        }

        cursor = response.cursor
      } while cursor != nil

      let following = allFollowing
      // Update the cache
      await MainActor.run {
        followingCache = following
        lastFollowingUpdate = Date()
      }

      return allFollowing
    } catch {
      logger.error("Error refreshing following: \(error.localizedDescription)")
      throw error
    }
  }

  // MARK: - Cache Utility Methods

  /// Checks if a cache is still valid based on its last update time
  /// - Parameter lastUpdate: The timestamp of the last cache update
  /// - Returns: True if the cache is still valid, false if it needs refresh
  @MainActor
  private func isCacheValid(lastUpdate: Date?) -> Bool {
    guard let lastUpdate = lastUpdate else {
      return false
    }

    return Date().timeIntervalSince(lastUpdate) < cacheExpirationTime
  }

  /// Updates the following cache with a new entry
  /// - Parameters:
  ///   - did: The DID of the user
  ///   - uri: The URI of the follow record
  @MainActor
  private func updateFollowingCache(did: String, uri: ATProtocolURI) {
    followingCache[did] = uri
    if lastFollowingUpdate == nil {
      lastFollowingUpdate = Date()
    }
  }

  /// Removes an entry from the following cache by URI
  /// - Parameter uri: The URI of the follow record to remove
  @MainActor
  private func removeFromFollowingCache(uri: ATProtocolURI) {
    // Find the DID with this URI
    if let did = followingCache.first(where: { $0.value == uri })?.key {
      followingCache.removeValue(forKey: did)
    }
  }

  /// Adds a DID to the block cache
  /// - Parameter did: The DID to add to the block cache
  @MainActor
  private func addToBlockCache(did: String) {
    blockCache.insert(did)
    if lastBlocksUpdate == nil {
      lastBlocksUpdate = Date()
    }
  }

  /// Removes a DID from the block cache
  /// - Parameter did: The DID to remove from the block cache
  @MainActor
  private func removeFromBlockCache(did: String) {
    blockCache.remove(did)
  }

  /// Adds a DID to the mute cache
  /// - Parameter did: The DID to add to the mute cache
  @MainActor
  private func addToMuteCache(did: String) {
    muteCache.insert(did)
    if lastMutesUpdate == nil {
      lastMutesUpdate = Date()
    }
  }

  /// Removes a DID from the mute cache
  /// - Parameter did: The DID to remove from the mute cache
  @MainActor
  private func removeFromMuteCache(did: String) {
    muteCache.remove(did)
  }

  /// Invalidates the following cache
  @MainActor
  private func invalidateFollowingCache() {
    lastFollowingUpdate = nil
  }

  /// Invalidates the block cache
  @MainActor
  private func invalidateBlockCache() {
    lastBlocksUpdate = nil
  }

  /// Invalidates the mute cache
  @MainActor
  private func invalidateMuteCache() {
    lastMutesUpdate = nil
  }

  enum GraphManagerError: Error {
    case invalidFollowUri
    case invalidBlockUri
    case failedToFetchBlocks
    case failedToFetchMutes
    case failedToFetchFollowing
    case noDID
  }
}

// Extension for AppState to access GraphManager
// Extension for AppState to access GraphManager
// Removed performFollow and performUnfollow as they are defined in AppState directly
extension AppState {
  // performFollow and performUnfollow removed - already exist in AppState

  /// Checks if the current user is following a user
  func isFollowing(did: String) async -> Bool {
    await graphManager.isFollowing(did: did)
  }

  /// Gets the followers count for a user
  func getFollowersCount(did: String) async -> Int? {
    await graphManager.getFollowersCount(did: did)
  }

  /// Blocks a user by their DID
  @discardableResult
  func block(did: String) async throws -> Bool {
    try await graphManager.block(did: did)
  }

  /// Unblocks a user by their DID
  @discardableResult
  func unblock(did: String) async throws -> Bool {
    try await graphManager.unblock(did: did)
  }

  /// Checks if the current user is blocking a user
  func isBlocking(did: String) async -> Bool {
    await graphManager.isBlocking(did: did)
  }

  /// Mutes a user by their DID
  @discardableResult
  func mute(did: String) async throws -> Bool {
    try await graphManager.mute(did: did)
  }

  /// Unmutes a user by their DID
  @discardableResult
  func unmute(did: String) async throws -> Bool {
    try await graphManager.unmute(did: did)
  }

  /// Checks if the current user is muting a user
  func isMuting(did: String) async -> Bool {
    await graphManager.isMuting(did: did)
  }

  /// Mutes a thread to prevent notifications
  @discardableResult
  func muteThread(threadRootUri: ATProtocolURI) async throws -> Bool {
    try await graphManager.muteThread(threadRootUri: threadRootUri)
  }

  /// Unmutes a thread to re-enable notifications
  @discardableResult
  func unmuteThread(threadRootUri: ATProtocolURI) async throws -> Bool {
    try await graphManager.unmuteThread(threadRootUri: threadRootUri)
  }

  /// Refreshes cached social graph information
  func refreshSocialGraph() async {
    Task {
      try? await graphManager.refreshFollowingCache()
    }

    Task {
      try? await graphManager.refreshBlockCache()
    }

    Task {
      _ = try? await graphManager.refreshMuteCache()  // Added try?
    }
  }
}
