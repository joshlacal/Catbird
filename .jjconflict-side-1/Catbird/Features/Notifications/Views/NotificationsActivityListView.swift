import Petrel
import SwiftUI

/// A list view displaying an activity batch of posts from subscribed accounts
struct NotificationsActivityListView: View {
  let postURIs: [ATProtocolURI]
  @Binding var path: NavigationPath
  
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.horizontalSizeClass) private var hSizeClass

  @State private var posts: [AppBskyFeedDefs.PostView] = []
  @State private var isLoading = true
  @State private var errorMessage: String?

  private var contentMaxWidth: CGFloat {
    hSizeClass == .compact ? .infinity : 600
  }

  var body: some View {
    VStack {
      if isLoading && posts.isEmpty {
        ProgressView()
          .padding()
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
      } else {
        List {
          ForEach(posts, id: \.uri) { post in
            Button {
              path.append(NavigationDestination.post(post.uri))
            } label: {
              PostView(
                post: post,
                grandparentAuthor: nil,
                isParentPost: false,
                isSelectable: false,
                path: $path,
                appState: appState
              )
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .listRowSeparator(.visible)
            .listRowSeparatorTint(Color.separator)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { d in d.width }
            .listRowBackground(
              Color.primaryBackground(
                themeManager: appState.themeManager,
                currentScheme: colorScheme
              )
            )
            .listRowInsets(EdgeInsets())
          }
        }
        .listStyle(.plain)
        .background(
          Color.primaryBackground(
            themeManager: appState.themeManager,
            currentScheme: colorScheme
          )
        )
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity, alignment: .center)
      }
    }
    .navigationTitle("Activity")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .task {
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
        errorMessage = "Failed to load posts (HTTP \(responseCode))"
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
      isLoading = false
    } catch {
      errorMessage = "Error loading posts: \(error.localizedDescription)"
      isLoading = false
    }
  }
}
