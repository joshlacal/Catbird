import Foundation
import OSLog
import Petrel

/// Service to check if users are available for MLS encrypted chat
/// Uses the server's getOptInStatus endpoint to check if users have opted in
actor MLSChatAvailabilityService {
  private let logger = Logger(subsystem: "blue.catbird", category: "MLSChatAvailability")

  /// Cache of DID -> availability status
  private var cache: [String: CachedStatus] = [:]

  /// How long to cache availability status (5 minutes)
  private let cacheDuration: TimeInterval = 300

  private struct CachedStatus {
    let available: Bool
    let checkedAt: Date

    func isExpired(now: Date, cacheDuration: TimeInterval) -> Bool {
      now.timeIntervalSince(checkedAt) > cacheDuration
    }
  }

  private struct UncachedEntry {
    let original: String
    let canonical: String
    let did: DID
  }

  private let apiClient: MLSAPIClient

  init(apiClient: MLSAPIClient) {
    self.apiClient = apiClient
  }

  /// Check if a single user can receive MLS messages
  func canChat(with did: String) async -> Bool {
    guard let normalizedDid = try? DID(didString: did) else {
      logger.error("Failed to normalize DID for chat availability: \(did)")
      return false
    }

    let cacheKey = normalizedDid.description
    let now = Date()

    if let cached = cache[cacheKey], !cached.isExpired(now: now, cacheDuration: cacheDuration) {
      return cached.available
    }

    do {
      let statuses = try await apiClient.getOptInStatus(dids: [normalizedDid])
      let available = statuses.first(where: { $0.did == cacheKey })?.optedIn ?? false
      cache[cacheKey] = CachedStatus(available: available, checkedAt: now)
      return available
    } catch {
      logger.error("Failed to check chat availability for \(cacheKey): \(error.localizedDescription)")
      return false // Fail closed - assume not available
    }
  }

  /// Batch check for multiple users (efficient for profile lists)
  func canChat(withDids dids: [String]) async -> [String: Bool] {
    var results: [String: Bool] = [:]
    var uncachedEntries: [UncachedEntry] = []
    let now = Date()

    for did in dids {
      guard let normalizedDid = try? DID(didString: did) else {
        logger.error("Invalid DID string provided for chat availability: \(did)")
        results[did] = false
        continue
      }

      let cacheKey = normalizedDid.description

      if let cached = cache[cacheKey], !cached.isExpired(now: now, cacheDuration: cacheDuration) {
        results[did] = cached.available
      } else {
        uncachedEntries.append(UncachedEntry(original: did, canonical: cacheKey, did: normalizedDid))
      }
    }

    guard !uncachedEntries.isEmpty else {
      return results
    }

    for batch in uncachedEntries.chunked(into: 100) {
      do {
        let statuses = try await apiClient.getOptInStatus(dids: batch.map(\.did))
        var statusMap: [String: Bool] = [:]
        statuses.forEach { status in
          statusMap[status.did] = status.optedIn
        }
        let timestamp = Date()

        for entry in batch {
          let available = statusMap[entry.canonical] ?? false
          results[entry.original] = available
          cache[entry.canonical] = CachedStatus(available: available, checkedAt: timestamp)
        }
      } catch {
        logger.error("Failed to batch check chat availability: \(error.localizedDescription)")
        for entry in batch {
          results[entry.original] = false
        }
      }
    }

    return results
  }

  /// Clear the cache (e.g., on logout)
  func clearCache() {
    cache.removeAll()
  }

  /// Invalidate cache for a specific user
  func invalidate(did: String) {
    if let normalizedDid = try? DID(didString: did) {
      cache.removeValue(forKey: normalizedDid.description)
    } else {
      cache.removeValue(forKey: did)
    }
  }
}

// Helper extension for chunking arrays
private extension Array {
  func chunked(into size: Int) -> [[Element]] {
    guard size > 0 else { return [self] }
    return stride(from: 0, to: count, by: size).map {
      Array(self[$0..<Swift.min($0 + size, count)])
    }
  }
}
