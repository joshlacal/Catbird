import SwiftUI
import Petrel

// MARK: - Environment Keys

struct PreviewModeKey: EnvironmentKey {
  static let defaultValue: Bool = false
}

struct PreviewNetworkModeKey: EnvironmentKey {
  static let defaultValue: PreviewNetworkMode = .real
}

enum PreviewNetworkMode: String {
  case real     // Use actual Bluesky API
  case mock     // Use mock responses (future)
  case offline  // No network calls
}

extension EnvironmentValues {
  /// Indicates if the view is running in preview mode
  var isPreviewMode: Bool {
    get { self[PreviewModeKey.self] }
    set { self[PreviewModeKey.self] = newValue }
  }

  /// Controls network behavior in previews
  var previewNetworkMode: PreviewNetworkMode {
    get { self[PreviewNetworkModeKey.self] }
    set { self[PreviewNetworkModeKey.self] = newValue }
  }
}

// MARK: - View Modifiers

/// Applies authenticated AppState and all required environment values for previews.
/// Injects the same environment hierarchy as ContentView:
/// - AppState (via @Environment)
/// - appSettings, adultContentEnabled
/// - toastManager, themeManager, fontManager
struct AuthenticatedPreviewModifier: ViewModifier {
  let appState: AppState

  func body(content: Content) -> some View {
    content
      .environment(appState)
      .environment(AppStateManager.shared)
      .applyAppStateEnvironment(appState)
      .applyTheme(appState.themeManager)
      .fontManager(appState.fontManager)
      .environment(\.toastManager, appState.toastManager)
      .environment(\.isPreviewMode, true)
      .environment(\.previewNetworkMode, .real)
  }
}

// MARK: - View Extensions

extension View {
  /// Apply full authenticated AppState for previews with real network access.
  ///
  /// Authenticates via PreviewSecrets.xcconfig credentials (preferred) or
  /// falls back to the running app's session. Shows skeleton UI if neither
  /// is available.
  ///
  /// Usage:
  /// ```swift
  /// #Preview {
  ///   MyView()
  ///     .previewWithAuthenticatedState()
  /// }
  /// ```
  @MainActor
  func previewWithAuthenticatedState() -> some View {
    modifier(AsyncPreviewStateModifier())
  }

  /// Apply preview environment without authentication.
  /// Shows the wrapped view with default environment values — useful for
  /// pure-UI components that don't need network data.
  @MainActor
  func previewWithMockEnvironment() -> some View {
    self
      .environment(\.isPreviewMode, true)
      .environment(\.previewNetworkMode, .offline)
  }
}

// MARK: - Async Loading Wrappers

private struct AsyncPreviewStateModifier: ViewModifier {
  @State private var appState: AppState?
  @State private var isLoading = true

  func body(content: Content) -> some View {
    Group {
      if let appState {
        content
          .modifier(AuthenticatedPreviewModifier(appState: appState))
      } else if isLoading {
        PreviewLoadingView()
          .task {
            appState = await PreviewContainer.shared.appState
            isLoading = false
          }
      } else {
        PreviewUnconfiguredView()
      }
    }
  }
}

// MARK: - Placeholder Views

/// Shown while preview authentication is in progress
private struct PreviewLoadingView: View {
  var body: some View {
    VStack(spacing: 16) {
      ProgressView()
        .controlSize(.large)
      Text("Authenticating preview…")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
  }
}

/// Shown when preview credentials are not configured
private struct PreviewUnconfiguredView: View {
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "key.slash")
        .font(.system(size: 40))
        .foregroundStyle(.tertiary)
      Text("Preview Not Configured")
        .font(.headline)
      Text("Add credentials to PreviewSecrets.xcconfig\nSee PreviewSecrets.xcconfig.template for setup")
        .font(.caption)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
  }
}
