import CatbirdMLSCore
import SwiftUI
import NukeUI

#if os(iOS)

/// Renders link preview cards in MLS messages (similar to ExternalEmbedView link cards)
struct MLSLinkCardView: View {
  let linkEmbed: MLSLinkEmbed

  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      // Thumbnail image if available
      if let thumbnailURL = linkEmbed.thumbnailURL,
         let url = URL(string: thumbnailURL) {
        thumbnailImage(url)
      }

      // Link details
      linkDetails
    }
    .padding(6)
    .background(Color.gray.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
    )
    .onTapGesture {
      if let url = URL(string: linkEmbed.url) {
        _ = appState.urlHandler.handle(url)
      }
    }
  }

  // MARK: - Thumbnail Image

  @ViewBuilder
  private func thumbnailImage(_ url: URL) -> some View {
    RoundedRectangle(cornerRadius: 7, style: .circular)
      .fill(Color.clear)
      .aspectRatio(1.91 / 1, contentMode: .fit)
      .overlay(
        LazyImage(url: url) { state in
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
            // Error or no image
            Color.gray.opacity(0.1)
          }
        }
        .clipped()
      )
      .clipShape(RoundedRectangle(cornerRadius: 7, style: .circular))
  }

  // MARK: - Link Details

  @ViewBuilder
  private var linkDetails: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Domain
      if let domain = linkEmbed.domain {
        Text(domain)
          .designCaption()
          .foregroundColor(.accentColor)
          .lineLimit(1)
      }

      // Title
      if let title = linkEmbed.title {
        Text(title)
          .designBody()
          .fontWeight(.semibold)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
      }

      // Description
      if let description = linkEmbed.description {
        Text(description)
          .designFootnote()
          .foregroundColor(.secondary)
          .lineLimit(3)
          .multilineTextAlignment(.leading)
      }

      // Full URL (fallback if no title)
      if linkEmbed.title == nil {
        Text(linkEmbed.url)
          .designCaption()
          .foregroundColor(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Preview

#Preview {
    @Previewable @Environment(AppState.self) var appState
  VStack(spacing: 20) {
    // Link with thumbnail
    MLSLinkCardView(
      linkEmbed: MLSLinkEmbed(
        url: "https://bsky.app",
        title: "Bluesky Social",
        description: "Social media as it should be. Find your community among millions of users, unleash your creativity, and have some fun again.",
        thumbnailURL: "https://bsky.app/static/social-card-default-gradient.png",
        domain: "bsky.app"
      )
    )

    // Link without thumbnail
    MLSLinkCardView(
      linkEmbed: MLSLinkEmbed(
        url: "https://example.com/article",
        title: "Interesting Article",
        description: "A detailed look at something fascinating...",
        thumbnailURL: nil,
        domain: "example.com"
      )
    )

    // Minimal link (just URL)
    MLSLinkCardView(
      linkEmbed: MLSLinkEmbed(
        url: "https://github.com",
        title: nil,
        description: nil,
        thumbnailURL: nil,
        domain: "github.com"
      )
    )
  }
  .padding()
  .environment(AppStateManager.shared)
}

#endif
