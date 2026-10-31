import SwiftUI

private struct ModerationListFilterExemptDIDKey: EnvironmentKey {
  static let defaultValue: String? = nil
}

extension EnvironmentValues {
  /// The DID whose own posts are not list-filtered on the surface being
  /// rendered. A profile's own feed sets this to the profile's DID, as the
  /// official app passes `ignoreFilterFor` to its author feeds.
  var moderationListFilterExemptDID: String? {
    get { self[ModerationListFilterExemptDIDKey.self] }
    set { self[ModerationListFilterExemptDIDKey.self] = newValue }
  }
}
