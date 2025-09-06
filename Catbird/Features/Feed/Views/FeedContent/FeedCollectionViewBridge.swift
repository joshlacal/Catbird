//
//  FeedCollectionViewBridge.swift
//  Catbird
//
//  Bridge to seamlessly integrate the optimized feed controller with existing SwiftUI views
//

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import os

#if os(iOS)
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
        
        // Theme updates are handled by the UIKitStateObserver<ThemeManager> in the controller
        // No need to force theme updates here - they happen automatically when theme properties change
    }
}

#else
/// macOS stub for FeedCollectionViewIntegrated
@available(macOS 13.0, *)
struct FeedCollectionViewIntegrated: View {
    @Bindable var stateManager: FeedStateManager
    @Binding var navigationPath: NavigationPath
    var onScrollOffsetChanged: ((CGFloat) -> Void)?
    
    var body: some View {
        VStack {
            Text("Feed collection view not available on macOS")
                .foregroundColor(.secondary)
            Text("Using fallback SwiftUI implementation")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
#endif

// MARK: - Controller Configuration

/// Configuration for feed controller features
struct FeedControllerConfiguration {
    /// Whether UIUpdateLink optimizations are available (iOS 18+ native, not Mac Catalyst)
    static var hasUIUpdateLinkSupport: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 18.0, *) {
            return true
        }
        #endif
        return false
    }
}



#if os(iOS)
// MARK: - Drop-in Replacement

/// Drop-in replacement for existing FeedCollectionView usage
@available(iOS 16.0, *)
struct FeedCollectionViewWrapper: View {
    @Bindable var stateManager: FeedStateManager
    @Binding var navigationPath: NavigationPath
    var onScrollOffsetChanged: ((CGFloat) -> Void)?
    
    var body: some View {
        FeedCollectionViewIntegrated(
            stateManager: stateManager,
            navigationPath: $navigationPath,
            onScrollOffsetChanged: onScrollOffsetChanged
        )
    }
}
#else
// MARK: - macOS Implementation

/// macOS implementation using native SwiftUI List
@available(macOS 13.0, *)
struct FeedCollectionViewWrapper: View {
    @Bindable var stateManager: FeedStateManager
    @Binding var navigationPath: NavigationPath
    var onScrollOffsetChanged: ((CGFloat) -> Void)?
    
    var body: some View {
        VStack {
            if stateManager.posts.isEmpty && stateManager.isLoading {
                // Initial loading state
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading feed...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if stateManager.posts.isEmpty && !stateManager.isLoading {
                // Empty state
                VStack(spacing: 16) {
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No posts yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Button("Refresh") {
                        Task {
                            await stateManager.refresh()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Content list - use explicit ForEach to avoid generic confusion
                List {
                    ForEach(stateManager.posts, id: \.id) { cachedPost in
                        FeedPostRow(
                            viewModel: stateManager.viewModel(for: cachedPost),
                            navigationPath: $navigationPath
                        )
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .onAppear {
                            // Trigger load more when nearing end (last 5 items)
                            if let lastIndex = stateManager.posts.lastIndex(where: { $0.id == cachedPost.id }),
                               lastIndex >= stateManager.posts.count - 5,
                               !stateManager.isLoading {
                                Task {
                                    await stateManager.loadMore()
                                }
                            }
                        }
                    }
                    
                    if stateManager.isLoading {
                        HStack {
                            Spacer()
                            ProgressView("Loading more...")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .padding(.vertical, 8)
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await stateManager.refresh()
                }
            }
        }
        .task {
            // Always try to load initial data if posts are empty
            if stateManager.posts.isEmpty {
                await stateManager.loadInitialData()
            }
        }
    }
}
#endif

// MARK: - Legacy Support

#if os(iOS)
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
#else
/// macOS stub for FeedCollectionViewLegacy
@available(macOS 13.0, *)
struct FeedCollectionViewLegacy: View {
    @Bindable var stateManager: FeedStateManager
    @Binding var navigationPath: NavigationPath
    var onScrollOffsetChanged: ((CGFloat) -> Void)?
    
    var body: some View {
        VStack {
            Text("Legacy feed collection view not available on macOS")
                .foregroundColor(.secondary)
            Text("Using fallback SwiftUI implementation")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
#endif
