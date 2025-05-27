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
        .font(.system(size: 48))
        .foregroundColor(.orange)
      
      // Error title
      Text("Something went wrong")
        .font(.title2)
        .fontWeight(.semibold)
        .multilineTextAlignment(.center)
      
      // Error message
      VStack(spacing: 8) {
        if !context.isEmpty {
          Text(context)
            .font(.body)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
        }
        
        Text(errorDescription)
          .font(.caption)
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
          .font(.subheadline)
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
        .font(.system(size: 64))
        .foregroundColor(.secondary)
      
      // Text content
      VStack(spacing: 8) {
        Text(title)
          .font(.title2)
          .fontWeight(.semibold)
          .multilineTextAlignment(.center)
        
        Text(description)
          .font(.body)
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
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
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
        .font(.body)
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