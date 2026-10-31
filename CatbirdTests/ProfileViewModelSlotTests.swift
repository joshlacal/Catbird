import Testing

@testable import Catbird

/// UnifiedProfileView keeps its view model in a slot so that the struct re-inits and the brief
/// extra screens SwiftUI makes during navigation build no view models; only the screen's first
/// read of `viewModel`, when it appears, builds one.
@Suite("Profile view model slot")
@MainActor
struct ProfileViewModelSlotTests {
  @Test("A slot builds nothing until viewModel is read")
  func buildsNothingUntilRead() {
    let slot = Self.makeSlot()

    #expect(slot.builtViewModel == nil)
    #expect(slot.userDID == "did:plc:slot-test")
  }

  @Test("Every read returns the one view model built on the first read")
  func buildsOnce() {
    let slot = Self.makeSlot()

    let first = slot.viewModel
    let second = slot.viewModel

    #expect(first === second)
    #expect(slot.builtViewModel === first)
    #expect(first.userDID == slot.userDID)
    #expect(first.currentUserDID == "did:plc:viewer")
  }

  // The integration's addition: the slot also carries the tab the screen opens on, which
  // Oct 11's init(did:) used to set on an eagerly built view model.

  @Test("An initial tab is applied when the view model is built, not before")
  func appliesInitialTabOnBuild() {
    let slot = ProfileViewModelSlot(
      client: nil, userDID: "did:plc:labeler", currentUserDID: "did:plc:viewer",
      initialProfileTab: .labelerInfo
    )

    #expect(slot.builtViewModel == nil)
    #expect(slot.viewModel.selectedProfileTab == .labelerInfo)
  }

  @Test("Without an initial tab a profile opens on Posts")
  func defaultsToPosts() {
    #expect(Self.makeSlot().viewModel.selectedProfileTab == .posts)
  }

  @Test("Without an initial tab Bluesky's moderation service keeps the view model's Labeler Info")
  func moderationServiceKeepsLabelerInfo() {
    let slot = ProfileViewModelSlot(
      client: nil, userDID: ModerationPrefs.blueskyModerationDID, currentUserDID: "did:plc:viewer"
    )

    #expect(slot.viewModel.selectedProfileTab == .labelerInfo)
  }

  @Test("Subscribed labelers and the moderation service open on Labeler Info; others keep the default")
  func initialTabForDID() {
    let subscribed = ["did:plc:labeler-a", "did:plc:labeler-b"]

    #expect(ProfileViewModelSlot.initialTab(for: "did:plc:labeler-b", subscribedLabelerDIDs: subscribed) == .labelerInfo)
    #expect(ProfileViewModelSlot.initialTab(
      for: ModerationPrefs.blueskyModerationDID, subscribedLabelerDIDs: [String]()
    ) == .labelerInfo)
    #expect(ProfileViewModelSlot.initialTab(for: "did:plc:person", subscribedLabelerDIDs: subscribed) == nil)
  }

  private static func makeSlot() -> ProfileViewModelSlot {
    ProfileViewModelSlot(client: nil, userDID: "did:plc:slot-test", currentUserDID: "did:plc:viewer")
  }
}
