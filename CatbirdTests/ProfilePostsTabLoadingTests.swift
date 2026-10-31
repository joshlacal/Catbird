import Testing

@testable import Catbird

/// A profile's header and first posts page load together, and the header usually lands
/// first. Until the page arrives the Posts tab must keep its spinner rather than say
/// "No Posts", and the list footer must not stack a second spinner under it.
@Suite("Profile posts tab loading states")
struct ProfilePostsTabLoadingTests {
  @Test("A tab that has not started loading shows its spinner")
  func notAttemptedShowsSpinner() {
    #expect(Self.spinner(hasAttempted: false))
  }

  @Test("Header landed and page 1 in flight: spinner, not 'No Posts'")
  func headerBeforeFirstPageShowsSpinner() {
    #expect(Self.spinner(isLoading: false, isLoadingMore: true, postsEmpty: true, hasPinned: false))
  }

  @Test("Page 1 finished empty: no spinner, so 'No Posts' shows")
  func emptyFirstPageShowsEmptyState() {
    #expect(!Self.spinner(isLoading: false, isLoadingMore: false, postsEmpty: true, hasPinned: false))
  }

  @Test("Paging past a pin-only first page keeps the pinned row instead of a spinner")
  func pinOnlyPagingKeepsPinnedRow() {
    #expect(!Self.spinner(isLoading: false, isLoadingMore: true, postsEmpty: true, hasPinned: true))
  }

  @Test("A refresh with rows on screen shows no spinner")
  func refreshWithRowsShowsNoSpinner() {
    #expect(!Self.spinner(isLoading: true, isLoadingMore: true, postsEmpty: false, hasPinned: false))
  }

  @Test("The header loading while the tab is empty still shows the spinner")
  func headerLoadingWhileEmptyShowsSpinner() {
    #expect(Self.spinner(isLoading: true, isLoadingMore: false, postsEmpty: true, hasPinned: true))
  }

  @Test("The footer spins only below rows that a page is being added to")
  func footerSpinsOnlyBelowRows() {
    #expect(ProfilePostsTabLoading.footerState(hasMore: true, isLoadingMore: true, listIsEmpty: true) == .hidden)
    #expect(ProfilePostsTabLoading.footerState(hasMore: true, isLoadingMore: true, listIsEmpty: false) == .loading)
    #expect(ProfilePostsTabLoading.footerState(hasMore: false, isLoadingMore: true, listIsEmpty: false) == .hidden)
    #expect(ProfilePostsTabLoading.footerState(hasMore: true, isLoadingMore: false, listIsEmpty: false) == .hidden)
  }

  private static func spinner(
    hasAttempted: Bool = true, isLoading: Bool = false, isLoadingMore: Bool = false,
    postsEmpty: Bool = true, hasPinned: Bool = false
  ) -> Bool {
    ProfilePostsTabLoading.showsSpinner(
      hasAttempted: hasAttempted, isLoading: isLoading, isLoadingMore: isLoadingMore,
      postsEmpty: postsEmpty, hasPinned: hasPinned
    )
  }
}
