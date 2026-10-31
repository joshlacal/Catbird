import Foundation
import Petrel

/// Holds a profile screen's view model and builds it on the first read of `viewModel`.
///
/// SwiftUI evaluates a `@State` initial value on every initialization of the view struct and
/// keeps only the first, and during navigation it briefly builds extra profile screens whose
/// bodies run before they are torn down. Building the view model in either place made
/// throwaway view models, each starting a state-invalidation subscription. A throwaway slot
/// only holds the inputs, including the tab the screen opens on. Screens read
/// `builtViewModel` while building their body and read `viewModel` once they appear.
@MainActor
final class ProfileViewModelSlot {
  /// The profile the view model is for, and its `userDID`.
  let userDID: String
  private let client: ATProtoClient?
  private let currentUserDID: String?
  private let stateInvalidationBus: StateInvalidationBus?
  /// The tab the view model starts on, when it is not the view model's own default.
  private let initialProfileTab: ProfileTab?

  /// The view model, or nil until something has read `viewModel`.
  private(set) var builtViewModel: ProfileViewModel?

  init(
    client: ATProtoClient?, userDID: String, currentUserDID: String?,
    stateInvalidationBus: StateInvalidationBus? = nil, initialProfileTab: ProfileTab? = nil
  ) {
    self.client = client
    self.userDID = userDID
    self.currentUserDID = currentUserDID
    self.stateInvalidationBus = stateInvalidationBus
    self.initialProfileTab = initialProfileTab
  }

  /// The view model, built on the first read with the initial tab already selected.
  var viewModel: ProfileViewModel {
    if let builtViewModel { return builtViewModel }
    let viewModel = ProfileViewModel(
      client: client,
      userDID: userDID,
      currentUserDID: currentUserDID,
      stateInvalidationBus: stateInvalidationBus
    )
    if let initialProfileTab {
      viewModel.selectedProfileTab = initialProfileTab
    }
    builtViewModel = viewModel
    return viewModel
  }

  /// The tab a profile opened by DID starts on: Labeler Info for Bluesky's moderation service
  /// and for subscribed labelers, so the first load fetches labeler details rather than an
  /// author feed. Nil keeps the view model's default.
  nonisolated static func initialTab(
    for did: String, subscribedLabelerDIDs: some Sequence<String>
  ) -> ProfileTab? {
    if did == ModerationPrefs.blueskyModerationDID || subscribedLabelerDIDs.contains(did) {
      return .labelerInfo
    }
    return nil
  }
}
