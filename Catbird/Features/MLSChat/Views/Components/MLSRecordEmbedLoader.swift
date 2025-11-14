import SwiftUI
import Petrel
import NukeUI
import OSLog

#if os(iOS)

/// Loads and renders Bluesky record embeds (quote posts) in MLS messages
struct MLSRecordEmbedLoader: View {
  let recordEmbed: MLSRecordEmbed
  @Binding var navigationPath: NavigationPath

  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme

  @State private var loadedPost: AppBskyEmbedRecord.ViewRecord?
  @State private var isLoading = false
  @State private var loadError: String?

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSRecordEmbedLoader")

  var body: some View {
    Group {
      if let post = loadedPost {
        loadedPostView(post)
      } else if isLoading {
        loadingView
      } else if let error = loadError {
        errorView(error)
      } else {
        placeholderView
      }
    }
    .task {
      await loadPost()
    }
  }

  // MARK: - Loaded Post View

  @ViewBuilder
  private func loadedPostView(_ post: AppBskyEmbedRecord.ViewRecord) -> some View {
    Button {
      if let atUri = try? ATProtocolURI(uriString: recordEmbed.uri) {
        navigationPath.append(NavigationDestination.post(atUri))
      }
    } label: {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
        // Author info
        HStack(spacing: DesignTokens.Spacing.sm) {
          if let avatarURL = post.author.finalAvatarURL() {
            LazyImage(url: avatarURL) { state in
              if let image = state.image {
                image
                  .resizable()
                  .aspectRatio(contentMode: .fill)
              } else {
                Image(systemName: "person.circle.fill")
                  .foregroundStyle(.secondary)
              }
            }
            .frame(width: 20, height: 20)
            .clipShape(Circle())
          }

          VStack(alignment: .leading, spacing: 2) {
            Text(post.author.displayName ?? post.author.handle.description)
              .designCaption()
              .fontWeight(.semibold)
              .foregroundStyle(.primary)
              .lineLimit(1)

            Text("@\(post.author.handle.description)")
              .designCaption()
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          Spacer()

          Image(systemName: "quote.bubble")
            .font(.system(size: 14))
            .foregroundColor(.accentColor)
        }

        // Post text
        if case let .knownType(record) = post.value,
           let feedPost = record as? AppBskyFeedPost,
           !feedPost.text.isEmpty {
          Text(feedPost.text)
            .designFootnote()
            .foregroundStyle(.primary)
            .lineLimit(4)
            .multilineTextAlignment(.leading)
        }

        // Timestamp
        if let createdAt = recordEmbed.createdAt {
          Text(createdAt.formatted(date: .abbreviated, time: .omitted))
            .designCaption()
            .foregroundColor(.secondary)
        }
      }
      .spacingSM()
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.gray.opacity(0.1))
      .cornerRadius(DesignTokens.Size.radiusSM)
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Size.radiusSM)
          .stroke(Color.gray.opacity(0.3), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Loading State

  @ViewBuilder
  private var loadingView: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      ProgressView()
        .scaleEffect(0.8)

      Text("Loading post...")
        .designFootnote()
        .foregroundColor(.secondary)
    }
    .spacingSM()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.gray.opacity(0.1))
    .cornerRadius(DesignTokens.Size.radiusSM)
  }

  // MARK: - Error State

  @ViewBuilder
  private func errorView(_ error: String) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      Label("Failed to load post", systemImage: "exclamationmark.triangle")
        .designCaption()
        .foregroundColor(.red)

      Text(error)
        .designCaption()
        .foregroundColor(.secondary)
        .lineLimit(2)
    }
    .spacingSM()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.red.opacity(0.1))
    .cornerRadius(DesignTokens.Size.radiusSM)
  }

  // MARK: - Placeholder State

  @ViewBuilder
  private var placeholderView: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      Label("Bluesky Post", systemImage: "quote.bubble")
        .designCaption()
        .foregroundColor(.accentColor)

      if let previewText = recordEmbed.previewText {
        Text(previewText)
          .designFootnote()
          .lineLimit(3)
      }

      Text(recordEmbed.uri)
        .designCaption()
        .foregroundColor(.secondary)
        .lineLimit(1)
    }
    .spacingSM()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.gray.opacity(0.1))
    .cornerRadius(DesignTokens.Size.radiusSM)
    .onTapGesture {
      Task {
        await loadPost()
      }
    }
  }

  // MARK: - Post Loading

  private func loadPost() async {
    guard loadedPost == nil, !isLoading else { return }

    isLoading = true
    loadError = nil

    do {
      // Parse AT-URI
        guard let uri = try? ATProtocolURI(uriString: recordEmbed.uri) else {
        loadError = "Invalid post URI"
        isLoading = false
        return
      }

      // Fetch post from Bluesky
      guard let client = appState.atProtoClient else {
        loadError = "AT Protocol client not available"
        isLoading = false
        return
      }

      let (responseCode, response) = try await client.app.bsky.feed.getPosts(
        input: .init(uris: [uri])
      )

      guard responseCode == 200, let posts = response?.posts, let post = posts.first else {
        loadError = "Post not found"
        isLoading = false
        return
      }

      // Convert FeedPost to ViewRecord format
      // Note: We omit the embeds field as it requires ViewRecordEmbedsUnion conversion
      // For our quote post preview, we only need the basic post info
      loadedPost = AppBskyEmbedRecord.ViewRecord(
        uri: uri,
        cid: post.cid,
        author: post.author,
        value: .knownType(post.record),
        labels: post.labels,
        replyCount: post.replyCount,
        repostCount: post.repostCount,
        likeCount: post.likeCount,
        quoteCount: post.quoteCount,
        embeds: nil,
        indexedAt: post.indexedAt
      )

      logger.info("Loaded record embed: \(recordEmbed.uri)")
    } catch {
      logger.error("Failed to load record embed: \(error.localizedDescription)")
      loadError = error.localizedDescription
    }

    isLoading = false
  }
}

// MARK: - Preview

#Preview {
    @Previewable @Environment(AppState.self) var appState
  MLSRecordEmbedLoader(
    recordEmbed: MLSRecordEmbed(
      uri: "at://did:plc:example/app.bsky.feed.post/abc123",
      cid: "bafyreiabc123",
      authorDID: "did:plc:example",
      previewText: "This is a preview of the quoted post...",
      createdAt: Date()
    ),
    navigationPath: .constant(NavigationPath())
  )
  .padding()
  .environment(AppStateManager.shared)
}

#endif
