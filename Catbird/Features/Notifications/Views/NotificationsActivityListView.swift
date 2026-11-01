import Petrel
import SwiftUI

/// A list view displaying an activity batch of posts from subscribed accounts
struct NotificationsActivityListView: View {
  let postURIs: [ATProtocolURI]
  @Binding var path: NavigationPath
  
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme

  @State private var posts: [AppBskyFeedDefs.PostView] = []
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var hasLoaded = false

  var body: some View {
    Group {
      if isLoading && posts.isEmpty {
        ProgressView()
          .padding()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let errorMessage = errorMessage {
        VStack(spacing: 12) {
          Text(errorMessage)
            .appBody()
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)

          Button("Retry") {
            Task { await loadPosts() }
          }
          .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if posts.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "bell.slash")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
          Text("No posts here")
            .appFont(AppTextRole.headline)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        PostListCollectionView(
          posts: posts,
          onRefresh: { await loadPosts() },
          appState: appState,
          accessibilityIdentifier: "notifications.activity.posts"
        ) { post in
          VStack(spacing: 0) {
            EnhancedFeedPost(
              feedViewPost: AppBskyFeedDefs.FeedViewPost(post: post),
              path: $path
            )

            Rectangle()
              .fill(Color.separator)
              .frame(height: 0.5)
          }
        }
      }
    }
    .background(
      Color.primaryBackground(
        themeManager: appState.themeManager,
        currentScheme: colorScheme
      )
    )
    .navigationTitle("Activity")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .task {
      guard !hasLoaded else { return }
      await loadPosts()
    }
    .refreshable {
      await loadPosts()
    }
  }

  private func loadPosts() async {
    guard !postURIs.isEmpty else {
      posts = []
      isLoading = false
      return
    }

    let client = appState.client

    isLoading = true
    errorMessage = nil

    do {
      let (responseCode, output) = try await client.app.bsky.feed.getPosts(
        input: .init(uris: postURIs)
      )

      guard (200 ... 299).contains(responseCode), let fetchedPosts = output?.posts else {
        errorMessage = "Couldn’t load these posts. Try again."
        isLoading = false
        return
      }

      // Build dictionary for fast lookup
      var postMap: [ATProtocolURI: AppBskyFeedDefs.PostView] = [:]
      for post in fetchedPosts {
        postMap[post.uri] = post
      }

      // Restore requested newest-first order and filter out deleted/missing posts
      posts = postURIs.compactMap { postMap[$0] }
      hasLoaded = true
      isLoading = false
    } catch {
      errorMessage = UserFacingError.message(for: error, action: "load these posts")
      isLoading = false
    }
  }
}
