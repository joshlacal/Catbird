import NukeUI
import Petrel
import SwiftUI

/// App Store-style horizontally scrollable stat bar directly beneath the feed product header:
/// Likes / Saves, live Velocity from preview post timestamps, tappable Creator, and Category.
struct FeedProductMetadataStrip: View {
  let feed: AppBskyFeedDefs.GeneratorView
  let displayedLikeCount: Int
  let liked: Bool
  let velocityEstimate: FeedVelocityEstimate?
  let category: FeedDiscoveryCategory?

  var body: some View {
    VStack(spacing: 0) {
      Divider()
        .padding(.horizontal, 16)

      ScrollView(.horizontal) {
        HStack(spacing: 0) {
          metadataTile(
            header: "LIKES",
            value: FeedCountFormatter.compact(displayedLikeCount),
            footer: liked
              ? String(localized: "Liked", comment: "Footer under feed likes count when liked by the user")
              : String(localized: "Community", comment: "Footer under feed likes count showing community likes"),
            symbol: liked ? "heart.fill" : "heart"
          )

          metadataDivider

          if let velocity = velocityEstimate {
            metadataTile(
              header: "VELOCITY",
              value: velocity.shortLabel,
              footer: velocity.detailLabel,
              symbol: velocity.symbolName
            )
          } else {
            VStack(spacing: 4) {
              Text("VELOCITY", comment: "Feed product page stat header for posting pace")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
              ProgressView()
                .controlSize(.small)
                .frame(height: 22)
              Text("Measuring", comment: "Placeholder while calculating feed posting pace")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(minWidth: 96)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
          }

          metadataDivider

          NavigationLink(value: NavigationDestination.profile(feed.creator.did.didString())) {
            VStack(spacing: 4) {
              Text("CREATOR", comment: "Feed product page stat header for the feed creator")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
              Image(systemName: "person.crop.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(height: 22)
              Text(verbatim: "@\(feed.creator.handle.description)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: 112)
            }
            .frame(minWidth: 100)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(
            Text(
              "Creator @\(feed.creator.handle.description), view profile",
              comment: "Accessibility label for feed creator stat tile — variable is the creator's handle"
            )
          )
          .accessibilityIdentifier("feed.product.stat.creator")

          if let category {
            metadataDivider

            metadataTile(
              header: "CATEGORY",
              value: category.shortTitle,
              footer: String(localized: "Topic", comment: "Footer under feed category stat tile"),
              symbol: category.symbolName
            )
          }
        }
        .padding(.horizontal, 6)
      }
      .scrollIndicators(.hidden)
      .accessibilityIdentifier("feed.product.metadataStrip")

      Divider()
        .padding(.horizontal, 16)
    }
  }

  private func metadataTile(
    header: LocalizedStringKey,
    value: String,
    footer: String,
    symbol: String
  ) -> some View {
    VStack(spacing: 4) {
      Text(header)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)

      HStack(spacing: 4) {
        Image(systemName: symbol)
          .font(.caption.weight(.bold))
          .foregroundStyle(.secondary)
        Text(value)
          .font(.subheadline.weight(.bold).monospacedDigit())
          .foregroundStyle(.primary)
      }
      .frame(height: 22)

      Text(footer)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(minWidth: 96)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private var metadataDivider: some View {
    Divider()
      .frame(height: 36)
  }
}

/// Interactive App Store "Screenshot" card rendering a live recent post (including live media
/// when present) so feeds are judged by real content rather than blown-up avatars.
struct FeedPreviewScreenshotCard: View {
  let post: AppBskyFeedDefs.FeedViewPost
  let onTap: () -> Void

  private var postText: String {
    if case .knownType(let raw) = post.post.record, let feedPost = raw as? AppBskyFeedPost {
      return feedPost.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return ""
  }

  private var createdAt: Date {
    if case .knownType(let raw) = post.post.record, let feedPost = raw as? AppBskyFeedPost {
      return feedPost.createdAt.date
    }
    return post.post.indexedAt.date
  }

  private var mediaThumbURLs: [URL] {
    guard let embed = post.post.embed else { return [] }
    switch embed {
    case .appBskyEmbedImagesView(let imagesView):
      return imagesView.images.prefix(2).compactMap { URL(string: $0.thumb.uriString()) }
    case .appBskyEmbedVideoView(let videoView):
      if let thumb = videoView.thumbnail, let url = URL(string: thumb.uriString()) {
        return [url]
      }
      return []
    case .appBskyEmbedExternalView(let externalView):
      if let thumb = externalView.external.thumb, let url = URL(string: thumb.uriString()) {
        return [url]
      }
      return []
    case .appBskyEmbedRecordWithMediaView(let rwm):
      if case .appBskyEmbedImagesView(let imagesView) = rwm.media {
        return imagesView.images.prefix(2).compactMap { URL(string: $0.thumb.uriString()) }
      }
      return []
    default:
      return []
    }
  }

  private var authorDisplayName: String {
    let name = post.post.author.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return name.isEmpty ? post.post.author.handle.description : name
  }

  var body: some View {
    Button(action: onTap) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          ProfileAvatarView(
            url: post.post.author.finalAvatarURL(),
            fallbackText: String(authorDisplayName.prefix(1)).uppercased(),
            size: 30
          )

          VStack(alignment: .leading, spacing: 1) {
            Text(authorDisplayName)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.primary)
              .lineLimit(1)
            Text(verbatim: "@\(post.post.author.handle.description)")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          Spacer(minLength: 4)

          Text(createdAt, style: .relative)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }

        if !postText.isEmpty {
          Text(postText)
            .appFont(AppTextRole.subheadline)
            .foregroundStyle(.primary)
            .lineLimit(mediaThumbURLs.isEmpty ? 6 : 3)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }

        if !mediaThumbURLs.isEmpty {
          HStack(spacing: 6) {
            ForEach(mediaThumbURLs, id: \.self) { url in
              LazyImage(url: url) { state in
                if let image = state.image {
                  image
                    .resizable()
                    .scaledToFill()
                } else {
                  Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                }
              }
              .frame(height: 120)
              .frame(maxWidth: .infinity)
              .clipShape(.rect(cornerRadius: Radius.md.value, style: .continuous))
            }
          }
        }

        Spacer(minLength: 0)

        HStack(spacing: 14) {
          Label {
            Text(post.post.replyCount ?? 0, format: .number)
          } icon: {
            Image(systemName: "bubble.right")
          }
          Label {
            Text(post.post.repostCount ?? 0, format: .number)
          } icon: {
            Image(systemName: "arrow.2.squarepath")
          }
          Label {
            Text(post.post.likeCount ?? 0, format: .number)
          } icon: {
            Image(systemName: "heart")
          }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
      }
      .padding(14)
      .frame(minHeight: 196, alignment: .topLeading)
      .background(
        Color(platformColor: .platformSecondarySystemBackground),
        in: RoundedRectangle(cornerRadius: Radius.lg.value, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Radius.lg.value, style: .continuous)
          .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
      )
      .contentShape(RoundedRectangle(cornerRadius: Radius.lg.value, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}
