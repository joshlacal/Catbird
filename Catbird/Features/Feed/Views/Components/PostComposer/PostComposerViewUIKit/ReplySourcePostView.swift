import NukeUI
import Petrel
import SwiftUI

struct ReplyContextPanel: View {
  let post: AppBskyFeedDefs.PostView
  let availableHeight: CGFloat
  let onViewOriginal: () -> Void
  @Binding var path: NavigationPath

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .body) private var editorReserve: CGFloat = 160

  private var sourceHeight: CGFloat {
    guard !dynamicTypeSize.isAccessibilitySize,
          availableHeight >= editorReserve + 68 + 96 else { return 0 }
    return min(240, availableHeight - editorReserve - 68)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: sourceHeight > 0 ? 8 : 0) {
      HStack(spacing: 8) {
        Label("Replying to @\(post.author.handle.description)", systemImage: "arrowshape.turn.up.left")
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .accessibilityIdentifier("reply-source-identity")
        Spacer(minLength: 0)
        Button(action: onViewOriginal) {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View original post")
        .accessibilityIdentifier("reply-source-expand")
      }

      ScrollView {
        ReplySourcePostView(post: post, path: $path)
      }
      .frame(height: sourceHeight)
      .clipped()
      .allowsHitTesting(sourceHeight > 0)
      .accessibilityHidden(sourceHeight == 0)
      .accessibilityIdentifier("reply-source-scroll")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 4)
    .accessibilityIdentifier("reply-source-panel")
  }
}

/// Source context omits social actions and retains existing content and moderation behavior.
struct ReplySourcePostView: View {
  let post: AppBskyFeedDefs.PostView
  @Binding var path: NavigationPath
  @State private var revealsBlockedSource = false

  private var selfLabelValues: [String] {
    guard case .knownType(let record) = post.record,
          let feedPost = record as? AppBskyFeedPost,
          let postLabels = feedPost.labels,
          case .comAtprotoLabelDefsSelfLabels(let labels) = postLabels else { return [] }
    return labels.values.map { $0.val.lowercased() }
  }

  var body: some View {
    let relationship = BlockRelationship(viewer: post.author.viewer)
    Group {
      if relationship.direction != .unknown && !(relationship.canReveal && revealsBlockedSource) {
        VStack(alignment: .leading, spacing: 12) {
          Label(relationship.statusText, systemImage: "hand.raised")
            .foregroundStyle(.secondary)
          if relationship.canReveal {
            Button("Show original post") { revealsBlockedSource = true }
              .frame(minHeight: 44)
              .accessibilityIdentifier("reply-blocked-source-reveal")
          }
        }
      } else if post.embed == nil {
        ContentLabelManager(labels: post.labels, selfLabelValues: selfLabelValues, contentType: "post") {
          sourceContent
        }
      } else {
        sourceContent
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityIdentifier("reply-original-post")
    .onChange(of: post.uri) { _, _ in revealsBlockedSource = false }
    .onChange(of: relationship) { _, _ in revealsBlockedSource = false }
  }

  @ViewBuilder
  private var sourceContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      if post.embed != nil && !selfLabelValues.isEmpty {
        ContentLabelManager(labels: nil, selfLabelValues: selfLabelValues, contentType: "post") {
          sourceText
        }
      } else {
        sourceText
      }

      if let embed = post.embed {
        if selfLabelValues.isEmpty {
          sourceEmbed(embed, labels: post.labels)
        } else {
          // Merge parent labels once for this media, retaining self-label safety.
          // The embed's own parent-label gates receive nil to avoid a nested duplicate.
          ContentLabelManager(labels: post.labels, selfLabelValues: selfLabelValues, contentType: "media") {
            sourceEmbed(embed, labels: nil)
          }
        }
      }
    }
  }

  private func sourceEmbed(_ embed: AppBskyFeedDefs.PostViewEmbedUnion,
                           labels: [ComAtprotoLabelDefs.Label]?) -> some View {
    PostEmbed(embed: embed, labels: labels, path: $path, authorDID: post.author.did)
      .environment(\.postID, post.uri.uriString())
  }

  @ViewBuilder
  private var sourceText: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        LazyImage(url: post.author.finalAvatarURL()) { state in
          if let image = state.image {
            image.resizable().scaledToFill()
          } else {
            Image(systemName: "person.circle.fill")
              .resizable()
              .scaledToFit()
              .foregroundStyle(.secondary)
          }
        }
        .frame(width: DesignTokens.Size.avatarLG, height: DesignTokens.Size.avatarLG)
        .clipShape(Circle())
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(post.author.displayName ?? post.author.handle.description)
            .appHeadline()
          Text(verbatim: "@\(post.author.handle.description)")
            .appSubheadline()
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        Spacer(minLength: 0)
      }

      if case .knownType(let record) = post.record,
         let feedPost = record as? AppBskyFeedPost {
        Post(post: feedPost, isSelectable: true, path: $path, useUIKitSelectableText: true)
      } else {
        Text("Original post text is unavailable.")
          .foregroundStyle(.secondary)
      }

    }
  }
}
