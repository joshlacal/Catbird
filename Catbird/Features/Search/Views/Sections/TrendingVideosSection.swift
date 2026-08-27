//
//  TrendingVideosSection.swift
//  Catbird
//
//  Explore Trending Videos carousel (G03).
//

import NukeUI
import Petrel
import SwiftUI

/// Horizontal carousel displaying trending videos loaded from the fixed `thevids` feed generator.
public struct TrendingVideosSection: View {
  public let videos: [AppBskyFeedDefs.FeedViewPost]
  public let onSelectPost: (AppBskyFeedDefs.PostView) -> Void
  public let onSeeAll: () -> Void

  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme

  public static let thevidsURI = "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/thevids"

  public init(
    videos: [AppBskyFeedDefs.FeedViewPost],
    onSelectPost: @escaping (AppBskyFeedDefs.PostView) -> Void,
    onSeeAll: @escaping () -> Void
  ) {
    self.videos = videos
    self.onSelectPost = onSelectPost
    self.onSeeAll = onSeeAll
  }

  public var body: some View {
    if !videos.isEmpty {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.base) {
        headerView
        carouselView
      }
    }
  }

  private var headerView: some View {
    HStack {
      HStack(spacing: 6) {
        Image(systemName: "play.rectangle.fill")
          .appFont(AppTextRole.subheadline)
          .foregroundColor(.accentColor)

        Text("Trending Videos")
          .appFont(.customSystemFont(size: 17, weight: .bold, width: 120, relativeTo: .headline))
      }

      Spacer()

      Button(action: onSeeAll) {
        HStack(spacing: 2) {
          Text("See All")
            .appFont(AppTextRole.subheadline)
            .fontWeight(.medium)
          Image(systemName: "chevron.right")
            .appFont(AppTextRole.caption)
        }
        .foregroundColor(.accentColor)
      }
    }
    .padding(.horizontal)
  }

  private var carouselView: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: 12) {
        ForEach(videos, id: \.post.uri) { feedViewPost in
          videoCard(feedViewPost.post)
        }
      }
      .padding(.horizontal)
    }
  }

  private func videoCard(_ post: AppBskyFeedDefs.PostView) -> some View {
    let thumbnailURL = extractVideoThumbnailURL(from: post)
    let altText = extractVideoAltText(from: post)
    let authorName = post.author.displayName ?? "@\(post.author.handle)"

    return Button {
      onSelectPost(post)
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        // Thumbnail with play icon overlay
        ZStack(alignment: .bottomTrailing) {
          if let url = thumbnailURL {
            LazyImage(url: url) { state in
              if let image = state.image {
                image
                  .resizable()
                  .aspectRatio(contentMode: .fill)
              } else if state.isLoading {
                Color.secondary.opacity(0.15)
                  .overlay(ProgressView())
              } else {
                fallbackThumbnail
              }
            }
            .frame(width: 160, height: 220)
            .clipped()
            .cornerRadius(12)
          } else {
            fallbackThumbnail
              .frame(width: 160, height: 220)
              .cornerRadius(12)
          }

          // Play icon pill
          HStack(spacing: 4) {
            Image(systemName: "play.fill")
              .font(.system(size: 10, weight: .bold))
            Text("Video")
              .font(.system(size: 10, weight: .semibold))
          }
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(.ultraThinMaterial)
          .cornerRadius(6)
          .padding(8)
        }

        // Author row
        HStack(spacing: 6) {
          if let avatarURL = post.author.avatar?.uriString(), let url = URL(string: avatarURL) {
            LazyImage(url: url) { state in
              if let image = state.image {
                image.resizable().aspectRatio(contentMode: .fill)
              } else {
                Circle().fill(Color.secondary.opacity(0.2))
              }
            }
            .frame(width: 20, height: 20)
            .clipShape(Circle())
          }

          Text(authorName)
            .appFont(AppTextRole.caption)
            .fontWeight(.medium)
            .lineLimit(1)
            .foregroundColor(.primary)
        }
        .frame(width: 160, alignment: .leading)
      }
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Video by \(authorName)\(altText.map { ", \($0)" } ?? "")")
    .accessibilityHint("Double tap to open post")
  }

  private var fallbackThumbnail: some View {
    Rectangle()
      .fill(Color.secondary.opacity(0.12))
      .overlay {
        Image(systemName: "play.rectangle")
          .font(.system(size: 32))
          .foregroundColor(.secondary)
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
