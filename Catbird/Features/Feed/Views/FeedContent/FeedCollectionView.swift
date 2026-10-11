//
//  FeedCollectionView.swift
//  Catbird
//
//  Created by Claude on 7/18/25.
//
//  SwiftUI integration bridge for UIKit collection view with @Observable state management
//

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import Petrel
import os

/// SwiftUI wrapper for the feed collection view with automatic controller selection
@available(iOS 16.0, macOS 13.0, *)
struct FeedCollectionView: View {
    // MARK: - Properties
    
    /// The state manager that coordinates feed data and ViewModels
    @Bindable var stateManager: FeedStateManager
    
    /// Navigation path for SwiftUI navigation
    @Binding var navigationPath: NavigationPath
    
    /// Optional callback for scroll offset changes
    let onScrollOffsetChanged: ((CGFloat) -> Void)?
    let headerView: AnyView?

    @Environment(\.feedHeaderView) private var injectedHeaderView
    
    // MARK: - Initialization
    
    init(
        stateManager: FeedStateManager,
        navigationPath: Binding<NavigationPath>,
        onScrollOffsetChanged: ((CGFloat) -> Void)? = nil,
        headerView: AnyView? = nil
    ) {
        self.stateManager = stateManager
        self._navigationPath = navigationPath
        self.onScrollOffsetChanged = onScrollOffsetChanged
        self.headerView = headerView
    }
    
    // MARK: - Body
    
    var body: some View {
        // Use the wrapper that automatically selects the appropriate controller
        FeedCollectionViewWrapper(
            stateManager: stateManager,
            navigationPath: $navigationPath,
            onScrollOffsetChanged: onScrollOffsetChanged,
            headerView: headerView ?? injectedHeaderView
        )
        // Recreate the controller on font changes so cells re-measure. Theme changes are applied in
        // place by the controller's ThemeManager observer; rebuilding for them reloaded every module.
        .id(
            "\(ObjectIdentifier(stateManager))-" +
            "\(stateManager.appState.fontDidChange)-" +
            "\(stateManager.appState.userDID ?? "unknown-account-")" +
            "\(stateManager.currentFeedType.identifier)"
        )
        .themedPrimaryBackground(stateManager.appState.themeManager, appSettings: stateManager.appState.appSettings)
        .task(id: stateManager.reconnectRetryKey) {
            await stateManager.retryAfterConnectionRestored()
        }
    }
}

// MARK: - Convenience Initializers

@available(iOS 16.0, macOS 13.0, *)
extension FeedCollectionView {
    /// Creates a feed collection view with just the essential parameters
    init(
        stateManager: FeedStateManager,
        navigationPath: Binding<NavigationPath>,
        headerView: AnyView? = nil
    ) {
        self.init(
            stateManager: stateManager,
            navigationPath: navigationPath,
            onScrollOffsetChanged: nil,
            headerView: headerView
        )
    }
}

 

// MARK: - View Modifiers

@available(iOS 16.0, macOS 13.0, *)
extension FeedCollectionView {
    /// Adds a scroll offset change handler
    func onScrollOffsetChanged(_ handler: @escaping (CGFloat) -> Void) -> FeedCollectionView {
        FeedCollectionView(
            stateManager: stateManager,
            navigationPath: $navigationPath,
            onScrollOffsetChanged: handler,
            headerView: headerView
        )
    }
}

// MARK: - Integration Helper

@available(iOS 16.0, macOS 13.0, *)
extension FeedCollectionView {
    /// Creates a complete feed view with state management and persistence
    static func create(
        for feedType: FetchType,
        appState: AppState,
        navigationPath: Binding<NavigationPath>
    ) -> some View {
        // Use a wrapper view that manages the persistence and state
        FeedCollectionWrapper(
            feedType: feedType,
            appState: appState,
            navigationPath: navigationPath
        )
    }
}

/// Simple wrapper view that creates fresh state without persistent caching
@available(iOS 16.0, macOS 13.0, *)
struct SimpleFeedCollectionWrapper: View {
    let feedType: FetchType
    let appState: AppState
    @Binding var navigationPath: NavigationPath
    
    @State private var stateManager: FeedStateManager?
    @State private var isInitialized = false
    
    var body: some View {
        Group {
            if let stateManager = stateManager, !stateManager.isCleanedUp {
                FeedCollectionView(
                    stateManager: stateManager,
                    navigationPath: $navigationPath
                )
                .themedPrimaryBackground(stateManager.appState.themeManager, appSettings: stateManager.appState.appSettings)
                .onAppear {
                    FeedStateStore.shared.attach(stateManager)
                }
                .onDisappear {
                    FeedStateStore.shared.detach(stateManager)
                }
                .task {
                    if !isInitialized {
                        isInitialized = true
                        await stateManager.loadInitialData()
                    }
                }
                .onChange(of: feedType) { oldFeedType, newFeedType in
                    // Send the old feed's pending feedback before switching
                    Task { await appState.feedFeedbackManager.flushInteractions() }
                    FeedStateStore.shared.detach(stateManager)
                    // Switch to a dedicated manager per feed to keep per-feed scroll state
                    let newManager = FeedStateStore.shared.stateManager(for: newFeedType, appState: appState)
                    FeedStateStore.shared.attach(newManager)
                    self.stateManager = newManager
                    Task { @MainActor in
                        if newManager.posts.isEmpty { await newManager.loadInitialData() }
                    }
                }
            } else {
                Color.clear
                    .onAppear {
                        // Resolve a per-feed state manager from the shared store
                        let manager = FeedStateStore.shared.stateManager(for: feedType, appState: appState)
                        FeedStateStore.shared.attach(manager)
                        self.stateManager = manager
                    }
            }
        }
        .onAppear {
            if stateManager == nil || stateManager?.isCleanedUp == true {
                let manager = FeedStateStore.shared.stateManager(for: feedType, appState: appState)
                FeedStateStore.shared.attach(manager)
                self.stateManager = manager
            }
        }
    }
}

/// Wrapper view that manages feed state and controller persistence
@available(iOS 16.0, macOS 13.0, *)
struct FeedCollectionWrapper: View {
    let feedType: FetchType
    let appState: AppState
    @Binding var navigationPath: NavigationPath
    
    @State private var stateManager: FeedStateManager?
    @State private var isInitialized = false
    
    var body: some View {
        Group {
            if let stateManager = stateManager, !stateManager.isCleanedUp {
                FeedCollectionView(
                    stateManager: stateManager,
                    navigationPath: $navigationPath
                )
                .themedPrimaryBackground(stateManager.appState.themeManager, appSettings: stateManager.appState.appSettings)
                .onAppear {
                    FeedStateStore.shared.attach(stateManager)
                }
                .onDisappear {
                    FeedStateStore.shared.detach(stateManager)
                }
                .task {
                    if !isInitialized {
                        isInitialized = true
                        await stateManager.loadInitialData()
                    }
                }
                .onChange(of: feedType) { oldFeedType, newFeedType in
                    // Send the old feed's pending feedback before switching
                    Task { await appState.feedFeedbackManager.flushInteractions() }
                    FeedStateStore.shared.detach(stateManager)
                    // Switch to the store-managed manager for the new feed
                    let newManager = FeedStateStore.shared.stateManager(for: newFeedType, appState: appState)
                    FeedStateStore.shared.attach(newManager)
                    self.stateManager = newManager
                    Task { @MainActor in
                        if newManager.posts.isEmpty { await newManager.loadInitialData() }
                    }
                }
            } else {
                Color.clear
                    .onAppear {
                        // Resolve a per-feed state manager from the shared store
                        let manager = FeedStateStore.shared.stateManager(for: feedType, appState: appState)
                        FeedStateStore.shared.attach(manager)
                        self.stateManager = manager
                    }
            }
        }
        .onAppear {
            if stateManager == nil || stateManager?.isCleanedUp == true {
                let manager = FeedStateStore.shared.stateManager(for: feedType, appState: appState)
                FeedStateStore.shared.attach(manager)
                self.stateManager = manager
            }
        }
    }
}
