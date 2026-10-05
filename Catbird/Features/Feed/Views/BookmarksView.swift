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
    hSizeClass == .compact ? .infinity : 600
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
    .toolbar {
      ToolbarItem(placement: .automatic) {
        if isLoading {
          ProgressView()
            .scaleEffect(0.8)
        }
      }
    }
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
    VStack(spacing: 24) {
      Image(systemName: "bookmark.fill")
        .font(.system(size: 64))
        .foregroundColor(.secondary)
      
      VStack(spacing: 8) {
        Text("No Bookmarks")
          .appFont(AppTextRole.title2)
          .fontWeight(.semibold)
        
        Text("Posts you bookmark will appear here.")
          .appFont(AppTextRole.body)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .padding()
    .background(Color.primaryBackground(themeManager: appState.themeManager, currentScheme: colorScheme))
  }
  
  // MARK: - Bookmarks List
  private var bookmarksListView: some View {
    List {
      ForEach(Array(bookmarks.enumerated()), id: \.element.subject.uri) { _, bookmarkView in
        bookmarkRowView(bookmarkView)
              .listRowBackground(Color.primaryBackground(themeManager: appState.themeManager, currentScheme: colorScheme))

          // Hide only the very top separator
      }
      
      // Load more content
      if hasMoreContent && !bookmarks.isEmpty && !isLoading {
        HStack {
          Spacer()
          ProgressView()
            .scaleEffect(0.8)
          Spacer()
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.primaryBackground(themeManager: appState.themeManager, currentScheme: colorScheme))

        .task {
          await loadMoreBookmarks()
        }
      }
    }
    .listRowInsets(EdgeInsets()) 
    .listStyle(.plain)
    .background(Color.primaryBackground(themeManager: appState.themeManager, currentScheme: colorScheme))
  }
  
  // MARK: - Bookmark Row
  @ViewBuilder
  private func bookmarkRowView(_ bookmarkView: AppBskyBookmarkDefs.BookmarkView) -> some View {
    switch bookmarkView.item {
    case .appBskyFeedDefsPostView(let postView):
      PostView(
        post: postView,
        grandparentAuthor: nil,
        isParentPost: false,
        isSelectable: false,
        path: $path,
        appState: appState
      )
      .padding(.top, BookmarksView.baseUnit * 3)
      .padding(.horizontal, BookmarksView.baseUnit * 1.5)
      .fixedSize(horizontal: false, vertical: true)
      .contentShape(Rectangle())
      .allowsHitTesting(true)
      .frame(maxWidth: contentMaxWidth, alignment: .center)
      .frame(maxWidth: .infinity, alignment: .center)
      .onTapGesture { path.append(NavigationDestination.post(postView.uri)) }
      .alignmentGuide(.listRowSeparatorLeading) { _ in 0}
      .alignmentGuide(.listRowSeparatorTrailing) { d in d.width}
      .listRowSeparator(.visible)
      .listRowInsets(EdgeInsets())

    case .appBskyFeedDefsBlockedPost(let blocked):
      BlockedContentCard(
        relationship: BlockRelationship(blockedPost: blocked),
        authorDid: blocked.author.did.didString(),
        postUri: blocked.uri,
        variant: .feed,
        path: $path
      )
      .padding(.top, BookmarksView.baseUnit * 3)
      .padding(.horizontal, BookmarksView.baseUnit * 1.5)
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets())

    case .appBskyFeedDefsNotFoundPost:
      VStack {
        HStack {
          Image(systemName: "exclamationmark.triangle")
            .foregroundColor(.orange)
          Text("Post unavailable")
            .foregroundColor(.secondary)
          Spacer()
        }
        .padding()
      }
      .background(Color.secondary.opacity(0.1))
      .cornerRadius(8)
      .listRowSeparator(.hidden)

    case .unexpected:
      EmptyView()
}
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
