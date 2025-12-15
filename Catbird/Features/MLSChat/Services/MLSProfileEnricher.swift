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
        uniqueDIDs.insert(participant.id)
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
        profileCache[profileData.did] = profileData
        logger.debug("Cached profile for \(profileData.handle)")
      }

      logger.info("Successfully cached \(profiles.count) profiles")

    } catch {
      logger.error("Failed to fetch profile batch: \(error.localizedDescription)")
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

#endif
