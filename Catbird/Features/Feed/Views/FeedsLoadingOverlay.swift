import SwiftUI

/// A view that displays a loading overlay when feeds are loading.
struct FeedsLoadingOverlay: View {
  /// Indicates whether the feeds are currently loading.
  let isLoading: Bool

  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var currentColorScheme

  var body: some View {
    if isLoading {
      Color.dynamicBackground(appState.themeManager, currentScheme: currentColorScheme)
        .ignoresSafeArea()
        .overlay {
          ProgressView("Loading feeds...")
        }
        .contentShape(Rectangle())
        .allowsHitTesting(true)
    }
  }
}
