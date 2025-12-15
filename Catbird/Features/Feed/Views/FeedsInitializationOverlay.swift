import SwiftUI

/// A view that displays an initialization overlay when feeds are initializing.
/// Note: This component is currently unused but kept for potential future use.
struct FeedsInitializationOverlay: View {
  /// Indicates whether the feeds have finished initializing.
  let isInitialized: Bool

  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    if !isInitialized {
      Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme)
        .ignoresSafeArea()
        .overlay {
          ProgressView("Loading your feeds...")
        }
        .contentShape(Rectangle())
        .allowsHitTesting(true)
    }
  }
}
