
  // Test-only inspection/setup. Cache, projection, grouping and pagination logic
  // are extracted production code; only external hydration lookups are inert.
  func testSeedCachedGroups(_ groups: [GroupedNotification]) {
    unfilteredGroupedNotifications = groups
  }

  var testRawGroups: [GroupedNotification] { unfilteredGroupedNotifications }
  var testCursor: String? { cursor }
  var testCurrentPage: Int { currentPage }

  func testFetchPage(resetCursor: Bool) async {
    await fetchNotifications(resetCursor: resetCursor)
  }

  private func fetchPosts(uris: [ATProtocolURI]) async -> [ATProtocolURI: AppBskyFeedDefs.PostView] {
    [:]
  }

  private func fetchViewerFollowCreatedAtByURI(
    for notifications: [AppBskyNotificationListNotifications.Notification]
  ) async -> [ATProtocolURI: Date] {
    [:]
  }
