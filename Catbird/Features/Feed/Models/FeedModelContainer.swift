import Foundation
import Observation

/// Container for feed models that preserves state across tab switches
@Observable
final class FeedModelContainer {
    // Cache of feed models by feed type for persistence
    private var modelCache: [String: FeedModel] = [:]
    
    // Last accessed time to track model lifecycle
    private var lastAccessed: [String: Date] = [:]
    
    // Single shared instance for app-wide use
    static let shared = FeedModelContainer()
    
    // Private initializer to enforce singleton pattern
    private init() {}
    
    func getModel(for feedType: FetchType, appState: AppState) -> FeedModel {
        let key = feedType.identifier
        
        // Record access time
        lastAccessed[key] = Date()
        
        // If model exists and matches feed type, return it
        if let model = modelCache[key],
           model.feedManager.fetchType.identifier == feedType.identifier
        {
            return model
        }
        
        // Create new model with safeguards
        do {
            let feedManager = FeedManager(
                client: appState.atProtoClient,
                fetchType: feedType
            )
            
            let model = FeedModel(
                feedManager: feedManager,
                appState: appState
            )
            
            modelCache[key] = model
            return model
        } catch {
            // Create a failsafe model if something goes wrong
            let failsafeModel = FeedModel(
                feedManager: FeedManager(
                    client: nil,  // No client in failsafe mode
                    fetchType: feedType
                ),
                appState: appState
            )
            
            return failsafeModel
        }
    }
        
    /// Prunes old models that haven't been accessed in a while to prevent memory bloat
    func pruneOldModels(olderThan interval: TimeInterval = 1800) { // 30 minutes by default
        let now = Date()
        let keysToRemove = lastAccessed.filter { key, date in
            now.timeIntervalSince(date) > interval
        }.keys
        
        for key in keysToRemove {
            modelCache.removeValue(forKey: key)
            lastAccessed.removeValue(forKey: key)
        }
    }
    
    func clearCache() {
        modelCache.removeAll()
        lastAccessed.removeAll()
    }
}
