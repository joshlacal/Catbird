#if os(iOS)
import Foundation
import Petrel

// MARK: - Trending Interstitial Model

/// What the trending interstitial shows, derived from `TrendingFeedContent` and live app state:
/// trending settings, the moderation policy and each topic's moderated preview. Built inside observation tracking, so any of those changing
/// rebuilds it.
@MainActor
struct TrendingInterstitialModel {
  struct Topic {
    let trend: AppBskyUnspeccedDefs.TrendView
    let layout: TrendingInterstitialLayoutInput.Topic
    let symbol: String
    let tint: TrendingTopicCategoryStyle.Tint
    /// Decorative preview stills (at most three), already moderated.
    let media: [TrendingTopicPreview.Media]
    /// "Who is chatting" avatars, already moderated.
    let participants: [TrendingTopicPreview.Participant]
    /// `accessibilityElement(children: .combine)` over the card's visible text.
    let accessibilityLabel: String
  }

  struct VideoCard {
    enum Thumbnail: Equatable {
      /// Moderation covers the preview: show the cause, never request the image.
      case covered(title: String)
      case image(URL)
      case none
    }

    let post: AppBskyFeedDefs.PostView
    let uri: String
    let authorName: String
    let thumbnail: Thumbnail
    let accessibilityLabel: String
  }

  static let emptyVideosMessage = "No video previews right now. Pull to refresh, or open The Vids."

  let showTopics: Bool
  let showVideos: Bool
  let topics: [Topic]
  /// Previews the account's policy lets the carousel list.
  let videos: [AppBskyFeedDefs.FeedViewPost]
  let videosState: TrendingInterstitialLayoutInput.Videos
  let policy: ModerationPolicy

  static let empty = TrendingInterstitialModel(
    showTopics: false, showVideos: false, topics: [], videos: [], videosState: .hidden, policy: .failClosed)

  var hasContent: Bool { !topics.isEmpty || videosState != .hidden }

  static func make(content: TrendingFeedContent, appState: AppState) -> TrendingInterstitialModel {
    let showTopics = appState.appSettings.showTrendingTopics
    let showVideos = appState.appSettings.showTrendingVideos
    let policy = appState.moderationPolicy
    let topics = showTopics ? content.trends.prefix(6).map { topic(for: $0, appState: appState) } : []

    var videos: [AppBskyFeedDefs.FeedViewPost] = []
    var videosState = TrendingInterstitialLayoutInput.Videos.hidden
    if showVideos && !content.videos.isEmpty {
      videos = TrendingVideoModeration.listed(content.videos, policy: policy)
      videosState = videos.isEmpty ? .empty(message: emptyVideosMessage) : .cards(count: videos.count)
    }
    return TrendingInterstitialModel(
      showTopics: showTopics, showVideos: showVideos, topics: topics, videos: videos,
      videosState: videosState, policy: policy)
  }

  private static func topic(for trend: AppBskyUnspeccedDefs.TrendView, appState: AppState) -> Topic {
    // One evaluation gives both the media (the SwiftUI fan reads it without actors) and the
    // participants (trend actors first, then preview authors).
    let artwork = appState.topicArtwork(for: trend.link, actors: trend.actors)
    let categoryName = trend.category.map(TrendingTopicCategoryStyle.name(for:))
    let description = TrendingTopicPresentation.description(for: trend)
    let postCount = trend.postCount > 0 ? postCountText(trend.postCount) : nil
    let participants = artwork.participants ?? []
    return Topic(
      trend: trend,
      layout: .init(
        categoryName: categoryName, title: trend.displayName, description: description,
        postCountText: postCount, participantCount: participants.count),
      symbol: TrendingTopicCategoryStyle.symbol(for: trend.category),
      tint: TrendingTopicCategoryStyle.tint(for: trend.category),
      media: Array(artwork.preview.media.prefix(3)),
      participants: participants,
      accessibilityLabel: [categoryName, trend.displayName, description, postCount]
        .compactMap { $0 }.joined(separator: ", "))
  }

  /// "48K posts": compact notation, as the topic rows in Search.
  static func postCountText(_ count: Int) -> String {
    "\(count.formatted(.number.notation(.compactName))) posts"
  }

  /// One video card, as `TrendingVideosSection.videoCard` derives it.
  static func videoCard(for post: AppBskyFeedDefs.PostView, policy: ModerationPolicy) -> VideoCard {
    let cover = TrendingVideoModeration.thumbnailUI(for: post, policy: policy)
    let coverTitle = cover.blur ? ModerationPresentation.title(for: cover) : nil
    let altText = cover.blur ? nil : TrendingVideoModeration.videoAltText(in: post)
    let thumbnail: VideoCard.Thumbnail
    if let coverTitle {
      thumbnail = .covered(title: coverTitle)
    } else if let url = TrendingVideoModeration.videoThumbnailURL(in: post) {
      thumbnail = .image(url)
    } else {
      thumbnail = .none
    }
    let displayName = post.author.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let author = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? "@\(post.author.handle)"
    return VideoCard(
      post: post, uri: post.uri.uriString(), authorName: author, thumbnail: thumbnail,
      accessibilityLabel: "Video by \(author)\((coverTitle ?? altText).map { ", \($0)" } ?? "")")
  }

  func layoutInput(width: CGFloat, typography: TrendingInterstitialTypography) -> TrendingInterstitialLayoutInput {
    TrendingInterstitialLayoutInput(width: width, typography: typography, topics: topics.map(\.layout), videos: videosState)
  }
}
#endif
