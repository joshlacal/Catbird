import Foundation
import Petrel
import OSLog
import CatbirdMLSCore

/// Service for enriching MLS conversation participants with Bluesky profile data
actor MLSProfileEnricher {
  private let logger = Logger(subsystem: "blue.catbird", category: "MLSProfileEnricher")

  // Cache DID → Profile data (keyed by canonical DID without any device fragment)
  private var profileCache: [String: ProfileData] = [:]
  // Track when each profile was last fetched from the network
  private var profileFetchedAt: [String: Date] = [:]
  // Re-fetch profiles older than this interval
  private static let profileStaleInterval: TimeInterval = 3600  // 1 hour

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

    init(did: String, handle: String, displayName: String?, avatarURL: URL?) {
      self.did = did
      self.handle = handle
      self.displayName = displayName
      self.avatarURL = avatarURL
    }
  }

  // MARK: - Public Methods

  /// Enrich conversation participants with profile data from Bluesky
  /// - Parameters:
  ///   - conversations: MLS conversations to enrich
  ///   - client: AT Protocol client for API calls
  func enrichConversations(_ conversations: [MLSConversationViewModel], using client: ATProtoClient) async {
    // Extract unique DIDs from all conversations
    let allDIDs = extractUniqueDIDs(from: conversations)

    // Filter to DIDs that are uncached or stale
    let now = Date()
    let didsToFetch = allDIDs.filter { did in
      guard profileCache[did] != nil else { return true }  // uncached
      guard let fetchedAt = profileFetchedAt[did] else { return true }  // no timestamp
      return now.timeIntervalSince(fetchedAt) > Self.profileStaleInterval  // stale
    }

    guard !didsToFetch.isEmpty else {
      logger.debug("All profiles cached and fresh, skipping fetch")
      return
    }

    logger.info("Fetching \(didsToFetch.count) profiles (uncached or stale)")

    // Batch fetch profiles in chunks of 25 (AT Protocol limit)
    await fetchProfilesInBatches(didsToFetch, using: client)
  }

  /// Get cached profile data for a DID
  /// - Parameter did: The DID to look up
  /// - Returns: Cached profile data if available
  func getCachedProfile(for did: String) -> ProfileData? {
    profileCache[Self.canonicalDID(did)]
  }

  /// Batch lookup of cached profiles for multiple DIDs
  /// Returns only entries that are already in the in-memory cache (no network calls)
  func getCachedProfiles(for dids: [String]) -> [String: ProfileData] {
    var result: [String: ProfileData] = [:]
    for did in dids {
      let canonical = Self.canonicalDID(did)
      if let profile = profileCache[canonical] {
        result[canonical] = profile
      }
    }
    return result
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
    // Delegate to the new method without database persistence
    await ensureProfiles(for: dids, using: client, currentUserDID: nil)
  }
  
  /// Ensure profile data exists for the provided DIDs with database persistence
  ///
  /// This overload persists fetched profiles to the MLS member table in the database,
  /// enabling the Notification Service Extension to show rich notifications with
  /// sender names instead of "New Message".
  ///
  /// - Parameters:
  ///   - dids: The unique DIDs to resolve
  ///   - client: Authenticated AT Protocol client for fetching missing profiles
  ///   - currentUserDID: Current user's DID for scoping database updates (nil skips DB persistence)
  /// - Returns: Mapping of DID → enriched profile info for the requested IDs
  func ensureProfiles(
    for dids: [String],
    using client: ATProtoClient,
    currentUserDID: String?
  ) async -> [String: ProfileData] {
    let requestedDIDs = Array(Set(dids))
    let canonicalByRequested = Dictionary(uniqueKeysWithValues: requestedDIDs.map { ($0, Self.canonicalDID($0)) })
    let canonicalDIDs = Array(Set(canonicalByRequested.values))

    let now = Date()
    let staleOrMissing = canonicalDIDs.filter { did in
      guard profileCache[did] != nil else { return true }
      guard let fetchedAt = profileFetchedAt[did] else { return true }
      return now.timeIntervalSince(fetchedAt) > Self.profileStaleInterval
    }
    if !staleOrMissing.isEmpty {
      logger.info("Ensuring profiles for \(staleOrMissing.count) uncached/stale participants")
      await fetchProfilesInBatches(staleOrMissing, using: client, currentUserDID: currentUserDID)
    }

    var resolved: [String: ProfileData] = [:]
    for requested in requestedDIDs {
      if let canonical = canonicalByRequested[requested], let profile = profileCache[canonical] {
        resolved[requested] = profile
      }
    }
    return resolved
  }

  /// Seed the in-memory cache from database-persisted profile data
  /// Only fills entries that aren't already cached (won't overwrite fresher network data)
  func seedFromDatabase(_ profiles: [ProfileData]) {
    var seeded = 0
    for profile in profiles {
      let canonical = Self.canonicalDID(profile.did)
      if profileCache[canonical] == nil {
        profileCache[canonical] = profile
        seeded += 1
      }
    }
    if seeded > 0 {
      logger.debug("Seeded \(seeded) profile(s) from database cache")
    }
  }

  /// Clear the profile cache
  func clearCache() {
    profileCache.removeAll()
    profileFetchedAt.removeAll()
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

  private func fetchProfilesInBatches(_ dids: [String], using client: ATProtoClient, currentUserDID: String? = nil) async {
    // AT Protocol getProfiles supports up to 25 actors per request
    let batchSize = 25
    let batches = dids.chunked(into: batchSize)

    for batch in batches {
      await fetchProfileBatch(batch, using: client, currentUserDID: currentUserDID)
    }
  }

  private func fetchProfileBatch(_ dids: [String], using client: ATProtoClient, currentUserDID: String? = nil) async {
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
      var profilesToPersist: [(did: String, handle: String?, displayName: String?, avatarURL: String?)] = []

      let now = Date()
      for profile in profiles {
        let profileData = ProfileData(from: profile)
        let canonical = Self.canonicalDID(profileData.did)
        profileCache[canonical] = profileData
        profileFetchedAt[canonical] = now
        logger.debug("Cached profile for \(profileData.handle)")

        // Collect profiles for database persistence (replaces UserDefaults shared storage)
        if currentUserDID != nil {
          profilesToPersist.append((
            did: profileData.did,
            handle: profileData.handle,
            displayName: profileData.displayName,
            avatarURL: profileData.avatarURL?.absoluteString
          ))
        }
      }
      
      // Persist to MLS member table for NSE rich notifications
      if let userDID = currentUserDID, !profilesToPersist.isEmpty {
        await persistProfilesToDatabase(profilesToPersist, currentUserDID: userDID)
      }

      logger.info("Successfully cached \(profiles.count) profiles")

    } catch {
      logger.error("Failed to fetch profile batch: \(error.localizedDescription)")
    }
  }
  
  /// Persist profiles to the MLS member table in the database
  ///
  /// This enables the NSE to look up sender names when showing notifications.
  /// The update only affects members that already exist in the database.
  private func persistProfilesToDatabase(
    _ profiles: [(did: String, handle: String?, displayName: String?, avatarURL: String?)],
    currentUserDID: String
  ) async {
    do {
      // Use smart routing - auto-routes to lightweight Queue if needed
      let updatedCount = try await MLSGRDBManager.shared.write(for: currentUserDID) { db in
        try MLSStorageHelpers.batchUpdateMemberProfilesSync(
          in: db,
          profiles: profiles,
          currentUserDID: currentUserDID
        )
      }
      
      if updatedCount > 0 {
        logger.info("📝 Persisted \(updatedCount) profile(s) to MLS member table for NSE access")
      }
    } catch {
      // Non-fatal - the in-memory cache and shared UserDefaults still work
      logger.warning("Failed to persist profiles to database: \(error.localizedDescription)")
    }
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
