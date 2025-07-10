import SwiftUI
import OSLog
import Petrel

// MARK: - Feed Continuity Indicator Types

enum FeedContinuityType {
  case newContentAvailable(count: Int)
  case loadingGap
  case connectionRestored
  case cacheFallback
}

// MARK: - Feed Continuity Banner

struct FeedContinuityBanner: View {
  let type: FeedContinuityType
  let onTap: (() -> Void)?
  let onDismiss: (() -> Void)?
  
  @Environment(AppState.self) private var appState: AppState
  @State private var isVisible = true
  
  var body: some View {
    if isVisible {
      bannerContent
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(bannerBackground)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .transition(.asymmetric(
          insertion: .opacity.combined(with: .move(edge: .top)),
          removal: .opacity.combined(with: .move(edge: .top))
        ))
        .animation(.easeInOut(duration: 0.3), value: isVisible)
        .onTapGesture {
          onTap?()
        }
        .onAppear {
          // Auto-dismiss after delay for certain types
          if shouldAutoDismiss {
            DispatchQueue.main.asyncAfter(deadline: .now() + autodismissDelay) {
              dismissBanner()
            }
          }
        }
    }
  }
  
  @ViewBuilder
  private var bannerContent: some View {
    HStack(spacing: 12) {
      bannerIcon
      
      VStack(alignment: .leading, spacing: 2) {
        Text(bannerTitle)
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(bannerTextColor)
        
        if let subtitle = bannerSubtitle {
          Text(subtitle)
            .font(.system(size: 12))
            .foregroundColor(bannerTextColor.opacity(0.8))
        }
      }
      
      Spacer()
      
      if let onDismiss = onDismiss {
        Button(action: { dismissBanner() }) {
          Image(systemName: "xmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(bannerTextColor.opacity(0.6))
        }
      }
      
      if onTap != nil {
        Image(systemName: "chevron.up")
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(bannerTextColor.opacity(0.6))
      }
    }
  }
  
  @ViewBuilder
  private var bannerIcon: some View {
    switch type {
    case .newContentAvailable:
      Image(systemName: "arrow.clockwise")
        .font(.system(size: 16, weight: .medium))
        .foregroundColor(bannerTextColor)
        
    case .loadingGap:
      ProgressView()
        .scaleEffect(0.8)
        .tint(bannerTextColor)
        
    case .connectionRestored:
      Image(systemName: "wifi")
        .font(.system(size: 16, weight: .medium))
        .foregroundColor(bannerTextColor)
        
    case .cacheFallback:
      Image(systemName: "clock.arrow.circlepath")
        .font(.system(size: 16, weight: .medium))
        .foregroundColor(bannerTextColor)
    }
  }
  
  private var bannerTitle: String {
    switch type {
    case .newContentAvailable(let count):
      return count == 1 ? "New post available" : "\(count) new posts available"
    case .loadingGap:
      return "Loading..."
    case .connectionRestored:
      return "Connection restored"
    case .cacheFallback:
      return "Showing cached content"
    }
  }
  
  private var bannerSubtitle: String? {
    switch type {
    case .newContentAvailable:
      return "Tap to scroll to top"
    case .loadingGap:
      return "Fetching latest posts"
    case .connectionRestored:
      return "Refreshing feed"
    case .cacheFallback:
      return "Pull to refresh when online"
    }
  }
  
  private var bannerBackground: some View {
    switch type {
    case .newContentAvailable:
      Color.blue
    case .loadingGap:
      Color.orange.opacity(0.9)
    case .connectionRestored:
      Color.green
    case .cacheFallback:
      Color.gray.opacity(0.8)
    }
  }
  
  private var bannerTextColor: Color {
    .white
  }
  
  private var shouldAutoDismiss: Bool {
    switch type {
    case .connectionRestored, .loadingGap:
      return true
    case .newContentAvailable, .cacheFallback:
      return false
    }
  }
  
  private var autodismissDelay: TimeInterval {
    switch type {
    case .connectionRestored:
      return 3.0
    case .loadingGap:
      return 10.0
    default:
      return 0
    }
  }
  
  private func dismissBanner() {
    withAnimation(.easeInOut(duration: 0.3)) {
      isVisible = false
    }
    
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      onDismiss?()
    }
  }
}

// MARK: - Feed Gap Indicator

struct FeedGapIndicator: View {
  let onLoadGap: () -> Void
  @State private var isLoading = false
  
  var body: some View {
    VStack(spacing: 8) {
      Divider()
        .background(Color.gray.opacity(0.3))
      
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Some posts may be missing")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.secondary)
          
          Text("Tap to load missing content")
            .font(.system(size: 12))
            .foregroundColor(.secondary)
        }
        
        Spacer()
        
        if isLoading {
          ProgressView()
            .scaleEffect(0.8)
        } else {
          Button("Load") {
            loadGap()
          }
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(.blue)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(Color.gray.opacity(0.05))
      .cornerRadius(8)
      .padding(.horizontal, 16)
      
      Divider()
        .background(Color.gray.opacity(0.3))
    }
  }
  
  private func loadGap() {
    isLoading = true
    onLoadGap()
    
    // Reset loading state after delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
      isLoading = false
    }
  }
}

// MARK: - Feed Continuity Manager

@Observable
final class FeedContinuityManager {
  private let logger = Logger(
    subsystem: "blue.catbird", 
    category: "FeedContinuity"
  )
  
  private let persistentManager = PersistentFeedStateManager.shared
  
  // Current state
  var currentBanner: FeedContinuityType?
  var showingBanner = false
  var detectedGaps: [String] = [] // Post IDs where gaps are detected
  
  // Timing tracking
  private var lastNetworkCheck = Date.distantPast
  private var lastBannerShow = Date.distantPast
  
  func checkForNewContent(
    currentPosts: [CachedFeedViewPost],
    feedIdentifier: String,
    onNewContentFound: @escaping (Int) -> Void
  ) {
    guard let continuityInfo = persistentManager.loadFeedContinuityInfo(for: feedIdentifier) else {
      logger.debug("No continuity info for \(feedIdentifier)")
      return
    }
    
    // Check if we have new content at the top
    if let lastKnownTopId = continuityInfo.lastKnownTopPostId,
       let currentTopPost = currentPosts.first,
       currentTopPost.id != lastKnownTopId {
      
      // Count how many new posts we have
      var newPostCount = 0
      for post in currentPosts {
        if post.id == lastKnownTopId {
          break
        }
        newPostCount += 1
      }
      
      if newPostCount > 0 {
        logger.debug("Found \(newPostCount) new posts in \(feedIdentifier)")
        onNewContentFound(newPostCount)
      }
    }
  }
  
  func showNewContentBanner(count: Int, onTap: @escaping () -> Void) {
    // Prevent banner spam
    guard Date().timeIntervalSince(lastBannerShow) > 5.0 else { 
      logger.debug("Skipping banner - too soon since last show")
      return 
    }
    
    currentBanner = .newContentAvailable(count: count)
    showingBanner = true
    lastBannerShow = Date()
    
    logger.info("🟦 CONTINUITY: Showing new content banner: \(count) posts, showingBanner=\(self.showingBanner)")
  }
  
  func showConnectionRestoredBanner() {
    currentBanner = .connectionRestored
    showingBanner = true
    lastBannerShow = Date()
    
    logger.debug("Showing connection restored banner")
  }
  
  func showCacheFallbackBanner() {
    currentBanner = .cacheFallback
    showingBanner = true
    lastBannerShow = Date()
    
    logger.debug("Showing cache fallback banner")
  }
  
  func showLoadingGapBanner() {
    currentBanner = .loadingGap
    showingBanner = true
    lastBannerShow = Date()
    
    logger.debug("Showing loading gap banner")
  }
  
  func hideBanner() {
      logger.debug("hideBanner called - was showing: \(self.showingBanner)")
    currentBanner = nil
    showingBanner = false
    
    logger.debug("Continuity banner hidden")
  }
  
  func detectGaps(in posts: [CachedFeedViewPost]) -> [String] {
    // Simple gap detection based on timestamp differences
    var gaps: [String] = []
    
    for i in 0..<(posts.count - 1) {
      let currentPost = posts[i]
      let nextPost = posts[i + 1]
      
      // Check for significant time gaps (>1 hour with <10 posts between)
      let currentTime = currentPost.feedViewPost.post.indexedAt.date
      let nextTime = nextPost.feedViewPost.post.indexedAt.date
      
      let timeDifference = currentTime.timeIntervalSince(nextTime)
      if timeDifference > 3600 && i < 10 { // 1 hour gap in recent posts
        gaps.append(currentPost.id)
        logger.debug("Detected potential gap after post \(currentPost.id)")
      }
    }
    
    detectedGaps = gaps
    return gaps
  }
  
  func updateContinuityInfo(
    for feedIdentifier: String,
    posts: [CachedFeedViewPost],
    hasNewContent: Bool = false
  ) {
    persistentManager.saveFeedContinuityInfo(
      feedIdentifier: feedIdentifier,
      hasNewContent: hasNewContent,
      lastKnownTopPostId: posts.first?.id,
      newPostCount: hasNewContent ? 1 : 0,
      gapDetected: !detectedGaps.isEmpty
    )
    logger.debug("Updated continuity info for \(feedIdentifier)")
  }
}

// MARK: - Feed Continuity View

struct FeedContinuityView: View {
  @Environment(AppState.self) private var appState: AppState
  @Bindable var continuityManager: FeedContinuityManager
  let onBannerTap: (() -> Void)?
  let onGapLoad: (() -> Void)?
  
  var body: some View {
    VStack(spacing: 0) {
      // Top banner for new content, connection status, etc.
      if continuityManager.showingBanner,
         let bannerType = continuityManager.currentBanner {
        FeedContinuityBanner(
          type: bannerType,
          onTap: onBannerTap,
          onDismiss: {
            continuityManager.hideBanner()
          }
        )
      }
      
      // Gap indicators in feed content would be inserted by the feed view
      // when gaps are detected in the post list
    }
    .onAppear {
      print("🟦 FeedContinuityView appeared - showingBanner: \(continuityManager.showingBanner), currentBanner: \(String(describing: continuityManager.currentBanner))")
    }
    .onChange(of: continuityManager.showingBanner) { oldValue, newValue in
      print("🟦 FeedContinuityView showingBanner changed from \(oldValue) to \(newValue)")
    }
  }
}
