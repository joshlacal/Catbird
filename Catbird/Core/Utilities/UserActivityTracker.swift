import Foundation
import UIKit
import os

// MARK: - User Activity Tracker

/// Tracks user scroll behavior and reading patterns to provide context-aware UX
final class UserActivityTracker {
  private let logger = Logger(subsystem: "blue.catbird", category: "UserActivityTracker")
  
  // MARK: - Activity State
  
  enum ActivityState {
    case idle
    case activeScrolling
    case readingEngaged
    case quickNavigation
  }
  
  struct ScrollMetrics {
    let velocity: CGFloat
    let direction: ScrollDirection
    let timestamp: Date
    let position: CGFloat
  }
  
  enum ScrollDirection {
    case up
    case down
    case stationary
  }
  
  // MARK: - Properties
  
  private var lastScrollTime = Date.distantPast
  private var lastScrollPosition: CGFloat = 0
  private var scrollVelocityHistory: [CGFloat] = []
  private var positionDwellTimes: [CGFloat: TimeInterval] = [:]
  private var currentActivityState: ActivityState = .idle
  private var lastSignificantScrollTime = Date.distantPast
  
  // Thresholds for activity detection
  private let activeScrollingThreshold: TimeInterval = 0.5 // Recent scroll activity
  private let engagedReadingThreshold: TimeInterval = 3.0 // Dwelling at position
  private let quickNavigationVelocityThreshold: CGFloat = 1000.0 // Fast scrolling
  private let significantScrollDistanceThreshold: CGFloat = 100.0 // Meaningful scroll distance
  
  // MARK: - Public Properties
  
  /// Current user activity state
  var activityState: ActivityState {
    updateActivityState()
    return currentActivityState
  }
  
  /// Whether user is actively engaged in reading (not suitable for interruption)
  var isActivelyReading: Bool {
    let state = activityState
    return state == .activeScrolling || state == .readingEngaged
  }
  
  /// Whether user has been idle long enough to show notifications
  var isIdleEnoughForNotifications: Bool {
    Date().timeIntervalSince(lastScrollTime) > activeScrollingThreshold
  }
  
  /// Time since last significant user interaction
  var timeSinceLastInteraction: TimeInterval {
    Date().timeIntervalSince(max(lastScrollTime, lastSignificantScrollTime))
  }
  
  /// Average scroll velocity over recent history
  var averageScrollVelocity: CGFloat {
    guard !scrollVelocityHistory.isEmpty else { return 0 }
    return scrollVelocityHistory.reduce(0, +) / CGFloat(scrollVelocityHistory.count)
  }
  
  // MARK: - Public Methods
  
  /// Update tracking with new scroll information
  func updateScrollActivity(
    scrollView: UIScrollView,
    velocity: CGFloat? = nil
  ) {
    let now = Date()
    let currentPosition = scrollView.contentOffset.y
    let actualVelocity = velocity ?? calculateVelocity(
      from: lastScrollPosition,
      to: currentPosition,
      timeInterval: now.timeIntervalSince(lastScrollTime)
    )
    
    // Update scroll history
    updateScrollHistory(
      position: currentPosition,
      velocity: actualVelocity,
      timestamp: now
    )
    
    // Track significant scroll movements
    let scrollDistance = abs(currentPosition - lastScrollPosition)
    if scrollDistance > significantScrollDistanceThreshold {
      lastSignificantScrollTime = now
    }
    
    // Update position dwell tracking
    updatePositionDwellTime(position: currentPosition, timestamp: now)
    
    // Update state
    lastScrollTime = now
    lastScrollPosition = currentPosition
    
      logger.debug("Scroll activity: position=\(currentPosition), velocity=\(actualVelocity), state=\(String(describing: self.activityState))")
  }
  
  /// Mark explicit user interaction (taps, gestures, etc.)
  func markUserInteraction() {
    let now = Date()
    lastSignificantScrollTime = now
    lastScrollTime = now
    logger.debug("User interaction marked")
  }
  
  /// Reset tracking state (e.g., when switching feeds)
  func reset() {
    lastScrollTime = Date.distantPast
    lastScrollPosition = 0
    scrollVelocityHistory.removeAll()
    positionDwellTimes.removeAll()
    currentActivityState = .idle
    lastSignificantScrollTime = Date.distantPast
    logger.debug("Activity tracker reset")
  }
  
  /// Check if position is considered "at top" for UX purposes
  func isAtTop(scrollView: UIScrollView, threshold: CGFloat = 100) -> Bool {
    let topOffset = -scrollView.adjustedContentInset.top
    return scrollView.contentOffset.y <= topOffset + threshold
  }
  
  /// Check if user is in a good state to show new content notifications
  func shouldShowNewContentIndicator(
    scrollView: UIScrollView,
    distanceFromTop: CGFloat = 300,
    minimumIdleTime: TimeInterval = 2.0
  ) -> Bool {
    // Don't show if user is at the top
    if isAtTop(scrollView: scrollView, threshold: distanceFromTop) {
      return false
    }
    
    // Don't show if user is actively scrolling or engaged
    if self.isActivelyReading {
      return false
    }
    
    // Don't show if user hasn't been idle long enough
    if self.timeSinceLastInteraction < minimumIdleTime {
      return false
    }
    
    return true
  }
  
  // MARK: - Private Methods
  
  private func calculateVelocity(from oldPosition: CGFloat, to newPosition: CGFloat, timeInterval: TimeInterval) -> CGFloat {
    guard timeInterval > 0 else { return 0 }
    return (newPosition - oldPosition) / timeInterval
  }
  
  private func updateScrollHistory(position: CGFloat, velocity: CGFloat, timestamp: Date) {
    // Add velocity to history
    scrollVelocityHistory.append(velocity)
    
    // Keep only recent history (last 10 samples)
    if scrollVelocityHistory.count > 10 {
      scrollVelocityHistory.removeFirst()
    }
  }
  
  private func updatePositionDwellTime(position: CGFloat, timestamp: Date) {
    // Round position to reduce granularity
    let roundedPosition = round(position / 50) * 50
    
    // Update dwell time for this position
    let existingDwellTime = positionDwellTimes[roundedPosition] ?? 0
    positionDwellTimes[roundedPosition] = existingDwellTime + timestamp.timeIntervalSince(lastScrollTime)
    
    // Clean up old positions (keep only recent ones)
    let relevantPositions = Set([
      roundedPosition,
      roundedPosition - 50,
      roundedPosition + 50
    ])
    
    positionDwellTimes = positionDwellTimes.filter { relevantPositions.contains($0.key) }
  }
  
  private func updateActivityState() {
    let now = Date()
    let timeSinceScroll = now.timeIntervalSince(lastScrollTime)
    let currentVelocity = abs(averageScrollVelocity)
    
    // Determine current activity state
    if timeSinceScroll < 0.1 {
      // Very recent scrolling
      if currentVelocity > quickNavigationVelocityThreshold {
        currentActivityState = .quickNavigation
      } else {
        currentActivityState = .activeScrolling
      }
    } else if timeSinceScroll < activeScrollingThreshold {
      // Recent scrolling activity
      currentActivityState = .activeScrolling
    } else {
      // Check if user is engaged at current position
      let currentDwellTime = getCurrentPositionDwellTime()
      if currentDwellTime > engagedReadingThreshold {
        currentActivityState = .readingEngaged
      } else {
        currentActivityState = .idle
      }
    }
  }
  
  private func getCurrentPositionDwellTime() -> TimeInterval {
    let roundedPosition = round(lastScrollPosition / 50) * 50
    return positionDwellTimes[roundedPosition] ?? 0
  }
}

// MARK: - Activity State Extensions

extension UserActivityTracker.ActivityState: CustomStringConvertible {
  var description: String {
    switch self {
    case .idle:
      return "idle"
    case .activeScrolling:
      return "activeScrolling"
    case .readingEngaged:
      return "readingEngaged"
    case .quickNavigation:
      return "quickNavigation"
    }
  }
}
