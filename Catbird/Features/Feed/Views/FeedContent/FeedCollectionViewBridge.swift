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
    @Environment(SceneNavigationContext.self) private var sceneContext
    @Bindable var stateManager: FeedStateManager
    @Binding var navigationPath: NavigationPath
    var onScrollOffsetChanged: ((CGFloat) -> Void)?
    var headerView: AnyView?
    var trendingContent: TrendingFeedContent
    
    final class Coordinator {
        var lastHeaderPresent: Bool = false
    }
    
    func makeCoordinator() -> Coordinator { Coordinator() }
    
    private let logger = Logger(subsystem: "blue.catbird", category: "FeedCollectionBridge")
    
    func makeUIViewController(context: Context) -> FeedCollectionViewControllerIntegrated {
        logger.debug("🏗️ Creating integrated feed controller")
        
        let controller = FeedCollectionViewControllerIntegrated(
            stateManager: stateManager,
            viewportState: sceneContext.feedViewportStore.state(
                accountDID: sceneContext.accountDID,
                feedIdentifier: stateManager.currentFeedType.identifier),
            sceneContext: sceneContext,
            navigationPath: $navigationPath,
            onScrollOffsetChanged: onScrollOffsetChanged
        )
        // Initial header presence will be applied in viewDidLoad
        
        return controller
    }
    
    func updateUIViewController(_ controller: FeedCollectionViewControllerIntegrated, context: Context) {
        controller.updateSceneContext(sceneContext)
        // Account data and scene viewport must be rebound together so outgoing
        // geometry is never saved into a different window or feed.
        let viewport = sceneContext.feedViewportStore.state(
            accountDID: sceneContext.accountDID,
            feedIdentifier: stateManager.currentFeedType.identifier)
        controller.updateStateManager(stateManager, viewportState: viewport)
        // Update header only when presence changes
        let present = (headerView != nil)
        if present != context.coordinator.lastHeaderPresent {
            controller.setHeaderView(headerView)
            context.coordinator.lastHeaderPresent = present
        }
        controller.setTrendingContent(trendingContent)
        
        // Theme updates are handled by the UIKitStateObserver<ThemeManager> in the controller
        // No need to force theme updates here - they happen automatically when theme properties change
    }
}

#else
/// macOS stub for FeedCollectionViewIntegrated
@available(macOS 13.0, *)
struct FeedCollectionViewIntegrated: View {
    @Environment(SceneNavigationContext.self) private var sceneContext
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
    @Environment(SceneNavigationContext.self) private var sceneContext
    @Environment(\.displayScale) private var displayScale
    @Bindable var stateManager: FeedStateManager
    @Binding var navigationPath: NavigationPath
    var onScrollOffsetChanged: ((CGFloat) -> Void)?
    var headerView: AnyView? = nil

    private var trendingRequestID: String {
        let appState = stateManager.appState
        return "\(appState.userDID ?? "")|\(stateManager.currentFeedType.identifier)|\(appState.appSettings.showTrendingTopics)|\(appState.appSettings.showTrendingVideos)"
    }
    
    var body: some View {
        FeedCollectionViewIntegrated(
            stateManager: stateManager,
            navigationPath: $navigationPath,
            onScrollOffsetChanged: onScrollOffsetChanged,
            headerView: headerView,
            trendingContent: stateManager.trendingContent(for: trendingRequestID)
        )
        .catalystPlainButtons()
        .task(id: trendingRequestID) {
            let feed = stateManager.currentFeedType
            guard feed == .timeline || feed.identifier.contains("discover") || feed.identifier == "timeline" else {
                stateManager.appState.cancelTopicPreviewPrefetch(owner: .timeline)
                return
            }
            await stateManager.loadTrendingIfNeeded(requestID: trendingRequestID, displayScale: displayScale)
        }
        .onDisappear { stateManager.appState.cancelTopicPreviewPrefetch(owner: .timeline) }
    }
}
#else
// MARK: - macOS Implementation

/// macOS implementation using native SwiftUI List
@available(macOS 13.0, *)
struct FeedCollectionViewWrapper: View {
    @Environment(SceneNavigationContext.self) private var sceneContext
    @Environment(\.displayScale) private var displayScale
    @Bindable var stateManager: FeedStateManager
    @Binding var navigationPath: NavigationPath
    var onScrollOffsetChanged: ((CGFloat) -> Void)?
    var headerView: AnyView? = nil

    var body: some View {
        VStack {
            if stateManager.contentState == .error {
                ContentUnavailableStateView(
                    title: "Couldn’t Load Feed",
                    description: stateManager.feedLoadError.flatMap {
                        UserFacingError.message(for: $0, action: "load this feed")
                    } ?? "Couldn’t load this feed. Try again.",
                    systemImage: "wifi.exclamationmark",
                    actionTitle: "Try Again"
                ) {
                    Task { await stateManager.retry() }
                }
            } else if stateManager.contentState == .loading {
                // Includes the interval before the initial task starts.
                LoadingStateView(
                    message: "Loading feed…"
                )
            } else if stateManager.contentState == .empty {
                // A successful request established an empty feed.
                if stateManager.currentFeedType == .timeline {
                    ContentUnavailableStateView.emptyFollowingFeed {
                        // Switch to the Search tab to discover people
                        sceneContext.navigationManager.tabSelection?(1)
                    }
                } else {
                    ContentUnavailableStateView.emptyFeed(
                        feedName: stateManager.currentFeedType.displayName
                    ) {
                        // Refresh action for non-timeline feeds
                        Task { await stateManager.refreshUserInitiated(displayScale: displayScale) }
                    }
                }
            } else {
                // Content list - use explicit ForEach to avoid generic confusion
                List {
                    ForEach(stateManager.posts, id: \.id) { cachedPost in
                        FeedPostRow(
                            viewModel: stateManager.viewModel(for: cachedPost),
                            navigationPath: $navigationPath,
                            feedTypeIdentifier: stateManager.currentFeedType.identifier
                        )
                        .environment(\.feedInteractionTarget, stateManager.feedInteractionTarget)
                        .frame(maxWidth: 700)
                        .frame(maxWidth: .infinity, alignment: .center)
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
                            ProgressView("Loading more…")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(maxWidth: 700)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .padding(.vertical, 8)
                    }
                }
                .listStyle(.plain)
                .contentMargins(.top, 8, for: .scrollContent)
                .refreshable {
                    await stateManager.refreshUserInitiated(displayScale: displayScale)
                }
            }
        }
        .catalystPlainButtons()
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await stateManager.refreshUserInitiated(displayScale: displayScale) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
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
    @Environment(SceneNavigationContext.self) private var sceneContext
    @Bindable var stateManager: FeedStateManager
    @Binding var navigationPath: NavigationPath
    var onScrollOffsetChanged: ((CGFloat) -> Void)?
    
    func makeUIViewController(context: Context) -> FeedCollectionViewControllerIntegrated {
        // Use integrated controller as the only implementation
        FeedCollectionViewControllerIntegrated(
            stateManager: stateManager,
            viewportState: sceneContext.feedViewportStore.state(
                accountDID: sceneContext.accountDID,
                feedIdentifier: stateManager.currentFeedType.identifier),
            sceneContext: sceneContext,
            navigationPath: $navigationPath,
            onScrollOffsetChanged: onScrollOffsetChanged
        )
    }
    
    func updateUIViewController(_ controller: FeedCollectionViewControllerIntegrated, context: Context) {
        controller.updateSceneContext(sceneContext)
        controller.updateStateManager(stateManager, viewportState: sceneContext.feedViewportStore.state(
            accountDID: sceneContext.accountDID,
            feedIdentifier: stateManager.currentFeedType.identifier))
    }
}
#else
/// macOS stub for FeedCollectionViewLegacy
@available(macOS 13.0, *)
struct FeedCollectionViewLegacy: View {
    @Environment(SceneNavigationContext.self) private var sceneContext
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
