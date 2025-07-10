import SwiftUI

/// Standardized error state view for consistent error handling across the app
struct ErrorStateView: View {
  // MARK: - Properties
  
  let error: Error
  let context: String
  let retryAction: (() -> Void)?
  
  // MARK: - Initialization
  
  init(error: Error, context: String = "", retryAction: (() -> Void)? = nil) {
    self.error = error
    self.context = context
    self.retryAction = retryAction
  }
  
  // MARK: - Body
  
  var body: some View {
    VStack(spacing: 16) {
      // Error icon
      Image(systemName: "exclamationmark.triangle.fill")
        .appFont(size: 48)
        .foregroundColor(.orange)
      
      // Error title
      Text("Something went wrong")
        .appFont(AppTextRole.title2)
        .fontWeight(.semibold)
        .multilineTextAlignment(.center)
      
      // Error message
      VStack(spacing: 8) {
        if !context.isEmpty {
          Text(context)
                            .appFont(AppTextRole.body)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
        }
        
        Text(errorDescription)
          .appFont(AppTextRole.caption)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal)
      }
      
      // Retry button
      if let retryAction = retryAction {
        Button("Try Again") {
          retryAction()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
  }
  
  // MARK: - Computed Properties
  
  private var errorDescription: String {
    if let localizedError = error as? LocalizedError {
      return localizedError.localizedDescription
    } else {
      return error.localizedDescription
    }
  }
}

/// Network state indicator for showing connection status
struct NetworkStateIndicator: View {
  // MARK: - Properties
  
  @State private var isConnected: Bool = true
  @State private var isRetrying: Bool = false
  
  let onRetry: (() -> Void)?
  
  // MARK: - Body
  
  var body: some View {
    if !isConnected {
      HStack(spacing: 12) {
        Image(systemName: "wifi.slash")
          .foregroundColor(.red)
        
        Text("No internet connection")
          .appFont(AppTextRole.subheadline)
          .foregroundColor(.primary)
        
        Spacer()
        
        if let onRetry = onRetry {
          Button("Retry") {
            isRetrying = true
            onRetry()
            
            // Reset retry state after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
              isRetrying = false
            }
          }
          .disabled(isRetrying)
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(Color(.systemGray6))
      .cornerRadius(8)
      .padding(.horizontal)
    }
  }
}

/// Content unavailable view for empty states
struct ContentUnavailableStateView: View {
  // MARK: - Properties
  
  let title: String
  let description: String
  let systemImage: String
  let actionTitle: String?
  let action: (() -> Void)?
  
  // MARK: - Initialization
  
  init(
    title: String,
    description: String,
    systemImage: String,
    actionTitle: String? = nil,
    action: (() -> Void)? = nil
  ) {
    self.title = title
    self.description = description
    self.systemImage = systemImage
    self.actionTitle = actionTitle
    self.action = action
  }
  
  // MARK: - Body
  
  var body: some View {
    VStack(spacing: 20) {
      // Icon
      Image(systemName: systemImage)
        .appFont(size: 64)
        .foregroundColor(.secondary)
        .accessibilityHidden(true) // Decorative, don't read to screen readers
      
      // Text content
      VStack(spacing: 8) {
        Text(title)
          .appFont(AppTextRole.title2)
          .fontWeight(.semibold)
          .multilineTextAlignment(.center)
          .accessibilityAddTraits(.isHeader)
        
        Text(description)
          .appFont(AppTextRole.body)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .lineLimit(nil)
      }
      
      // Action button
      if let actionTitle = actionTitle, let action = action {
        Button(actionTitle) {
          action()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityHint("Takes action to resolve the empty state")
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
    .accessibilityElement(children: .contain)
  }
}

/// Loading state view with customizable message
struct LoadingStateView: View {
  // MARK: - Properties
  
  let message: String
  let showProgress: Bool
  
  // MARK: - Initialization
  
  init(message: String = "Loading...", showProgress: Bool = true) {
    self.message = message
    self.showProgress = showProgress
  }
  
  // MARK: - Body
  
  var body: some View {
    VStack(spacing: 16) {
      if showProgress {
        ProgressView()
          .scaleEffect(1.2)
      }
      
      Text(message)
                        .appFont(AppTextRole.body)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
  }
}

// MARK: - Convenience Extensions

extension ErrorStateView {
  /// Create an error view for network errors
  static func networkError(retryAction: @escaping () -> Void) -> ErrorStateView {
    ErrorStateView(
      error: NetworkError.connectionFailed,
      context: "Please check your internet connection and try again.",
      retryAction: retryAction
    )
  }
  
  /// Create an error view for authentication errors
  static func authenticationError() -> ErrorStateView {
    ErrorStateView(
      error: AuthenticationError.sessionExpired,
      context: "Your session has expired. Please log in again."
    )
  }
}

extension ContentUnavailableStateView {
  /// Create an empty feed state view
  static func emptyFeed(feedName: String = "feed", onRefresh: (() -> Void)? = nil, onExplore: (() -> Void)? = nil) -> ContentUnavailableStateView {
    if let onExplore = onExplore {
      return ContentUnavailableStateView(
        title: "No Posts in \(feedName)",
        description: "This \(feedName) doesn't have any posts yet. Try refreshing or explore other feeds to discover new content.",
        systemImage: "tray",
        actionTitle: "Explore Feeds"
      ) {
        onExplore()
      }
    } else if let onRefresh = onRefresh {
      return ContentUnavailableStateView(
        title: "No Posts in \(feedName)",
        description: "This \(feedName) doesn't have any posts yet. Pull down to refresh or try again later.",
        systemImage: "tray",
        actionTitle: "Refresh"
      ) {
        onRefresh()
      }
    } else {
      return ContentUnavailableStateView(
        title: "No Posts in \(feedName)",
        description: "This \(feedName) doesn't have any posts yet. Check back later for new content.",
        systemImage: "tray"
      )
    }
  }
  
  /// Create an empty following feed state view
  static func emptyFollowingFeed(onDiscover: @escaping () -> Void) -> ContentUnavailableStateView {
    ContentUnavailableStateView(
      title: "Your Timeline is Empty",
      description: "Follow some people to see their posts in your timeline. Discover interesting accounts to get started.",
      systemImage: "person.2",
      actionTitle: "Discover People"
    ) {
      onDiscover()
    }
  }
  
  /// Create a content filtered state view
  static func contentFiltered(onAdjustFilters: @escaping () -> Void) -> ContentUnavailableStateView {
    ContentUnavailableStateView(
      title: "All Content Filtered",
      description: "Your current content filters are hiding all posts in this feed. You can adjust your filter settings to see more content.",
      systemImage: "eye.slash",
      actionTitle: "Adjust Filters"
    ) {
      onAdjustFilters()
    }
  }
  
  /// Create a network error state view for feeds
  static func feedNetworkError(onRetry: @escaping () -> Void) -> ContentUnavailableStateView {
    ContentUnavailableStateView(
      title: "Can't Load Feed",
      description: "There was a problem loading this feed. Check your internet connection and try again.",
      systemImage: "wifi.slash",
      actionTitle: "Try Again"
    ) {
      onRetry()
    }
  }
}

// MARK: - Error Types

enum NetworkError: LocalizedError {
  case connectionFailed
  case requestTimeout
  case serverError(Int)
  
  var errorDescription: String? {
    switch self {
    case .connectionFailed:
      return "Unable to connect to the server"
    case .requestTimeout:
      return "The request timed out"
    case .serverError(let code):
      return "Server error (\(code))"
    }
  }
}

enum AuthenticationError: LocalizedError {
  case sessionExpired
  case invalidCredentials
  case accountSuspended
  
  var errorDescription: String? {
    switch self {
    case .sessionExpired:
      return "Your session has expired"
    case .invalidCredentials:
      return "Invalid username or password"
    case .accountSuspended:
      return "Your account has been suspended"
    }
  }
}

// MARK: - Preview

#Preview("Error State") {
  ErrorStateView.networkError {
    print("Retry tapped")
  }
}

#Preview("Content Unavailable") {
  ContentUnavailableStateView(
    title: "No Posts Yet",
    description: "When you follow people, their posts will appear here.",
    systemImage: "tray",
    actionTitle: "Find People to Follow"
  ) {
    print("Action tapped")
  }
}

#Preview("Loading State") {
  LoadingStateView(message: "Loading your timeline...")
}
