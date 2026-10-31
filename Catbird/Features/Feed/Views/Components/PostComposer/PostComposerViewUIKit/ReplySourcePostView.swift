import NukeUI
import Petrel
import SwiftUI

/// Reply source built from the same pieces as `PostView` (`PostHeaderView`, `Post`, `PostEmbed`
/// and the moderation gates) so pronouns, verification, labels and embeds match the feed.
/// Omits action buttons and the ellipsis menu; links push onto the composer's own stack.
struct ReplySourcePostView: View {
  let post: AppBskyFeedDefs.PostView
  var avatarSize: CGFloat = DesignTokens.Size.avatarLG
  @Binding var path: NavigationPath
  @State private var revealsBlockedSource = false
  @Environment(\.moderationPolicy) private var moderationPolicy

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
      } else {
        sourceContent(PostModerationPresentation.make(post: post, policy: moderationPolicy))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityIdentifier("reply-inline-source")
    .onChange(of: post.uri) { _, _ in revealsBlockedSource = false }
    .onChange(of: relationship) { _, _ in revealsBlockedSource = false }
  }

  /// Header beside the avatar; text and embed behind one body gate, with the
  /// embed behind the media gate as in the feed.
  private func sourceContent(_ moderation: PostModerationPresentation) -> some View {
    HStack(alignment: .top, spacing: 12) {
      sourceAvatar(concealed: moderation.concealsAvatar)

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
                                                     did: post.author.did),
            isAutomated: AutomationBadge.isSelfDeclared(labels: post.author.labels, authorDID: post.author.did)
          )
          .frame(maxWidth: .infinity, alignment: .leading)

          ModerationContentGate(ui: moderation.body) {
            ContentLabelView(causes: moderation.chips)
            Post(post: feedPost, isSelectable: true, path: $path, useUIKitSelectableText: true)
            if let embed = post.embed {
              PostEmbed(embed: embed, mediaModeration: moderation.media, path: $path, authorDID: post.author.did)
                .environment(\.postID, post.uri.uriString())
                .padding(.top, 6)
            }
          }
        } else {
          VStack(alignment: .leading, spacing: 2) {
            EmbeddedAuthorNameView(
              name: post.author.displayName ?? post.author.handle.description,
              verification: post.author.verification,
              isAutomated: AutomationBadge.isSelfDeclared(labels: post.author.labels, authorDID: post.author.did)
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

  @ViewBuilder
  private func sourceAvatar(concealed: Bool) -> some View {
    Group {
      if concealed {
        ModeratedAvatarPlaceholder(size: avatarSize)
      } else {
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
