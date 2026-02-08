import SwiftUI
import Petrel
import OSLog
import CatbirdMLSService

#if os(iOS)

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
      .navigationBarTitleDisplayMode(.inline)
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
      .buttonStyle(.bordered)
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
      }
    }
    .listStyle(.plain)
  }

  // MARK: - Load Posts

  private func loadPosts() async {
    guard let client = appState.atProtoClient,
          let currentUser = appState.currentUserProfile else {
      error = "Not authenticated"
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
        error = "Failed to load posts (HTTP \(responseCode))"
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

  var body: some View {
    HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        // Post text
        if case let .knownType(record) = post.record,
           let feedPost = record as? AppBskyFeedPost,
           !feedPost.text.isEmpty {
          Text(feedPost.text)
            .designBody()
            .lineLimit(3)
            .multilineTextAlignment(.leading)
        }

        // Metadata
        HStack(spacing: DesignTokens.Spacing.sm) {
          Text(post.indexedAt.date.formatted(date: .abbreviated, time: .omitted))
            .designCaption()
            .foregroundColor(.secondary)

          if let likeCount = post.likeCount, likeCount > 0 {
            Label("\(likeCount)", systemImage: "heart")
              .designCaption()
              .foregroundColor(.secondary)
          }

          if let replyCount = post.replyCount, replyCount > 0 {
            Label("\(replyCount)", systemImage: "bubble.left")
              .designCaption()
              .foregroundColor(.secondary)
          }
        }
      }

      Spacer()

      // Indicator that post has images
      if let embed = post.embed, case .appBskyEmbedImagesView = embed {
        Image(systemName: "photo")
          .font(.system(size: 20))
          .foregroundColor(.secondary)
      }
    }
    .padding(.vertical, DesignTokens.Spacing.xs)
  }
}

// MARK: - Preview

#Preview {
  @Previewable @Environment(AppState.self) var appState
  MLSPostPickerView { post in
    _ = post.uri
  }
  .environment(AppStateManager.shared)
}

#endif
