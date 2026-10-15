import Foundation
import SwiftUI

/// Navigation destinations specific to the Profile feature
enum ProfileNavigationDestination: Hashable {
  /// A More section. `viewModel` is the view model of the profile screen that opened it, which
  /// the section reuses instead of loading the profile again; see `section(_:of:)`.
  case section(ProfileTab, did: String, viewModel: ProfileViewModel?)
  case followers(String)
  case following(String)
  case knownFollowers(String)

  /// The `tab` section of the profile `viewModel` shows. The view model travels in the value
  /// because SwiftUI can build the destination from a short-lived copy of the profile screen
  /// whose own view model was never built. Main-actor isolated because it reads the
  /// view model's profile.
  @MainActor
  static func section(_ tab: ProfileTab, of viewModel: ProfileViewModel) -> Self {
    .section(tab, did: viewModel.profile?.did.didString() ?? viewModel.userDID, viewModel: viewModel)
  }
}
