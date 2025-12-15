import Foundation
import Petrel
import OSLog

#if os(iOS)

/// Service for enriching MLS conversation participants with Bluesky profile data
actor MLSProfileEnricher {
  private let logger = Logger(subsystem: "blue.catbird", category: "MLSProfileEnricher")

  // Cache DID → Profile data (keyed by canonical DID without any device fragment)
  private var profileCache: [String: ProfileData] = [:]

  nonisolated static func canonicalDID(_ did: String) -> String {
    let trimmed = did.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
  }

  // MARK: - Profile Data

  struct ProfileData: Sendable {
    let did: String
    let handle: String
    let displayName: String?
    let avatarURL: URL?

    init(from profile: AppBskyActorDefs.ProfileViewDetailed) {
      self.did = profile.did.didString()
      self.handle = profile.handle.description
      self.displayName = profile.displayName
      self.avatarURL = profile.avatar.flatMap { URL(string: $0.uriString()) }
    }
  }

  // MARK: - Public Methods

  /// Enrich conversation participants with profile data from Bluesky
  /// - Parameters:
  ///   - conversations: MLS conversations to enrich
  ///   - client: AT Protocol client for API calls
  func enrichConversations(_ conversations: [MLSConversationViewModel], using client: ATProtoClient) async {
    // Periodically cleanup old shared cache entries
    cleanupSharedProfileCache()
    
    // Extract unique DIDs from all conversations
    let allDIDs = extractUniqueDIDs(from: conversations)

    // Filter out DIDs we already have cached
    let uncachedDIDs = allDIDs.filter { profileCache[$0] == nil }

    guard !uncachedDIDs.isEmpty else {
      logger.debug("All profiles already cached, skipping fetch")
      return
    }

    logger.info("Fetching \(uncachedDIDs.count) uncached profiles")

    // Batch fetch profiles in chunks of 25 (AT Protocol limit)
    await fetchProfilesInBatches(uncachedDIDs, using: client)
  }

  /// Get cached profile data for a DID
  /// - Parameter did: The DID to look up
  /// - Returns: Cached profile data if available
  func getCachedProfile(for did: String) -> ProfileData? {
    profileCache[Self.canonicalDID(did)]
  }

  /// Ensure profile data exists for the provided DIDs and return cached entries
  /// - Parameters:
  ///   - dids: The unique DIDs to resolve
  ///   - client: Authenticated AT Protocol client for fetching missing profiles
  /// - Returns: Mapping of DID → enriched profile info for the requested IDs
  func ensureProfiles(
    for dids: [String],
    using client: ATProtoClient
  ) async -> [String: ProfileData] {
    let requestedDIDs = Array(Set(dids))
    let canonicalByRequested = Dictionary(uniqueKeysWithValues: requestedDIDs.map { ($0, Self.canonicalDID($0)) })
    let canonicalDIDs = Array(Set(canonicalByRequested.values))

    let uncachedCanonical = canonicalDIDs.filter { profileCache[$0] == nil }
    if !uncachedCanonical.isEmpty {
      logger.info("Ensuring profiles for \(uncachedCanonical.count) uncached participants")
      await fetchProfilesInBatches(uncachedCanonical, using: client)
    }

    var resolved: [String: ProfileData] = [:]
    for requested in requestedDIDs {
      if let canonical = canonicalByRequested[requested], let profile = profileCache[canonical] {
        resolved[requested] = profile
      }
    }
    return resolved
  }

  /// Clear the profile cache
  func clearCache() {
    profileCache.removeAll()
    logger.debug("Profile cache cleared")
  }

  // MARK: - Private Methods

  private func extractUniqueDIDs(from conversations: [MLSConversationViewModel]) -> [String] {
    var uniqueDIDs = Set<String>()

    for conversation in conversations {
      for participant in conversation.participants {
        uniqueDIDs.insert(Self.canonicalDID(participant.id))
      }
    }

    return Array(uniqueDIDs)
  }

  private func fetchProfilesInBatches(_ dids: [String], using client: ATProtoClient) async {
    // AT Protocol getProfiles supports up to 25 actors per request
    let batchSize = 25
    let batches = dids.chunked(into: batchSize)

    for batch in batches {
      await fetchProfileBatch(batch, using: client)
    }
  }

  private func fetchProfileBatch(_ dids: [String], using client: ATProtoClient) async {
    let actors = dids.compactMap { did -> ATIdentifier? in
      do {
        return try ATIdentifier(string: did)
      } catch {
        logger.warning("Skipping invalid DID for profile fetch: \(did)")
        return nil
      }
    }

    guard !actors.isEmpty else { return }

    do {
      // Create request parameters
      let params = AppBskyActorGetProfiles.Parameters(actors: actors)

      // Fetch profiles
      let (responseCode, response) = try await client.app.bsky.actor.getProfiles(input: params)

      guard responseCode >= 200 && responseCode < 300 else {
        logger.error("Batch profile fetch failed: HTTP \(responseCode)")
        return
      }

      guard let profiles = response?.profiles else {
        logger.warning("No profiles in response")
        return
      }

      // Cache the fetched profiles
      for profile in profiles {
        let profileData = ProfileData(from: profile)
        profileCache[Self.canonicalDID(profileData.did)] = profileData
        logger.debug("Cached profile for \(profileData.handle)")
        
        // Also persist to shared UserDefaults for NSE access
        persistProfileToSharedStorage(profileData)
      }

      logger.info("Successfully cached \(profiles.count) profiles")

    } catch {
      logger.error("Failed to fetch profile batch: \(error.localizedDescription)")
    }
  }
  
  // MARK: - Shared Storage for NSE
  
  /// App Group suite name for shared storage
  private static let appGroupSuite = "group.blue.catbird.shared"
  
  /// Maximum number of profiles to keep in shared storage
  private static let maxSharedProfiles = 500
  
  /// Key prefix for profile cache entries
  private static let profileCacheKeyPrefix = "profile_cache_"
  
  /// Cached profile structure for shared storage (Codable for UserDefaults)
  private struct SharedCachedProfile: Codable {
    let did: String
    let handle: String
    let displayName: String?
    let avatarURL: String?
    let cachedAt: Date
  }
  
  /// Persists a profile to shared UserDefaults so the NSE can access it
  private func persistProfileToSharedStorage(_ profile: ProfileData) {
    guard let defaults = UserDefaults(suiteName: Self.appGroupSuite) else {
      return
    }
    
    let cachedProfile = SharedCachedProfile(
      did: profile.did,
      handle: profile.handle,
      displayName: profile.displayName,
      avatarURL: profile.avatarURL?.absoluteString,
      cachedAt: Date()
    )
    
    let cacheKey = "\(Self.profileCacheKeyPrefix)\(profile.did.lowercased())"
    
    if let data = try? JSONEncoder().encode(cachedProfile) {
      defaults.set(data, forKey: cacheKey)
    }
  }
  
  /// Cleans up old profile entries from shared storage
  /// Call this periodically (e.g., on app launch or when enriching profiles)
  func cleanupSharedProfileCache() {
    guard let defaults = UserDefaults(suiteName: Self.appGroupSuite) else {
      return
    }
    
    // Find all profile cache keys
    let allKeys = defaults.dictionaryRepresentation().keys
    let profileKeys = allKeys.filter { $0.hasPrefix(Self.profileCacheKeyPrefix) }
    
    guard profileKeys.count > Self.maxSharedProfiles else {
      logger.debug("Profile cache has \(profileKeys.count) entries, under limit of \(Self.maxSharedProfiles)")
      return
    }
    
    logger.info("Profile cache has \(profileKeys.count) entries, cleaning up...")
    
    // Decode all profiles with their cached timestamps
    var profilesWithDates: [(key: String, cachedAt: Date)] = []
    
    for key in profileKeys {
      if let data = defaults.data(forKey: key),
         let profile = try? JSONDecoder().decode(SharedCachedProfile.self, from: data) {
        profilesWithDates.append((key: key, cachedAt: profile.cachedAt))
      } else {
        // Invalid entry - remove it
        defaults.removeObject(forKey: key)
      }
    }
    
    // Sort by date (oldest first) and remove excess
    profilesWithDates.sort { $0.cachedAt < $1.cachedAt }
    let toRemove = profilesWithDates.count - Self.maxSharedProfiles
    
    if toRemove > 0 {
      for i in 0..<toRemove {
        defaults.removeObject(forKey: profilesWithDates[i].key)
      }
      logger.info("Removed \(toRemove) old profile cache entries")
    }
  }
  
  /// Clears all profile entries from shared storage
  func clearSharedProfileCache() {
    guard let defaults = UserDefaults(suiteName: Self.appGroupSuite) else {
      return
    }
    
    let allKeys = defaults.dictionaryRepresentation().keys
    var removedCount = 0
    
    for key in allKeys where key.hasPrefix(Self.profileCacheKeyPrefix) {
      defaults.removeObject(forKey: key)
      removedCount += 1
    }
    
    logger.info("Cleared \(removedCount) profile cache entries from shared storage")
  }
}

// MARK: - Array Extension

private extension Array {
  /// Split array into chunks of specified size
  func chunked(into size: Int) -> [[Element]] {
    stride(from: 0, to: count, by: size).map {
      Array(self[$0..<Swift.min($0 + size, count)])
    }
  }
}

#endif
