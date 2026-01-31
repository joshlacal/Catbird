import CatbirdMLSCore
import Petrel
import OSLog

/// Trust checker that checks if the current user follows a given DID.
/// Used by MLSConversationManager to determine if incoming conversations
/// should appear in the main inbox (trusted) or Requests (untrusted).
final class FollowingTrustChecker: MLSTrustChecker, @unchecked Sendable {
  private weak var client: ATProtoClient?
  private let currentUserDID: String
  private let logger = Logger(subsystem: "blue.catbird", category: "TrustChecker")
  
  /// Cache of known trusted DIDs (people we follow)
  private var trustedDIDs: Set<String> = []
  private var cacheLoaded = false
  
  init(client: ATProtoClient, currentUserDID: String) {
    self.client = client
    self.currentUserDID = currentUserDID
  }
  
  /// Check if we trust the given DID (i.e., we follow them)
  func isTrusted(did: String) async -> Bool {
    // Always trust ourselves
    if did.lowercased() == currentUserDID.lowercased() {
      return true
    }
    
    // Load following list if not cached
    if !cacheLoaded {
      await loadFollowing()
    }
    
    // Check if DID is in our following list
    return trustedDIDs.contains(did.lowercased())
  }
  
  /// Load the list of people we follow
  private func loadFollowing() async {
    guard let client = client else {
      logger.warning("Trust checker: No AT Proto client available")
      cacheLoaded = true
      return
    }
    
    do {
      var cursor: String? = nil
      var allFollows: [String] = []
      
      repeat {
        let response = try await client.app.bsky.graph.getFollows(
          input: .init(
            actor: ATIdentifier(string: currentUserDID),
            limit: 100,
            cursor: cursor
          )
        )
        
        if let output = response.data {
          allFollows.append(contentsOf: output.follows.map { $0.did.description.lowercased() })
          cursor = output.cursor
        } else {
          cursor = nil
        }
      } while cursor != nil
      
      trustedDIDs = Set(allFollows)
      cacheLoaded = true
      logger.info("Trust checker: Loaded \(allFollows.count) followed accounts")
      
    } catch {
      logger.error("Trust checker: Failed to load following list: \(error.localizedDescription)")
      cacheLoaded = true
    }
  }
  
  /// Refresh the trust cache (call when user follows/unfollows someone)
  func refreshCache() async {
    cacheLoaded = false
    await loadFollowing()
  }
}
