import Testing

@testable import Catbird

/// A profile's More sections reuse the profile screen's view model. It travels in the navigation
/// value, because SwiftUI can answer the push from a short-lived copy of the profile screen whose
/// own view model was never built, and the section host keeps whichever view model it gets first.
@Suite("Profile section view model reuse")
@MainActor
struct ProfileSectionViewModelReuseTests {
  @Test("A section value carries the view model of the profile that opened it")
  func sectionCarriesViewModel() {
    let viewModel = Self.makeViewModel(userDID: "did:plc:section-owner")

    let destination = ProfileNavigationDestination.section(.likes, of: viewModel)

    guard case .section(let tab, let did, let carried) = destination else {
      Issue.record("Expected a section destination, got \(destination)")
      return
    }
    #expect(tab == .likes)
    #expect(did == "did:plc:section-owner")
    #expect(carried === viewModel)
  }

  @Test("The section host reuses a view model for the same profile")
  func hostReusesMatchingViewModel() {
    let viewModel = Self.makeViewModel(userDID: "did:plc:section-owner")

    let reused = ProfileSectionHostView.reusableViewModel(
      viewModel, for: "did:plc:section-owner", viewer: Self.viewer
    )

    #expect(reused === viewModel)
  }

  @Test("The section host loads its own profile without a matching view model")
  func hostIgnoresMissingOrOtherViewModel() {
    let other = Self.makeViewModel(userDID: "did:plc:someone-else")

    #expect(ProfileSectionHostView.reusableViewModel(nil, for: "did:plc:section-owner", viewer: Self.viewer) == nil)
    #expect(ProfileSectionHostView.reusableViewModel(other, for: "did:plc:section-owner", viewer: Self.viewer) == nil)
  }

  @Test("The section host does not reuse another account's view model of the same profile")
  func hostIgnoresViewModelOfAnotherViewer() {
    let anotherAccounts = ProfileViewModel(
      client: nil, userDID: "did:plc:section-owner", currentUserDID: "did:plc:other-viewer"
    )

    #expect(ProfileSectionHostView.reusableViewModel(
      anotherAccounts, for: "did:plc:section-owner", viewer: Self.viewer
    ) == nil)
  }

  private static let viewer = "did:plc:viewer"

  private static func makeViewModel(userDID: String) -> ProfileViewModel {
    ProfileViewModel(client: nil, userDID: userDID, currentUserDID: viewer)
  }
}
