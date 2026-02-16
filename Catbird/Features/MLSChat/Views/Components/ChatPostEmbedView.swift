import CatbirdMLSCore
import SwiftUI
import Petrel
import NukeUI
import OSLog

#if os(iOS)

/// Unified view for rendering Bluesky post embeds in chat messages.
/// Handles both full post data (ready to display) and minimal references (needs API fetch).
/// Uses the same rendering components as the Feed for consistency.
struct ChatPostEmbedView: View {
  let postEmbed: MLSPostEmbed
  @Binding var navigationPath: NavigationPath

  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme

  @State private var fetchedPost: AppBskyFeedDefs.PostView?
  @State private var isLoading = false
  @State private var loadError: String?

  private let logger = Logger(subsystem: "blue.catbird", category: "ChatPostEmbedView")

  var body: some View {
    Group {
      if let post = fetchedPost {
        // Full post data available - render rich preview
        fetchedPostView(post)
      } else if postEmbed.needsFetch {
        // Minimal data - need to fetch
        if isLoading {
          loadingView
        } else if let error = loadError {
          errorView(error)
        } else {
          placeholderView
        }
      } else {
        // Have enough local data to render
        localPostView
      }
    }
    .task {
      if postEmbed.needsFetch && fetchedPost == nil {
        await fetchPost()
      }
    }
  }

  // MARK: - Fetched Post View (Full API Data)

  @ViewBuilder
  private func fetchedPostView(_ post: AppBskyFeedDefs.PostView) -> some View {
    Button {
      navigateToPost()
    } label: {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
        // Author row
        authorRow(
          avatarURL: post.author.finalAvatarURL(),
          displayName: post.author.displayName ?? post.author.handle.description,
          handle: post.author.handle.description
        )

        // Post text
        if case let .knownType(record) = post.record,
           let feedPost = record as? AppBskyFeedPost,
           !feedPost.text.isEmpty {
          Text(feedPost.text)
            .designBody()
            .foregroundStyle(.primary)
            .lineLimit(4)
            .multilineTextAlignment(.leading)
        }

        // Embedded content (images, videos, links, etc.)
        if let embed = post.embed {
          PostEmbed(embed: embed, labels: post.labels, path: $navigationPath)
            .environment(\.postID, post.uri.uriString())
        }

        // Engagement stats
        engagementRow(
          likeCount: post.likeCount,
          replyCount: post.replyCount,
          repostCount: post.repostCount,
          indexedAt: post.indexedAt.date
        )
      }
      .chatEmbedCardStyle(colorScheme: colorScheme)
    }
    .buttonStyle(.plain)
  }

  // MARK: - Local Post View (From MLSPostEmbed Data)

  @ViewBuilder
  private var localPostView: some View {
    Button {
      navigateToPost()
    } label: {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
        // Author row
        authorRow(
          avatarURL: postEmbed.authorAvatar,
          displayName: postEmbed.authorDisplayName ?? postEmbed.authorHandle ?? "Unknown",
          handle: postEmbed.authorHandle ?? postEmbed.authorDid
        )

        // Post text
        if let text = postEmbed.text, !text.isEmpty {
          Text(text)
            .designBody()
            .foregroundStyle(.primary)
            .lineLimit(4)
            .multilineTextAlignment(.leading)
        }

        // Images if present
        if let images = postEmbed.images, !images.isEmpty {
          imageGrid(images: images)
        }

        // Engagement stats
        engagementRow(
          likeCount: postEmbed.likeCount,
          replyCount: postEmbed.replyCount,
          repostCount: postEmbed.repostCount,
          indexedAt: postEmbed.createdAt
        )
      }
      .chatEmbedCardStyle(colorScheme: colorScheme)
    }
    .buttonStyle(.plain)
  }

  // MARK: - Author Row

  @ViewBuilder
  private func authorRow(avatarURL: URL?, displayName: String, handle: String) -> some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      if let avatarURL {
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
        .frame(width: 32, height: 32)
        .clipShape(Circle())
      } else {
        Image(systemName: "person.circle.fill")
          .font(.system(size: 32))
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(displayName)
          .designBody()
          .fontWeight(.semibold)
          .foregroundStyle(.primary)
          .lineLimit(1)

        Text("@\(handle)")
          .designCaption()
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      Image(systemName: "text.bubble")
        .font(.system(size: 14))
        .foregroundColor(.accentColor)
    }
  }

  // MARK: - Image Grid

  @ViewBuilder
  private func imageGrid(images: [MLSPostImage]) -> some View {
    let displayImages = Array(images.prefix(4))

    switch displayImages.count {
    case 1:
      singleImage(displayImages[0])
    case 2:
      HStack(spacing: 4) {
        ForEach(Array(displayImages.enumerated()), id: \.offset) { _, image in
          imageCell(image)
        }
      }
    case 3:
      HStack(spacing: 4) {
        imageCell(displayImages[0])
        VStack(spacing: 4) {
          imageCell(displayImages[1])
          imageCell(displayImages[2])
        }
      }
    case 4:
      VStack(spacing: 4) {
        HStack(spacing: 4) {
          imageCell(displayImages[0])
          imageCell(displayImages[1])
        }
        HStack(spacing: 4) {
          imageCell(displayImages[2])
          imageCell(displayImages[3])
        }
      }
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  private func singleImage(_ image: MLSPostImage) -> some View {
    LazyImage(url: image.thumb) { state in
      if let image = state.image {
        image
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else if state.isLoading {
        ZStack {
          Color.gray.opacity(0.1)
          ProgressView()
            .scaleEffect(0.8)
        }
      } else {
        Color.gray.opacity(0.1)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 200)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private func imageCell(_ image: MLSPostImage) -> some View {
    LazyImage(url: image.thumb) { state in
      if let image = state.image {
        image
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else if state.isLoading {
        ZStack {
          Color.gray.opacity(0.1)
          ProgressView()
            .scaleEffect(0.6)
        }
      } else {
        Color.gray.opacity(0.1)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 100)
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  // MARK: - Engagement Row

  @ViewBuilder
  private func engagementRow(likeCount: Int?, replyCount: Int?, repostCount: Int?, indexedAt: Date?) -> some View {
    HStack(spacing: DesignTokens.Spacing.base) {
      if let replyCount {
        engagementItem(icon: "bubble.left", count: replyCount)
      }

      if let repostCount {
        engagementItem(icon: "arrow.2.squarepath", count: repostCount)
      }

      if let likeCount {
        engagementItem(icon: "heart", count: likeCount)
      }

      Spacer()

      if let date = indexedAt {
        Text(date.formatted(date: .abbreviated, time: .omitted))
          .designCaption()
          .foregroundColor(.secondary)
      }
    }
  }

  @ViewBuilder
  private func engagementItem(icon: String, count: Int) -> some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
        .font(.system(size: 12))
        .foregroundColor(.secondary)

      Text("\(count)")
        .designCaption()
        .foregroundColor(.secondary)
    }
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
    .chatEmbedCardStyle(colorScheme: colorScheme)
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

      Button("Tap to retry") {
        Task { await fetchPost() }
      }
      .designCaption()
      .foregroundColor(.accentColor)
    }
    .chatEmbedCardStyle(colorScheme: colorScheme, isError: true)
  }

  // MARK: - Placeholder State

  @ViewBuilder
  private var placeholderView: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      Label("Bluesky Post", systemImage: "quote.bubble")
        .designCaption()
        .foregroundColor(.accentColor)

      if let text = postEmbed.text {
        Text(text)
          .designFootnote()
          .lineLimit(3)
      }

      Text(postEmbed.uri)
        .designCaption()
        .foregroundColor(.secondary)
        .lineLimit(1)
    }
    .chatEmbedCardStyle(colorScheme: colorScheme)
    .onTapGesture {
      Task { await fetchPost() }
    }
  }

  // MARK: - Post Fetching

  private func fetchPost() async {
    guard fetchedPost == nil, !isLoading else { return }

    isLoading = true
    loadError = nil

    do {
      guard let uri = try? ATProtocolURI(uriString: postEmbed.uri) else {
        loadError = "Invalid post URI"
        isLoading = false
        return
      }

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

      fetchedPost = post
      logger.info("Fetched post embed: \(postEmbed.uri)")
    } catch {
      logger.error("Failed to fetch post embed: \(error.localizedDescription)")
      loadError = error.localizedDescription
    }

    isLoading = false
  }

  // MARK: - Navigation

  private func navigateToPost() {
    guard let atUri = try? ATProtocolURI(uriString: postEmbed.uri) else {
      logger.error("Invalid post URI: \(postEmbed.uri)")
      return
    }

    navigationPath.append(NavigationDestination.post(atUri))
    logger.info("Navigating to post: \(postEmbed.uri)")
  }
}

// MARK: - Chat Embed Card Style

private extension View {
  func chatEmbedCardStyle(colorScheme: ColorScheme, isError: Bool = false) -> some View {
    self
      .padding(DesignTokens.Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Size.radiusSM)
          .fill(isError ? Color.red.opacity(0.1) : Color.gray.opacity(0.1))
      )
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Size.radiusSM)
          .stroke(isError ? Color.red.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 1)
      )
  }
}

// MARK: - Preview

#Preview("Full Post Data") {
  ChatPostEmbedView(
    postEmbed: MLSPostEmbed(
      uri: "at://did:plc:example/app.bsky.feed.post/abc123",
      cid: "bafyreiabc123",
      authorDid: "did:plc:example",
      authorHandle: "alice.bsky.social",
      authorDisplayName: "Alice",
      text: "This is a complete post with all the data needed to render immediately!",
      createdAt: Date(),
      likeCount: 42,
      replyCount: 7,
      repostCount: 3
    ),
    navigationPath: .constant(NavigationPath())
  )
  .padding()
  .environment(AppStateManager.shared)
}

#Preview("Minimal Reference") {
  ChatPostEmbedView(
    postEmbed: MLSPostEmbed(
      uri: "at://did:plc:example/app.bsky.feed.post/xyz789",
      authorDid: "did:plc:example",
      text: "Preview text only..."
    ),
    navigationPath: .constant(NavigationPath())
  )
  .padding()
  .environment(AppStateManager.shared)
}

#endif
