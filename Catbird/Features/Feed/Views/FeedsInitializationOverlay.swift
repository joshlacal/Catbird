import SwiftUI

/// A view that displays an initialization overlay when feeds are initializing.
struct FeedsInitializationOverlay: View {
  /// Indicates whether the feeds have finished initializing.
  let isInitialized: Bool

  var body: some View {
    if !isInitialized {
      VStack {
        Spacer()
        ProgressView("Loading your feeds...")
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.systemBackground.opacity(0.9))
    }
  }
}
