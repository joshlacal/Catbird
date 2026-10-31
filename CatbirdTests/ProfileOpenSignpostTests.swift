import Testing

@testable import Catbird

/// ProfileOpen runs from a profile's first load to its first post row. It must end exactly
/// once on every path, including those that never show a row, and say which path it took so
/// only first-row ends count toward the measurement protocol's numbers.
@Suite("Profile open signpost")
@MainActor
struct ProfileOpenSignpostTests {
  @Test("The interval ends at the first row, and later rows and fallbacks do nothing")
  func endsOnceAtFirstRow() {
    let viewModel = Self.makeViewModel()

    viewModel.beginOpenSignpost()
    #expect(viewModel.isOpenSignpostActive)

    viewModel.markFirstPostVisible()
    #expect(!viewModel.isOpenSignpostActive)

    viewModel.markFirstPostVisible()
    viewModel.endOpenSignpostIfNothingToShow()
    viewModel.abandonOpenSignpost()
    #expect(!viewModel.isOpenSignpostActive)
  }

  @Test("Only the first load of a view model is measured")
  func measuresOnlyTheFirstLoad() {
    let viewModel = Self.makeViewModel()

    viewModel.beginOpenSignpost()
    viewModel.abandonOpenSignpost()
    viewModel.beginOpenSignpost()

    #expect(!viewModel.isOpenSignpostActive)
  }

  @Test("A first load that brings no profile ends the interval as failed")
  func missingProfileEndsTheInterval() {
    let viewModel = Self.makeViewModel()

    viewModel.beginOpenSignpost()
    viewModel.endOpenSignpostIfNothingToShow()

    #expect(!viewModel.isOpenSignpostActive)
  }

  @Test("Fallback outcomes: failed without a profile, noRows for an empty post tab, nonPostTab otherwise")
  func fallbackOutcomes() {
    #expect(ProfileViewModel.openOutcomeWithoutRows(hasProfile: false, tab: .posts, tabIsEmpty: false) == .failed)
    #expect(ProfileViewModel.openOutcomeWithoutRows(hasProfile: true, tab: .posts, tabIsEmpty: true) == .noRows)
    #expect(ProfileViewModel.openOutcomeWithoutRows(hasProfile: true, tab: .replies, tabIsEmpty: true) == .noRows)
    #expect(ProfileViewModel.openOutcomeWithoutRows(hasProfile: true, tab: .media, tabIsEmpty: true) == .noRows)
    #expect(ProfileViewModel.openOutcomeWithoutRows(hasProfile: true, tab: .labelerInfo, tabIsEmpty: true) == .nonPostTab)
    #expect(ProfileViewModel.openOutcomeWithoutRows(hasProfile: true, tab: .more, tabIsEmpty: true) == .nonPostTab)
  }

  @Test("A post tab with rows keeps the interval open for its first row")
  func rowsKeepTheIntervalOpen() {
    #expect(ProfileViewModel.openOutcomeWithoutRows(hasProfile: true, tab: .posts, tabIsEmpty: false) == nil)
    #expect(ProfileViewModel.openOutcomeWithoutRows(hasProfile: true, tab: .media, tabIsEmpty: false) == nil)
  }

  private static func makeViewModel() -> ProfileViewModel {
    ProfileViewModel(client: nil, userDID: "did:plc:signpost-test", currentUserDID: "did:plc:viewer")
  }
}
