import Foundation
import Testing

@testable import Catbird

/// A labeler opens on Labels, but only the first header load may choose that. Later loads (pull to
/// refresh, the reload after a follow, the refresh of a stale header on return) must leave a reader
/// who picked Posts on Posts.
@Suite("Profile labeler default tab")
@MainActor
struct ProfileLabelerDefaultTabTests {
  @Test("The first load opens a labeler on Labels; a later load keeps the tab the reader chose")
  func laterLoadsKeepTheChosenTab() {
    let viewModel = ProfileViewModel(
      client: nil, userDID: ModerationPrefs.blueskyModerationDID, currentUserDID: "did:plc:me")
    #expect(viewModel.isLabeler)
    viewModel.selectedProfileTab = .posts

    viewModel.applyDefaultTabForLoadedProfile()
    #expect(viewModel.selectedProfileTab == .labelerInfo)

    viewModel.selectedProfileTab = .posts
    viewModel.applyDefaultTabForLoadedProfile()
    #expect(viewModel.selectedProfileTab == .posts)
  }

  @Test("A profile that is not a labeler keeps Posts")
  func nonLabelerKeepsPosts() {
    let viewModel = ProfileViewModel(client: nil, userDID: "did:plc:someone", currentUserDID: "did:plc:me")
    #expect(!viewModel.isLabeler)

    viewModel.applyDefaultTabForLoadedProfile()

    #expect(viewModel.selectedProfileTab == .posts)
  }
}
