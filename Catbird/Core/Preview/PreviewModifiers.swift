import SwiftUI
import Petrel

// MARK: - Environment Keys

struct PreviewModeKey: EnvironmentKey {
  static let defaultValue: Bool = false
}

struct PreviewNetworkModeKey: EnvironmentKey {
  static let defaultValue: PreviewNetworkMode = .real
}

enum PreviewNetworkMode: String, Sendable {
  case real     // Use actual Bluesky API
  case mock     // Use static fixture data, no auth/network (see PreviewFixtures)
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

/// Applies authenticated or offline fixture `AppState` and all required environment values
/// for previews. Injects the same environment hierarchy as `ContentView`.
struct AuthenticatedPreviewModifier: ViewModifier {
  let appState: AppState
  let networkMode: PreviewNetworkMode
  @State private var sceneContext: SceneNavigationContext

  init(appState: AppState, networkMode: PreviewNetworkMode = .real) {
    self.appState = appState
    self.networkMode = networkMode
    _sceneContext = State(initialValue: SceneNavigationContext(appState: appState, sceneID: UUID()))
  }

  func body(content: Content) -> some View {
    content
      .environment(appState)
      .environment(sceneContext)
      .environment(AppStateManager.shared)
      .applyAppStateEnvironment(appState)
      .applyTheme(appState.themeManager)
      .fontManager(appState.fontManager)
      .environment(\.toastManager, appState.toastManager)
      .environment(\.isPreviewMode, true)
      .environment(\.previewNetworkMode, networkMode)
  }
}

// MARK: - View Extensions

extension View {
  /// Apply full `AppState` for previews.
  ///
  /// Pass `mode: .mock` to skip auth/network entirely and resolve a fixture-backed
  /// `AppState` (`PreviewContainer.fixtureAppState()`).
  @MainActor
  func previewWithAuthenticatedState(mode: PreviewNetworkMode = .real) -> some View {
    modifier(AsyncPreviewStateModifier(mode: mode))
  }

  /// Apply preview environment without authentication.
  @MainActor
  func previewWithMockEnvironment() -> some View {
    self
      .environment(\.isPreviewMode, true)
      .environment(\.previewNetworkMode, .offline)
  }
}

// MARK: - Async Loading Wrappers

private struct AsyncPreviewStateModifier: ViewModifier {
  var mode: PreviewNetworkMode = .real
  @State private var appState: AppState?
  @State private var isLoading = true

  func body(content: Content) -> some View {
    Group {
      if let appState {
        content
          .modifier(AuthenticatedPreviewModifier(appState: appState, networkMode: mode))
      } else if isLoading {
        PreviewLoadingView()
          .task {
            switch mode {
            case .mock:
              appState = await PreviewContainer.fixtureAppState()
            case .real, .offline:
              appState = await PreviewContainer.shared.appState
            }
            isLoading = false
          }
      } else {
        PreviewUnconfiguredView()
      }
    }
  }
}

// MARK: - Platform Helpers

#if os(iOS)
private let platformBackgroundColor = Color(.systemBackground)
#elseif os(macOS)
private let platformBackgroundColor = Color(.windowBackgroundColor)
#endif

// MARK: - Placeholder Views

/// Shown while preview authentication is in progress
private struct PreviewLoadingView: View {
  var body: some View {
    VStack(spacing: Space.lg) {
      ProgressView()
        .controlSize(.large)
      Text(verbatim: "Authenticating preview…")
        .appFont(AppTextRole.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(platformBackgroundColor)
  }
}

/// Shown when preview credentials are not configured
private struct PreviewUnconfiguredView: View {
  var body: some View {
    VStack(spacing: Space.md) {
      Image(systemName: "key.slash")
        .appFont(AppTextRole.largeTitle)
        .foregroundStyle(.tertiary)
      Text(verbatim: "Preview Not Configured")
        .appFont(AppTextRole.headline)
      Text(
        verbatim: "Add credentials to PreviewSecrets.xcconfig for live data.\nOr use a fixture-backed preview (mode: .mock / PreviewFixtures) — those render without credentials."
      )
      .appFont(AppTextRole.caption)
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
    }
    .padding(Space.x3l)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(platformBackgroundColor)
  }
}
