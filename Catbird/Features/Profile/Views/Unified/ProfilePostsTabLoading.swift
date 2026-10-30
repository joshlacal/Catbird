import Foundation

/// When a profile post tab shows its loading states. Shared by the iOS list header and the
/// macOS posts tab so the two cannot drift apart.
enum ProfilePostsTabLoading {
  /// Whether the Posts tab shows its "Loading…" row instead of rows or "No Posts".
  ///
  /// The first page loads alongside the header, so an empty tab is still loading until that
  /// request finishes. A pinned post is a row, so paging past a pin-only first page keeps
  /// showing it rather than a spinner.
  static func showsSpinner(
    hasAttempted: Bool, isLoading: Bool, isLoadingMore: Bool, postsEmpty: Bool, hasPinned: Bool
  ) -> Bool {
    !hasAttempted || (isLoading && postsEmpty) || (isLoadingMore && postsEmpty && !hasPinned)
  }

  /// The list footer under a profile post tab. An empty tab already shows its spinner in the
  /// header, so the footer stays hidden until there is a row to page after.
  static func footerState(hasMore: Bool, isLoadingMore: Bool, listIsEmpty: Bool) -> PostListFooterState {
    hasMore && isLoadingMore && !listIsEmpty ? .loading : .hidden
  }
}
