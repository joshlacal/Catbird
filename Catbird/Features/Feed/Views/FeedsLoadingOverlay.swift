import SwiftUI

/// A view that displays a loading overlay when feeds are loading.
struct FeedsLoadingOverlay: View {
  /// Indicates whether the feeds are currently loading.
  let isLoading: Bool
  
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var currentColorScheme

  var body: some View {
    if isLoading {
      VStack {
        Spacer()
        ProgressView("Loading feeds...")
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.dynamicBackground(appState.themeManager, currentScheme: currentColorScheme).opacity(0.9))
    }
  }
}
