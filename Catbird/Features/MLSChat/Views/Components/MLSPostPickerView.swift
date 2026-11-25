import SwiftUI
import Petrel
import OSLog
import CatbirdMLSCore

/// Picker view for selecting a Bluesky post to share in MLS chat
struct MLSPostPickerView: View {
  let onSelect: (AppBskyFeedDefs.PostView) -> Void

  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  @State private var posts: [AppBskyFeedDefs.PostView] = []
  @State private var isLoading = false
  @State private var error: String?

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSPostPickerView")

  var body: some View {
    NavigationStack {
      Group {
        if isLoading {
          loadingView
        } else if let error = error {
          errorView(error)
        } else if posts.isEmpty {
          emptyView
        } else {
          postList
        }
      }
      .navigationTitle("Share a Post")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
      }
      .task {
        await loadPosts()
      }
    }
  }

  // MARK: - Loading State

  @ViewBuilder
  private var loadingView: some View {
    VStack(spacing: DesignTokens.Spacing.base) {
      ProgressView()
        .scaleEffect(1.2)

      Text("Loading your posts...")
        .designBody()
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Error State

  @ViewBuilder
  private func errorView(_ errorMessage: String) -> some View {
    VStack(spacing: DesignTokens.Spacing.base) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 48))
        .foregroundColor(.red)

      Text("Failed to Load Posts")
        .designTitle2()

      Text(errorMessage)
        .designBody()
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)

      Button("Try Again") {
        Task {
          await loadPosts()
        }
      }
      .buttonStyle(.catbird(.tonal))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Empty State

  @ViewBuilder
  private var emptyView: some View {
    VStack(spacing: DesignTokens.Spacing.base) {
      Image(systemName: "text.bubble")
        .font(.system(size: 48))
        .foregroundColor(.secondary)

      Text("No Posts Found")
        .designTitle2()

      Text("You don't have any recent posts to share.")
        .designBody()
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Post List

  @ViewBuilder
  private var postList: some View {
    List {
        ForEach(posts, id: \.uri.description) { post in
        Button {
          onSelect(post)
          dismiss()
        } label: {
          PostPickerRow(post: post)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: Space.sm, bottom: 0, trailing: Space.sm))
      }
    }
    .listStyle(.plain)
  }

  // MARK: - Load Posts

  private func loadPosts() async {
    guard let client = appState.atProtoClient,
          let currentUser = appState.currentUserProfile else {
      error = String(localized: "Not authenticated", comment: "Error when loading posts while signed out")
      return
    }

    isLoading = true
    error = nil

    do {
      let (responseCode, response) = try await client.app.bsky.feed.getAuthorFeed(
        input: .init(
            actor: ATIdentifier(string: currentUser.handle.description),
          limit: 50,
          filter: "posts_no_replies",
          includePins: false
        )
      )

      guard responseCode == 200, let feed = response?.feed else {
        error = String(localized: "Failed to load posts (HTTP \(responseCode))", comment: "Error when loading posts to share in chat fails. %lld is the HTTP status code.")
        isLoading = false
        return
      }

      posts = feed.map { $0.post }
      logger.info("Loaded \(self.posts.count) posts for sharing")
    } catch {
      logger.error("Failed to load posts: \(error.localizedDescription)")
      self.error = error.localizedDescription
    }

    isLoading = false
  }
}

// MARK: - Post Picker Row

private struct PostPickerRow: View {
  let post: AppBskyFeedDefs.PostView

  private var bodyText: String {
    if case let .knownType(record) = post.record, let feedPost = record as? AppBskyFeedPost {
      return feedPost.text
    }
    return ""
  }

  private var thumbURL: URL? {
    if case .appBskyEmbedImagesView(let images) = post.embed, let first = images.images.first {
      return URL(string: first.thumb.uriString())
    }
    return nil
  }

  var body: some View {
    HStack(alignment: .top, spacing: Space.sm) {
      CompactPostCard(
        avatarURL: post.author.avatar.flatMap { URL(string: $0.uriString()) },
        displayName: post.author.displayName ?? post.author.handle.description,
        handle: post.author.handle.description,
        text: bodyText,
        imageURL: thumbURL,
        did: post.author.did.didString(),
        lineLimit: 3,
        showsChrome: false
      ) {
        // Metadata
        HStack(spacing: Space.sm) {
          Text(post.indexedAt.date.formatted(date: .abbreviated, time: .omitted))
            .designCaption()
            .foregroundColor(.secondary)

          if let likeCount = post.likeCount, likeCount > 0 {
            Label {
              Text(likeCount, format: .number)
            } icon: {
              Image(systemName: "heart")
            }
              .designCaption()
              .foregroundColor(.secondary)
          }

          if let replyCount = post.replyCount, replyCount > 0 {
            Label {
              Text(replyCount, format: .number)
            } icon: {
              Image(systemName: "bubble.left")
            }
              .designCaption()
              .foregroundColor(.secondary)
          }
        }
      }

      // Indicator that a post has images but no inline thumbnail (e.g. galleries)
      if thumbURL == nil, let embed = post.embed, hasImages(embed) {
        Image(systemName: "photo")
          .font(.system(size: 20))
          .foregroundColor(.secondary)
      }
    }
  }

  private func hasImages(_ embed: AppBskyFeedDefs.PostViewEmbedUnion) -> Bool {
    switch embed {
    case .appBskyEmbedImagesView, .appBskyEmbedGalleryView:
      return true
    default:
      return false
    }
  }
}

// MARK: - Preview

#Preview {
  AsyncPreviewContent { appState in
    MLSPostPickerView { post in
        _ = post.uri
      }
      .environment(AppStateManager.shared)
  }
}

