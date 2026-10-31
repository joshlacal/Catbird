import SwiftUI

/// Keeps `\.moderationPolicy` current inside a UIKit-hosted SwiftUI tree.
///
/// The content closure of a `UIHostingConfiguration` runs once, when the cell
/// is configured, outside any SwiftUI body. A policy injected there with
/// `applyAppStateEnvironment` is a snapshot: nothing re-runs the closure when
/// a preference write publishes a new `AppState.moderationPolicy`, so rows on
/// screen keep their old gates. This view reads the policy in its own body,
/// which SwiftUI observes, and re-injects it whenever the source changes.
struct ModerationPolicyTracking<Content: View>: View {
  /// Read inside `body`, so an `@Observable` source re-renders this view.
  let source: @MainActor () -> ModerationPolicy
  let content: Content

  var body: some View {
    let policy = source()
    content
      .environment(\.moderationPolicy, policy)
      .environment(\.adultContentEnabled, policy.adultContentEnabled)
  }
}

extension View {
  /// Re-injects the account's moderation policy whenever `appState` publishes
  /// a new one. Apply inside every `UIHostingConfiguration` that renders
  /// moderated content, before `applyAppStateEnvironment`: the innermost
  /// environment value is the one the content reads.
  func trackingModerationPolicy(of appState: AppState) -> some View {
    ModerationPolicyTracking(source: { appState.moderationPolicy }, content: self)
  }
}
