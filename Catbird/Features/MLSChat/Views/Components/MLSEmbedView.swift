import SwiftUI
import Petrel

#if os(iOS)

/// Unified view for rendering MLS message embeds (record, link, or GIF)
struct MLSEmbedView: View {
  let embed: MLSEmbedData
  @Binding var navigationPath: NavigationPath

  var body: some View {
    switch embed {
    case .record(let recordEmbed):
      MLSRecordEmbedLoader(recordEmbed: recordEmbed, navigationPath: $navigationPath)

    case .link(let linkEmbed):
      MLSLinkCardView(linkEmbed: linkEmbed)

    case .gif(let gifEmbed):
      MLSGIFView(gifEmbed: gifEmbed)
    }
  }
}

// MARK: - Preview

#Preview("Record Embed") {
  MLSEmbedView(
    embed: .record(
      MLSRecordEmbed(
        uri: "at://did:plc:example/app.bsky.feed.post/abc123",
        cid: "bafyreiabc123",
        authorDID: "did:plc:example",
        previewText: "This is a preview of the quoted post...",
        createdAt: Date()
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
