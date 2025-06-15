import Foundation
import UIKit
import os

// MARK: - Smart Tab Handler

/// Provides intelligent tab tap behavior based on user context and feed state
final class SmartTabHandler {
  private let logger = Logger(subsystem: "blue.catbird", category: "SmartTabHandler")
  
  // MARK: - Tab Action Types
  
  enum TabAction {
    case scrollToTop
    case refresh
    case scrollToTopThenRefresh
    case noAction
  }
  
  struct TabTapContext {
    let isAtTop: Bool
    let timeSinceLastRefresh: TimeInterval
    let timeSinceLastTap: TimeInterval
    let userActivityState: UserActivityTracker.ActivityState
    let hasPendingContent: Bool
    let scrollPosition: CGFloat
    let contentHeight: CGFloat
  }
  
  // MARK: - Properties
  
  private var lastTabTapTime = Date.distantPast
  private var lastRefreshTime = Date.distantPast
  private var consecutiveTapCount = 0
  private let consecutiveTapWindow: TimeInterval = 2.0 // 2 seconds for multi-tap detection
  
  // Configuration
  private let minimumRefreshInterval: TimeInterval = 30.0 // 30 seconds between auto-refreshes
  private let atTopThreshold: CGFloat = 100.0 // Consider "at top" if within 100pts
  private let quickTapWindow: TimeInterval = 1.0 // Quick double-tap window
  
  // MARK: - Public Methods
  
  /// Determine the appropriate action for a tab tap based on context
  @MainActor
  func determineTabAction(
    scrollView: UIScrollView,
    userActivity: UserActivityTracker,
    backgroundLoader: BackgroundFeedLoader,
    fetchType: FetchType,
    lastRefreshTime: Date? = nil
  ) -> TabAction {
    let now = Date()
    let timeSinceLastTap = now.timeIntervalSince(lastTabTapTime)
    
    // Update consecutive tap tracking
    if timeSinceLastTap < consecutiveTapWindow {
      consecutiveTapCount += 1
    } else {
      consecutiveTapCount = 1
    }
    
    // Create context
    let context = TabTapContext(
      isAtTop: userActivity.isAtTop(scrollView: scrollView, threshold: atTopThreshold),
      timeSinceLastRefresh: lastRefreshTime.map { now.timeIntervalSince($0) } ?? .infinity,
      timeSinceLastTap: timeSinceLastTap,
      userActivityState: userActivity.activityState,
      hasPendingContent: backgroundLoader.hasPendingContent(for: fetchType),
      scrollPosition: scrollView.contentOffset.y,
      contentHeight: scrollView.contentSize.height
    )
    
    // Determine action
    let action = calculateTabAction(context: context)
    
    // Update tracking
    lastTabTapTime = now
    if case .refresh = action {
      self.lastRefreshTime = now
    } else if case .scrollToTopThenRefresh = action {
      self.lastRefreshTime = now
    }
    
    logger.info("Tab tap action determined: \(String(describing: action)) (taps: \(self.consecutiveTapCount), atTop: \(context.isAtTop), hasPending: \(context.hasPendingContent))")
    
    return action
  }
  
  /// Handle tab tap with the determined action
  func handleTabTap(
    action: TabAction,
    scrollView: UIScrollView,
    backgroundLoader: BackgroundFeedLoader,
    fetchType: FetchType,
    onRefresh: @escaping () async -> Void,
    onScrollToTop: @escaping () -> Void
  ) async {
    switch action {
    case .scrollToTop:
      onScrollToTop()
      
    case .refresh:
      await onRefresh()
      
    case .scrollToTopThenRefresh:
      onScrollToTop()
      // Small delay to let scroll animation start
      try? await Task.sleep(for: .milliseconds(100))
      await onRefresh()
      
    case .noAction:
      logger.debug("No action taken for tab tap")
    }
  }
  
  /// Reset state (e.g., when switching feeds)
  func reset() {
    consecutiveTapCount = 0
    lastTabTapTime = Date.distantPast
    lastRefreshTime = Date.distantPast
    logger.debug("SmartTabHandler reset")
  }
  
  /// Update last refresh time (called when refresh happens from other sources)
  func markRefreshCompleted() {
    lastRefreshTime = Date()
  }
  
  // MARK: - Private Methods
  
  private func calculateTabAction(context: TabTapContext) -> TabAction {
    // Priority 1: Handle multiple taps
    if consecutiveTapCount > 1 {
      return handleMultipleTaps(context: context)
    }
    
    // Priority 2: User is at top
    if context.isAtTop {
      return handleAtTopTap(context: context)
    }
    
    // Priority 3: User is scrolled down
    return handleScrolledDownTap(context: context)
  }
  
  private func handleMultipleTaps(context: TabTapContext) -> TabAction {
    switch consecutiveTapCount {
    case 2:
      // Second tap: If first tap scrolled to top, now refresh
      if context.isAtTop {
        return shouldRefresh(context: context) ? .refresh : .noAction
      } else {
        // If still not at top, continue scrolling
        return .scrollToTop
      }
      
    case 3:
      // Third tap: Force refresh regardless of timing
      return context.isAtTop ? .refresh : .scrollToTopThenRefresh
      
    default:
      // Too many taps, ignore
      return .noAction
    }
  }
  
  private func handleAtTopTap(context: TabTapContext) -> TabAction {
    // User is already at top, check if we should refresh
    if shouldRefresh(context: context) {
      return .refresh
    } else {
      // Too soon to refresh, but still acknowledge the tap
      logger.debug("At top but too soon to refresh (last refresh: \(context.timeSinceLastRefresh)s ago)")
      return .noAction
    }
  }
  
  private func handleScrolledDownTap(context: TabTapContext) -> TabAction {
    // User is scrolled down, primary action is to scroll to top
    
    // Check if we have pending content and user might want it
    if context.hasPendingContent && 
       context.userActivityState == .idle &&
       context.timeSinceLastRefresh > minimumRefreshInterval {
      // User might want to see new content, scroll to top and refresh
      return .scrollToTopThenRefresh
    } else {
      // Just scroll to top
      return .scrollToTop
    }
  }
  
  private func shouldRefresh(context: TabTapContext) -> Bool {
    // Don't refresh if user is actively reading
    if context.userActivityState == .activeScrolling || 
       context.userActivityState == .readingEngaged {
      return false
    }
    
    // Don't refresh too frequently
    if context.timeSinceLastRefresh < minimumRefreshInterval {
      return false
    }
    
    // Refresh if we have pending content or enough time has passed
    return context.hasPendingContent || context.timeSinceLastRefresh > 60.0
  }
}

// MARK: - Tab Action Extensions

extension SmartTabHandler.TabAction: CustomStringConvertible {
  var description: String {
    switch self {
    case .scrollToTop:
      return "scrollToTop"
    case .refresh:
      return "refresh"
    case .scrollToTopThenRefresh:
      return "scrollToTopThenRefresh"
    case .noAction:
      return "noAction"
    }
  }
}

// MARK: - Smart Tab Coordinator

/// Coordinates smart tab behavior across the entire app
@MainActor
final class SmartTabCoordinator: ObservableObject {
  private let logger = Logger(subsystem: "blue.catbird", category: "SmartTabCoordinator")
  
  // MARK: - Properties
  
  private var tabHandlers: [Int: SmartTabHandler] = [:]
  private let appState: AppState
  
  // MARK: - Initialization
  
  init(appState: AppState) {
    self.appState = appState
  }
  
  // MARK: - Public Methods
  
  /// Get or create a tab handler for a specific tab index
  func getTabHandler(for tabIndex: Int) -> SmartTabHandler {
    if let existing = tabHandlers[tabIndex] {
      return existing
    }
    
    let handler = SmartTabHandler()
    tabHandlers[tabIndex] = handler
    return handler
  }
  
  /// Handle tab tap for the home feed (tab index 0)
  func handleHomeFeedTabTap(
    scrollView: UIScrollView,
    userActivity: UserActivityTracker,
    backgroundLoader: BackgroundFeedLoader,
    fetchType: FetchType,
    lastRefreshTime: Date?,
    onRefresh: @escaping () async -> Void,
    onScrollToTop: @escaping () -> Void
  ) async {
    let handler = getTabHandler(for: 0)
    
    let action = handler.determineTabAction(
      scrollView: scrollView,
      userActivity: userActivity,
      backgroundLoader: backgroundLoader,
      fetchType: fetchType,
      lastRefreshTime: lastRefreshTime
    )
    
    await handler.handleTabTap(
      action: action,
      scrollView: scrollView,
      backgroundLoader: backgroundLoader,
      fetchType: fetchType,
      onRefresh: onRefresh,
      onScrollToTop: onScrollToTop
    )
  }
  
  /// Reset all tab handlers
  func resetAllHandlers() {
    for handler in tabHandlers.values {
      handler.reset()
    }
    logger.debug("Reset all tab handlers")
  }
  
  /// Reset handler for specific tab
  func resetHandler(for tabIndex: Int) {
    tabHandlers[tabIndex]?.reset()
    logger.debug("Reset tab handler for tab \(tabIndex)")
  }
}
