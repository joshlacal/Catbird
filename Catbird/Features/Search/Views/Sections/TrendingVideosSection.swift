//
//  TrendingVideosSection.swift
//  Catbird
//

import Nuke
import NukeUI
import Petrel
import SwiftUI

/// Horizontal previews of The Vids; cards open the pager at the selected video.
public struct TrendingVideosSection: View {
  public enum Presentation {
    case timeline, discovery

    var width: CGFloat { self == .timeline ? 136 : 156 }
    var thumbnailHeight: CGFloat { self == .timeline ? 144 : 176 }
  }

  public let videos: [AppBskyFeedDefs.FeedViewPost]
  public let presentation: Presentation
  public let isLoading: Bool
  public let onSelectPost: (AppBskyFeedDefs.PostView) -> Void
  public let onSeeAll: () -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.fontManager) private var fontManager
  @ScaledMetric(relativeTo: .caption) private var authorLineHeight: CGFloat = 18

  public static let thevidsURI = VideoFeedView.thevidsURI

  public init(
    videos: [AppBskyFeedDefs.FeedViewPost],
    presentation: Presentation = .discovery,
    isLoading: Bool = false,
    onSelectPost: @escaping (AppBskyFeedDefs.PostView) -> Void,
    onSeeAll: @escaping () -> Void
  ) {
    self.videos = videos
    self.presentation = presentation
    self.isLoading = isLoading
    self.onSelectPost = onSelectPost
    self.onSeeAll = onSeeAll
  }

  private var cardWidth: CGFloat { dynamicTypeSize.isAccessibilitySize ? 208 : presentation.width }
  private var authorHeight: CGFloat {
    let lineHeight = (fontManager.dynamicTypeEnabled ? authorLineHeight : 18) * fontManager.sizeScale
    let lineSpacing = fontManager.getLineSpacing(for: Typography.Size.caption)
    return max(36, lineHeight * 2 + max(0, lineSpacing))
  }
  /// Small author avatar sized to the first caption line so the caption area keeps its height.
  private var authorAvatarSize: CGFloat {
    let lineHeight = (fontManager.dynamicTypeEnabled ? authorLineHeight : 18) * fontManager.sizeScale
    return min(24, max(16, lineHeight))
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      DiscoverySectionHeader(
        "Trending Videos",
        subtitle: presentation == .discovery ? "A preview of The Vids, Bluesky’s video feed." : nil
      ) {
        Button(action: onSeeAll) {
          Label("Open The Vids", systemImage: "chevron.right")
            .labelStyle(.titleAndIcon)
            .appFont(size: Typography.Size.subheadline, weight: .medium, relativeTo: .subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44)
        }
        .accessibilityHint("Open the full-screen Bluesky video feed")
      }
      if videos.isEmpty {
        HStack(spacing: DesignTokens.Spacing.md) {
          if isLoading { ProgressView() }
          Text(isLoading ? "Loading video previews…" : "No video previews right now. Pull to refresh, or open The Vids.")
            .appFont(AppTextRole.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(.horizontal, 16)
      } else {
        carouselView
      }
    }
  }

  private var carouselView: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(alignment: .top, spacing: DesignTokens.Spacing.base) {
        ForEach(videos, id: \.post.uri) { feedViewPost in
          videoCard(feedViewPost.post)
        }
      }
      .padding(.horizontal, 16)
    }
    // A lazy horizontal stack needs an explicit cross-axis size inside the timeline's self-sizing cell.
    // Reserve two scaled author lines from first layout; remote images cannot change the cell height.
    .frame(height: presentation.thumbnailHeight + DesignTokens.Spacing.sm + authorHeight)
  }

  private func videoCard(_ post: AppBskyFeedDefs.PostView) -> some View {
    let thumbnailURL = extractVideoThumbnailURL(from: post)
    let altText = extractVideoAltText(from: post)
    let authorName = post.author.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let author = authorName.flatMap { $0.isEmpty ? nil : $0 } ?? "@\(post.author.handle)"

    return Button { onSelectPost(post) } label: {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
        ZStack(alignment: .bottomLeading) {
          if let url = thumbnailURL {
            LazyImage(request: TrendingTopicImageRequests.request(url,
              size: CGSize(width: cardWidth, height: presentation.thumbnailHeight), priority: .normal)) { state in
              if let image = state.image {
                image.resizable().scaledToFill()
              } else if state.isLoading {
                Color.secondary.opacity(0.12)
              } else {
                fallbackThumbnail
              }
            }
            .pipeline(ImageLoadingManager.shared.pipeline)
          } else {
            fallbackThumbnail
          }
        }
        .frame(width: cardWidth, height: presentation.thumbnailHeight)
        .clipped()
        .overlay(alignment: .bottomLeading) {
          Image(systemName: "play.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(.black.opacity(0.65), in: Circle())
            .padding(8)
            .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Size.radiusMD))

        authorRow(post, name: author)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Video by \(author)\(altText.map { ", \($0)" } ?? "")")
    .accessibilityHint("Play this video in The Vids")
  }

  /// Small avatar beside the creator's name; the row keeps the fixed author height.
  private func authorRow(_ post: AppBskyFeedDefs.PostView, name: String) -> some View {
    HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
      AsyncProfileImage(
        url: post.author.finalAvatarURL(),
        size: authorAvatarSize,
        labels: post.author.labels
      )
      .accessibilityHidden(true)

      Text(name)
        .appFont(size: Typography.Size.caption, weight: .medium, relativeTo: .caption)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(width: cardWidth, height: authorHeight, alignment: .topLeading)
  }

  private var fallbackThumbnail: some View {
    Rectangle()
      .fill(Color.secondary.opacity(0.12))
      .overlay {
        Image(systemName: "play.rectangle")
          .font(.title2)
          .foregroundStyle(.secondary)
      }
  }

  private func extractVideoThumbnailURL(from post: AppBskyFeedDefs.PostView) -> URL? {
    if let embed = post.embed {
      switch embed {
      case .appBskyEmbedVideoView(let videoView):
        if let thumb = videoView.thumbnail?.uriString() {
          return URL(string: thumb)
        }
      case .appBskyEmbedRecordWithMediaView(let recordWithMedia):
        switch recordWithMedia.media {
        case .appBskyEmbedVideoView(let videoView):
          if let thumb = videoView.thumbnail?.uriString() {
            return URL(string: thumb)
          }
        default:
          break
        }
      default:
        break
      }
    }
    return nil
  }

  private func extractVideoAltText(from post: AppBskyFeedDefs.PostView) -> String? {
    if let embed = post.embed {
      switch embed {
      case .appBskyEmbedVideoView(let videoView):
        return videoView.alt
      case .appBskyEmbedRecordWithMediaView(let recordWithMedia):
        switch recordWithMedia.media {
        case .appBskyEmbedVideoView(let videoView):
          return videoView.alt
        default:
          break
        }
      default:
        break
      }
    }
    return nil
  }
}
