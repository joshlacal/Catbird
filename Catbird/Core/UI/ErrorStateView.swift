import SwiftUI

/// Standardized error state view for consistent error handling across the app.
struct ErrorStateView: View {
  @Environment(\.catbirdTheme) private var theme
  let error: Error
  let context: String
  let retryAction: (() -> Void)?

  init(error: Error, context: String = "", retryAction: (() -> Void)? = nil) {
    self.error = error
    self.context = context
    self.retryAction = retryAction
  }

  var body: some View {
    VStack(spacing: Space.lg) {
      Image(systemName: "exclamationmark.triangle.fill")
        .catbirdSymbol(.hero)
        .foregroundStyle(theme.semantic(.warning))
        .accessibilityHidden(true)

      Text("Something went wrong")
        .appFont(AppTextRole.title2)
        .foregroundStyle(theme.text(.primary))
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)

      VStack(spacing: Space.sm) {
        if !context.isEmpty {
          Text(context)
            .appFont(AppTextRole.body)
            .foregroundStyle(theme.text(.secondary))
            .multilineTextAlignment(.center)
        }

        Text(errorDescription)
          .appFont(AppTextRole.caption)
          .foregroundStyle(theme.text(.secondary))
          .multilineTextAlignment(.center)
          .padding(.horizontal, Space.lg)
      }

      if let retryAction {
        Button("Try Again") {
          retryAction()
        }
        .buttonStyle(.catbird(.primary, size: .lg))
      }
    }
    .padding(Space.xxl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.surface(.canvas))
    .accessibilityElement(children: .contain)
  }

  // MARK: - Computed Properties

  /// Plain-language explanation of the failure. Raw error text (HTTP codes, decoder
  /// messages) stays in the logs of whoever produced the error.
  private var errorDescription: String {
    switch UserFacingError.kind(of: error) {
    case .offline:
      return String(localized: "You’re offline. Check your connection and try again.", comment: "Error state explanation when device has no internet connection.")
    case .timedOut:
      return String(localized: "This is taking longer than usual. Try again in a moment.", comment: "Error state explanation when network request times out.")
    case .rateLimited:
      return String(localized: "Too many requests. Wait a moment and try again.", comment: "Error state explanation when server rate-limits requests.")
    case .notFound:
      return String(localized: "This content isn’t available. It may have been deleted.", comment: "Error state explanation when requested content is 404/missing.")
    case .notAllowed:
      return String(localized: "You don’t have permission to view this.", comment: "Error state explanation when access is forbidden.")
    case .signInRequired:
      return String(localized: "Sign in again to continue.", comment: "Error state explanation when session requires re-authentication.")
    case .server:
      return String(localized: "The server is having trouble right now. Try again in a moment.", comment: "Error state explanation when server returns 5xx error.")
    case .cancelled, .other:
      // View models often wrap a bad HTTP response in an NSError whose code is the status.
      let code = (error as NSError).code
      if code == 429 {
        return String(localized: "Too many requests. Wait a moment and try again.", comment: "Error state explanation when server rate-limits requests.")
      }
      if (500...599).contains(code) {
        return String(localized: "The server is having trouble right now. Try again in a moment.", comment: "Error state explanation when server returns 5xx error.")
      }
      return String(localized: "Please try again.", comment: "Generic fallback error state explanation.")
    }
  }
}

/// Network state indicator for showing connection status.
struct NetworkStateIndicator: View {
  // MARK: - Properties
  @Environment(\.catbirdTheme) private var theme
  @State private var isConnected: Bool = true
  @State private var isRetrying: Bool = false

  let onRetry: (() -> Void)?

  // MARK: - Body

  var body: some View {
    if !isConnected {
      HStack(spacing: Space.md) {
        Image(systemName: "wifi.slash")
          .catbirdSymbol(.row)
          .foregroundStyle(theme.semantic(.danger))
          .accessibilityHidden(true)

        Text("No internet connection")
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(theme.text(.primary))

        Spacer(minLength: Space.sm)

        if let onRetry {
          Button("Retry") {
            self.isRetrying = true
            onRetry()
            Task { @MainActor in
              try? await Task.sleep(for: .seconds(1))
              self.isRetrying = false
            }
          }
          .disabled(isRetrying)
          .buttonStyle(.catbird(.tonal, size: .sm, isLoading: isRetrying))
        }
      }
      .padding(.horizontal, Space.lg)
      .padding(.vertical, Space.sm)
      .catbirdCard(.embed, radius: .sm)
      .padding(.horizontal, Space.screenMargin)
    }
  }
}

/// Content unavailable view for empty states.
struct ContentUnavailableStateView: View {
  // MARK: - Properties
  @Environment(\.catbirdTheme) private var theme

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
    VStack(spacing: Space.xl) {
      Image(systemName: systemImage)
        .appFont(size: AvatarSize.xl, weight: .medium, relativeTo: .largeTitle)
        .foregroundStyle(theme.text(.secondary))
        .accessibilityHidden(true)

      VStack(spacing: Space.sm) {
        Text(title)
          .appFont(AppTextRole.title2)
          .foregroundStyle(theme.text(.primary))
          .multilineTextAlignment(.center)
          .accessibilityAddTraits(.isHeader)

        Text(description)
          .appFont(AppTextRole.body)
          .foregroundStyle(theme.text(.secondary))
          .multilineTextAlignment(.center)
          .lineLimit(nil)
      }

      if let actionTitle, let action {
        Button(actionTitle) {
          action()
        }
        .buttonStyle(.catbird(.primary, size: .lg))
      }
    }
    .padding(Space.x3l)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.surface(.canvas))
    .accessibilityElement(children: .contain)
  }
}

/// Loading state view with customizable message.
struct LoadingStateView: View {
  // MARK: - Properties
  @Environment(\.catbirdTheme) private var theme
  let message: String
  let showProgress: Bool

  // MARK: - Initialization

  init(message: String = String(localized: "Loading…", comment: "Default loading state message."), showProgress: Bool = true) {
    self.message = message
    self.showProgress = showProgress
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: Space.lg) {
      if showProgress {
        ProgressView()
          .scaleEffect(1.2)
      }

      Text(message)
        .appFont(AppTextRole.body)
        .foregroundStyle(theme.text(.secondary))
        .multilineTextAlignment(.center)
    }
    .padding(Space.xxl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.surface(.canvas))
  }
}

// MARK: - Convenience Extensions

extension ErrorStateView {
  /// Create an error view for network errors
  static func networkError(retryAction: @escaping () -> Void) -> ErrorStateView {
    ErrorStateView(
      error: NetworkError.connectionFailed,
      context: String(localized: "Please check your internet connection and try again.", comment: "Network error context message."),
      retryAction: retryAction
    )
  }

  /// Create an error view for authentication errors
  static func authenticationError(retryAction: (() -> Void)? = nil) -> ErrorStateView {
    ErrorStateView(
      error: AuthenticationError.sessionExpired,
      context: String(localized: "Your session has expired. Please log in again.", comment: "Authentication error context message."),
      retryAction: retryAction
    )
  }
}

extension ContentUnavailableStateView {
  /// Create an empty feed state view
  static func emptyFeed(feedName: String = "feed", onRefresh: (() -> Void)? = nil, onExplore: (() -> Void)? = nil) -> ContentUnavailableStateView {
    // Uncached feeds and lists fall back to "Feed: <record key>" / "List: <record key>",
    // which must never reach the title.
    let hasName = !feedName.isEmpty
      && feedName.lowercased() != "feed"
      && !feedName.hasPrefix("Feed: ")
      && !feedName.hasPrefix("List: ")
    let title = hasName
      ? String(localized: "No Posts in \(feedName)", comment: "Empty state title for a named feed — variable is feed name.")
      : String(localized: "No Posts Yet", comment: "Empty state title when a feed has no posts.")
    if let onExplore {
      return ContentUnavailableStateView(
        title: title,
        description: String(localized: "This feed doesn’t have any posts yet. Try refreshing, or explore other feeds to discover new posts.", comment: "Empty feed state description with explore option."),
        systemImage: "tray",
        actionTitle: String(localized: "Explore Feeds", comment: "Button to browse feeds from empty feed state.")
      ) {
        onExplore()
      }
    } else if let onRefresh {
      return ContentUnavailableStateView(
        title: title,
        description: String(localized: "This feed doesn’t have any posts yet. Pull down to refresh or try again later.", comment: "Empty feed state description with refresh option."),
        systemImage: "tray",
        actionTitle: String(localized: "Refresh", comment: "Button to refresh an empty feed.")
      ) {
        onRefresh()
      }
    } else {
      return ContentUnavailableStateView(
        title: title,
        description: String(localized: "This feed doesn’t have any posts yet. Check back later for new posts.", comment: "Empty feed state description."),
        systemImage: "tray"
      )
    }
  }

  /// Create an empty following feed state view
  static func emptyFollowingFeed(onDiscover: @escaping () -> Void) -> ContentUnavailableStateView {
    ContentUnavailableStateView(
      title: String(localized: "Your Timeline is Empty", comment: "Empty state title when user's Following timeline has no posts."),
      description: String(localized: "Follow some people to see their posts in your timeline. Discover interesting accounts to get started.", comment: "Empty Following timeline description."),
      systemImage: "person.2",
      actionTitle: String(localized: "Discover People", comment: "Button to discover accounts to follow from empty timeline.")
    ) {
      onDiscover()
    }
  }

  /// Create a content filtered state view
  static func contentFiltered(onAdjustFilters: @escaping () -> Void) -> ContentUnavailableStateView {
    ContentUnavailableStateView(
      title: String(localized: "All Content Filtered", comment: "Empty state title when all posts in a feed are hidden by content filters."),
      description: String(localized: "Your current content filters are hiding all posts in this feed. You can adjust your filter settings to see more content.", comment: "Empty state description when content filters hide all posts."),
      systemImage: "eye.slash",
      actionTitle: String(localized: "Adjust Filters", comment: "Button to open content filter settings.")
    ) {
      onAdjustFilters()
    }
  }

  /// Create a network error state view for feeds
  static func feedNetworkError(onRetry: @escaping () -> Void) -> ContentUnavailableStateView {
    ContentUnavailableStateView(
      title: String(localized: "Can’t Load Feed", comment: "Error state title when a feed fails to load."),
      description: String(localized: "There was a problem loading this feed. Check your internet connection and try again.", comment: "Error state description when a feed fails to load."),
      systemImage: "wifi.slash",
      actionTitle: String(localized: "Try Again", comment: "Retry button when feed fails to load.")
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
      return String(localized: "Unable to connect to the server", comment: "Network error description when connection fails.")
    case .requestTimeout:
      return String(localized: "The request timed out", comment: "Network error description when request times out.")
    case .serverError(let code):
      return String(localized: "Server error (\(code))", comment: "Network error description with HTTP status code.")
    }
  }
}

enum AuthenticationError: LocalizedError {
  case sessionExpired
  case invalidCredentials
  case accountSuspended

  var errorDescription: String? {
    switch self {
    case .sessionExpired: String(localized: "Your session has expired", comment: "Auth error description when session expires.")
    case .invalidCredentials: String(localized: "Invalid username or password", comment: "Auth error description for invalid login credentials.")
    case .accountSuspended: String(localized: "Your account has been suspended", comment: "Auth error description when account is suspended.")
    }
  }

  var failureReason: String? {
    switch self {
    case .sessionExpired: String(localized: "Your authentication session has timed out for security reasons.", comment: "Auth error failure reason when session expires.")
    case .invalidCredentials: String(localized: "The username or password you entered is incorrect.", comment: "Auth error failure reason for invalid credentials.")
    case .accountSuspended: String(localized: "Your account access has been restricted due to policy violations.", comment: "Auth error failure reason when account is suspended.")
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .sessionExpired: String(localized: "Please log out and log back in to continue.", comment: "Auth error recovery suggestion when session expires.")
    case .invalidCredentials: String(localized: "Please check your username and password and try again.", comment: "Auth error recovery suggestion for invalid credentials.")
    case .accountSuspended: String(localized: "Please contact support for assistance with your account.", comment: "Auth error recovery suggestion when account is suspended.")
    }
  }
}

#Preview("Error State") {
  ErrorStateView.networkError { logger.debug("Retry tapped") }
}

#Preview("Content Unavailable") {
  ContentUnavailableStateView(
    title: "No Posts Yet",
    description: "When you follow people, their posts will appear here.",
    systemImage: "tray",
    actionTitle: "Find People to Follow"
  ) { logger.debug("Action tapped") }
}

#Preview("Loading State") {
  LoadingStateView(message: "Loading your timeline...")
}
