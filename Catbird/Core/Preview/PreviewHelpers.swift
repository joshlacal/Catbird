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
// Fixture-backed (zero credentials, zero network — recommended):
//
//   #Preview("MyView — fixtures") {
//     MyView()
//       .previewWithAuthenticatedState(mode: .mock)
//   }
//
// Live authenticated:
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
        ProgressView {
          Text(verbatim: "Authenticating…")
        }
        .task {
          appState = await PreviewContainer.shared.appState
          isLoading = false
        }
      } else {
        Text(verbatim: "Configure PreviewSecrets.xcconfig")
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// Preview wrapper that resolves an offline fixture-backed `AppState` (no auth, no network)
/// before rendering — the `.mock`-mode counterpart to `AsyncPreviewContent`.
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
        ProgressView {
          Text(verbatim: "Loading fixtures…")
        }
        .task {
          appState = await PreviewContainer.fixtureAppState()
        }
      }
    }
  }
}

/// Preview wrapper that loads async data (e.g., API posts) before rendering.
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
        ProgressView {
          Text(verbatim: "Loading preview data…")
        }
        .task {
          let state = await PreviewContainer.shared.appState
          appState = state
          if let state {
            loadedData = await loader(state)
          }
          isLoading = false
        }
      } else {
        Text(verbatim: "No preview data available")
          .foregroundStyle(.secondary)
      }
    }
  }
}
