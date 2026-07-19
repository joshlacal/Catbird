import Foundation
import SwiftUI

// MARK: - Preview Helper Extensions

@MainActor
extension PreviewContainer {

  /// Quick access to AppStateManager for previews
  var manager: AppStateManager {
    AppStateManager.shared
  }

  /// Whether preview credentials are configured in PreviewSecrets.xcconfig
  var isConfigured: Bool {
    PreviewAuthManager.shared.isConfigured
  }
}

// MARK: - Usage Examples
//
// Basic (recommended):
//
//   #Preview {
//     FeedView()
//       .previewWithAuthenticatedState()
//   }
//
// Pure-UI components (no network):
//
//   #Preview {
//     MyButton()
//       .previewWithMockEnvironment()
//   }
//
// Direct AppState access:
//
//   #Preview {
//     AsyncPreviewContent { appState in
//       ProfileView(handle: "example.bsky.social")
//         .environment(appState)
//     }
//   }

/// Convenience wrapper for previews that need direct access to AppState
struct AsyncPreviewContent<Content: View>: View {
  @State private var appState: AppState?
  @State private var isLoading = true
  let content: (AppState) -> Content

  init(@ViewBuilder content: @escaping (AppState) -> Content) {
    self.content = content
  }

  var body: some View {
    Group {
      if let appState {
        content(appState)
          .modifier(AuthenticatedPreviewModifier(appState: appState))
      } else if isLoading {
        ProgressView("Authenticating…")
          .task {
            appState = await PreviewContainer.shared.appState
            isLoading = false
          }
      } else {
        Text("Configure PreviewSecrets.xcconfig")
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// Preview wrapper that resolves a fixture-backed AppState (no auth, no network) before
/// rendering — the `.mock`-mode counterpart to `AsyncPreviewContent`. Use for fixture-first
/// `#Preview` blocks that need an `AppState` (e.g. to construct a view model) but don't need
/// live network data (that comes from `PreviewFixtures` directly).
///
/// Usage:
///   #Preview("MyView — fixtures") {
///     FixturePreviewContent { appState in
///       if let post = PreviewFixtures.post(.textShort) {
///         MyView(post: post, appState: appState)
///       } else {
///         Text("Run scripts/preview-fixtures/ to generate fixtures")
///       }
///     }
///   }
struct FixturePreviewContent<Content: View>: View {
  @State private var appState: AppState?
  let content: (AppState) -> Content

  init(@ViewBuilder content: @escaping (AppState) -> Content) {
    self.content = content
  }

  var body: some View {
    Group {
      if let appState {
        content(appState)
          .modifier(AuthenticatedPreviewModifier(appState: appState, networkMode: .mock))
      } else {
        ProgressView("Loading fixtures…")
          .task {
            appState = await PreviewContainer.fixtureAppState()
          }
      }
    }
  }
}

/// Preview wrapper that loads async data (e.g., API posts) before rendering.
/// Usage:
///   AsyncPreviewDataContent { appState in
///     await PreviewData.firstPostView(from: appState)
///   } content: { appState, postView in
///     PostView(post: postView, ...)
///   }
struct AsyncPreviewDataContent<Data: Sendable, Content: View>: View {
  @State private var appState: AppState?
  @State private var loadedData: Data?
  @State private var isLoading = true
  let loader: (AppState) async -> Data?
  let content: (AppState, Data) -> Content

  init(
    loader: @escaping (AppState) async -> Data?,
    @ViewBuilder content: @escaping (AppState, Data) -> Content
  ) {
    self.loader = loader
    self.content = content
  }

  var body: some View {
    Group {
      if let appState, let loadedData {
        content(appState, loadedData)
          .modifier(AuthenticatedPreviewModifier(appState: appState))
      } else if isLoading {
        ProgressView("Loading preview data…")
          .task {
            let state = await PreviewContainer.shared.appState
            appState = state
            if let state {
              loadedData = await loader(state)
            }
            isLoading = false
          }
      } else {
        Text("No preview data available")
          .foregroundStyle(.secondary)
      }
    }
  }
}
