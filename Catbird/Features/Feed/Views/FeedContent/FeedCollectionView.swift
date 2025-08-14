//
//  FeedCollectionView.swift
//  Catbird
//
//  Created by Claude on 7/18/25.
//
//  SwiftUI integration bridge for UIKit collection view with @Observable state management
//

import SwiftUI
import UIKit
import Petrel
import os

/// SwiftUI wrapper for the feed collection view with automatic controller selection
@available(iOS 16.0, *)
struct FeedCollectionView: View {
    // MARK: - Properties
    
    /// The state manager that coordinates feed data and ViewModels
    @Bindable var stateManager: FeedStateManager
    
    /// Navigation path for SwiftUI navigation
    @Binding var navigationPath: NavigationPath
    
    /// Optional callback for scroll offset changes
    let onScrollOffsetChanged: ((CGFloat) -> Void)?
    
    // MARK: - Initialization
    
    init(
        stateManager: FeedStateManager,
        navigationPath: Binding<NavigationPath>,
        onScrollOffsetChanged: ((CGFloat) -> Void)? = nil
    ) {
        self.stateManager = stateManager
        self._navigationPath = navigationPath
        self.onScrollOffsetChanged = onScrollOffsetChanged
    }
    
    // MARK: - Body
    
    var body: some View {
        // Use the wrapper that automatically selects the appropriate controller
        FeedCollectionViewWrapper(
            stateManager: stateManager,
            navigationPath: $navigationPath,
            onScrollOffsetChanged: onScrollOffsetChanged
        )
        .themedPrimaryBackground(stateManager.appState.themeManager, appSettings: stateManager.appState.appSettings)
    }
}

// MARK: - Convenience Initializers

@available(iOS 16.0, *)
extension FeedCollectionView {
    /// Creates a feed collection view with just the essential parameters
    init(
        stateManager: FeedStateManager,
        navigationPath: Binding<NavigationPath>
    ) {
        self.init(
            stateManager: stateManager,
            navigationPath: navigationPath,
            onScrollOffsetChanged: nil
        )
    }
}

// MARK: - View Modifiers

@available(iOS 16.0, *)
extension FeedCollectionView {
    /// Adds a scroll offset change handler
    func onScrollOffsetChanged(_ handler: @escaping (CGFloat) -> Void) -> FeedCollectionView {
        FeedCollectionView(
            stateManager: stateManager,
            navigationPath: $navigationPath,
            onScrollOffsetChanged: handler
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
        .toolbarTitleDisplayMode(.large)
    }
}

// MARK: - Integration Helper

@available(iOS 16.0, *)
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
@available(iOS 16.0, *)
struct SimpleFeedCollectionWrapper: View {
    let feedType: FetchType
    let appState: AppState
    @Binding var navigationPath: NavigationPath
    
    @State private var stateManager: FeedStateManager?
    @State private var isInitialized = false
    
    var body: some View {
        if let stateManager = stateManager {
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
            .onChange(of: feedType) { newFeedType in
                Task {
                    await stateManager.updateFetchType(newFeedType)
                }
            }
        } else {
            Color.clear
                .onAppear {
                    // Create the state manager
                    let feedManager = FeedManager(
                        client: appState.atProtoClient,
                        fetchType: feedType
                    )
                    
                    let feedModel = FeedModel(
                        feedManager: feedManager,
                        appState: appState
                    )
                    
                    self.stateManager = FeedStateManager(
                        appState: appState,
                        feedModel: feedModel,
                        feedType: feedType
                    )
                }
        }
    }
}

/// Wrapper view that manages feed state and controller persistence
@available(iOS 16.0, *)
struct FeedCollectionWrapper: View {
    let feedType: FetchType
    let appState: AppState
    @Binding var navigationPath: NavigationPath
    
    @State private var stateManager: FeedStateManager?
    @State private var isInitialized = false
    
    var body: some View {
        if let stateManager = stateManager {
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
            .onChange(of: feedType) { newFeedType in
                Task {
                    await stateManager.updateFetchType(newFeedType)
                }
            }
        } else {
            Color.clear
                .onAppear {
                    // Create the state manager
                    let feedManager = FeedManager(
                        client: appState.atProtoClient,
                        fetchType: feedType
                    )
                    
                    let feedModel = FeedModel(
                        feedManager: feedManager,
                        appState: appState
                    )
                    
                    self.stateManager = FeedStateManager(
                        appState: appState,
                        feedModel: feedModel,
                        feedType: feedType
                    )
                }
        }
    }
}
