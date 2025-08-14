//
//  FeedCollectionViewBridge.swift
//  Catbird
//
//  Bridge to seamlessly integrate the optimized feed controller with existing SwiftUI views
//

import SwiftUI
import UIKit
import os

/// SwiftUI wrapper for the integrated feed collection view controller
@available(iOS 16.0, *)
struct FeedCollectionViewIntegrated: UIViewControllerRepresentable {
    @Bindable var stateManager: FeedStateManager
    @Binding var navigationPath: NavigationPath
    var onScrollOffsetChanged: ((CGFloat) -> Void)?
    
    private let logger = Logger(subsystem: "blue.catbird", category: "FeedCollectionBridge")
    
    func makeUIViewController(context: Context) -> FeedCollectionViewControllerIntegrated {
        logger.debug("🏗️ Creating integrated feed controller")
        
        let controller = FeedCollectionViewControllerIntegrated(
            stateManager: stateManager,
            navigationPath: $navigationPath,
            onScrollOffsetChanged: onScrollOffsetChanged
        )
        
        return controller
    }
    
    func updateUIViewController(_ controller: FeedCollectionViewControllerIntegrated, context: Context) {
        // Only update if state manager has changed
        if controller.stateManager !== stateManager {
            logger.debug("🔄 Updating controller with new state manager")
            controller.updateStateManager(stateManager)
        }
    }
}

// MARK: - Controller Extensions

@available(iOS 16.0, *)
extension FeedCollectionViewControllerIntegrated {
    /// Update the state manager when feed changes
    func updateStateManager(_ newStateManager: FeedStateManager) {
        guard newStateManager !== stateManager else { return }
        
        logger.info("🔄 Switching state manager: \(self.stateManager.currentFeedType.identifier) → \(newStateManager.currentFeedType.identifier)")
        
        // Save current position before switching
        savePersistedScrollState(force: true)
        
        // Cancel ongoing operations
        loadMoreTask?.cancel()
        observationTask?.cancel()
        
        // Update the state manager
        stateManager = newStateManager
        
        // Restart observations
        setupObservers()
        setupScrollToTopCallback()
        
        // Load data and restore position if available
        Task { @MainActor in
            // Check if new feed has persisted position
            if let persistedState = loadPersistedScrollState() {
                await performUpdate(type: .viewAppearance(persistedState: persistedState))
            } else {
                // Fresh load for new feed
                await loadInitialData()
            }
        }
    }
}

// MARK: - Controller Configuration

/// Configuration for feed controller features
struct FeedControllerConfiguration {
    /// Whether UIUpdateLink optimizations are available (iOS 18+)
    static var hasUIUpdateLinkSupport: Bool {
        if #available(iOS 18.0, *) {
            return true
        }
        return false
    }
}

// MARK: - Migration Helper

/// Helper to migrate scroll positions from old to new controller
struct FeedScrollPositionMigrator {
    private static let logger = Logger(subsystem: "blue.catbird", category: "FeedMigration")
    
    /// Migrate persisted scroll positions from old format to new
    static func migrateIfNeeded() {
        let migrationKey = "feed_scroll_migration_completed"
        
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }
        
        logger.info("🔄 Starting feed scroll position migration")
        
        // Migrate each feed type's persisted position
        let feedTypes = ["timeline", "following", "discover"] // Add all your feed types
        
        for feedType in feedTypes {
            migrateScrollPosition(for: feedType)
        }
        
        UserDefaults.standard.set(true, forKey: migrationKey)
        logger.info("✅ Feed scroll position migration completed")
    }
    
    private static func migrateScrollPosition(for feedType: String) {
        let oldKey = "ScrollPosition_\(feedType)"
        let newKey = "feed_scroll_\(feedType)"
        
        // Check if old format exists
        if let oldData = UserDefaults.standard.data(forKey: oldKey) {
            // Try to decode old format and convert
            if let oldPosition = try? JSONDecoder().decode(LegacyScrollPosition.self, from: oldData) {
                // Convert to new format
                let newPosition = PersistedScrollState(
                    postID: oldPosition.postID,
                    offsetFromTop: oldPosition.offset,
                    contentOffset: oldPosition.offset
                )
                
                if let encoded = try? JSONEncoder().encode(newPosition) {
                    UserDefaults.standard.set(encoded, forKey: newKey)
                    UserDefaults.standard.set(Date(), forKey: "\(newKey)_timestamp")
                    
                    // Remove old key
                    UserDefaults.standard.removeObject(forKey: oldKey)
                    
                    logger.debug("✅ Migrated scroll position for \(feedType)")
                }
            }
        }
    }
    
    private struct LegacyScrollPosition: Codable {
        let postID: String
        let offset: CGFloat
    }
}

// MARK: - Drop-in Replacement

/// Drop-in replacement for existing FeedCollectionView usage
@available(iOS 16.0, *)
struct FeedCollectionViewWrapper: View {
    @Bindable var stateManager: FeedStateManager
    @Binding var navigationPath: NavigationPath
    var onScrollOffsetChanged: ((CGFloat) -> Void)?
    
    var body: some View {
        Group {
            // Always use the integrated controller (only implementation now)
            FeedCollectionViewIntegrated(
                stateManager: stateManager,
                navigationPath: $navigationPath,
                onScrollOffsetChanged: onScrollOffsetChanged
            )
        }
        .onAppear {
            // Run migration on first appearance
            FeedScrollPositionMigrator.migrateIfNeeded()
        }
    }
}

// MARK: - Legacy Support

/// Legacy fallback - uses the integrated controller for all iOS versions
@available(iOS 16.0, *)
struct FeedCollectionViewLegacy: UIViewControllerRepresentable {
    @Bindable var stateManager: FeedStateManager
    @Binding var navigationPath: NavigationPath
    var onScrollOffsetChanged: ((CGFloat) -> Void)?
    
    func makeUIViewController(context: Context) -> FeedCollectionViewControllerIntegrated {
        // Use integrated controller as the only implementation
        FeedCollectionViewControllerIntegrated(
            stateManager: stateManager,
            navigationPath: $navigationPath,
            onScrollOffsetChanged: onScrollOffsetChanged
        )
    }
    
    func updateUIViewController(_ controller: FeedCollectionViewControllerIntegrated, context: Context) {
        if controller.stateManager !== stateManager {
            controller.updateStateManager(stateManager)
        }
    }
}
