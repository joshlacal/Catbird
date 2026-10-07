//
//  BookmarksView.swift
//  Catbird
//
//  Created by Claude on 9/5/24.
//

import Foundation
import SwiftUI
import Petrel
import OSLog

struct BookmarksView: View {
  // MARK: - Properties
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.horizontalSizeClass) private var hSizeClass
  @Binding var path: NavigationPath

  private var contentMaxWidth: CGFloat {
    #if os(macOS)
    return 700
    #else
    return hSizeClass == .compact ? .infinity : 600
    #endif
  }
  
  // State
  @State private var bookmarks: [AppBskyBookmarkDefs.BookmarkView] = []
  @State private var isLoading = false
  @State private var hasLoaded = false
  @State private var loadError: String?
  @State private var cursor: String?
  @State private var hasMoreContent = true
  
  // Performance
  private let logger = Logger(subsystem: "blue.catbird", category: "BookmarksView")
  
  private static let baseUnit: CGFloat = 3

  // MARK: - Body
  var body: some View {
    Group {
      if !bookmarks.isEmpty {
        bookmarksListView
      } else if let loadError, !isLoading {
        ContentUnavailableStateView(
          title: "Couldn’t Load Bookmarks",
          description: loadError,
          systemImage: "bookmark.slash",
          actionTitle: "Try Again"
        ) {
          Task { await loadInitialBookmarks() }
        }
      } else if hasLoaded && !isLoading {
        emptyStateView
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle("Bookmarks")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .task {
      await loadInitialBookmarks()
    }
    .refreshable {
      await refreshBookmarks()
    }
    .background(Color.primaryBackground(themeManager: appState.themeManager, currentScheme: colorScheme))
  }
  
  // MARK: - Empty State
  private var emptyStateView: some View {
    ContentUnavailableView {
      Label("No Bookmarks", systemImage: "bookmark")
    } description: {
      Text("Tap the bookmark button on any post to save it here for later.")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  
  // MARK: - Bookmarks List
  private var bookmarksListView: some View {
    List {
      ForEach(bookmarks, id: \.subject.uri) { bookmarkView in
        bookmarkRowView(bookmarkView)
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
              Task { await removeBookmark(bookmarkView) }
            } label: {
              Label("Remove Bookmark", systemImage: "bookmark.slash")
            }
          }
      }
      
      // Load more content
      if hasMoreContent && !isLoading {
        ProgressView()
          .frame(maxWidth: .infinity)
          .padding(.vertical, BookmarksView.baseUnit * 6)
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .task {
            await loadMoreBookmarks()
          }
      }
    }
    .listStyle(.plain)
    .listSectionSeparator(.hidden)
    .scrollContentBackground(.hidden)
    .environment(\.defaultMinListRowHeight, 0)
  }
  
  // MARK: - Bookmark Row
  /// Matches the main feed: the same post component, spacing, and full-width hairline divider.
  @ViewBuilder
  private func bookmarkRowView(_ bookmarkView: AppBskyBookmarkDefs.BookmarkView) -> some View {
    VStack(spacing: 0) {
      switch bookmarkView.item {
      case .appBskyFeedDefsPostView(let postView):
        EnhancedFeedPost(
          feedViewPost: AppBskyFeedDefs.FeedViewPost(post: postView),
          path: $path
        )

      case .appBskyFeedDefsBlockedPost(let blocked):
        BlockedContentCard(
          relationship: BlockRelationship(blockedPost: blocked),
          authorDid: blocked.author.did.didString(),
          postUri: blocked.uri,
          variant: .feed,
          path: $path
        )
        .padding(.vertical, BookmarksView.baseUnit * 3)
        .padding(.horizontal, BookmarksView.baseUnit * 4)
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity)

      case .appBskyFeedDefsNotFoundPost:
        unavailablePostRow

      case .unexpected:
        unavailablePostRow
      }

      Rectangle()
        .fill(Color.separator)
        .frame(height: 0.5)
    }
  }

  private var unavailablePostRow: some View {
    HStack(spacing: BookmarksView.baseUnit * 3) {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text("Post unavailable")
          .appFont(AppTextRole.subheadline.weight(.semibold))
        Text("It may have been deleted. Swipe to remove this bookmark.")
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, BookmarksView.baseUnit * 4)
    .padding(.horizontal, BookmarksView.baseUnit * 5)
    .frame(maxWidth: contentMaxWidth)
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
  
  // MARK: - Data Loading
  
  /// Loads initial bookmarks
  private func loadInitialBookmarks() async {
    guard !isLoading else { return }
    guard let client = appState.atProtoClient else {
      loadError = "Couldn’t load your bookmarks. Sign in again and try again."
      return
    }
    
    isLoading = true
    loadError = nil
    
    do {
      let (fetchedBookmarks, nextCursor) = try await appState.bookmarksManager.fetchBookmarks(
        client: client,
        limit: 50,
        cursor: nil
      )
      
      await MainActor.run {
        self.bookmarks = fetchedBookmarks
        self.cursor = nextCursor
        // If we got no bookmarks OR no cursor, there's no more content
        self.hasMoreContent = nextCursor != nil && !fetchedBookmarks.isEmpty
        self.hasLoaded = true
        self.isLoading = false
      }
      
      logger.info("Loaded \(fetchedBookmarks.count) initial bookmarks")
      
    } catch {
      await MainActor.run {
        self.loadError = UserFacingError.message(for: error, action: "load your bookmarks")
        self.isLoading = false
      }
      logger.error("Failed to load initial bookmarks: \(error)")
    }
  }
  
  /// Refreshes bookmarks from the beginning
  private func refreshBookmarks() async {
    guard let client = appState.atProtoClient else { return }
    
    do {
      let (fetchedBookmarks, nextCursor) = try await appState.bookmarksManager.fetchBookmarks(
        client: client,
        limit: 50,
        cursor: nil
      )
      
      await MainActor.run {
        self.bookmarks = fetchedBookmarks
        self.cursor = nextCursor
        // If we got no bookmarks OR no cursor, there's no more content
        self.hasMoreContent = nextCursor != nil && !fetchedBookmarks.isEmpty
        self.hasLoaded = true
        self.loadError = nil
      }
      
      logger.info("Refreshed bookmarks: \(fetchedBookmarks.count) items")
      
    } catch {
      showFailureToast(for: error, action: "refresh your bookmarks")
      logger.error("Failed to refresh bookmarks: \(error)")
    }
  }
  
  /// Loads more bookmarks for pagination
  private func loadMoreBookmarks() async {
    guard hasMoreContent, !isLoading else { return }
    guard let client = appState.atProtoClient else { return }
    
    do {
      let (moreBookmarks, nextCursor) = try await appState.bookmarksManager.fetchBookmarks(
        client: client,
        limit: 50,
        cursor: cursor
      )
      
      await MainActor.run {
        self.bookmarks.append(contentsOf: moreBookmarks)
        self.cursor = nextCursor
        // If we got no bookmarks OR no cursor, there's no more content
        self.hasMoreContent = nextCursor != nil && !moreBookmarks.isEmpty
      }
      
      logger.info("Loaded \(moreBookmarks.count) more bookmarks")
      
    } catch {
      await MainActor.run {
        // Stop the footer from retrying in a loop; pull to refresh starts over.
        self.hasMoreContent = false
      }
      showFailureToast(for: error, action: "load more bookmarks")
      logger.error("Failed to load more bookmarks: \(error)")
    }
  }

  /// Removes a bookmark optimistically, restoring the row if the request fails.
  private func removeBookmark(_ bookmarkView: AppBskyBookmarkDefs.BookmarkView) async {
    guard let client = appState.atProtoClient,
          let index = bookmarks.firstIndex(where: { $0.subject.uri == bookmarkView.subject.uri })
    else { return }

    let postUri = bookmarkView.subject.uri
    let postUriString = postUri.uriString()
    withAnimation { _ = bookmarks.remove(at: index) }
    await appState.postShadowManager.setBookmarked(postUri: postUriString, isBookmarked: false)

    do {
      try await appState.bookmarksManager.deleteBookmark(postUri: postUri, client: client)
      appState.toastManager.show(ToastItem(message: "Bookmark removed", icon: "bookmark"))
    } catch {
      withAnimation { bookmarks.insert(bookmarkView, at: min(index, bookmarks.count)) }
      await appState.postShadowManager.setBookmarked(postUri: postUriString, isBookmarked: true)
      showFailureToast(for: error, action: "remove this bookmark")
      logger.error("Failed to remove bookmark: \(error)")
    }
  }

  private func showFailureToast(for error: Error, action: String) {
    guard let message = UserFacingError.message(for: error, action: action) else { return }
    appState.toastManager.show(ToastItem(message: message, icon: "exclamationmark.triangle.fill"))
  }
}

#Preview("BookmarksView") {
  @Previewable @State var path = NavigationPath()
  NavigationStack(path: $path) {
    BookmarksView(path: $path)
  }
  .previewWithAuthenticatedState()
}
