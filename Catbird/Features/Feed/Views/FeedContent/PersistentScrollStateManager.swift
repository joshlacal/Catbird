//
//  PersistentScrollStateManager.swift
//  Catbird
//
//  Created by Claude on 7/19/25.
//
//  Manages persistent scroll state across app suspensions and launches
//

import Foundation
import os
import UIKit

/// Manages persistent scroll state across app lifecycle events
@MainActor
final class PersistentScrollStateManager {
    
    // MARK: - Singleton
    
    static let shared = PersistentScrollStateManager()
    
    // MARK: - Types
    
    struct ScrollState: Codable {
        let feedIdentifier: String
        let postID: String
        let offsetFromTop: CGFloat
        let timestamp: Date
        let contentOffset: CGFloat
        
        var isStale: Bool {
            Date().timeIntervalSince(timestamp) > FeedConstants.maxScrollStateAge
        }
    }
    
    // MARK: - Properties
    
    /// Maximum number of scroll states to persist
    private let maxPersistedStates = 20
    
    /// Maximum age of scroll states (24 hours)
    private static let maxScrollStateAge: TimeInterval = 24 * 60 * 60
    
    /// Logger for debugging
    private let logger = Logger(subsystem: "blue.catbird", category: "PersistentScrollStateManager")
    
    /// User defaults key for storing scroll states
    private let scrollStatesKey = "CatbirdPersistentScrollStates"
    
    /// In-memory cache of scroll states
    private var scrollStatesCache: [String: ScrollState] = [:]
    
    /// Whether we've loaded from disk
    private var hasLoadedFromDisk = false
    
    // MARK: - Initialization
    
    private init() {
        setupAppLifecycleObservers()
        loadScrollStatesFromDisk()
    }
    
    // MARK: - Public Methods
    
    /// Saves scroll state for a feed
    func saveScrollState(
        feedIdentifier: String,
        postID: String,
        offsetFromTop: CGFloat,
        contentOffset: CGFloat
    ) {
        let scrollState = ScrollState(
            feedIdentifier: feedIdentifier,
            postID: postID,
            offsetFromTop: offsetFromTop,
            timestamp: Date(),
            contentOffset: contentOffset
        )
        
        scrollStatesCache[feedIdentifier] = scrollState
        
        logger.debug("Saved scroll state for feed: \(feedIdentifier), post: \(postID)")
        
        // Save to disk asynchronously
        Task {
            await persistScrollStatesToDisk()
        }
    }
    
    /// Loads scroll state for a feed
    func loadScrollState(for feedIdentifier: String) -> ScrollState? {
        ensureLoaded()
        
        guard let state = scrollStatesCache[feedIdentifier], !state.isStale else {
            if scrollStatesCache[feedIdentifier]?.isStale == true {
                scrollStatesCache.removeValue(forKey: feedIdentifier)
                logger.debug("Removed stale scroll state for feed: \(feedIdentifier)")
            }
            return nil
        }
        
        logger.debug("Loaded scroll state for feed: \(feedIdentifier), post: \(state.postID)")
        return state
    }
    
    /// Clears scroll state for a specific feed
    func clearScrollState(for feedIdentifier: String) {
        scrollStatesCache.removeValue(forKey: feedIdentifier)
        logger.debug("Cleared scroll state for feed: \(feedIdentifier)")
        
        Task {
            await persistScrollStatesToDisk()
        }
    }
    
    /// Clears all scroll states
    func clearAllScrollStates() {
        scrollStatesCache.removeAll()
        logger.debug("Cleared all scroll states")
        
        Task {
            await persistScrollStatesToDisk()
        }
    }
    
    // MARK: - Private Methods
    
    private func ensureLoaded() {
        if !hasLoadedFromDisk {
            loadScrollStatesFromDisk()
        }
    }
    
    private func loadScrollStatesFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: scrollStatesKey) else {
            logger.debug("No persisted scroll states found")
            hasLoadedFromDisk = true
            return
        }
        
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            let states = try decoder.decode([ScrollState].self, from: data)
            
            // Convert to dictionary and filter out stale states
            scrollStatesCache = Dictionary(
                uniqueKeysWithValues: states
                    .filter { !$0.isStale }
                    .map { ($0.feedIdentifier, $0) }
            )
            
            logger.debug("Loaded \(self.scrollStatesCache.count) scroll states from disk")
            
            // Clean up stale states if we removed any
            if states.count != scrollStatesCache.count {
                Task {
                    await persistScrollStatesToDisk()
                }
            }
            
        } catch {
            logger.error("Failed to load scroll states: \(error.localizedDescription)")
            scrollStatesCache.removeAll()
        }
        
        hasLoadedFromDisk = true
    }
    
    private func persistScrollStatesToDisk() async {
        // Clean up stale states before persisting
        let currentStates = scrollStatesCache.values.filter { !$0.isStale }
        
        // Enforce maximum number of states
        let statesToPersist = Array(currentStates
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(maxPersistedStates))
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            
            let data = try encoder.encode(statesToPersist)
            UserDefaults.standard.set(data, forKey: scrollStatesKey)
            
            logger.debug("Persisted \(statesToPersist.count) scroll states to disk")
            
        } catch {
            logger.error("Failed to persist scroll states: \(error.localizedDescription)")
        }
    }
    
    private func setupAppLifecycleObservers() {
        // Save states when app backgrounds
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.persistScrollStatesToDisk()
            }
        }
        
        // Clean up stale states when app becomes active
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupStaleStates()
            }
        }
    }
    
    private func cleanupStaleStates() {
        let originalCount = scrollStatesCache.count
        scrollStatesCache = scrollStatesCache.compactMapValues { state in
            state.isStale ? nil : state
        }
        
        if scrollStatesCache.count != originalCount {
            logger.debug("Cleaned up \(originalCount - self.scrollStatesCache.count) stale scroll states")
            Task {
                await persistScrollStatesToDisk()
            }
        }
    }
}

// MARK: - FeedConstants Extension

extension FeedConstants {
    /// Maximum age for scroll state persistence (24 hours)
    static let maxScrollStateAge: TimeInterval = 24 * 60 * 60
}
