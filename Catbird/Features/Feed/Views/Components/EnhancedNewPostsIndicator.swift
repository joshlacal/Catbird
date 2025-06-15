import SwiftUI
import Petrel
import os

// MARK: - Enhanced New Posts Indicator

/// A sophisticated new posts indicator that respects user activity and provides contextual information
struct EnhancedNewPostsIndicator: View {
  // MARK: - Properties
  
  let newPostCount: Int
  let authors: [AppBskyActorDefs.ProfileViewBasic]
  let timestamp: Date
  let onTap: () -> Void
  let onDismiss: () -> Void
  
  @Environment(AppState.self) private var appState: AppState
  @State private var isVisible = false
  @State private var dismissTimer: Timer?
  
  // Configuration
  private let maxDisplayedAvatars = 3
  private let autoHideDelay: TimeInterval = 15.0 // 15 seconds
  private let fadeAnimationDuration: Double = 0.3
  
  // MARK: - Computed Properties
  
  private var displayText: String {
    if newPostCount == 1 {
      return "New post"
    } else {
      return "\(newPostCount) new posts"
    }
  }
  
  private var timeAgoText: String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: timestamp, relativeTo: Date())
  }
  
  private var shouldShowTimeStamp: Bool {
    let age = Date().timeIntervalSince(timestamp)
    return age > 60 // Show timestamp if older than 1 minute
  }
  
  // MARK: - View Components
  
  private var avatarStack: some View {
    HStack(spacing: -6) {
      ForEach(Array(authors.prefix(maxDisplayedAvatars).enumerated()), id: \.element.did) { index, author in
        authorAvatar(author: author, index: index)
      }
      
      if authors.count > maxDisplayedAvatars {
        moreAuthorsIndicator
      }
    }
  }
  
  private func authorAvatar(author: AppBskyActorDefs.ProfileViewBasic, index: Int) -> some View {
    AsyncImage(url: author.avatar?.url) { image in
      image
        .resizable()
        .aspectRatio(contentMode: .fill)
    } placeholder: {
      Circle()
        .fill(Color.gray.opacity(0.3))
        .overlay(
          Text(author.displayName ?? author.handle.description)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundColor(.white)
        )
    }
    .frame(width: 26, height: 26)
    .clipShape(Circle())
    .overlay(
      Circle()
        .stroke(Color.white, lineWidth: 2)
    )
    .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
    .zIndex(Double(authors.count - index))
  }
  
  private var moreAuthorsIndicator: some View {
    Circle()
      .fill(Color.blue)
      .frame(width: 26, height: 26)
      .overlay(
        Text("+\(authors.count - maxDisplayedAvatars)")
          .font(.caption2)
          .fontWeight(.bold)
          .foregroundColor(.white)
      )
      .overlay(
        Circle()
          .stroke(Color.white, lineWidth: 2)
      )
      .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
  }
  
  private var contentStack: some View {
    HStack(spacing: 10) {
      avatarStack
      
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(displayText)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
          
          if shouldShowTimeStamp {
            Text("• \(timeAgoText)")
              .font(.system(size: 13, weight: .medium))
              .foregroundColor(.white.opacity(0.8))
          }
        }
        
        if authors.count == 1, let author = authors.first {
          Text("by \(author.displayName ?? author.handle.description)")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(0.9))
            .lineLimit(1)
        } else if authors.count > 1 {
          Text("from \(authors.count) people")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(0.9))
        }
      }
      
      Spacer()
      
      Image(systemName: "arrow.up")
        .font(.system(size: 14, weight: .bold))
        .foregroundColor(.white)
        .padding(.trailing, 2)
    }
  }
  
  private var backgroundShape: some View {
    RoundedRectangle(cornerRadius: 24)
      .fill(
        LinearGradient(
          colors: [Color.blue, Color.blue.opacity(0.9)],
          startPoint: .leading,
          endPoint: .trailing
        )
      )
      .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
      .shadow(color: .blue.opacity(0.3), radius: 4, x: 0, y: 2)
  }
  
  private var dismissButton: some View {
    Button(action: onDismiss) {
      Image(systemName: "xmark")
        .font(.system(size: 12, weight: .bold))
        .foregroundColor(.white.opacity(0.8))
        .frame(width: 20, height: 20)
    }
    .buttonStyle(PlainButtonStyle())
  }
  
  // MARK: - Main Body
  
  var body: some View {
    HStack(spacing: 0) {
      Button(action: onTap) {
        contentStack
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
      }
      .buttonStyle(PlainButtonStyle())
      
      dismissButton
        .padding(.trailing, 12)
    }
    .background(backgroundShape)
    .opacity(isVisible ? 1 : 0)
    .scaleEffect(isVisible ? 1 : 0.85)
    .animation(
      .spring(response: 0.5, dampingFraction: 0.8),
      value: isVisible
    )
    .onAppear {
      startAppearanceAnimation()
      scheduleAutoHide()
    }
    .onDisappear {
      cancelAutoHide()
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(displayText) available. Tap to view.")
    .accessibilityHint("Double tap to scroll to top and view new posts")
  }
  
  // MARK: - Animation Methods
  
  private func startAppearanceAnimation() {
    withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) {
      isVisible = true
    }
  }
  
  private func scheduleAutoHide() {
    cancelAutoHide()
    
    dismissTimer = Timer.scheduledTimer(withTimeInterval: autoHideDelay, repeats: false) { _ in
      hideWithAnimation()
    }
  }
  
  private func cancelAutoHide() {
    dismissTimer?.invalidate()
    dismissTimer = nil
  }
  
  private func hideWithAnimation() {
    withAnimation(.easeOut(duration: fadeAnimationDuration)) {
      isVisible = false
    }
    
    DispatchQueue.main.asyncAfter(deadline: .now() + fadeAnimationDuration) {
      onDismiss()
    }
  }
}

// MARK: - New Posts Indicator Manager

/// Manages the display logic and state for new posts indicators
@MainActor
final class NewPostsIndicatorManager: ObservableObject {
  private let logger = Logger(subsystem: "blue.catbird", category: "NewPostsIndicatorManager")
  
  // MARK: - Indicator State
  
  struct IndicatorState {
    let newPostCount: Int
    let authors: [AppBskyActorDefs.ProfileViewBasic]
    let timestamp: Date
    let feedType: FetchType
    
    var shouldShow: Bool {
      newPostCount > 0 && !authors.isEmpty
    }
    
    var age: TimeInterval {
      Date().timeIntervalSince(timestamp)
    }
    
    var isStale: Bool {
      age > 300 // 5 minutes
    }
  }
  
  // MARK: - Properties
  
  @Published private(set) var currentIndicator: IndicatorState?
  private var showTask: Task<Void, Never>?
  
  // Configuration
  private let minimumDisplayThreshold: CGFloat = 300 // Distance from top to show
  private let minimumIdleTime: TimeInterval = 2.0 // Time user must be idle
  private let debounceDelay: TimeInterval = 1.0 // Delay before showing
  
  // MARK: - Public Methods
  
  /// Attempt to show new posts indicator with smart timing
  func showNewPostsIndicator(
    newPostCount: Int,
    authors: [AppBskyActorDefs.ProfileViewBasic],
    feedType: FetchType,
    userActivity: UserActivityTracker,
    scrollView: UIScrollView
  ) {
    // Cancel any pending show task
    showTask?.cancel()
    
    // Quick validation
    guard newPostCount > 0, !authors.isEmpty else {
      logger.debug("Not showing indicator: no new posts or authors")
      return
    }
    
    // Check if we should show based on user activity and position
    guard userActivity.shouldShowNewContentIndicator(
      scrollView: scrollView,
      distanceFromTop: minimumDisplayThreshold,
      minimumIdleTime: minimumIdleTime
    ) else {
      logger.debug("Not showing indicator: user activity check failed")
      return
    }
    
    // Create indicator state
    let indicatorState = IndicatorState(
      newPostCount: newPostCount,
      authors: authors,
      timestamp: Date(),
      feedType: feedType
    )
    
    // Schedule showing with debounce
    showTask = Task { @MainActor in
      do {
        try await Task.sleep(for: .seconds(debounceDelay))
        
        if !Task.isCancelled {
          // Re-check conditions after debounce
          if userActivity.shouldShowNewContentIndicator(
            scrollView: scrollView,
            distanceFromTop: minimumDisplayThreshold,
            minimumIdleTime: minimumIdleTime
          ) {
            currentIndicator = indicatorState
            logger.info("Showing new posts indicator: \(newPostCount) posts from \(authors.count) authors")
          } else {
            logger.debug("Indicator conditions changed during debounce, not showing")
          }
        }
      } catch {
        // Task was cancelled
        logger.debug("Show indicator task cancelled")
      }
      
      showTask = nil
    }
  }
  
  /// Hide the current indicator
  func hideIndicator() {
    showTask?.cancel()
    showTask = nil
    currentIndicator = nil
    logger.debug("New posts indicator hidden")
  }
  
  /// Update indicator visibility based on scroll position
  func updateVisibilityForScrollPosition(
    userActivity: UserActivityTracker,
    scrollView: UIScrollView
  ) {
    guard let indicator = currentIndicator else { return }
    
    // Hide if user scrolled near top
    if userActivity.isAtTop(scrollView: scrollView, threshold: 150) {
      logger.debug("Hiding indicator: user scrolled near top")
      hideIndicator()
      return
    }
    
    // Hide if indicator is stale
    if indicator.isStale {
      logger.debug("Hiding indicator: content is stale")
      hideIndicator()
      return
    }
  }
  
  /// Check if we currently have a visible indicator
  var hasVisibleIndicator: Bool {
    currentIndicator?.shouldShow == true
  }
}

//// MARK: - Preview Provider
//
//#if DEBUG
//struct EnhancedNewPostsIndicator_Previews: PreviewProvider {
//  static var previews: some View {
//    VStack(spacing: 20) {
//      // Single post
//      EnhancedNewPostsIndicator(
//        newPostCount: 1,
//        authors: [
//          AppBskyActorDefs.ProfileViewBasic(
//            did: DID(didString: "did:test"),
//            handle: Handle(handleString: "alice.bsky.social"),
//            displayName: "Alice",
//            avatar: nil,
//            associated: nil,
//            viewer: nil,
//            labels: nil,
//            createdAt: nil,
//            verification: nil,
//            status: nil
//          )
//        ],
//        timestamp: Date().addingTimeInterval(-30),
//        onTap: {},
//        onDismiss: {}
//      )
//      
//      // Multiple posts
//      EnhancedNewPostsIndicator(
//        newPostCount: 5,
//        authors: [
//          AppBskyActorDefs.ProfileViewBasic(
//            did: DID(didString: "did:test1"),
//            handle: Handle(handleString: "alice.bsky.social"),
//            displayName: "Alice",
//            avatar: nil,
//            associated: nil,
//            viewer: nil,
//            labels: nil,
//            createdAt: nil,
//            verification: nil,
//            status: nil
//          ),
//          AppBskyActorDefs.ProfileViewBasic(
//            did: DID(didString: "did:test2"),
//            handle: Handle(handleString: "bob.bsky.social"),
//            displayName: "Bob",
//            avatar: nil,
//            associated: nil,
//            viewer: nil,
//            labels: nil,
//            createdAt: nil,
//            verification: nil,
//            status: nil
//          ),
//          AppBskyActorDefs.ProfileViewBasic(
//            did: DID(didString: "did:test3"),
//            handle: Handle(handleString: "charlie.bsky.social"),
//            displayName: "Charlie",
//            avatar: nil,
//            associated: nil,
//            viewer: nil,
//            labels: nil,
//            createdAt: nil,
//            verification: nil,
//            status: nil
//          )
//        ],
//        timestamp: Date().addingTimeInterval(-120),
//        onTap: {},
//        onDismiss: {}
//      )
//    }
//    .padding()
//    .background(Color.gray.opacity(0.1))
//  }
//}
//#endif
