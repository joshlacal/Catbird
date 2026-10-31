import SwiftUI

extension Notification.Name {
  /// Posted when an account's `ModerationPolicy` value changes. `userInfo["accountDID"]` is the
  /// account whose `AppState` published the new policy.
  static let moderationPolicyDidChange = Notification.Name("ModerationPolicyDidChange")
}

private struct ModerationPolicyKey: EnvironmentKey {
  static let defaultValue = ModerationPolicy.failClosed
}

extension EnvironmentValues {
  /// The signed-in account's moderation policy. Views outside an `AppState` environment get the
  /// fail-closed policy.
  var moderationPolicy: ModerationPolicy {
    get { self[ModerationPolicyKey.self] }
    set { self[ModerationPolicyKey.self] = newValue }
  }
}
