import NukeUI
import Petrel
import SwiftUI

/// Reply source built from the same pieces as `PostView` (`PostHeaderView`, `Post`, `PostEmbed`,
/// `ContentLabelManager`) so pronouns, verification, labels and embeds match the feed.
/// Omits action buttons and the ellipsis menu; links push onto the composer's own stack.
struct ReplySourcePostView: View {
  let post: AppBskyFeedDefs.PostView
  var avatarSize: CGFloat = DesignTokens.Size.avatarLG
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
            Button("Show Original Post") { revealsBlockedSource = true }
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
    .accessibilityIdentifier("reply-inline-source")
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
        Group {
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
        .padding(.leading, avatarSize + 12)
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
    HStack(alignment: .top, spacing: 12) {
      sourceAvatar

      VStack(alignment: .leading, spacing: 6) {
        if case .knownType(let record) = post.record,
           let feedPost = record as? AppBskyFeedPost {
          // Same header the feed and thread use: name, verification, pronouns, handle, time.
          PostHeaderView(
            displayName: post.author.displayName ?? post.author.handle.description,
            handle: post.author.handle.description,
            timeAgo: feedPost.createdAt.date,
            pronouns: post.author.pronouns,
            verificationKind: VerificationBadge.kind(for: post.author.verification,
                                                     did: post.author.did)
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          Post(post: feedPost, isSelectable: true, path: $path, useUIKitSelectableText: true)
        } else {
          VStack(alignment: .leading, spacing: 2) {
            EmbeddedAuthorNameView(
              name: post.author.displayName ?? post.author.handle.description,
              verification: post.author.verification
            )
            .appHeadline()
            Text(verbatim: "@\(post.author.handle.description)")
              .appSubheadline()
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          Text("Original post text is unavailable.")
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var sourceAvatar: some View {
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
    .frame(width: avatarSize, height: avatarSize)
    .clipShape(Circle())
    .overlay {
      if post.author.status?.isLiveNow == true {
        Circle().strokeBorder(Color.red, lineWidth: 2)
      }
    }
    .accessibilityHidden(true)
  }
}
