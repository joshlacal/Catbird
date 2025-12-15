import SwiftUI
import Petrel
import CatbirdMLSCore

#if os(iOS)

/// Unified view for rendering MLS message embeds (post, link, or GIF)
struct MLSEmbedView: View {
  let embed: MLSEmbedData
  @Binding var navigationPath: NavigationPath

  var body: some View {
    switch embed {
    case .link(let linkEmbed):
      MLSLinkCardView(linkEmbed: linkEmbed)

    case .gif(let gifEmbed):
      MLSGIFView(gifEmbed: gifEmbed)

    case .post(let postEmbed):
      ChatPostEmbedView(postEmbed: postEmbed, navigationPath: $navigationPath)
    }
  }
}

// MARK: - Preview

#Preview("Post Embed (minimal)") {
  MLSEmbedView(
    embed: .post(
      MLSPostEmbed(
        uri: "at://did:plc:example/app.bsky.feed.post/abc123",
        cid: "bafyreiabc123",
        authorDid: "did:plc:example",
        text: "This is a preview of the quoted post...",
        createdAt: Date()
      )
    ),
    navigationPath: .constant(NavigationPath())
  )
  .padding()
  .environment(AppStateManager.shared)
}

#Preview("Post Embed (full)") {
  MLSEmbedView(
    embed: .post(
      MLSPostEmbed(
        uri: "at://did:plc:example/app.bsky.feed.post/abc123",
        cid: "bafyreiabc123",
        authorDid: "did:plc:example",
        authorHandle: "alice.bsky.social",
        authorDisplayName: "Alice",
        text: "This is a full post with all the data!",
        createdAt: Date(),
        likeCount: 42,
        replyCount: 5,
        repostCount: 3
      )
    ),
    navigationPath: .constant(NavigationPath())
  )
  .padding()
  .environment(AppStateManager.shared)
}

#Preview("Link Embed") {
  MLSEmbedView(
    embed: .link(
      MLSLinkEmbed(
        url: "https://bsky.app",
        title: "Bluesky Social",
        description: "What's next in social media",
        thumbnailURL: nil,
        domain: "bsky.app"
      )
    ),
    navigationPath: .constant(NavigationPath())
  )
  .padding()
  .environment(AppStateManager.shared)
}

#Preview("GIF Embed") {
  MLSEmbedView(
    embed: .gif(
      MLSGIFEmbed(
        tenorURL: "https://media.tenor.com/example.gif",
        mp4URL: "https://media.tenor.com/example.mp4",
        title: "Funny Cat GIF",
        thumbnailURL: "https://media.tenor.com/example-thumb.jpg",
        width: 498,
        height: 280
      )
    ),
    navigationPath: .constant(NavigationPath())
  )
  .padding()
  .environment(AppStateManager.shared)
}

#endif
