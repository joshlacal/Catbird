import UIKit
import SwiftUI
import Petrel
import OSLog

@available(iOS 18.0, *)
final class FeedHeaderCell: UICollectionViewCell {
  private var currentFetchType: FetchType?
  private var feedGeneratorView: AppBskyFeedDefs.GeneratorView?
  private var loadingTask: Task<Void, Never>?
  private var isDiscoveryContext: Bool = false
  private var shouldKeepVisible: Bool = false
  private var keepVisibleUntil: Date?
  
  override init(frame: CGRect) {
    super.init(frame: frame)
    setupCell()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func prepareForReuse() {
    super.prepareForReuse()
    // Cancel any ongoing loading task
    loadingTask?.cancel()
    loadingTask = nil
    currentFetchType = nil
    feedGeneratorView = nil
    contentConfiguration = nil
    isDiscoveryContext = false
    shouldKeepVisible = false
    keepVisibleUntil = nil
  }
  
  private func setupCell() {
    // Configure cell appearance
    backgroundColor = .clear
    
    // Configure for better performance
    layer.shouldRasterize = false
    isOpaque = false
    
    // CRITICAL: Enable user interaction at all levels for touch events to work
    isUserInteractionEnabled = true
    contentView.isUserInteractionEnabled = true
    
    // Ensure the cell doesn't interfere with touch handling
    clipsToBounds = false
    contentView.clipsToBounds = false
    
    // Enable automatic content configuration updates
    automaticallyUpdatesContentConfiguration = false
    
    // Additional touch handling configuration
    contentView.backgroundColor = .clear
  }

  func configure(fetchType: FetchType, appState: AppState, isDiscoveryContext: Bool = false) {
    // Store the fetch type for comparison
    currentFetchType = fetchType
    self.isDiscoveryContext = isDiscoveryContext
    
    // Set themed background color
    let currentScheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
    let effectiveScheme = appState.themeManager.effectiveColorScheme(for: currentScheme)
    contentView.backgroundColor = UIColor(Color.dynamicBackground(appState.themeManager, currentScheme: effectiveScheme))
    
    // Show header if in discovery context OR if it's a discovery feed (not pinned/saved) OR if we should keep it visible temporarily
    if isDiscoveryContext || shouldKeepVisible || shouldShowHeaderForFeed(fetchType: fetchType, appState: appState) {
      // Show loading state initially
      showLoadingState()
      
      // Load feed generator data asynchronously
      loadingTask = Task { @MainActor in
        await loadFeedGeneratorData(fetchType: fetchType, appState: appState)
      }
    } else {
      // Hide the header by setting empty content
      hideHeader()
    }
  }
  
  private func showLoadingState() {
    let loadingView = AnyView(
      HStack(spacing: 12) {
        // Loading placeholder
        RoundedRectangle(cornerRadius: 8)
          .fill(Color.gray.opacity(0.2))
          .frame(width: 48, height: 48)
          .shimmering()
        
        VStack(alignment: .leading, spacing: 6) {
          RoundedRectangle(cornerRadius: 4)
            .fill(Color.gray.opacity(0.2))
            .frame(width: 150, height: 16)
            .shimmering()
          
          RoundedRectangle(cornerRadius: 4)
            .fill(Color.gray.opacity(0.2))
            .frame(width: 100, height: 12)
            .shimmering()
        }
        
        Spacer()
      }
      .padding()
    )
    
    // Use UIHostingConfiguration with better touch handling setup
    contentConfiguration = UIHostingConfiguration {
      loadingView
    }
    .margins(.all, .zero)
  }
  
  private func hideHeader() {
    contentConfiguration = UIHostingConfiguration {
      EmptyView()
    }
    .margins(.all, .zero)
  }
  
  @MainActor
  private func loadFeedGeneratorData(fetchType: FetchType, appState: AppState) async {
    // Only load for custom feeds
    guard case .feed(let uri) = fetchType else {
      hideHeader()
      return
    }
    
    guard let client = appState.atProtoClient else {
      logger.warning("No AT Protocol client available")
      hideHeader()
      return
    }
    
    do {
      // Check if task was cancelled
      if Task.isCancelled { return }
      
      // Fetch the feed generator data
      let params = AppBskyFeedGetFeedGenerator.Parameters(feed: uri)
      let (code, response) = try await client.app.bsky.feed.getFeedGenerator(input: params)
      
      // Check if task was cancelled before updating UI
      if Task.isCancelled { return }
      
      if code == 200, let generatorResponse = response {
        self.feedGeneratorView = generatorResponse.view
        
        // Check subscription status
        let preferences = try? appState.preferencesManager.getLocalPreferences()
        let isSubscribed = preferences?.savedFeeds.contains(uri.uriString()) ?? false ||
                          preferences?.pinnedFeeds.contains(uri.uriString()) ?? false
        
        // Update UI with the discovery header
        showDiscoveryHeader(
          feed: generatorResponse.view,
          isSubscribed: isSubscribed,
          appState: appState
        )
      } else {
        logger.warning("Failed to fetch feed generator: HTTP \(code)")
        hideHeader()
      }
    } catch {
      if !Task.isCancelled {
        logger.error("Error loading feed generator: \(error)")
        hideHeader()
      }
    }
  }
  
  private func showDiscoveryHeader(feed: AppBskyFeedDefs.GeneratorView, isSubscribed: Bool, appState: AppState) {
    // Use UIHostingConfiguration - this is the correct approach for collection view cells
    // IMPORTANT: Don't wrap in AnyView as it can interfere with touch handling
    var config = UIHostingConfiguration {
      FeedDiscoveryHeaderView(
        feed: feed,
        isSubscribed: isSubscribed,
        onSubscriptionToggle: { [weak self] in
          await self?.handleSubscriptionToggle(feed: feed, appState: appState)
        }
      )
      .environment(appState)
    }
    .margins(.all, .zero)
    .background(.clear) // Ensure transparent background doesn't block touches
    
    // CRITICAL: Apply the configuration and force layout update
    contentConfiguration = config
    setNeedsLayout()
    layoutIfNeeded()
  }
  
  @MainActor
  private func handleSubscriptionToggle(feed: AppBskyFeedDefs.GeneratorView, appState: AppState) async {
    do {
      let preferences = try await appState.preferencesManager.getPreferences()
      var updatedSavedFeeds = preferences.savedFeeds
      let feedUri = feed.uri.uriString()
      
      if updatedSavedFeeds.contains(feedUri) {
        // Unsubscribe
        updatedSavedFeeds.removeAll { $0 == feedUri }
      } else {
        // Subscribe
        updatedSavedFeeds.append(feedUri)
      }
      
      // Update preferences
      try await appState.preferencesManager.updatePreferences(
        savedFeeds: updatedSavedFeeds,
        pinnedFeeds: preferences.pinnedFeeds
      )
      
      logger.info("Toggled subscription for feed: \(feedUri)")
      
      // Keep header visible for 3 seconds after subscription to show the updated state
      shouldKeepVisible = true
      keepVisibleUntil = Date().addingTimeInterval(3.0)
      
      // Notify state invalidation bus that feeds have changed
    appState.stateInvalidationBus.notify(.feedListChanged)
      
      // Refresh the header to show updated state (maintain discovery context)
      if let fetchType = currentFetchType {
        configure(fetchType: fetchType, appState: appState, isDiscoveryContext: isDiscoveryContext)
      }
      
      // After 3 seconds, hide the header and refresh the view
      Task {
        try? await Task.sleep(for: .seconds(3))
        await MainActor.run {
          shouldKeepVisible = false
          if let fetchType = currentFetchType {
            configure(fetchType: fetchType, appState: appState, isDiscoveryContext: isDiscoveryContext)
          }
        }
      }
      
    } catch {
      logger.error("Failed to toggle subscription: \(error)")
    }
  }
  
  /// Determines if header should be shown for this feed type
  private func shouldShowHeaderForFeed(fetchType: FetchType, appState: AppState) -> Bool {
    // Only show header for custom feeds
    guard case .feed(let uri) = fetchType else {
      return false
    }
    
    // Check if we should keep visible due to recent subscription change
    if let keepUntil = keepVisibleUntil, Date() < keepUntil {
      return true
    }
    
    // Try to get preferences synchronously (uses cache if available)
    do {
      guard let preferences = try appState.preferencesManager.getLocalPreferences() else {
        // If no preferences available, default to showing header (discovery mode)
        logger.debug("No preferences available for \(uri.uriString()), showing header")
        return true
      }
      
      let feedUri = uri.uriString()
      
      // Check if feed is pinned or saved
      let isPinned = preferences.pinnedFeeds.contains(feedUri)
      let isSaved = preferences.savedFeeds.contains(feedUri)
      
      let shouldShow = !isPinned && !isSaved
      
      logger.debug("""
        Feed header check for \(feedUri):
        - isPinned: \(isPinned)
        - isSaved: \(isSaved)
        - shouldShow: \(shouldShow)
        - keepVisible: \(self.shouldKeepVisible)
      """)
      
      // Only show header for feeds that are NOT pinned or saved (discovery feeds)
      return shouldShow
      
    } catch {
      // If there's an error accessing preferences, default to showing header
      logger.warning("Error accessing preferences for \(uri.uriString()): \(error), showing header")
      return true
    }
  }
}


private struct ShimmeringModifier: ViewModifier {
  @State private var phase: CGFloat = 0
  
  func body(content: Content) -> some View {
    content
      .overlay(
        LinearGradient(
          gradient: Gradient(colors: [
            Color.clear,
            Color.white.opacity(0.3),
            Color.clear
          ]),
          startPoint: .leading,
          endPoint: .trailing
        )
        .offset(x: phase * 200 - 100)
        .mask(content)
      )
      .onAppear {
        withAnimation(
          Animation.linear(duration: 1.2)
            .repeatForever(autoreverses: false)
        ) {
          phase = 1
        }
      }
  }
}
