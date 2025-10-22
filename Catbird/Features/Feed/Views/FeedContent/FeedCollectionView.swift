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
        // Recreate controller on theme or font change to ensure UIKit reflects updates
        .id("\(ObjectIdentifier(stateManager))-\(stateManager.appState.themeDidChange)-\(stateManager.appState.fontDidChange)")
        .themedPrimaryBackground(stateManager.appState.themeManager, appSettings: stateManager.appState.appSettings)
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

// MARK: - Preview Support

#Preview {
    @Previewable @State var navigationPath = NavigationPath()
    
    // Mock state manager for preview
    let mockFeedManager = FeedManager(
        client: AppState.shared.atProtoClient,
        fetchType: .timeline
    )
    
    let mockFeedModel = FeedModel(
        feedManager: mockFeedManager,
        appState: AppState.shared
    )
    
    let mockStateManager = FeedStateManager(
        appState: AppState.shared,
        feedModel: mockFeedModel,
        feedType: .timeline
    )
    
    NavigationStack(path: $navigationPath) {
        FeedCollectionView(
            stateManager: mockStateManager,
            navigationPath: $navigationPath
        )
        .navigationTitle("Feed")
    #if os(iOS)
    .toolbarTitleDisplayMode(.large)
    #endif
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
        if var stateManager = stateManager {
            FeedCollectionView(
                stateManager: stateManager,
                navigationPath: $navigationPath
            )
            .themedPrimaryBackground(stateManager.appState.themeManager, appSettings: stateManager.appState.appSettings)
            .task {
                if !isInitialized {
                    isInitialized = true
                    await stateManager.loadInitialData()
                }
            }
            .onChange(of: feedType) { oldFeedType, newFeedType in
                // Disable feedback for the old feed before switching
                appState.feedFeedbackManager.disable()
                
                // Switch to a dedicated manager per feed to keep per-feed scroll state
                let newManager = FeedStateStore.shared.stateManager(for: newFeedType, appState: appState)
                stateManager = newManager
                Task { @MainActor in
                    if newManager.posts.isEmpty { await newManager.loadInitialData() }
                }
            }
        } else {
            Color.clear
                .onAppear {
                    // Resolve a per-feed state manager from the shared store
                    self.stateManager = FeedStateStore.shared.stateManager(for: feedType, appState: appState)
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
        if var stateManager = stateManager {
            FeedCollectionView(
                stateManager: stateManager,
                navigationPath: $navigationPath
            )
            .themedPrimaryBackground(stateManager.appState.themeManager, appSettings: stateManager.appState.appSettings)
            .task {
                if !isInitialized {
                    isInitialized = true
                    await stateManager.loadInitialData()
                }
            }
            .onChange(of: feedType) { oldFeedType, newFeedType in
                // Disable feedback for the old feed before switching
                appState.feedFeedbackManager.disable()
                
                // Switch to the store-managed manager for the new feed
                let newManager = FeedStateStore.shared.stateManager(for: newFeedType, appState: appState)
                stateManager = newManager
                Task { @MainActor in
                    if newManager.posts.isEmpty { await newManager.loadInitialData() }
                }
            }
        } else {
            Color.clear
                .onAppear {
                    // Resolve a per-feed state manager from the shared store
                    self.stateManager = FeedStateStore.shared.stateManager(for: feedType, appState: appState)
                }
        }
    }
}
